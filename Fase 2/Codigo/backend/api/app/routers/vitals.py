"""Módulo 5: Vitals y resumen del día / semáforo (endpoints 5.1–5.8).

Cambios 2FN aplicados:
- UNITS dict eliminado: la unidad se lee desde vital_types.unit (fuente única de verdad).
- scheduled_doses ya no tiene patient_id: las consultas hacen JOIN medications.
- alerts.update_at → updated_at (typo corregido en BD).
"""
import json
import uuid
from datetime import date, datetime, timezone
from enum import Enum

from fastapi import APIRouter, Depends, Query
from pydantic import BaseModel, Field
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

from app.db import get_db
from app.deps import CurrentUser, PatientContext, get_current_user, get_patient_member
from app.errors import ApiError

router = APIRouter(prefix="/api/v1", tags=["vitals"])


# --------------------------------------------------------------------------
# Enums
# --------------------------------------------------------------------------
class VitalType(str, Enum):
    heart_rate    = "heart_rate"
    spo2          = "spo2"
    sleep         = "sleep"
    steps         = "steps"
    sedentary_min = "sedentary_min"
    fall_event    = "fall_event"
    blood_pressure= "blood_pressure"
    temperature   = "temperature"
    glucose       = "glucose"


class ManualVitalType(str, Enum):
    """Subconjunto de tipos que la cuidadora puede registrar a mano (5.2)."""
    blood_pressure = "blood_pressure"
    temperature    = "temperature"
    glucose        = "glucose"
    heart_rate     = "heart_rate"
    spo2           = "spo2"


class Granularity(str, Enum):
    raw  = "raw"
    hour = "hour"
    day  = "day"
    week = "week"


# UNITS dict eliminado: la unidad ahora viene de vital_types.unit (tabla catálogo).
# Se mantiene un fallback en memoria para no romper si la BD no está disponible
# durante tests unitarios sin BD.
_UNITS_FALLBACK: dict[str, str] = {
    "heart_rate": "bpm", "spo2": "%", "sleep": "h", "steps": "pasos",
    "sedentary_min": "min", "fall_event": "", "blood_pressure": "mmHg",
    "temperature": "°C", "glucose": "mg/dL",
}

MAX_BATCH      = 500
MAX_RANGE_DAYS = 92

_TRUNC_UNIT = {
    Granularity.hour: "hour",
    Granularity.day:  "day",
    Granularity.week: "week",
}


# --------------------------------------------------------------------------
# Schemas
# --------------------------------------------------------------------------
class BatchReadingIn(BaseModel):
    type: VitalType
    value: float
    measured_at: datetime
    meta: dict | None = None


class BatchIn(BaseModel):
    readings: list[BatchReadingIn] = Field(min_length=1, max_length=MAX_BATCH)


class BatchOut(BaseModel):
    accepted: int
    duplicates: int
    alerts_triggered: int


class ManualIn(BaseModel):
    type: ManualVitalType
    value: float
    value_secondary: float | None = None
    measured_at: datetime | None = None
    note: str | None = None


class ManualOut(BaseModel):
    reading_id: str
    alert_triggered: bool = False


class SeriesPoint(BaseModel):
    ts: datetime
    value: float | None
    min: float | None = None
    max: float | None = None


class ThresholdOut(BaseModel):
    type: str
    min_value: float | None
    max_value: float | None
    updated_by: str | None
    updated_at: datetime | None


class SeriesOut(BaseModel):
    type: str
    unit: str
    points: list[SeriesPoint]
    threshold: ThresholdOut | None


class LatestItem(BaseModel):
    type: str
    value: float
    unit: str
    measured_at: datetime
    in_range: bool


class LatestOut(BaseModel):
    items: list[LatestItem]


class ThresholdsOut(BaseModel):
    items: list[ThresholdOut]


class ThresholdIn(BaseModel):
    min_value: float | None = None
    max_value: float | None = None


class MedicationsToday(BaseModel):
    taken: int
    pending: int
    missed: int
    next_dose: datetime | None


class SummaryTodayOut(BaseModel):
    wellbeing_status: str
    status_reasons: list[str]
    active_alerts: list[dict]
    latest_vitals: list[LatestItem]
    medications_today: MedicationsToday
    last_observation: None = None


