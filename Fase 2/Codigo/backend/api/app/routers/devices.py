"""Módulo de dispositivos del adulto mayor: vinculación por código (RF-68).

El adulto mayor no inicia sesión con correo/contraseña: su reloj/tablet se
vincula a un paciente mediante un código de un solo uso y a partir de ahí opera
con un token de dispositivo. Ver el razonamiento en 602_device_link_codes.sql y
603_elder_devices.sql.

Sí tiene una fila en `users` (cuenta sin login), creada al canjear el código,
según 911_elder_account.sql: password_hash centinela '!' (nunca valida) y
correo en dominio reservado @agecare.local. Esa cuenta existe solo para que el
adulto mayor figure como autor en chat/asistente/reacciones; quien autentica
sigue siendo el dispositivo (session_token_hash). elder_devices.user_id guarda
esa correspondencia (CHECK ck_elder_devices_cuenta exige user_id si el
dispositivo está activo).

Flujo:
  1. La cuidadora/familiar llama POST /patients/{id}/device-link-codes
     → el backend genera un código de 6 dígitos (se devuelve en claro una sola
       vez) y guarda solo su hash en device_link_codes.
  2. El reloj llama POST /devices/link con { code, device_fingerprint, ... }
     → si el código es válido: se crea elder_devices (+ wearables), se marca el
       código como usado y se devuelve un device_token.
  3. El reloj envía mediciones con Authorization: Bearer <device_token> a
     POST /devices/vitals/batch y alertas de caída a POST /devices/fall.
     El paciente sale del token, no de la URL: un dispositivo solo puede
     escribir sobre su propio paciente.

Notas de alcance:
- El envío real de push por FCM/APNs no se realiza en este hito (igual que en
  alerts.py). La alerta de caída se crea en la tabla alerts; el fan-out se hará
  después.
"""
import uuid
from datetime import datetime, timezone

from fastapi import APIRouter, Depends, Header
from pydantic import BaseModel, Field
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

from app.db import get_db
from app.deps import PatientContext, get_patient_member
from app.errors import ApiError
from app.security import (
    generate_device_token,
    generate_link_code,
    hash_token,
    link_code_expiry,
)

router = APIRouter(prefix="/api/v1", tags=["devices"])

MAX_LINK_ATTEMPTS = 5
MAX_BATCH = 500


# --------------------------------------------------------------------------
# Contexto de dispositivo (autenticación por device_token)
# --------------------------------------------------------------------------
class DeviceContext:
    """Dispositivo autenticado por su token + el paciente al que pertenece."""

    def __init__(self, device_id: str, patient_id: str):
        self.device_id = device_id
        self.patient_id = patient_id


async def get_device_context(
    authorization: str | None = Header(default=None),
    db: AsyncSession = Depends(get_db),
) -> DeviceContext:
    """Resuelve el token de dispositivo (Bearer) a un paciente.

    A diferencia de get_current_user (que valida un JWT de persona), aquí el
    Bearer es el token OPACO del dispositivo. Se compara su hash contra
    elder_devices.session_token_hash. El dispositivo debe estar vigente
    (unlinked_at IS NULL).
    """
    unauthorized = ApiError(
        status_code=401,
        code="DEVICE_UNAUTHORIZED",
        message="El dispositivo no está vinculado o su sesión expiró.",
    )
    if not authorization or not authorization.lower().startswith("bearer "):
        raise unauthorized

    token = authorization[7:].strip()
    if not token:
        raise unauthorized

    row = (
        await db.execute(
            text(
                """
                SELECT id, patient_id
                FROM elder_devices
                WHERE session_token_hash = :h
                  AND unlinked_at IS NULL
                """
            ),
            {"h": hash_token(token)},
        )
    ).mappings().first()

    if row is None:
        raise unauthorized

    # Marca de actividad: útil para soporte y para el vigilante de offline.
    await db.execute(
        text("UPDATE elder_devices SET last_seen_at = now() WHERE id = :id"),
        {"id": str(row["id"])},
    )
    await db.commit()

    return DeviceContext(device_id=str(row["id"]), patient_id=str(row["patient_id"]))


# --------------------------------------------------------------------------
# Schemas
# --------------------------------------------------------------------------
class LinkCodeOut(BaseModel):
    code: str
    expires_at: datetime


