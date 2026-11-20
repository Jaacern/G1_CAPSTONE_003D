"""Administracion de cuentas, para el personal de Alloxentric.

QUE HACE
    - Listar y buscar usuarios, con su plan vigente.
    - Asignar un plan a una cuenta (free, premium o el que exista).
    - Desactivar y reactivar cuentas, con motivo.
    - Un resumen para decidir: cuantos usuarios hay, cuantos pagan, como
      se mueven las altas y las bajas.
    - Consultar el registro de acciones del personal.

REGLAS
    - Desactivar NO borra nada. Marca la cuenta, corta sus sesiones y
      conserva todo su historial (pacientes, dosis, suscripciones), que es
      lo que permite la analitica futura y responder un reclamo.
    - Una cuenta que el propio usuario elimino (deleted_at) no se
      reactiva desde aqui: fue una decision suya.
    - Nadie puede desactivarse a si mismo ni dejar a la empresa sin
      personal activo.
    - Cambiar un plan nunca edita la suscripcion anterior: la cierra y abre
      otra, para que el historial de cobros y la analitica de retencion
      sigan cuadrando. Sin suscripcion vigente la cuenta es gratuita, igual
      que en el resto de la API; por eso asignar un plan gratuito solo
      cierra la suscripcion de pago.
    - Toda accion queda en admin_audit_log dentro de la misma transaccion.
"""
from __future__ import annotations

import json
from datetime import datetime, timezone
from decimal import Decimal
from uuid import UUID, uuid4

from fastapi import APIRouter, Depends, Path, Query
from pydantic import BaseModel, Field, field_validator
from sqlalchemy import text
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from app.db import get_db
from app.deps import StaffUser, get_staff_user
from app.errors import ApiError

router = APIRouter(prefix="/api/v1/admin", tags=["admin-users"])

_USUARIO_NO_EXISTE = ApiError(
    status_code=404, code="NOT_FOUND", message="Ese usuario no existe."
)

# Plan vigente de cada usuario: suscripcion activa y no vencida; si hubiera
# mas de una, la de mayor jerarquia. Sin suscripcion no hay fila y la cuenta
# se trata como gratuita (misma regla que caregiver._plan_del_usuario).
_PLAN_EFECTIVO = """
    efectivo AS (
        SELECT DISTINCT ON (s.user_id)
               s.user_id, p.code, p.name, p.tier,
               s.current_period_end, s.source
          FROM subscriptions s
          JOIN plans p ON p.id = s.plan_id
         WHERE s.status = 'active'
           AND (s.current_period_end IS NULL OR s.current_period_end > now())
         ORDER BY s.user_id, p.tier DESC
    )
"""


def _texto(v: str) -> str:
    limpio = v.strip()
    if not limpio:
        raise ValueError("No puede ir vacio.")
    return limpio


def _estado(deleted_at, is_active) -> str:
    if deleted_at is not None:
        return "deleted"
    return "active" if is_active else "inactive"


async def _auditar(
    db: AsyncSession, actor_id: str, action: str, target_id: str, detail: dict
) -> None:
    await db.execute(
        text(
            """
            INSERT INTO admin_audit_log (actor_id, action, target_user_id, detail)
            VALUES (:a, :act, :t, CAST(:d AS jsonb))
            """
        ),
        {"a": actor_id, "act": action, "t": target_id,
         "d": json.dumps(detail, default=str)},
    )


# ---------------------------------------------------------------------------
# Listado
# ---------------------------------------------------------------------------
class UsuarioFila(BaseModel):
    user_id:      UUID
    email:        str
    full_name:    str
    account_type: str
    status:       str            # active | inactive | deleted
    plan_code:    str
    plan_name:    str
    is_staff:     bool
    created_at:   datetime


class UsuariosOut(BaseModel):
    items:  list[UsuarioFila]
    total:  int
    limit:  int
    offset: int


def _patron_busqueda(q: str) -> str:
    """Escapa % _ \\ para que el texto buscado se tome literal."""
    esc = q.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")
    return f"%{esc}%"