class DashboardItem(BaseModel):
    patient_id: str
    full_name: str
    photo_url: str | None
    wellbeing_status: str
    active_alerts_count: int
    top_reason: str | None


class DashboardOut(BaseModel):
    items: list[DashboardItem]


# --------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------
def _in_range(value: float, min_value, max_value) -> bool:
    if min_value is not None and value < float(min_value):
        return False
    if max_value is not None and value > float(max_value):
        return False
    return True


async def _get_unit(db: AsyncSession, vital_type: str) -> str:
    """Lee la unidad desde vital_types (catálogo normalizado).
    Cae al fallback en memoria si la fila no existe."""
    row = (
        await db.execute(
            text("SELECT unit FROM vital_types WHERE code = :code"),
            {"code": vital_type},
        )
    ).first()
    return row[0] if row else _UNITS_FALLBACK.get(vital_type, "")


async def _load_thresholds_map(db: AsyncSession, patient_id: str) -> dict[str, dict]:
    """Umbrales del paciente indexados por tipo."""
    rows = (
        await db.execute(
            text(
                """
                SELECT type, min_value, max_value, updated_by, updated_at
                FROM vital_thresholds
                WHERE patient_id = :pid
                """
            ),
            {"pid": patient_id},
        )
    ).mappings().all()
    return {r["type"]: dict(r) for r in rows}


async def _latest_items(db: AsyncSession, patient_id: str) -> list[LatestItem]:
    """Últimos valores por tipo (comparados contra umbrales)."""
    rows = (
        await db.execute(
            text(
                """
                SELECT DISTINCT ON (type) type, value, measured_at
                FROM vital_readings
                WHERE patient_id = :pid
                ORDER BY type, measured_at DESC
                """
            ),
            {"pid": patient_id},
        )
    ).mappings().all()

    thresholds = await _load_thresholds_map(db, patient_id)
    items: list[LatestItem] = []
    for r in rows:
        th = thresholds.get(r["type"])
        in_range = True
        if th is not None:
            in_range = _in_range(float(r["value"]), th["min_value"], th["max_value"])
        items.append(
            LatestItem(
                type=r["type"],
                value=float(r["value"]),
                unit=await _get_unit(db, r["type"]),
                measured_at=r["measured_at"],
                in_range=in_range,
            )
        )
    return items


async def _active_alerts(db: AsyncSession, patient_id: str) -> list[dict]:
    rows = (
        await db.execute(
            text(
                """
                SELECT id, type, severity, title, detail, created_at
                FROM alerts
                WHERE patient_id = :pid AND status = 'active'
                ORDER BY created_at DESC
                """
            ),
            {"pid": patient_id},
        )
    ).mappings().all()
    return [
        {
            "id": str(r["id"]),
            "type": r["type"],
            "severity": r["severity"],
            "title": r["title"],
            "detail": r["detail"],
            "created_at": r["created_at"].isoformat() if r["created_at"] else None,
        }
        for r in rows
    ]


async def _medications_today(db: AsyncSession, patient_id: str) -> MedicationsToday:
    """Conteo de dosis de hoy por estado + próxima dosis pending.
    scheduled_doses no tiene patient_id → JOIN medications."""
    counts = (
        await db.execute(
            text(
                """
                SELECT sd.status, count(*) AS n
                FROM scheduled_doses sd
                JOIN medications m ON m.id = sd.medication_id
                WHERE m.patient_id = :pid
                  AND sd.scheduled_at::date = current_date
                GROUP BY sd.status
                """
            ),
            {"pid": patient_id},
        )
    ).mappings().all()
    by_status = {r["status"]: r["n"] for r in counts}

    next_row = (
        await db.execute(
            text(
                """
                SELECT sd.scheduled_at
                FROM scheduled_doses sd
                JOIN medications m ON m.id = sd.medication_id
                WHERE m.patient_id = :pid
                  AND sd.status = 'pending'
                  AND sd.scheduled_at::date = current_date
                ORDER BY sd.scheduled_at ASC
                LIMIT 1
                """
            ),
            {"pid": patient_id},
        )
    ).mappings().first()

    return MedicationsToday(
        taken=by_status.get("taken", 0),
        pending=by_status.get("pending", 0),
        missed=by_status.get("missed", 0),
        next_dose=next_row["scheduled_at"] if next_row else None,
    )