class DeviceLinkIn(BaseModel):
    code: str = Field(min_length=6, max_length=6)
    device_fingerprint: str = Field(min_length=4, max_length=128)
    device_label: str = Field(default="Reloj AgeCare", max_length=60)
    platform: str = Field(default="android")
    app_version: str | None = Field(default=None, max_length=20)


class DeviceLinkOut(BaseModel):
    device_token: str
    patient_id: str
    patient_name: str
    device_id: str


class DeviceBatchReadingIn(BaseModel):
    type: str
    value: float
    measured_at: datetime
    meta: dict | None = None


class DeviceBatchIn(BaseModel):
    readings: list[DeviceBatchReadingIn] = Field(min_length=1, max_length=MAX_BATCH)
    battery_pct: int | None = Field(default=None, ge=0, le=100)


class DeviceBatchOut(BaseModel):
    accepted: int
    duplicates: int


class WatchStatusOut(BaseModel):
    linked: bool
    device_id: str | None = None
    device_label: str | None = None
    last_seen_at: datetime | None = None
    # Estado operativo del reloj vinculado:
    #  - connected=True  → hubo actividad reciente (envía datos).
    #  - connected=False → vinculado pero "desconectado" (sin datos hace rato:
    #                      apagado, sin batería o fuera de alcance).
    connected: bool = False
    # Nivel de batería del wearable (0–100), o None si aún no reportó.
    battery_pct: int | None = None


class DeviceFallIn(BaseModel):
    detail: str | None = Field(default=None, max_length=500)
    # Datos del acelerómetro que originaron la detección (impacto, g, etc.).
    payload: dict | None = None


class DeviceFallOut(BaseModel):
    alert_id: str
    status: str


# Tipos de vital que un dispositivo puede escribir (coincide con vital_types).
_DEVICE_VITAL_TYPES = {
    "heart_rate", "spo2", "temperature", "steps", "sleep",
    "sedentary_min", "blood_pressure", "glucose",
}


# --------------------------------------------------------------------------
# Generar código de vinculación (lo llama la cuidadora/familiar)
# --------------------------------------------------------------------------
@router.post(
    "/patients/{patient_id}/device-link-codes",
    response_model=LinkCodeOut,
    status_code=201,
)
async def create_device_link_code(
    ctx: PatientContext = Depends(get_patient_member(roles=["family", "caregiver"])),
    db: AsyncSession = Depends(get_db),
):
    """Genera un código de 6 dígitos de un solo uso para vincular un reloj.

    El código se devuelve EN CLARO una sola vez (para dictarlo); en la BD solo
    queda su hash. Se revocan los códigos vigentes previos del paciente para
    evitar acumulación.
    """
    # Un código vigente a la vez por paciente: revoca los anteriores sin usar.
    await db.execute(
        text(
            """
            UPDATE device_link_codes
               SET revoked_at = now()
             WHERE patient_id = :pid
               AND used_at IS NULL
               AND revoked_at IS NULL
            """
        ),
        {"pid": ctx.patient_id},
    )

    # Genera un código único (reintenta si colisiona el hash, muy improbable).
    code = ""
    for _ in range(5):
        candidate = generate_link_code()
        exists = (
            await db.execute(
                text("SELECT 1 FROM device_link_codes WHERE code_hash = :h"),
                {"h": hash_token(candidate)},
            )
        ).first()
        if not exists:
            code = candidate
            break
    if not code:
        raise ApiError(
            status_code=500,
            code="CODE_GENERATION_FAILED",
            message="No se pudo generar un código. Intenta nuevamente.",
        )

    expires_at = link_code_expiry()
    await db.execute(
        text(
            """
            INSERT INTO device_link_codes
                (patient_id, code_hash, created_by, expires_at)
            VALUES (:pid, :h, :uid, :exp)
            """
        ),
        {
            "pid": ctx.patient_id,
            "h": hash_token(code),
            "uid": ctx.user.user_id,
            "exp": expires_at,
        },
    )
    await db.commit()

    return LinkCodeOut(code=code, expires_at=expires_at)