@router.get("/users", response_model=UsuariosOut)
async def listar_usuarios(
    q: str | None = Query(default=None, max_length=100),
    status: str = Query(default="all", pattern="^(all|active|inactive|deleted)$"),
    plan: str | None = Query(default=None, max_length=20),
    account_type: str | None = Query(
        default=None, pattern="^(family|caregiver|doctor|elder)$"),
    limit: int = Query(default=25, ge=1, le=100),
    offset: int = Query(default=0, ge=0),
    staff: StaffUser = Depends(get_staff_user),
    db: AsyncSession = Depends(get_db),
):
    """Usuarios con su plan vigente, mas nuevos primero."""
    filtros = ["TRUE"]
    params: dict = {"limit": limit, "offset": offset}

    if q and q.strip():
        filtros.append(
            "(u.email ILIKE :q ESCAPE '\\' OR u.full_name ILIKE :q ESCAPE '\\')"
        )
        params["q"] = _patron_busqueda(q.strip())
    if status == "active":
        filtros.append("u.is_active AND u.deleted_at IS NULL")
    elif status == "inactive":
        filtros.append("NOT u.is_active AND u.deleted_at IS NULL")
    elif status == "deleted":
        filtros.append("u.deleted_at IS NOT NULL")
    if plan:
        filtros.append("COALESCE(e.code, 'free') = :plan")
        params["plan"] = plan
    if account_type:
        filtros.append("u.account_type = :tipo")
        params["tipo"] = account_type

    filas = (
        await db.execute(
            text(
                f"""
                WITH {_PLAN_EFECTIVO}
                SELECT u.id AS user_id, u.email, u.full_name, u.account_type,
                       u.is_active, u.deleted_at, u.is_staff, u.created_at,
                       COALESCE(e.code, 'free')    AS plan_code,
                       COALESCE(e.name, 'Gratis')  AS plan_name,
                       count(*) OVER ()            AS total
                  FROM users u
                  LEFT JOIN efectivo e ON e.user_id = u.id
                 WHERE {' AND '.join(filtros)}
                 ORDER BY u.created_at DESC, u.id
                 LIMIT :limit OFFSET :offset
                """
            ),
            params,
        )
    ).mappings().all()

    total = int(filas[0]["total"]) if filas else 0
    if not filas and offset > 0:
        # Pagina fuera de rango: el total real hay que pedirlo aparte.
        total = int(
            (
                await db.execute(
                    text(
                        f"""
                        WITH {_PLAN_EFECTIVO}
                        SELECT count(*) FROM users u
                          LEFT JOIN efectivo e ON e.user_id = u.id
                         WHERE {' AND '.join(filtros)}
                        """
                    ),
                    params,
                )
            ).scalar() or 0
        )

    return UsuariosOut(
        items=[
            UsuarioFila(
                user_id=f["user_id"], email=f["email"], full_name=f["full_name"],
                account_type=f["account_type"],
                status=_estado(f["deleted_at"], f["is_active"]),
                plan_code=f["plan_code"], plan_name=f["plan_name"],
                is_staff=f["is_staff"], created_at=f["created_at"],
            )
            for f in filas
        ],
        total=total, limit=limit, offset=offset,
    )


# ---------------------------------------------------------------------------
# Detalle
# ---------------------------------------------------------------------------
class SuscripcionHist(BaseModel):
    id:                 UUID
    plan_code:          str
    plan_name:          str
    status:             str
    started_at:         datetime
    current_period_end: datetime | None
    cancelled_at:       datetime | None
    granted_by_name:    str | None
    change_reason:      str | None
    source:             str          # purchase | admin
    cancel_requested_at: datetime | None = None   # pidio no renovar


class PagoFila(BaseModel):
    type:        str
    status:      str
    amount:      Decimal | None
    currency:    str | None
    plan_name:   str
    provider_ref: str | None
    failure_reason: str | None
    occurred_at: datetime


class AuditoriaFila(BaseModel):
    id:         UUID
    action:     str
    actor_name: str
    target_name: str | None = None
    detail:     dict
    created_at: datetime

    @field_validator("detail", mode="before")
    @classmethod
    def _detail_json(cls, v):
        # Segun el driver, jsonb llega como texto o ya como dict.
        return json.loads(v) if isinstance(v, str) else (v or {})