def _compute_wellbeing(
    active_alerts: list[dict],
    latest_vitals: list[LatestItem],
    meds: MedicationsToday,
) -> tuple[str, list[str]]:
    """Cálculo simple y documentado del semáforo (5.7).

    - attention: hay una alerta critical activa, o un vital fuera de rango.
    - warning:   hay una alerta warning activa, o dosis missed hoy.
    - ok:        ningún motivo de los anteriores.
    """
    reasons: list[str] = []
    status = "ok"

    # Motivos de atención (rojo).
    crit_alerts = [a for a in active_alerts if a["severity"] == "critical"]
    for a in crit_alerts:
        reasons.append(f"Alerta crítica activa: {a['title']}")
    out_of_range = [v for v in latest_vitals if not v.in_range]
    for v in out_of_range:
        reasons.append(f"{v.type} fuera de rango ({v.value} {v.unit})")

    if crit_alerts or out_of_range:
        status = "attention"

    # Motivos de advertencia (amarillo).
    warn_alerts = [a for a in active_alerts if a["severity"] == "warning"]
    for a in warn_alerts:
        reasons.append(f"Alerta activa: {a['title']}")
    if meds.missed > 0:
        reasons.append(f"{meds.missed} dosis omitida(s) hoy")

    if status != "attention" and (warn_alerts or meds.missed > 0):
        status = "warning"

    return status, reasons


# --------------------------------------------------------------------------
# 5.1 Ingesta por lote
# --------------------------------------------------------------------------
@router.post("/patients/{patient_id}/vitals/batch", response_model=BatchOut)
async def ingest_batch(
    payload: BatchIn,
    ctx: PatientContext = Depends(
        get_patient_member(roles=["caregiver", "elder", "family"])
    ),
    db: AsyncSession = Depends(get_db),
):
    if len(payload.readings) > MAX_BATCH:
        raise ApiError(
            status_code=400,
            code="BATCH_TOO_LARGE",
            message="El lote excede el máximo de 500 lecturas.",
        )

    accepted = 0
    # Idempotente: ON CONFLICT sobre la clave natural. RETURNING id sólo
    # aparece cuando la fila se insertó de verdad, así contamos duplicados.
    for r in payload.readings:
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
                    "type": r.type.value,
                    "value": r.value,
                    "measured_at": r.measured_at,
                    "meta": json.dumps(r.meta) if r.meta is not None else None,
                },
            )
        ).first()
        if row is not None:
            accepted += 1

    await db.commit()
    duplicates = len(payload.readings) - accepted
    # El motor de alertas es un componente aparte; aún no dispara nada aquí.
    return BatchOut(accepted=accepted, duplicates=duplicates, alerts_triggered=0)


# --------------------------------------------------------------------------
# 5.2 Vital manual
# --------------------------------------------------------------------------
@router.post(
    "/patients/{patient_id}/vitals/manual",
    response_model=ManualOut,
    status_code=201,
)
async def ingest_manual(
    payload: ManualIn,
    ctx: PatientContext = Depends(get_patient_member(roles=["caregiver"])),
    db: AsyncSession = Depends(get_db),
):
    # value_secondary sólo es válido en presión arterial (CHECK en BD).
    if payload.value_secondary is not None and payload.type != ManualVitalType.blood_pressure:
        raise ApiError(
            status_code=422,
            code="VALIDATION_ERROR",
            message="Hay datos inválidos en la solicitud. Revisa los campos marcados.",
        )

    reading_id = str(uuid.uuid4())
    measured_at = payload.measured_at or datetime.now(timezone.utc)
    meta = json.dumps({"note": payload.note}) if payload.note is not None else None

    row = (
        await db.execute(
            text(
                """
                INSERT INTO vital_readings
                    (id, patient_id, type, value, value_secondary, measured_at,
                     source, meta)
                VALUES
                    (:id, :pid, :type, :value, :value_secondary, :measured_at,
                     'manual', :meta)
                RETURNING id
                """
            ),
            {
                "id": reading_id,
                "pid": ctx.patient_id,
                "type": payload.type.value,
                "value": payload.value,
                "value_secondary": payload.value_secondary,
                "measured_at": measured_at,
                "meta": meta,
            },
        )
    ).mappings().first()
    await db.commit()
    return ManualOut(reading_id=str(row["id"]), alert_triggered=False)