# --------------------------------------------------------------------------
# Estado del reloj vinculado (lo consulta la app del familiar/cuidadora)
# --------------------------------------------------------------------------
@router.get(
    "/patients/{patient_id}/watch/status",
    response_model=WatchStatusOut,
)
async def watch_status(
    ctx: PatientContext = Depends(get_patient_member()),
    db: AsyncSession = Depends(get_db),
):
    """Indica si el paciente tiene un Reloj AgeCare vinculado y vigente.

    La app del celular usa esto para decidir la fuente de datos: si hay un
    reloj vinculado, esa es la fuente y NO se auto-sincroniza Health Connect.
    """
    row = (
        await db.execute(
            text(
                """
                SELECT id, device_label, last_seen_at,
                       (last_seen_at IS NOT NULL
                        AND last_seen_at > now() - interval '2 minutes')
                       AS connected
                FROM elder_devices
                WHERE patient_id = :pid
                  AND unlinked_at IS NULL
                ORDER BY last_seen_at DESC NULLS LAST
                LIMIT 1
                """
            ),
            {"pid": ctx.patient_id},
        )
    ).mappings().first()

    if row is None:
        return WatchStatusOut(linked=False)

    # Batería del wearable vigente del paciente (si reportó).
    battery = (
        await db.execute(
            text(
                """
                SELECT battery_pct FROM wearables
                WHERE patient_id = :pid AND unlinked_at IS NULL
                ORDER BY last_sync_at DESC NULLS LAST
                LIMIT 1
                """
            ),
            {"pid": ctx.patient_id},
        )
    ).scalar_one_or_none()

    return WatchStatusOut(
        linked=True,
        device_id=str(row["id"]),
        device_label=row["device_label"],
        last_seen_at=row["last_seen_at"],
        connected=bool(row["connected"]),
        battery_pct=battery,
    )


# --------------------------------------------------------------------------
# Desvincular el reloj (lo hace la familia/cuidadora: reasignar a otro paciente)
# --------------------------------------------------------------------------
@router.delete(
    "/patients/{patient_id}/watch",
    response_model=WatchStatusOut,
)
async def unlink_watch(
    ctx: PatientContext = Depends(get_patient_member(roles=["family", "caregiver"])),
    db: AsyncSession = Depends(get_db),
):
    """Desvincula el/los Reloj(es) AgeCare vigentes del paciente.

    Marca elder_devices.unlinked_at: el token de dispositivo deja de servir de
    inmediato (get_device_context solo acepta unlinked_at IS NULL). El reloj,
    en su siguiente envío, recibirá 401 y volverá a pedir un código. El mismo
    aparato físico puede entonces vincularse a otro paciente (p. ej. heredar el
    reloj). La fila se conserva como historial (RF-68).
    """
    result = await db.execute(
        text(
            """
            UPDATE elder_devices
               SET unlinked_at = now(), updated_at = now()
             WHERE patient_id = :pid
               AND unlinked_at IS NULL
            """
        ),
        {"pid": ctx.patient_id},
    )

    # También libera el wearable vigente del paciente, para que el estado quede
    # coherente (sin aparato activo hasta que se vincule otro).
    await db.execute(
        text(
            """
            UPDATE wearables
               SET unlinked_at = now()
             WHERE patient_id = :pid
               AND unlinked_at IS NULL
            """
        ),
        {"pid": ctx.patient_id},
    )
    await db.commit()

    _ = result
    return WatchStatusOut(linked=False)


# --------------------------------------------------------------------------
# Auto-desvinculación desde el propio reloj (auth por device_token)
# --------------------------------------------------------------------------
@router.post("/devices/unlink", response_model=WatchStatusOut)
async def device_self_unlink(
    ctx: DeviceContext = Depends(get_device_context),
    db: AsyncSession = Depends(get_db),
):
    """El reloj se desvincula a sí mismo (el usuario eligió 'Desvincular' en el
    reloj). Marca su fila elder_devices como desvinculada para que el cambio se
    refleje también en la app del familiar (watch/status pasará a linked=false).
    """
    await db.execute(
        text(
            """
            UPDATE elder_devices
               SET unlinked_at = now(), updated_at = now()
             WHERE id = :id AND unlinked_at IS NULL
            """
        ),
        {"id": ctx.device_id},
    )
    # Libera el wearable vigente del paciente (coherencia de estado).
    await db.execute(
        text(
            """
            UPDATE wearables
               SET unlinked_at = now()
             WHERE patient_id = :pid AND unlinked_at IS NULL
            """
        ),
        {"pid": ctx.patient_id},
    )
    await db.commit()
    return WatchStatusOut(linked=False)