class UsuarioDetalleOut(BaseModel):
    user_id:            UUID
    email:              str
    full_name:          str
    phone:              str | None
    account_type:       str
    status:             str
    is_staff:           bool
    created_at:         datetime
    deleted_at:         datetime | None
    deactivated_at:     datetime | None
    deactivated_reason: str | None
    deactivated_by_name: str | None
    pacientes:          int
    ultima_sesion:      datetime | None
    plan_code:          str
    plan_name:          str
    plan_vence:         datetime | None
    suscripciones:      list[SuscripcionHist]
    pagos:              list[PagoFila]
    auditoria:          list[AuditoriaFila]


@router.get("/users/{user_id}", response_model=UsuarioDetalleOut)
async def detalle_usuario(
    user_id: UUID = Path(...),
    staff: StaffUser = Depends(get_staff_user),
    db: AsyncSession = Depends(get_db),
):
    """Ficha de la cuenta: datos basicos, plan, historial y acciones del personal.

    No incluye nada clinico. El personal administra la cuenta, no ve
    expedientes; de los pacientes solo se informa cuantos hay.
    """
    u = (
        await db.execute(
            text(
                f"""
                WITH {_PLAN_EFECTIVO}
                SELECT u.id, u.email, u.full_name, u.phone, u.account_type,
                       u.is_active, u.is_staff, u.created_at, u.deleted_at,
                       u.deactivated_at, u.deactivated_reason,
                       db.full_name AS deactivated_by_name,
                       COALESCE(e.code, 'free')   AS plan_code,
                       COALESCE(e.name, 'Gratis') AS plan_name,
                       e.current_period_end       AS plan_vence,
                       (SELECT count(*) FROM patient_members pm
                         WHERE pm.user_id = u.id AND pm.removed_at IS NULL)
                                                  AS pacientes,
                       (SELECT max(rt.created_at) FROM refresh_tokens rt
                         WHERE rt.user_id = u.id) AS ultima_sesion
                  FROM users u
                  LEFT JOIN efectivo e ON e.user_id = u.id
                  LEFT JOIN users db   ON db.id = u.deactivated_by
                 WHERE u.id = :uid
                """
            ),
            {"uid": str(user_id)},
        )
    ).mappings().first()
    if u is None:
        raise _USUARIO_NO_EXISTE

    subs = (
        await db.execute(
            text(
                """
                SELECT s.id, p.code AS plan_code, p.name AS plan_name,
                       s.status, s.started_at, s.current_period_end,
                       s.cancelled_at, g.full_name AS granted_by_name,
                       s.change_reason, s.source, s.cancel_requested_at
                  FROM subscriptions s
                  JOIN plans p ON p.id = s.plan_id
                  LEFT JOIN users g ON g.id = s.granted_by
                 WHERE s.user_id = :uid
                 ORDER BY s.started_at DESC
                 LIMIT 50
                """
            ),
            {"uid": str(user_id)},
        )
    ).mappings().all()

    pagos = (
        await db.execute(
            text(
                """
                SELECT b.type, b.status, b.amount, b.currency, p.name AS plan_name,
                       b.provider_ref, b.failure_reason, b.occurred_at
                  FROM billing_events b
                  JOIN subscriptions s ON s.id = b.subscription_id
                  JOIN plans p ON p.id = s.plan_id
                 WHERE s.user_id = :uid
                 ORDER BY b.occurred_at DESC
                 LIMIT 30
                """
            ),
            {"uid": str(user_id)},
        )
    ).mappings().all()

    aud = (
        await db.execute(
            text(
                """
                SELECT a.id, a.action, ac.full_name AS actor_name,
                       a.detail, a.created_at
                  FROM admin_audit_log a
                  JOIN users ac ON ac.id = a.actor_id
                 WHERE a.target_user_id = :uid
                 ORDER BY a.created_at DESC
                 LIMIT 30
                """
            ),
            {"uid": str(user_id)},
        )
    ).mappings().all()

    return UsuarioDetalleOut(
        user_id=u["id"], email=u["email"], full_name=u["full_name"],
        phone=u["phone"], account_type=u["account_type"],
        status=_estado(u["deleted_at"], u["is_active"]),
        is_staff=u["is_staff"], created_at=u["created_at"],
        deleted_at=u["deleted_at"], deactivated_at=u["deactivated_at"],
        deactivated_reason=u["deactivated_reason"],
        deactivated_by_name=u["deactivated_by_name"],
        pacientes=u["pacientes"], ultima_sesion=u["ultima_sesion"],
        plan_code=u["plan_code"], plan_name=u["plan_name"],
        plan_vence=u["plan_vence"],
        suscripciones=[SuscripcionHist(**s) for s in subs],
        pagos=[PagoFila(**p) for p in pagos],
        auditoria=[AuditoriaFila(**a) for a in aud],
    )


