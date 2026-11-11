"""Módulo 5: Vitals y resumen del día / semáforo (endpoints 5.1–5.8).

Cambios 2FN aplicados:
- UNITS dict eliminado: la unidad se lee desde vital_types.unit (fuente única de verdad).
- scheduled_doses ya no tiene patient_id: las consultas hacen JOIN medications.
- alerts.update_at → updated_at (typo corregido en BD).
"""
import json
import uuid
from datetime import date, datetime, timedelta, timezone
from enum import Enum

from fastapi import APIRouter, BackgroundTasks, Depends, Query
from pydantic import BaseModel, Field
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

from app.avisos import despachar
from app.db import get_db
from app.deps import CurrentUser, PatientContext, get_current_user, get_patient_member
from app.errors import ApiError
from app.maintenance import evaluar_vitales

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
    # Nivel de batería del dispositivo (0–100). Opcional: lo envía la app del
    # reloj en cada lote. Si viene, actualiza wearables.battery_pct.
    battery_pct: int | None = Field(default=None, ge=0, le=100)


class BatchOut(BaseModel):
    accepted: int
    duplicates: int
    alerts_triggered: int


class ManualIn(BaseModel):
    type: ManualVitalType
    value: float
    value_secondary: float | None = None
    measured_at: datetime | None = None
    note: str | None = Field(default=None, max_length=200)


# Rango fisiologicamente posible por tipo. No es el rango "normal" (eso son
# los umbrales del paciente): es lo que una persona viva puede marcar. Un
# valor fuera de aqui es un error de digitacion (180 en vez de 18,0) y no se
# guarda, porque terminaria disparando alertas y moviendo el semaforo.
_RANGO_POSIBLE: dict[str, tuple[float, float]] = {
    "heart_rate":     (25, 250),
    "spo2":           (50, 100),
    "blood_pressure": (50, 260),   # sistolica
    "temperature":    (30, 45),
    "glucose":        (20, 600),
}
_RANGO_DIASTOLICA = (30, 160)
_ATRASO_MAXIMO = timedelta(days=30)


class ManualOut(BaseModel):
    reading_id: str
    alert_triggered: bool = False


class SeriesPoint(BaseModel):
    ts: datetime
    value: float | None
    min: float | None = None
    max: float | None = None
    # Solo en presion arterial: promedio de la diastolica del periodo. El
    # grafico dibuja sistolica (value) y diastolica (value_secondary) como dos
    # lineas, que es como se lee una presion; para el resto de vitales queda
    # en null y se usa la banda min-max.
    value_secondary: float | None = None


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
    # Resumen de orígenes presentes en el rango (transparencia de fuente).
    # Ej: {"watch": 180, "health_connect": 40, "simulator": 10}.
    sources: dict[str, int] = {}