# --------------------------------------------------------------------------
# 5.3 Series
# --------------------------------------------------------------------------
@router.get("/patients/{patient_id}/vitals", response_model=SeriesOut)
async def get_series(
    type: VitalType = Query(...),
    date_from: date = Query(...),
    date_to: date = Query(...),
    granularity: Granularity = Query(Granularity.day),
    ctx: PatientContext = Depends(get_patient_member()),
    db: AsyncSession = Depends(get_db),
):
    if (date_to - date_from).days > MAX_RANGE_DAYS:
        raise ApiError(
            status_code=400,
            code="RANGE_TOO_WIDE",
            message="El rango solicitado excede el máximo de 92 días.",
        )

    params = {
        "pid": ctx.patient_id,
        "type": type.value,
        "from": date_from,
        # date_to es inclusivo por día: usamos < (date_to + 1 día).
        "to": date_to,
    }

    if granularity == Granularity.raw:
        rows = (
            await db.execute(
                text(
                    """
                    SELECT measured_at AS ts, value
                    FROM vital_readings
                    WHERE patient_id = :pid
                      AND type = :type
                      AND measured_at >= :from
                      AND measured_at < (:to::date + interval '1 day')
                    ORDER BY measured_at ASC
                    """
                ),
                params,
            )
        ).mappings().all()
        points = [
            SeriesPoint(ts=r["ts"], value=float(r["value"]), min=None, max=None)
            for r in rows
        ]
    else:
        unit = _TRUNC_UNIT[granularity]
        rows = (
            await db.execute(
                text(
                    f"""
                    SELECT date_trunc('{unit}', measured_at) AS ts,
                           avg(value) AS avg_v,
                           min(value) AS min_v,
                           max(value) AS max_v
                    FROM vital_readings
                    WHERE patient_id = :pid
                      AND type = :type
                      AND measured_at >= :from
                      AND measured_at < (:to::date + interval '1 day')
                    GROUP BY date_trunc('{unit}', measured_at)
                    ORDER BY ts ASC
                    """
                ),
                params,
            )
        ).mappings().all()
        points = [
            SeriesPoint(
                ts=r["ts"],
                value=float(r["avg_v"]) if r["avg_v"] is not None else None,
                min=float(r["min_v"]) if r["min_v"] is not None else None,
                max=float(r["max_v"]) if r["max_v"] is not None else None,
            )
            for r in rows
        ]

    thresholds = await _load_thresholds_map(db, ctx.patient_id)
    th = thresholds.get(type.value)
    threshold = None
    if th is not None:
        threshold = ThresholdOut(
            type=type.value,
            min_value=float(th["min_value"]) if th["min_value"] is not None else None,
            max_value=float(th["max_value"]) if th["max_value"] is not None else None,
            updated_by=str(th["updated_by"]) if th["updated_by"] else None,
            updated_at=th["updated_at"],
        )

    return SeriesOut(
        type=type.value,
        unit=await _get_unit(db, type.value),
        points=points,
        threshold=threshold,
    )


# --------------------------------------------------------------------------
# 5.4 Últimos valores
# --------------------------------------------------------------------------
@router.get("/patients/{patient_id}/vitals/latest", response_model=LatestOut)
async def get_latest(
    ctx: PatientContext = Depends(get_patient_member()),
    db: AsyncSession = Depends(get_db),
):
    return LatestOut(items=await _latest_items(db, ctx.patient_id))


# --------------------------------------------------------------------------
# 5.5 Listar umbrales
# --------------------------------------------------------------------------
@router.get("/patients/{patient_id}/vitals/thresholds", response_model=ThresholdsOut)
async def list_thresholds(
    ctx: PatientContext = Depends(get_patient_member()),
    db: AsyncSession = Depends(get_db),
):
    rows = (
        await db.execute(
            text(
                """
                SELECT type, min_value, max_value, updated_by, updated_at
                FROM vital_thresholds
                WHERE patient_id = :pid
                ORDER BY type
                """
            ),
            {"pid": ctx.patient_id},
        )
    ).mappings().all()
    return ThresholdsOut(
        items=[
            ThresholdOut(
                type=r["type"],
                min_value=float(r["min_value"]) if r["min_value"] is not None else None,
                max_value=float(r["max_value"]) if r["max_value"] is not None else None,
                updated_by=str(r["updated_by"]) if r["updated_by"] else None,
                updated_at=r["updated_at"],
            )
            for r in rows
        ]
    )