# ---------------------------------------------------------------------------
# Asignar plan
# ---------------------------------------------------------------------------
class AsignarPlanIn(BaseModel):
    plan_code:   str = Field(min_length=3, max_length=20)
    # Vacio = sin fecha de termino (por ejemplo una cortesia indefinida).
    valid_until: datetime | None = None
    reason:      str = Field(min_length=3, max_length=200)

    _r = field_validator("reason")(_texto)


async def _usuario_vivo(db: AsyncSession, user_id: UUID):
    u = (
        await db.execute(
            text("SELECT id, is_active, deleted_at, is_staff FROM users "
                 "WHERE id = :uid FOR UPDATE"),
            {"uid": str(user_id)},
        )
    ).mappings().first()
    if u is None:
        raise _USUARIO_NO_EXISTE
    return u


@router.post("/users/{user_id}/plan", response_model=UsuarioDetalleOut)
async def asignar_plan(
    payload: AsignarPlanIn,
    user_id: UUID = Path(...),
    staff: StaffUser = Depends(get_staff_user),
    db: AsyncSession = Depends(get_db),
):
    """Deja a la cuenta en el plan indicado.

    Solo se puede asignar un plan activo: uno en borrador todavia no esta
    listo y uno archivado ya no se ofrece. Cierra la suscripcion vigente y,
    si el plan nuevo es de pago, abre otra. Todo en una transaccion: la
    base solo permite una suscripcion activa por usuario, asi que cerrar y
    abrir en pasos separados dejaria una ventana invalida.
    """
    u = await _usuario_vivo(db, user_id)
    if u["deleted_at"] is not None:
        raise ApiError(status_code=409, code="USUARIO_ELIMINADO",
                       message="La cuenta fue eliminada por su titular. "
                               "No se le puede asignar un plan.")

    plan = (
        await db.execute(
            text("SELECT id, code, name, tier, status FROM plans WHERE code = :c"),
            {"c": payload.plan_code},
        )
    ).mappings().first()
    if plan is None:
        raise ApiError(status_code=404, code="NOT_FOUND",
                       message="Ese plan no existe.")
    if plan["status"] != "active":
        raise ApiError(status_code=409, code="PLAN_NO_ASIGNABLE",
                       message="Solo se puede asignar un plan activo.")

    hasta = payload.valid_until
    if hasta is not None:
        if hasta.tzinfo is None:
            hasta = hasta.replace(tzinfo=timezone.utc)
        if hasta <= datetime.now(timezone.utc):
            raise ApiError(
                status_code=422, code="VALIDATION_ERROR",
                message="La fecha de termino debe ser futura.",
                details=[{"field": "valid_until",
                          "message": "Debe ser una fecha futura."}],
            )
    if plan["tier"] == 0:
        hasta = None  # el plan gratuito no vence
    elif hasta is None:
        # Una cortesia sin fin se vuelve premium gratis para siempre sin que
        # nadie lo haya decidido. El personal fija hasta cuando.
        raise ApiError(
            status_code=422, code="VALIDATION_ERROR",
            message="Un plan de pago otorgado a mano necesita fecha de termino.",
            details=[{"field": "valid_until",
                      "message": "Obligatoria para planes de pago."}],
        )

    anterior = (
        await db.execute(
            text(
                """
                SELECT s.id, p.code FROM subscriptions s
                  JOIN plans p ON p.id = s.plan_id
                 WHERE s.user_id = :uid AND s.status = 'active'
                """
            ),
            {"uid": str(user_id)},
        )
    ).mappings().first()

    if anterior is not None:
        await db.execute(
            text(
                """
                UPDATE subscriptions
                   SET status = 'cancelled', cancelled_at = now(),
                       change_reason = :r, updated_at = now()
                 WHERE id = :sid
                """
            ),
            {"sid": str(anterior["id"]), "r": payload.reason},
        )

    sub_evento = str(anterior["id"]) if anterior is not None else None
    if plan["tier"] > 0:
        try:
            sub_evento = str((
                await db.execute(
                    text(
                        """
                        INSERT INTO subscriptions
                            (user_id, plan_id, status, started_at,
                             current_period_end, granted_by, change_reason,
                             source)
                        VALUES (:uid, :pid, 'active', now(), :fin, :by, :r,
                                'admin')
                        RETURNING id
                        """
                    ),
                    {"uid": str(user_id), "pid": str(plan["id"]), "fin": hasta,
                     "by": staff.user_id, "r": payload.reason},
                )
            ).scalar())
        except IntegrityError:
            await db.rollback()
            raise ApiError(
                status_code=409, code="SUSCRIPCION_CONCURRENTE",
                message="La suscripcion cambio mientras la editabas. "
                        "Recarga la ficha e intenta de nuevo.",
            )

    if sub_evento is not None:
        # Sin monto: no es un cobro. Deja el cambio en la linea de tiempo de
        # facturacion, al lado de los cobros reales.
        await db.execute(
            text(
                """
                INSERT INTO billing_events
                    (subscription_id, type, status, provider_ref,
                     provider_event_id, occurred_at)
                VALUES (:sid, 'plan_changed', 'succeeded', :ref, :evt, now())
                """
            ),
            {"sid": sub_evento, "ref": f"admin:{staff.user_id}",
             "evt": f"admin-{uuid4()}"},
        )

    await _auditar(db, staff.user_id, "plan_assigned", str(user_id), {
        "from": anterior["code"] if anterior else "free",
        "to": plan["code"],
        "valid_until": hasta.isoformat() if hasta else None,
        "reason": payload.reason,
    })
    await db.commit()
    return await detalle_usuario(user_id, staff, db)