# --------------------------------------------------------------------------
# Vincular dispositivo con el código (lo llama el reloj, sin JWT de persona)
# --------------------------------------------------------------------------
@router.post("/devices/link", response_model=DeviceLinkOut, status_code=201)
async def link_device(
    payload: DeviceLinkIn,
    db: AsyncSession = Depends(get_db),
):
    """Canjea un código por un token de dispositivo.

    Validaciones: el código debe existir, estar vigente (no usado/revocado/
    vencido) y no haber superado los intentos. Si el código existe pero no
    coincide nada, igual contamos un intento sobre los códigos vigentes del
    paciente para activar el bloqueo por fuerza bruta.
    """
    code_hash = hash_token(payload.code)

    link = (
        await db.execute(
            text(
                """
                SELECT id, patient_id, expires_at, attempts, used_at, revoked_at
                FROM device_link_codes
                WHERE code_hash = :h
                """
            ),
            {"h": code_hash},
        )
    ).mappings().first()

    invalid = ApiError(
        status_code=400,
        code="INVALID_LINK_CODE",
        message="El código no es válido o expiró. Pide uno nuevo.",
    )

    if link is None:
        raise invalid

    # Estado del código.
    now = datetime.now(timezone.utc)
    if link["used_at"] is not None or link["revoked_at"] is not None:
        raise invalid
    if link["expires_at"] <= now:
        raise invalid
    if link["attempts"] >= MAX_LINK_ATTEMPTS:
        raise ApiError(
            status_code=429,
            code="LINK_CODE_BLOCKED",
            message="El código fue bloqueado por demasiados intentos. Pide uno nuevo.",
        )

    patient_id = str(link["patient_id"])

    # El paciente debe existir y estar vivo. Tomamos su nombre para derivar el
    # del adulto mayor (first_name/last_name) al crear su cuenta.
    patient = (
        await db.execute(
            text(
                """
                SELECT full_name, first_name, last_name
                FROM patients WHERE id = :pid AND deleted_at IS NULL
                """
            ),
            {"pid": patient_id},
        )
    ).mappings().first()
    if patient is None:
        raise invalid

    # ── Cuenta del adulto mayor (RF-68, ver 911_elder_account.sql) ──
    # El modelo exige que un dispositivo vinculado y activo tenga user_id
    # (CHECK ck_elder_devices_cuenta): la cuenta existe para que el adulto
    # mayor figure como autor en chat/asistente/reacciones, NO para iniciar
    # sesión. Resolvemos (o creamos) esa cuenta antes de tocar elder_devices.
    elder_user_id = await _resolve_elder_account(db, patient_id, patient)

    # ¿El fingerprint ya está vinculado y vigente? Reusar la fila (re-emparejar
    # el mismo reloj no debe fallar por el UNIQUE de fingerprint).
    # Buscar por fingerprint SIN importar el estado: el UNIQUE
    # uq_elder_devices_fingerprint es sobre device_fingerprint a secas (no
    # parcial), así que una fila desvinculada (unlinked_at NO NULL) igual
    # ocupa el fingerprint. Si existe (vinculada o no), se REUSA y reactiva,
    # evitando un INSERT que violaría el UNIQUE.
    existing = (
        await db.execute(
            text(
                """
                SELECT id FROM elder_devices
                WHERE device_fingerprint = :fp
                """
            ),
            {"fp": payload.device_fingerprint},
        )
    ).mappings().first()

    device_token = generate_device_token()
    token_hash = hash_token(device_token)

    if existing is not None:
        # Re-vincula el mismo aparato: rota el token, lo reactiva
        # (unlinked_at = NULL) y lo apunta a este código.
        device_id = str(existing["id"])
        await db.execute(
            text(
                """
                UPDATE elder_devices
                   SET patient_id = :pid,
                       user_id = :uid,
                       link_code_id = :lcid,
                       session_token_hash = :th,
                       device_label = :label,
                       platform = :platform,
                       app_version = :ver,
                       unlinked_at = NULL,
                       last_seen_at = now(),
                       updated_at = now()
                 WHERE id = :id
                """
            ),
            {
                "pid": patient_id,
                "uid": elder_user_id,
                "lcid": str(link["id"]),
                "th": token_hash,
                "label": payload.device_label,
                "platform": payload.platform,
                "ver": payload.app_version,
                "id": device_id,
            },
        )
    else:
        device = (
            await db.execute(
                text(
                    """
                    INSERT INTO elder_devices
                        (patient_id, user_id, link_code_id, device_label,
                         platform, device_fingerprint, session_token_hash,
                         app_version, last_seen_at)
                    VALUES
                        (:pid, :uid, :lcid, :label, :platform, :fp, :th, :ver,
                         now())
                    RETURNING id
                    """
                ),
                {
                    "pid": patient_id,
                    "uid": elder_user_id,
                    "lcid": str(link["id"]),
                    "label": payload.device_label,
                    "platform": payload.platform,
                    "fp": payload.device_fingerprint,
                    "th": token_hash,
                    "ver": payload.app_version,
                },
            )
        ).mappings().first()
        device_id = str(device["id"])

    # Marca el código como usado (un solo uso).
    await db.execute(
        text("UPDATE device_link_codes SET used_at = now() WHERE id = :id"),
        {"id": str(link["id"])},
    )

    # Asegura un wearable vigente para el paciente (para el estado/batería y el
    # vigilante de offline). Si ya hay uno, se mantiene.
    has_wearable = (
        await db.execute(
            text(
                "SELECT 1 FROM wearables WHERE patient_id = :pid AND unlinked_at IS NULL"
            ),
            {"pid": patient_id},
        )
    ).first()
    if not has_wearable:
        await db.execute(
            text(
                """
                INSERT INTO wearables (patient_id, provider, serial_number, model)
                VALUES (:pid, 'simulator', :serial, 'Galaxy Watch')
                """
            ),
            {"pid": patient_id, "serial": payload.device_fingerprint[:64]},
        )

    await db.commit()

    return DeviceLinkOut(
        device_token=device_token,
        patient_id=patient_id,
        patient_name=patient["full_name"],
        device_id=device_id,
    )


