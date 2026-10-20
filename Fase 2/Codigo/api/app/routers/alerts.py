"""Módulo 9: Alertas y notificaciones (endpoints 9.1–9.6).

Alineado con la Especificación de Endpoints v1. Usa las tablas existentes:
alerts, alert_deliveries, notification_settings, emergency_contacts,
sos_events. SQL crudo con text() y sesiones async, igual que los módulos 3
(auth.py) y 4 (patients.py). Sin ORM.

Notas de alcance / desviaciones respecto a la spec por el hito actual:
- El envío real de push/notificaciones NO se realiza en este hito. Los
  endpoints crean las alertas y los eventos en la base; la generación de
  filas en alert_deliveries y el envío por FCM/APNs se implementará después.
- Coherencia con los CHECK de alerts (ver 401_alerts.sql): al resolver una
  alerta que aún está 'active' (sin acknowledged_at) se setea también
  acknowledged_by/acknowledged_at, porque los constraints ck_alerts_status_ack
  y ck_alerts_order impiden resolver sin haber atendido antes.
"""
import json

from fastapi import APIRouter, Depends, Query
from pydantic import BaseModel, Field
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

from app.db import get_db
from app.deps import (
    CurrentUser,
    PatientContext,
    get_current_user,
    get_patient_member,
)
from app.errors import ApiError

router = APIRouter(prefix="/api/v1", tags=["alerts"])

# Los 5 tipos de alerta soportados (ck_alerts_type / ck_notification_settings_type).
ALERT_TYPES = ("fall", "vital_out_of_range", "missed_dose", "sos", "wearable_offline")
# Tipos críticos que no se pueden silenciar (ck_notification_settings_critical_locked).
LOCKED_ALERT_TYPES = ("fall", "sos")


# --------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------
def _parse_payload(value):
    """El payload de alerts es jsonb: puede llegar como dict o como str."""
    if value is None:
        return None
    if isinstance(value, str):
        try:
            return json.loads(value)
        except (ValueError, TypeError):
            return value
    return value


async def _membership_role(
    db: AsyncSession, patient_id: str, user_id: str
) -> str | None:
    """Rol vivo del usuario sobre el paciente, o None si no tiene membresía."""
    row = (
        await db.execute(
            text(
                """
                SELECT pm.role
                FROM patient_members pm
                JOIN patients p ON p.id = pm.patient_id
                WHERE pm.patient_id = :pid
                  AND pm.user_id = :uid
                  AND pm.removed_at IS NULL
                  AND p.deleted_at IS NULL
                """
            ),
            {"pid": patient_id, "uid": user_id},
        )
    ).mappings().first()
    return row["role"] if row else None


async def _load_alert_for_action(
    db: AsyncSession, alert_id: str, user: CurrentUser, allowed_roles: list[str]
) -> dict:
    """Carga la alerta y valida que el usuario tenga una membresía viva
    (con uno de los roles permitidos) sobre el paciente de la alerta.

    404 si la alerta no existe; 403 si no hay membresía o el rol no aplica.
    """
    alert = (
        await db.execute(
            text(
                """
                SELECT id, patient_id, status, acknowledged_at
                FROM alerts
                WHERE id = :aid
                """
            ),
            {"aid": alert_id},
        )
    ).mappings().first()

    if alert is None:
        raise ApiError(
            status_code=404,
            code="NOT_FOUND",
            message="El recurso solicitado no existe o no está disponible.",
        )

    role = await _membership_role(db, str(alert["patient_id"]), user.user_id)
    if role is None or role not in allowed_roles:
        raise ApiError(
            status_code=403,
            code="FORBIDDEN",
            message="No tienes permisos para realizar esta acción sobre este paciente.",
        )

    return alert


# --------------------------------------------------------------------------
# Schemas
# --------------------------------------------------------------------------
class AlertItem(BaseModel):
    alert_id: str
    patient_id: str
    patient_name: str
    type: str
    severity: str
    title: str
    detail: str | None = None
    payload: dict | list | None = None
    status: str
    created_at: str
    acknowledged_by: str | None = None
    resolved_at: str | None = None