# ---------------------------------------------------------------------------
# Desactivar / reactivar
# ---------------------------------------------------------------------------
class DesactivarIn(BaseModel):
    reason: str = Field(min_length=3, max_length=200)

    _r = field_validator("reason")(_texto)


@router.post("/users/{user_id}/deactivate", response_model=UsuarioDetalleOut)
async def desactivar_usuario(
    payload: DesactivarIn,
    user_id: UUID = Path(...),
    staff: StaffUser = Depends(get_staff_user),
    db: AsyncSession = Depends(get_db),
):
    """Desactiva la cuenta sin borrar nada.

    Sus sesiones se cortan en el acto: get_current_user consulta is_active
    en cada peticion, y ademas se revocan los refresh tokens para que no
    pueda pedir uno nuevo. Pacientes, dosis y suscripciones quedan intactos.
    """
    if str(user_id) == staff.user_id:
        raise ApiError(status_code=409, code="AUTODESACTIVACION",
                       message="No puedes desactivar tu propia cuenta.")

    u = await _usuario_vivo(db, user_id)
    if u["deleted_at"] is not None:
        raise ApiError(status_code=409, code="USUARIO_ELIMINADO",
                       message="La cuenta ya fue eliminada por su titular.")
    if not u["is_active"]:
        raise ApiError(status_code=409, code="YA_DESACTIVADO",
                       message="La cuenta ya esta desactivada.")

    if u["is_staff"]:
        otros = (
            await db.execute(
                text(
                    """
                    SELECT count(*) FROM users
                     WHERE is_staff AND is_active AND deleted_at IS NULL
                       AND id <> :uid
                    """
                ),
                {"uid": str(user_id)},
            )
        ).scalar()
        if not otros:
            raise ApiError(status_code=409, code="ULTIMO_STAFF",
                           message="Es el unico miembro del personal activo. "
                                   "Dejarlo desactivado bloquearia el panel.")

    await db.execute(
        text(
            """
            UPDATE users
               SET is_active = false, deactivated_at = now(),
                   deactivated_reason = :r, deactivated_by = :by
             WHERE id = :uid
            """
        ),
        {"uid": str(user_id), "r": payload.reason, "by": staff.user_id},
    )
    await db.execute(
        text(
            """
            UPDATE refresh_tokens
               SET revoked_at = now(), revoked_reason = 'account_disabled'
             WHERE user_id = :uid AND revoked_at IS NULL
            """
        ),
        {"uid": str(user_id)},
    )
    await _auditar(db, staff.user_id, "user_deactivated", str(user_id),
                   {"reason": payload.reason})
    await db.commit()
    return await detalle_usuario(user_id, staff, db)