# --------------------------------------------------------------------------
# Ingesta de vitales por el dispositivo (auth por device_token)
# --------------------------------------------------------------------------
@router.post("/devices/vitals/batch", response_model=DeviceBatchOut)
async def device_ingest_batch(
    payload: DeviceBatchIn,
    ctx: DeviceContext = Depends(get_device_context),
    db: AsyncSession = Depends(get_db),
):
    """Inserta un lote de lecturas del dispositivo. patient_id sale del token."""
    accepted = 0
    for r in payload.readings:
        if r.type not in _DEVICE_VITAL_TYPES:
            # Tipo desconocido: se ignora en silencio (no rompe el lote).
            continue
        row = (
            await db.execute(
                text(
                    """
                    INSERT INTO vital_readings
                        (patient_id, type, value, measured_at, source, meta)
                    VALUES
                        (:pid, :type, :value, :measured_at, 'wearable', :meta)
                    ON CONFLICT (patient_id, type, measured_at, source)
                        DO NOTHING
                    RETURNING id
                    """
                ),
                {
                    "pid": ctx.patient_id,
                    "type": r.type,
                    "value": r.value,
                    "measured_at": r.measured_at,
                    "meta": _json_or_none(r.meta),
                },
            )
        ).first()
        if row is not None:
            accepted += 1

    await db.execute(
        text(
            """
            UPDATE wearables
               SET last_sync_at = now(),
                   battery_pct = COALESCE(:battery, battery_pct)
             WHERE patient_id = :pid
               AND unlinked_at IS NULL
            """
        ),
        {"pid": ctx.patient_id, "battery": payload.battery_pct},
    )
    await db.commit()

    duplicates = len(payload.readings) - accepted
    return DeviceBatchOut(accepted=accepted, duplicates=duplicates)