class AlertsListOut(BaseModel):
    items: list[AlertItem]
    total: int
    unread_count: int


class AckOut(BaseModel):
    alert_id: str
    status: str


class ResolveIn(BaseModel):
    resolution_note: str | None = Field(default=None, max_length=500)


class NotificationSettingItem(BaseModel):
    alert_type: str
    push_enabled: bool
    is_locked: bool


class NotificationSettingsOut(BaseModel):
    items: list[NotificationSettingItem]


class NotificationSettingIn(BaseModel):
    alert_type: str
    push_enabled: bool


class NotificationSettingsIn(BaseModel):
    items: list[NotificationSettingIn]


class SosIn(BaseModel):
    note: str | None = Field(default=None, max_length=300)


class EmergencyContactOut(BaseModel):
    full_name: str
    phone: str
    role: str | None = None


class SosOut(BaseModel):
    alert_id: str
    notified_count: int
    emergency_contacts: list[EmergencyContactOut]


# --------------------------------------------------------------------------
# 9.1 Centro de alertas de todos mis pacientes
# --------------------------------------------------------------------------
@router.get("/users/me/alerts", response_model=AlertsListOut)
async def list_my_alerts(
    status: str = Query("active"),
    patient_id: str | None = Query(None),
    page: int = Query(1, ge=1),
    page_size: int = Query(20, ge=1, le=100),
    user: CurrentUser = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    if status not in ("active", "acknowledged", "resolved", "all"):
        raise ApiError(
            status_code=422,
            code="VALIDATION_ERROR",
            message="Hay datos inválidos en la solicitud. Revisa los campos marcados.",
        )

    # Filtro común: alertas de pacientes donde el usuario tiene membresía viva.
    where = [
        "pm.user_id = :uid",
        "pm.removed_at IS NULL",
        "p.deleted_at IS NULL",
    ]
    params: dict = {"uid": user.user_id}

    if status != "all":
        where.append("a.status = :status")
        params["status"] = status

    if patient_id is not None:
        where.append("a.patient_id = :pid")
        params["pid"] = patient_id

    where_sql = " AND ".join(where)

    # Total con el filtro aplicado (para la paginación).
    total = (
        await db.execute(
            text(
                f"""
                SELECT count(*)
                FROM alerts a
                JOIN patient_members pm ON pm.patient_id = a.patient_id
                JOIN patients p ON p.id = a.patient_id
                WHERE {where_sql}
                """
            ),
            params,
        )
    ).scalar_one()

    # unread_count: alertas activas de esos pacientes (independiente del filtro
    # de estado, pero respeta el filtro opcional de patient_id).
    unread_where = ["pm.user_id = :uid", "pm.removed_at IS NULL",
                    "p.deleted_at IS NULL", "a.status = 'active'"]
    unread_params: dict = {"uid": user.user_id}
    if patient_id is not None:
        unread_where.append("a.patient_id = :pid")
        unread_params["pid"] = patient_id

    unread_count = (
        await db.execute(
            text(
                f"""
                SELECT count(*)
                FROM alerts a
                JOIN patient_members pm ON pm.patient_id = a.patient_id
                JOIN patients p ON p.id = a.patient_id
                WHERE {' AND '.join(unread_where)}
                """
            ),
            unread_params,
        )
    ).scalar_one()

    page_params = dict(params)
    page_params["limit"] = page_size
    page_params["offset"] = (page - 1) * page_size

    rows = (
        await db.execute(
            text(
                f"""
                SELECT a.id, a.patient_id, p.full_name AS patient_name,
                       a.type, a.severity, a.title, a.detail, a.payload,
                       a.status, a.created_at, a.acknowledged_by, a.resolved_at
                FROM alerts a
                JOIN patient_members pm ON pm.patient_id = a.patient_id
                JOIN patients p ON p.id = a.patient_id
                WHERE {where_sql}
                ORDER BY a.created_at DESC
                LIMIT :limit OFFSET :offset
                """
            ),
            page_params,
        )
    ).mappings().all()

    items = [
        AlertItem(
            alert_id=str(r["id"]),
            patient_id=str(r["patient_id"]),
            patient_name=r["patient_name"],
            type=r["type"],
            severity=r["severity"],
            title=r["title"],
            detail=r["detail"],
            payload=_parse_payload(r["payload"]),
            status=r["status"],
            created_at=r["created_at"].isoformat(),
            acknowledged_by=str(r["acknowledged_by"]) if r["acknowledged_by"] else None,
            resolved_at=r["resolved_at"].isoformat() if r["resolved_at"] else None,
        )
        for r in rows
    ]

    return AlertsListOut(items=items, total=int(total), unread_count=int(unread_count))


# --------------------------------------------------------------------------
# 9.2 Marcar alerta como atendida
# --------------------------------------------------------------------------
@router.post("/alerts/{alert_id}/acknowledge", response_model=AckOut)
async def acknowledge_alert(
    alert_id: str,
    user: CurrentUser = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    alert = await _load_alert_for_action(
        db, alert_id, user, allowed_roles=["family", "caregiver"]
    )

    if alert["status"] != "active":
        raise ApiError(
            status_code=409,
            code="ALERT_ALREADY_CLOSED",
            message="La alerta ya fue atendida o resuelta.",
        )

    await db.execute(
        text(
            """
            UPDATE alerts
            SET status = 'acknowledged',
                acknowledged_by = :uid,
                acknowledged_at = now()
            WHERE id = :aid AND status = 'active'
            """
        ),
        {"uid": user.user_id, "aid": alert_id},
    )
    await db.commit()

    return AckOut(alert_id=alert_id, status="acknowledged")


# --------------------------------------------------------------------------
# 9.3 Resolver alerta
# --------------------------------------------------------------------------
@router.post("/alerts/{alert_id}/resolve", response_model=AckOut)
async def resolve_alert(
    alert_id: str,
    payload: ResolveIn,
    user: CurrentUser = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    alert = await _load_alert_for_action(
        db, alert_id, user, allowed_roles=["family", "caregiver"]
    )

    if alert["status"] == "resolved":
        raise ApiError(
            status_code=409,
            code="ALERT_ALREADY_CLOSED",
            message="La alerta ya fue atendida o resuelta.",
        )

    # Los CHECK ck_alerts_status_ack y ck_alerts_order impiden resolver sin
    # haber atendido: si la alerta sigue 'active' (acknowledged_at NULL),
    # registramos también quién/cuándo la atendió, en el mismo momento.
    if alert["acknowledged_at"] is None:
        await db.execute(
            text(
                """
                UPDATE alerts
                SET status = 'resolved',
                    acknowledged_by = :uid,
                    acknowledged_at = now(),
                    resolved_by = :uid,
                    resolved_at = now(),
                    resolution_note = :note
                WHERE id = :aid
                """
            ),
            {"uid": user.user_id, "aid": alert_id, "note": payload.resolution_note},
        )
    else:
        await db.execute(
            text(
                """
                UPDATE alerts
                SET status = 'resolved',
                    resolved_by = :uid,
                    resolved_at = now(),
                    resolution_note = :note
                WHERE id = :aid
                """
            ),
            {"uid": user.user_id, "aid": alert_id, "note": payload.resolution_note},
        )
    await db.commit()

    return AckOut(alert_id=alert_id, status="resolved")


# --------------------------------------------------------------------------
# 9.4 Obtener preferencias de notificación
# --------------------------------------------------------------------------
@router.get("/users/me/notification-settings", response_model=NotificationSettingsOut)
async def get_notification_settings(
    user: CurrentUser = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    rows = (
        await db.execute(
            text(
                """
                SELECT alert_type, push_enabled
                FROM notification_settings
                WHERE user_id = :uid
                """
            ),
            {"uid": user.user_id},
        )
    ).mappings().all()

    existing = {r["alert_type"]: r["push_enabled"] for r in rows}

    # Construimos el set completo de los 5 tipos; los faltantes default true.
    items = [
        NotificationSettingItem(
            alert_type=t,
            push_enabled=existing.get(t, True),
            is_locked=t in LOCKED_ALERT_TYPES,
        )
        for t in ALERT_TYPES
    ]
    return NotificationSettingsOut(items=items)


# --------------------------------------------------------------------------
# 9.5 Actualizar preferencias de notificación
# --------------------------------------------------------------------------
@router.put("/users/me/notification-settings", response_model=NotificationSettingsOut)
async def update_notification_settings(
    payload: NotificationSettingsIn,
    user: CurrentUser = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    for item in payload.items:
        if item.alert_type not in ALERT_TYPES:
            raise ApiError(
                status_code=422,
                code="VALIDATION_ERROR",
                message="Hay datos inválidos en la solicitud. Revisa los campos marcados.",
            )
        # Las alertas críticas (caída y SOS) no se pueden desactivar (RF-50).
        if item.alert_type in LOCKED_ALERT_TYPES and not item.push_enabled:
            raise ApiError(
                status_code=400,
                code="CRITICAL_ALERT_LOCKED",
                message="Las alertas de caída y SOS no pueden desactivarse.",
            )

    for item in payload.items:
        await db.execute(
            text(
                """
                INSERT INTO notification_settings (user_id, alert_type, push_enabled)
                VALUES (:uid, :atype, :enabled)
                ON CONFLICT (user_id, alert_type) DO UPDATE
                    SET push_enabled = EXCLUDED.push_enabled
                """
            ),
            {"uid": user.user_id, "atype": item.alert_type, "enabled": item.push_enabled},
        )
    await db.commit()

    return await get_notification_settings(user=user, db=db)


# --------------------------------------------------------------------------
# 9.6 Disparar SOS
# --------------------------------------------------------------------------
@router.post("/patients/{patient_id}/sos", response_model=SosOut, status_code=201)
async def trigger_sos(
    payload: SosIn,
    ctx: PatientContext = Depends(
        get_patient_member(roles=["caregiver", "elder"])
    ),
    db: AsyncSession = Depends(get_db),
):
    detail = payload.note or "Se activó el botón de emergencia del paciente."

    # Alerta crítica del SOS. NOTA: en este hito NO se envía push real; solo
    # se crea la alerta y el evento SOS. El fan-out a alert_deliveries y el
    # envío por FCM/APNs se implementará en un hito posterior.
    alert = (
        await db.execute(
            text(
                """
                INSERT INTO alerts
                    (patient_id, type, severity, title, detail, status, dedup_key)
                VALUES
                    (:pid, 'sos', 'critical', :title, :detail, 'active', 'sos')
                RETURNING id
                """
            ),
            {
                "pid": ctx.patient_id,
                "title": "Botón de emergencia activado",
                "detail": detail,
            },
        )
    ).mappings().first()
    alert_id = str(alert["id"])

    # Registro del evento SOS (UNIQUE sobre alert_id: uno por alerta).
    await db.execute(
        text(
            """
            INSERT INTO sos_events (patient_id, triggered_by, alert_id, note)
            VALUES (:pid, :uid, :aid, :note)
            """
        ),
        {
            "pid": ctx.patient_id,
            "uid": ctx.user.user_id,
            "aid": alert_id,
            "note": payload.note,
        },
    )

    # Familiares que serían notificados (miembros vivos con rol family).
    notified_count = (
        await db.execute(
            text(
                """
                SELECT count(*)
                FROM patient_members
                WHERE patient_id = :pid
                  AND role = 'family'
                  AND removed_at IS NULL
                """
            ),
            {"pid": ctx.patient_id},
        )
    ).scalar_one()

    # Contactos de emergencia, en orden de escalamiento.
    contact_rows = (
        await db.execute(
            text(
                """
                SELECT full_name, phone, relationship
                FROM emergency_contacts
                WHERE patient_id = :pid AND deleted_at IS NULL
                ORDER BY escalation_order
                """
            ),
            {"pid": ctx.patient_id},
        )
    ).mappings().all()

    await db.commit()

    contacts = [
        EmergencyContactOut(
            full_name=r["full_name"],
            phone=r["phone"],
            role=r["relationship"],
        )
        for r in contact_rows
    ]

    return SosOut(
        alert_id=alert_id,
        notified_count=int(notified_count),
        emergency_contacts=contacts,
    )