@router.post("/users/{user_id}/reactivate", response_model=UsuarioDetalleOut)
async def reactivar_usuario(
    user_id: UUID = Path(...),
    staff: StaffUser = Depends(get_staff_user),
    db: AsyncSession = Depends(get_db),
):
    """Devuelve el acceso a una cuenta desactivada por el personal."""
    u = await _usuario_vivo(db, user_id)
    if u["deleted_at"] is not None:
        raise ApiError(status_code=409, code="USUARIO_ELIMINADO",
                       message="La cuenta fue eliminada por su titular y no "
                               "se puede reactivar desde aqui.")
    if u["is_active"]:
        raise ApiError(status_code=409, code="YA_ACTIVO",
                       message="La cuenta ya esta activa.")

    await db.execute(
        text(
            """
            UPDATE users
               SET is_active = true, deactivated_at = NULL,
                   deactivated_reason = NULL, deactivated_by = NULL
             WHERE id = :uid
            """
        ),
        {"uid": str(user_id)},
    )
    await _auditar(db, staff.user_id, "user_reactivated", str(user_id), {})
    await db.commit()
    return await detalle_usuario(user_id, staff, db)


# ---------------------------------------------------------------------------
# Resumen
# ---------------------------------------------------------------------------
class PorPlan(BaseModel):
    plan_code: str
    plan_name: str
    tier:      int
    # purchase | admin. Un premium por cortesia se cuenta aparte del pagado.
    source:    str
    usuarios:  int


class PorMes(BaseModel):
    mes:   str        # YYYY-MM
    altas: int
    bajas: int


class ResumenOut(BaseModel):
    usuarios_total:     int
    usuarios_activos:   int
    usuarios_inactivos: int
    usuarios_eliminados: int
    por_tipo:           dict[str, int]
    por_plan:           list[PorPlan]
    # Porcentaje de cuentas activas con un plan de pago COMPRADO. Las
    # cortesias no cuentan. None si no hay cuentas.
    conversion_pct:     float | None
    # Cobros exitosos del mes (los reembolsos restan), segun billing_events.
    ingresos_mes:       Decimal
    moneda:             str
    cobros_mes:         int
    por_mes:            list[PorMes]