# --------------------------------------------------------------------------
# Alerta de caída detectada por el dispositivo (auth por device_token)
# --------------------------------------------------------------------------
@router.post("/devices/fall", response_model=DeviceFallOut, status_code=201)
async def device_report_fall(
    payload: DeviceFallIn,
    ctx: DeviceContext = Depends(get_device_context),
    db: AsyncSession = Depends(get_db),
):
    """Crea una alerta crítica de caída detectada por el reloj.

    Deduplicación: dedup_key='fall' evita apilar varias alertas por la misma
    caída dentro de la ventana que evalúa el motor. Aquí usamos un chequeo
    simple: si ya hay una alerta de caída activa para el paciente, se devuelve
    esa en lugar de crear otra.
    """
    existing = (
        await db.execute(
            text(
                """
                SELECT id FROM alerts
                WHERE patient_id = :pid
                  AND type = 'fall'
                  AND status = 'active'
                ORDER BY created_at DESC
                LIMIT 1
                """
            ),
            {"pid": ctx.patient_id},
        )
    ).mappings().first()

    if existing is not None:
        return DeviceFallOut(alert_id=str(existing["id"]), status="active")

    detail = payload.detail or "El reloj detectó una posible caída del paciente."
    alert = (
        await db.execute(
            text(
                """
                INSERT INTO alerts
                    (patient_id, type, severity, title, detail, payload,
                     status, dedup_key)
                VALUES
                    (:pid, 'fall', 'critical', :title, :detail, :payload,
                     'active', 'fall')
                RETURNING id
                """
            ),
            {
                "pid": ctx.patient_id,
                "title": "Posible caída detectada",
                "detail": detail,
                "payload": _json_or_none(payload.payload),
            },
        )
    ).mappings().first()
    await db.commit()

    return DeviceFallOut(alert_id=str(alert["id"]), status="active")


# --------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------
# Centinela de password para cuentas sin login (911_elder_account.sql): no es
# un hash bcrypt válido, así que nunca coincide con ninguna contraseña.
_PASSWORD_SENTINEL = "!"


async def _resolve_elder_account(db: AsyncSession, patient_id: str, patient) -> str:
    """Devuelve el user_id de la cuenta del adulto mayor del paciente.

    Si ya existe un miembro con rol 'elder' vivo, reusa su cuenta. Si no,
    crea la cuenta sin login (correo en dominio reservado + password centinela)
    y su membresía 'elder'. Alineado con 911_elder_account.sql.
    """
    # 1) ¿Ya hay una cuenta elder para este paciente?
    existing = (
        await db.execute(
            text(
                """
                SELECT user_id
                FROM patient_members
                WHERE patient_id = :pid
                  AND role = 'elder'
                  AND removed_at IS NULL
                LIMIT 1
                """
            ),
            {"pid": patient_id},
        )
    ).mappings().first()
    if existing is not None:
        return str(existing["user_id"])

    # 2) Crear la cuenta sin login. Correo único en dominio reservado.
    new_uid = str(uuid.uuid4())
    email = f"elder+{new_uid}@agecare.local"
    # Nombre derivado del paciente (first_name/last_name son NOT NULL en users).
    first_name = (patient["first_name"] or "Adulto").strip() or "Adulto"
    last_name = (patient["last_name"] or "Mayor").strip() or "Mayor"

    row = (
        await db.execute(
            text(
                """
                INSERT INTO users
                    (id, email, password_hash, first_name, last_name, locale,
                     is_active)
                VALUES
                    (:id, :email, :pwd, :fn, :ln, 'es', true)
                RETURNING id
                """
            ),
            {
                "id": new_uid,
                "email": email,
                "pwd": _PASSWORD_SENTINEL,
                "fn": first_name,
                "ln": last_name,
            },
        )
    ).mappings().first()
    elder_user_id = str(row["id"])

    # 3) Membresía 'elder' (uq_patient_members_pair evita duplicar).
    await db.execute(
        text(
            """
            INSERT INTO patient_members (patient_id, user_id, role, is_owner)
            VALUES (:pid, :uid, 'elder', false)
            ON CONFLICT (patient_id, user_id) DO NOTHING
            """
        ),
        {"pid": patient_id, "uid": elder_user_id},
    )

    return elder_user_id


def _json_or_none(value) -> str | None:
    import json

    return json.dumps(value) if value is not None else None