class LatestItem(BaseModel):
    type: str
    value: float
    # Solo presión arterial: la diastólica. Sin ella la tarjeta mostraba
    # "148 mmHg", que no es una presión.
    value_secondary: float | None = None
    unit: str
    measured_at: datetime
    in_range: bool
    # Origen del dato (transparencia de fuente). source: wearable|manual.
    # origin viene de meta.origin: simulator | health_connect | watch | ...
    source: str | None = None
    origin: str | None = None


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
    """Umbrales vigentes del paciente, indexados por tipo.

    Se descartan los que tienen deleted_at. Faltaba ese filtro, y sin el un
    umbral dado de baja seguia pintando el valor en rojo: el borrado suave
    existe para dejar de aplicar la regla sin perder el registro de que
    alguna vez estuvo. Hoy ninguna ruta escribe esa columna, asi que no
    cambia nada todavia; el dia que se agregue dar de baja un umbral, esto
    ya esta de este lado. El proceso que crea las alertas por medicion
    fuera de rango tambien lo filtra, y los dos tienen que coincidir o la
    pantalla y la alerta se contradicen.
    """
    rows = (
        await db.execute(
            text(
                """
                SELECT type, min_value, max_value, updated_by, updated_at
                FROM vital_thresholds
                WHERE patient_id = :pid
                  AND deleted_at IS NULL
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
                SELECT DISTINCT ON (type)
                       type, value, value_secondary, measured_at, source, meta
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
        meta = r["meta"]
        if isinstance(meta, str):
            try:
                meta = json.loads(meta)
            except (ValueError, TypeError):
                meta = None
        origin = meta.get("origin") if isinstance(meta, dict) else None
        items.append(
            LatestItem(
                type=r["type"],
                value=float(r["value"]),
                value_secondary=float(r["value_secondary"])
                if r["value_secondary"] is not None else None,
                unit=await _get_unit(db, r["type"]),
                measured_at=r["measured_at"],
                in_range=in_range,
                source=r["source"],
                origin=origin,
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
                LEFT JOIN medications m ON m.id = sd.medication_id
                LEFT JOIN treatment_items ti ON ti.id = sd.treatment_item_id
                LEFT JOIN treatments tr ON tr.id = ti.treatment_id
                WHERE COALESCE(m.patient_id, tr.patient_id) = :pid
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
                LEFT JOIN medications m ON m.id = sd.medication_id
                LEFT JOIN treatment_items ti ON ti.id = sd.treatment_item_id
                LEFT JOIN treatments tr ON tr.id = ti.treatment_id
                WHERE COALESCE(m.patient_id, tr.patient_id) = :pid
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
    segundo_plano: BackgroundTasks,
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

    # Actualiza el estado del wearable activo del paciente: se recibió un lote,
    # así que last_sync_at = ahora. Si el dispositivo reportó batería, se guarda
    # (RF-16). Solo afecta al aparato vigente (unlinked_at IS NULL).
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

    # Las mediciones del reloj se evalúan al llegar, en la misma transacción.
    # Antes esperaban a la pasada horaria del mantenimiento: una saturación
    # de 85 medida por el reloj tardaba hasta una hora en avisar, y la misma
    # medición tomada a mano avisaba al instante. Solo si entró algo nuevo:
    # reenviar un lote ya recibido no cambia cuál es la última medición.
    alertas = 0
    if accepted:
        alertas, _ = await evaluar_vitales(db, patient_id=ctx.patient_id)

    await db.commit()
    if alertas:
        segundo_plano.add_task(despachar)
    duplicates = len(payload.readings) - accepted
    return BatchOut(accepted=accepted, duplicates=duplicates,
                    alerts_triggered=alertas)


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
    segundo_plano: BackgroundTasks,
    ctx: PatientContext = Depends(get_patient_member(roles=["caregiver"])),
    db: AsyncSession = Depends(get_db),
):
    def invalido(campo: str, motivo: str) -> ApiError:
        return ApiError(
            status_code=422,
            code="VALIDATION_ERROR",
            message="Hay datos inválidos en la solicitud. Revisa los campos marcados.",
            details=[{"field": campo, "message": motivo}],
        )

    es_presion = payload.type == ManualVitalType.blood_pressure
    # value_secondary sólo es válido en presión arterial (CHECK en BD), y la
    # presión sin diastólica no es una presión: "140" no dice nada.
    if payload.value_secondary is not None and not es_presion:
        raise invalido("value_secondary", "Solo la presión arterial lleva un segundo valor.")
    if es_presion and payload.value_secondary is None:
        raise invalido("value_secondary", "Indica la presión diastólica (el valor de abajo).")

    minimo, maximo = _RANGO_POSIBLE[payload.type.value]
    if not minimo <= payload.value <= maximo:
        raise invalido("value", f"El valor debe estar entre {_n(minimo)} y {_n(maximo)}. "
                                "Revisa que esté bien escrito.")
    if es_presion:
        dmin, dmax = _RANGO_DIASTOLICA
        if not dmin <= payload.value_secondary <= dmax:
            raise invalido("value_secondary",
                           f"La diastólica debe estar entre {dmin} y {dmax}.")
        if payload.value_secondary >= payload.value:
            raise invalido("value_secondary",
                           "La diastólica (abajo) tiene que ser menor que la sistólica (arriba).")

    ahora = datetime.now(timezone.utc)
    measured_at = payload.measured_at or ahora
    if measured_at.tzinfo is None:
        measured_at = measured_at.replace(tzinfo=timezone.utc)
    if measured_at > ahora + timedelta(minutes=5):
        raise invalido("measured_at", "La medición no puede ser en el futuro.")
    if measured_at < ahora - _ATRASO_MAXIMO:
        raise invalido("measured_at", "Solo se pueden registrar mediciones de los últimos 30 días.")

    reading_id = str(uuid.uuid4())
    nota = (payload.note or "").strip() or None
    # Quién la tomó queda con la lectura: el historial lo muestra.
    meta = json.dumps({"note": nota, "recorded_by": ctx.user.user_id})

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
    # Lectura y alerta en la misma transacción: o quedan las dos o ninguna.
    alerta = await _alertar_si_fuera_de_rango(
        db, ctx.patient_id, str(row["id"]), payload.type.value,
        payload.value, measured_at)
    await db.commit()
    if alerta:
        segundo_plano.add_task(despachar)
    return ManualOut(reading_id=str(row["id"]), alert_triggered=alerta)


def _n(v: float) -> str:
    return str(int(v)) if float(v) == int(v) else str(v)


async def _alertar_si_fuera_de_rango(db: AsyncSession, patient_id: str,
                                     reading_id: str, tipo: str, valor: float,
                                     measured_at: datetime) -> bool:
    """Avisa al círculo si una medición manual sale del rango del paciente.

    Las del reloj las revisa el mantenimiento cada hora. Una medición manual
    la tomó una persona que está con el paciente, y si sale alterada el aviso
    no puede esperar a la próxima pasada. Usa el mismo título, detalle,
    payload y clave de deduplicación que maintenance.alertar_vitales_fuera_de_rango:
    así el mantenimiento reconoce la alerta por su reading_id y no la repite.
    """
    th = (
        await db.execute(
            text("SELECT t.min_value, t.max_value, vt.label, vt.unit "
                 "FROM vital_thresholds t JOIN vital_types vt ON vt.code = t.type "
                 "WHERE t.patient_id = :pid AND t.type = :t AND t.deleted_at IS NULL"),
            {"pid": patient_id, "t": tipo},
        )
    ).mappings().first()
    if th is None:
        return False
    bajo = th["min_value"] is not None and valor < float(th["min_value"])
    alto = th["max_value"] is not None and valor > float(th["max_value"])
    if not (bajo or alto):
        return False

    clave = f"{tipo}_{'low' if bajo else 'high'}"
    ventana = (
        await db.execute(text("SELECT value FROM system_parameters "
                              "WHERE key = 'alert_dedup_minutes'"))
    ).scalar()
    try:
        ventana = int(ventana)
    except (TypeError, ValueError):
        ventana = 30
    reciente = (
        await db.execute(
            text("SELECT 1 FROM alerts WHERE patient_id = :pid AND dedup_key = :c "
                 "AND created_at > now() - make_interval(mins => CAST(:v AS integer)) LIMIT 1"),
            {"pid": patient_id, "c": clave, "v": ventana},
        )
    ).first()
    if reciente is not None:
        return False

    unidad = f" {th['unit']}" if th["unit"] else ""
    limite = th["min_value"] if bajo else th["max_value"]
    titulo = f"{th['label']} bajo el mínimo" if bajo else f"{th['label']} sobre el máximo"
    detalle = (f"{th['label']} {_n(valor)}{unidad} "
               f"({'mínimo' if bajo else 'máximo'} configurado {_n(float(limite))}{unidad}). "
               "Medición manual.")
    await db.execute(
        text("INSERT INTO alerts (patient_id, type, severity, title, detail, payload, "
             "dedup_key, status) VALUES (:pid, 'vital_out_of_range', 'warning', :ti, :de, "
             "CAST(:pl AS jsonb), :c, 'active')"),
        {"pid": patient_id, "ti": titulo[:120], "de": detalle, "c": clave,
         "pl": json.dumps({
             "reading_id": reading_id, "type": tipo, "value": valor,
             "min_value": float(th["min_value"]) if th["min_value"] is not None else None,
             "max_value": float(th["max_value"]) if th["max_value"] is not None else None,
             "measured_at": measured_at.isoformat(),
         })},
    )
    return True


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

    # La presion arterial tiene dos componentes (sistolica en value,
    # diastolica en value_secondary). El grafico las dibuja como dos lineas,
    # asi que aqui se traen las dos y NO la banda min-max, que para presion se
    # leia como si fuera la diastolica sin serlo.
    es_presion = type == VitalType.blood_pressure

    if granularity == Granularity.raw:
        rows = (
            await db.execute(
                text(
                    """
                    SELECT measured_at AS ts, value, value_secondary
                    FROM vital_readings
                    WHERE patient_id = :pid
                      AND type = :type
                      AND measured_at >= :from
                      AND measured_at < (cast(:to as date) + interval '1 day')
                    ORDER BY measured_at ASC
                    """
                ),
                params,
            )
        ).mappings().all()
        points = [
            SeriesPoint(
                ts=r["ts"],
                value=float(r["value"]),
                min=None,
                max=None,
                value_secondary=float(r["value_secondary"])
                if es_presion and r["value_secondary"] is not None
                else None,
            )
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
                           max(value) AS max_v,
                           avg(value_secondary) AS avg_v2
                    FROM vital_readings
                    WHERE patient_id = :pid
                      AND type = :type
                      AND measured_at >= :from
                      AND measured_at < (cast(:to as date) + interval '1 day')
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
                # Para presion la banda min-max se omite: confunde con la
                # diastolica. Para el resto se conserva.
                min=None if es_presion
                else (float(r["min_v"]) if r["min_v"] is not None else None),
                max=None if es_presion
                else (float(r["max_v"]) if r["max_v"] is not None else None),
                value_secondary=float(r["avg_v2"])
                if es_presion and r["avg_v2"] is not None
                else None,
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

    # Resumen de orígenes presentes en el rango (transparencia de fuente).
    src_rows = (
        await db.execute(
            text(
                """
                SELECT COALESCE(meta->>'origin', source) AS origen, count(*) AS n
                FROM vital_readings
                WHERE patient_id = :pid
                  AND type = :type
                  AND measured_at >= :from
                  AND measured_at < (cast(:to as date) + interval '1 day')
                GROUP BY origen
                """
            ),
            params,
        )
    ).mappings().all()
    sources = {r["origen"]: int(r["n"]) for r in src_rows if r["origen"]}

    return SeriesOut(
        type=type.value,
        unit=await _get_unit(db, type.value),
        points=points,
        threshold=threshold,
        sources=sources,
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
                  AND deleted_at IS NULL
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
                -- El WHERE va aqui porque el indice unico de la tabla es
                -- PARCIAL: uq_vital_thresholds_patient_type solo cubre las
                -- filas con deleted_at IS NULL. Un ON CONFLICT sin repetir
                -- esa condicion no infiere ningun indice, y Postgres
                -- rechaza la sentencia SIEMPRE, no solo cuando hay
                -- conflicto. Sin esto el endpoint devolvia 500 en cada
                -- llamada y la familia no podia guardar ningun umbral.
                ON CONFLICT (patient_id, type) WHERE deleted_at IS NULL
                DO UPDATE
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