@router.get("/summary", response_model=ResumenOut)
async def resumen(
    staff: StaffUser = Depends(get_staff_user),
    db: AsyncSession = Depends(get_db),
):
    """Cifras para decidir: base de usuarios, mezcla de planes y movimiento.

    Las bajas son desactivaciones del personal y eliminaciones del titular.
    Las cuentas del personal no cuentan como usuarios.
    """
    base = (
        await db.execute(
            text(
                """
                SELECT count(*) AS total,
                       count(*) FILTER (WHERE is_active AND deleted_at IS NULL) AS activos,
                       count(*) FILTER (WHERE NOT is_active AND deleted_at IS NULL) AS inactivos,
                       count(*) FILTER (WHERE deleted_at IS NOT NULL) AS eliminados
                  FROM users WHERE NOT is_staff
                """
            )
        )
    ).mappings().first()

    tipos = (
        await db.execute(
            text(
                """
                SELECT account_type, count(*) AS n FROM users
                 WHERE NOT is_staff AND is_active AND deleted_at IS NULL
                 GROUP BY account_type
                """
            )
        )
    ).mappings().all()

    planes = (
        await db.execute(
            text(
                f"""
                WITH {_PLAN_EFECTIVO}
                SELECT COALESCE(e.code, 'free')          AS plan_code,
                       COALESCE(e.name, 'Gratis')        AS plan_name,
                       COALESCE(max(e.tier), 0)          AS tier,
                       COALESCE(e.source, 'purchase')    AS source,
                       count(*)                          AS usuarios
                  FROM users u
                  LEFT JOIN efectivo e ON e.user_id = u.id
                 WHERE NOT u.is_staff AND u.is_active AND u.deleted_at IS NULL
                 GROUP BY 1, 2, 4
                 ORDER BY 3, 4, 1
                """
            )
        )
    ).mappings().all()

    meses = (
        await db.execute(
            text(
                """
                WITH m AS (
                    SELECT date_trunc('month', now()) - make_interval(months => g) AS mes
                      FROM generate_series(0, 5) g
                )
                SELECT to_char(m.mes, 'YYYY-MM') AS mes,
                       (SELECT count(*) FROM users u
                         WHERE NOT u.is_staff
                           AND date_trunc('month', u.created_at) = m.mes) AS altas,
                       (SELECT count(*) FROM users u
                         WHERE NOT u.is_staff
                           AND date_trunc('month',
                                 COALESCE(u.deleted_at, u.deactivated_at)) = m.mes) AS bajas
                  FROM m ORDER BY m.mes
                """
            )
        )
    ).mappings().all()

    cobros = (
        await db.execute(
            text(
                """
                SELECT COALESCE(sum(amount), 0)          AS total,
                       COALESCE(max(currency), 'CLP')    AS moneda,
                       count(*) FILTER (WHERE type = 'charge' OR type = 'renewal')
                                                         AS n
                  FROM billing_events
                 WHERE status = 'succeeded' AND amount IS NOT NULL
                   AND occurred_at >= date_trunc('month', now())
                """
            )
        )
    ).mappings().first()

    activos = int(base["activos"])
    de_pago = sum(
        int(p["usuarios"]) for p in planes
        if p["tier"] > 0 and p["source"] == "purchase"
    )
    return ResumenOut(
        ingresos_mes=cobros["total"], moneda=cobros["moneda"],
        cobros_mes=int(cobros["n"]),
        usuarios_total=int(base["total"]),
        usuarios_activos=activos,
        usuarios_inactivos=int(base["inactivos"]),
        usuarios_eliminados=int(base["eliminados"]),
        por_tipo={t["account_type"]: int(t["n"]) for t in tipos},
        por_plan=[PorPlan(plan_code=p["plan_code"], plan_name=p["plan_name"],
                          tier=int(p["tier"]), source=p["source"],
                          usuarios=int(p["usuarios"])) for p in planes],
        conversion_pct=round(100.0 * de_pago / activos, 1) if activos else None,
        por_mes=[PorMes(mes=m["mes"], altas=int(m["altas"]), bajas=int(m["bajas"]))
                 for m in meses],
    )


# ---------------------------------------------------------------------------
# Registro de acciones
# ---------------------------------------------------------------------------
class AuditoriaOut(BaseModel):
    items: list[AuditoriaFila]


@router.get("/audit", response_model=AuditoriaOut)
async def listar_auditoria(
    limit: int = Query(default=50, ge=1, le=200),
    staff: StaffUser = Depends(get_staff_user),
    db: AsyncSession = Depends(get_db),
):
    """Las ultimas acciones del personal sobre cuentas."""
    filas = (
        await db.execute(
            text(
                """
                SELECT a.id, a.action, ac.full_name AS actor_name,
                       t.full_name AS target_name, a.detail, a.created_at
                  FROM admin_audit_log a
                  JOIN users ac ON ac.id = a.actor_id
                  LEFT JOIN users t ON t.id = a.target_user_id
                 ORDER BY a.created_at DESC
                 LIMIT :n
                """
            ),
            {"n": limit},
        )
    ).mappings().all()
    return AuditoriaOut(items=[AuditoriaFila(**f) for f in filas])