# --------------------------------------------------------------------------
# 5.6 Configurar umbral
# --------------------------------------------------------------------------
@router.put(
    "/patients/{patient_id}/vitals/thresholds/{type}",
    response_model=ThresholdOut,
)
async def set_threshold(
    type: VitalType,
    payload: ThresholdIn,
    ctx: PatientContext = Depends(get_patient_member(roles=["family", "doctor"])),
    db: AsyncSession = Depends(get_db),
):
    if payload.min_value is None and payload.max_value is None:
        raise ApiError(
            status_code=400,
            code="EMPTY_THRESHOLD",
            message="Debes indicar al menos un valor mínimo o máximo.",
        )
    if (
        payload.min_value is not None
        and payload.max_value is not None
        and payload.min_value >= payload.max_value
    ):
        raise ApiError(
            status_code=400,
            code="INVALID_THRESHOLD_RANGE",
            message="El mínimo no puede ser mayor que el máximo.",
        )

    row = (
        await db.execute(
            text(
                """
                INSERT INTO vital_thresholds
                    (patient_id, type, min_value, max_value, updated_by)
                VALUES (:pid, :type, :min_value, :max_value, :uid)
                ON CONFLICT (patient_id, type) DO UPDATE
                    SET min_value = EXCLUDED.min_value,
                        max_value = EXCLUDED.max_value,
                        updated_by = EXCLUDED.updated_by,
                        updated_at = now()
                RETURNING type, min_value, max_value, updated_by, updated_at
                """
            ),
            {
                "pid": ctx.patient_id,
                "type": type.value,
                "min_value": payload.min_value,
                "max_value": payload.max_value,
                "uid": ctx.user.user_id,
            },
        )
    ).mappings().first()
    await db.commit()
    return ThresholdOut(
        type=row["type"],
        min_value=float(row["min_value"]) if row["min_value"] is not None else None,
        max_value=float(row["max_value"]) if row["max_value"] is not None else None,
        updated_by=str(row["updated_by"]) if row["updated_by"] else None,
        updated_at=row["updated_at"],
    )


# --------------------------------------------------------------------------
# 5.7 Semáforo del día
# --------------------------------------------------------------------------
@router.get("/patients/{patient_id}/summary/today", response_model=SummaryTodayOut)
async def summary_today(
    ctx: PatientContext = Depends(get_patient_member()),
    db: AsyncSession = Depends(get_db),
):
    active_alerts = await _active_alerts(db, ctx.patient_id)
    latest_vitals = await _latest_items(db, ctx.patient_id)
    meds = await _medications_today(db, ctx.patient_id)

    status, reasons = _compute_wellbeing(active_alerts, latest_vitals, meds)

    return SummaryTodayOut(
        wellbeing_status=status,
        status_reasons=reasons,
        active_alerts=active_alerts,
        latest_vitals=latest_vitals,
        medications_today=meds,
        last_observation=None,
    )


# --------------------------------------------------------------------------
# 5.8 Tablero multi-paciente
# --------------------------------------------------------------------------
@router.get("/users/me/dashboard", response_model=DashboardOut)
async def dashboard(
    user: CurrentUser = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    # Pacientes vivos del usuario (misma lógica de membresía que auth).
    patients = (
        await db.execute(
            text(
                """
                SELECT p.id, p.full_name, p.photo_url
                FROM patient_members pm
                JOIN patients p ON p.id = pm.patient_id
                WHERE pm.user_id = :uid
                  AND pm.removed_at IS NULL
                  AND p.deleted_at IS NULL
                ORDER BY p.full_name
                """
            ),
            {"uid": user.user_id},
        )
    ).mappings().all()

    items: list[DashboardItem] = []
    for p in patients:
        pid = str(p["id"])
        active_alerts = await _active_alerts(db, pid)
        latest_vitals = await _latest_items(db, pid)
        meds = await _medications_today(db, pid)
        status, reasons = _compute_wellbeing(active_alerts, latest_vitals, meds)
        items.append(
            DashboardItem(
                patient_id=pid,
                full_name=p["full_name"],
                photo_url=p["photo_url"],
                wellbeing_status=status,
                active_alerts_count=len(active_alerts),
                top_reason=reasons[0] if reasons else None,
            )
        )

    return DashboardOut(items=items)
