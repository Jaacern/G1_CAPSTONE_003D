"""Módulo 6: Medicamentos y adherencia (endpoints 6.1–6.7).

Alineado con la Especificación de Endpoints v1. Usa las tablas existentes:
medications, scheduled_doses. SQL crudo con text() y sesiones async, igual que
los módulos 3 (auth.py) y 4 (patients.py). Sin ORM.

Notas de alcance / desviaciones respecto a la spec por el esquema SQL actual:
- La BD permite grace_window_min entre 5 y 720, pero la spec limita la API a
  5–240: se valida 5–240 en la entrada.
- La generación de scheduled_doses NO se hace aquí: es un job (Anexo B). Al
  crear un medicamento solo se inserta la fila del plan.
- 6.4 (descontinuar) NO cancela dosis pendientes futuras: solo marca
  discontinued_at. Tocar scheduled_doses pendientes para marcarlas 'skipped'
  violaría el CHECK ck_scheduled_doses_skip_reason (exige motivo).
- 6.6 acepta status taken|postponed|missed. 'missed' se guarda tal cual en la
  BD (el CHECK permite 'missed'). Aunque 'missed' no exige logged_at por el
  CHECK ck_scheduled_doses_logged_status (solo taken/skipped lo exigen), se
  setea logged_by/logged_at por consistencia.
"""
import json
from datetime import date, datetime, timedelta

from fastapi import APIRouter, Depends, Query, Response, status
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

router = APIRouter(prefix="/api/v1", tags=["medications"])

_DEFAULT_DAYS = [1, 2, 3, 4, 5, 6, 7]


# --------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------
def _parse_jsonb_list(value) -> list:
    """asyncpg suele devolver jsonb ya parseado; por seguridad maneja str."""
    if value is None:
        return []
    if isinstance(value, str):
        return json.loads(value)
    return value


# --------------------------------------------------------------------------
# Schemas
# --------------------------------------------------------------------------
class MedicationCreateIn(BaseModel):
    name: str = Field(min_length=2, max_length=120)
    dose: str = Field(min_length=1, max_length=60)
    instructions: str | None = None
    times: list[str] = Field(min_length=1, max_length=8)
    days_of_week: list[int] | None = None
    start_date: date
    end_date: date | None = None
    grace_window_min: int = Field(default=60, ge=5, le=240)


class MedicationCreateOut(BaseModel):
    medication_id: str
    name: str
    prescribed_by: str | None = None
    created_at: datetime


class MedicationPatchIn(BaseModel):
    name: str | None = Field(default=None, min_length=2, max_length=120)
    dose: str | None = Field(default=None, min_length=1, max_length=60)
    instructions: str | None = None
    times: list[str] | None = Field(default=None, min_length=1, max_length=8)
    days_of_week: list[int] | None = None
    start_date: date | None = None
    end_date: date | None = None
    grace_window_min: int | None = Field(default=None, ge=5, le=240)


class MedicationItem(BaseModel):
    medication_id: str
    name: str
    dose: str
    instructions: str | None = None
    times: list[str]
    days_of_week: list[int]
    start_date: date
    end_date: date | None = None
    prescribed_by: str | None = None
    is_active: bool


class MedicationListOut(BaseModel):
    items: list[MedicationItem]


class DoseItem(BaseModel):
    dose_id: str
    medication_id: str
    medication_name: str
    dose: str
    scheduled_at: datetime
    status: str
    logged_by: str | None = None
    logged_at: datetime | None = None
    reason: str | None = None


class DosesListOut(BaseModel):
    items: list[DoseItem]
    next_dose: DoseItem | None = None


class DoseLogIn(BaseModel):
    status: str  # taken | postponed | missed
    postponed_until: datetime | None = None
    reason: str | None = None


class DoseLogOut(BaseModel):
    dose_id: str
    status: str
    alert_triggered: bool = False


class AdherenceByMedication(BaseModel):
    medication_id: str
    name: str
    adherence_pct: float


class AdherenceDaily(BaseModel):
    date: date
    taken: int
    missed: int
    pending: int


class AdherenceOut(BaseModel):
    adherence_pct: float
    taken: int
    missed: int
    by_medication: list[AdherenceByMedication]
    daily: list[AdherenceDaily]


# --------------------------------------------------------------------------
# Helpers de lectura de medicamentos
# --------------------------------------------------------------------------
def _medication_row_to_item(row) -> MedicationItem:
    return MedicationItem(
        medication_id=str(row["id"]),
        name=row["name"],
        dose=row["dose"],
        instructions=row["instructions"],
        times=_parse_jsonb_list(row["times"]),
        days_of_week=_parse_jsonb_list(row["days_of_week"]),
        start_date=row["start_date"],
        end_date=row["end_date"],
        prescribed_by=str(row["prescribed_by"]) if row["prescribed_by"] else None,
        is_active=row["discontinued_at"] is None,
    )


async def _load_medication(
    db: AsyncSession, patient_id: str, medication_id: str
) -> MedicationItem:
    row = (
        await db.execute(
            text(
                """
                SELECT id, name, dose, instructions, times, days_of_week,
                       start_date, end_date, prescribed_by, discontinued_at
                FROM medications
                WHERE id = :mid AND patient_id = :pid
                """
            ),
            {"mid": medication_id, "pid": patient_id},
        )
    ).mappings().first()

    if row is None:
        raise ApiError(
            status_code=404,
            code="NOT_FOUND",
            message="El recurso solicitado no existe o no está disponible.",
        )
    return _medication_row_to_item(row)


# --------------------------------------------------------------------------
# 6.1 Crear medicamento
# --------------------------------------------------------------------------
@router.post(
    "/patients/{patient_id}/medications",
    response_model=MedicationCreateOut,
    status_code=201,
)
async def create_medication(
    payload: MedicationCreateIn,
    ctx: PatientContext = Depends(
        get_patient_member(roles=["caregiver", "doctor"])
    ),
    db: AsyncSession = Depends(get_db),
):
    if payload.end_date is not None and payload.end_date < payload.start_date:
        raise ApiError(
            status_code=400,
            code="INVALID_DATE_RANGE",
            message="La fecha de fin no puede ser anterior a la de inicio.",
        )

    days = payload.days_of_week if payload.days_of_week else _DEFAULT_DAYS

    # El plan lo prescribe un médico; si lo crea una cuidadora, queda sin
    # prescriptor (RF-24).
    prescribed_by = ctx.user.user_id if ctx.role == "doctor" else None

    row = (
        await db.execute(
            text(
                """
                INSERT INTO medications
                    (patient_id, name, dose, instructions, times, days_of_week,
                     start_date, end_date, grace_window_min, prescribed_by)
                VALUES
                    (:pid, :name, :dose, :instructions,
                     CAST(:times AS jsonb), CAST(:days AS jsonb),
                     :start_date, :end_date, :grace, :prescribed_by)
                RETURNING id, name, prescribed_by, created_at
                """
            ),
            {
                "pid": ctx.patient_id,
                "name": payload.name,
                "dose": payload.dose,
                "instructions": payload.instructions,
                "times": json.dumps(payload.times),
                "days": json.dumps(days),
                "start_date": payload.start_date,
                "end_date": payload.end_date,
                "grace": payload.grace_window_min,
                "prescribed_by": prescribed_by,
            },
        )
    ).mappings().first()

    # La generación de scheduled_doses la hace el job del Anexo B, no la API.
    await db.commit()

    return MedicationCreateOut(
        medication_id=str(row["id"]),
        name=row["name"],
        prescribed_by=str(row["prescribed_by"]) if row["prescribed_by"] else None,
        created_at=row["created_at"],
    )


# --------------------------------------------------------------------------
# 6.2 Listar plan de medicamentos
# --------------------------------------------------------------------------
@router.get(
    "/patients/{patient_id}/medications",
    response_model=MedicationListOut,
)
async def list_medications(
    active_only: bool = Query(default=True),
    ctx: PatientContext = Depends(get_patient_member()),
    db: AsyncSession = Depends(get_db),
):
    sql = """
        SELECT id, name, dose, instructions, times, days_of_week,
               start_date, end_date, prescribed_by, discontinued_at
        FROM medications
        WHERE patient_id = :pid
    """
    if active_only:
        sql += " AND discontinued_at IS NULL"
    sql += " ORDER BY name"

    rows = (
        await db.execute(text(sql), {"pid": ctx.patient_id})
    ).mappings().all()

    return MedicationListOut(items=[_medication_row_to_item(r) for r in rows])


# --------------------------------------------------------------------------
# 6.3 Actualizar medicamento
# --------------------------------------------------------------------------
@router.patch(
    "/patients/{patient_id}/medications/{medication_id}",
    response_model=MedicationItem,
)
async def update_medication(
    medication_id: str,
    payload: MedicationPatchIn,
    ctx: PatientContext = Depends(
        get_patient_member(roles=["caregiver", "doctor"])
    ),
    db: AsyncSession = Depends(get_db),
):
    # Debe existir y pertenecer al paciente (404 si no).
    current = await _load_medication(db, ctx.patient_id, medication_id)

    fields = payload.model_dump(exclude_unset=True)

    # Valida rango de fechas contra el estado resultante (nuevo o actual).
    new_start = fields.get("start_date", current.start_date)
    new_end = fields["end_date"] if "end_date" in fields else current.end_date
    if new_end is not None and new_end < new_start:
        raise ApiError(
            status_code=400,
            code="INVALID_DATE_RANGE",
            message="La fecha de fin no puede ser anterior a la de inicio.",
        )

    sets: list[str] = []
    params: dict = {"mid": medication_id, "pid": ctx.patient_id}

    if "name" in fields:
        sets.append("name = :name")
        params["name"] = fields["name"]
    if "dose" in fields:
        sets.append("dose = :dose")
        params["dose"] = fields["dose"]
    if "instructions" in fields:
        sets.append("instructions = :instructions")
        params["instructions"] = fields["instructions"]
    if "times" in fields:
        sets.append("times = CAST(:times AS jsonb)")
        params["times"] = json.dumps(fields["times"])
    if "days_of_week" in fields:
        days = fields["days_of_week"] if fields["days_of_week"] else _DEFAULT_DAYS
        sets.append("days_of_week = CAST(:days AS jsonb)")
        params["days"] = json.dumps(days)
    if "start_date" in fields:
        sets.append("start_date = :start_date")
        params["start_date"] = fields["start_date"]
    if "end_date" in fields:
        sets.append("end_date = :end_date")
        params["end_date"] = fields["end_date"]
    if "grace_window_min" in fields:
        sets.append("grace_window_min = :grace")
        params["grace"] = fields["grace_window_min"]

    if sets:
        await db.execute(
            text(
                f"UPDATE medications SET {', '.join(sets)} "
                "WHERE id = :mid AND patient_id = :pid"
            ),
            params,
        )
        await db.commit()

    return await _load_medication(db, ctx.patient_id, medication_id)


# --------------------------------------------------------------------------
# 6.4 Descontinuar medicamento
# --------------------------------------------------------------------------
@router.delete(
    "/patients/{patient_id}/medications/{medication_id}",
    status_code=204,
)
async def discontinue_medication(
    medication_id: str,
    ctx: PatientContext = Depends(
        get_patient_member(roles=["caregiver", "doctor"])
    ),
    db: AsyncSession = Depends(get_db),
):
    # Debe existir y pertenecer al paciente (404 si no).
    await _load_medication(db, ctx.patient_id, medication_id)

    # Solo marca discontinued_at: NO tocamos dosis pendientes futuras para no
    # violar el CHECK que exige motivo al pasar a 'skipped'.
    await db.execute(
        text(
            """
            UPDATE medications
            SET discontinued_at = now()
            WHERE id = :mid AND patient_id = :pid AND discontinued_at IS NULL
            """
        ),
        {"mid": medication_id, "pid": ctx.patient_id},
    )
    await db.commit()

    return Response(status_code=status.HTTP_204_NO_CONTENT)


# --------------------------------------------------------------------------
# 6.5 Dosis del día
# --------------------------------------------------------------------------
@router.get("/patients/{patient_id}/doses", response_model=DosesListOut)
async def list_doses(
    date: date | None = Query(default=None),
    ctx: PatientContext = Depends(get_patient_member()),
    db: AsyncSession = Depends(get_db),
):
    target_date = date if date is not None else datetime.now().date()

    rows = (
        await db.execute(
            text(
                """
                SELECT sd.id AS dose_id, sd.medication_id, m.name AS medication_name,
                       m.dose, sd.scheduled_at, sd.status, sd.logged_by,
                       sd.logged_at, sd.reason
                FROM scheduled_doses sd
                JOIN medications m ON m.id = sd.medication_id
                WHERE sd.patient_id = :pid
                  AND sd.scheduled_at::date = :d
                ORDER BY sd.scheduled_at
                """
            ),
            {"pid": ctx.patient_id, "d": target_date},
        )
    ).mappings().all()

    items = [
        DoseItem(
            dose_id=str(r["dose_id"]),
            medication_id=str(r["medication_id"]),
            medication_name=r["medication_name"],
            dose=r["dose"],
            scheduled_at=r["scheduled_at"],
            status=r["status"],
            logged_by=str(r["logged_by"]) if r["logged_by"] else None,
            logged_at=r["logged_at"],
            reason=r["reason"],
        )
        for r in rows
    ]

    # Próxima dosis pendiente del día, ordenada por hora programada.
    next_dose = next((it for it in items if it.status == "pending"), None)

    return DosesListOut(items=items, next_dose=next_dose)


# --------------------------------------------------------------------------
# 6.6 Registrar administración de una dosis
# --------------------------------------------------------------------------
@router.post("/doses/{dose_id}/log", response_model=DoseLogOut)
async def log_dose(
    dose_id: str,
    payload: DoseLogIn,
    user: CurrentUser = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    # Esta ruta no lleva {patient_id}, así que la autorización es manual:
    # cargamos la dosis, obtenemos su paciente y validamos membresía caregiver.
    dose = (
        await db.execute(
            text(
                """
                SELECT id, patient_id, scheduled_at, status
                FROM scheduled_doses
                WHERE id = :did
                """
            ),
            {"did": dose_id},
        )
    ).mappings().first()

    if dose is None:
        raise ApiError(
            status_code=404,
            code="NOT_FOUND",
            message="El recurso solicitado no existe o no está disponible.",
        )

    membership = (
        await db.execute(
            text(
                """
                SELECT pm.role
                FROM patient_members pm
                JOIN patients p ON p.id = pm.patient_id
                WHERE pm.patient_id = :pid
                  AND pm.user_id = :uid
                  AND pm.role = 'caregiver'
                  AND pm.removed_at IS NULL
                  AND p.deleted_at IS NULL
                """
            ),
            {"pid": str(dose["patient_id"]), "uid": user.user_id},
        )
    ).mappings().first()

    # No revelamos la existencia de la dosis a quien no tiene acceso (spec 2.5).
    if membership is None:
        raise ApiError(
            status_code=404,
            code="NOT_FOUND",
            message="El recurso solicitado no existe o no está disponible.",
        )

    if dose["status"] != "pending":
        raise ApiError(
            status_code=409,
            code="DOSE_ALREADY_LOGGED",
            message="Esta dosis ya fue registrada.",
        )

    if payload.status not in ("taken", "postponed", "missed"):
        raise ApiError(
            status_code=422,
            code="VALIDATION_ERROR",
            message="Hay datos inválidos en la solicitud. Revisa los campos marcados.",
        )

    if payload.status == "missed" and not payload.reason:
        raise ApiError(
            status_code=400,
            code="MISSING_REASON",
            message="Debes indicar el motivo cuando la dosis se marca como omitida.",
        )

    postponed_until = None
    if payload.status == "postponed":
        if payload.postponed_until is None:
            raise ApiError(
                status_code=422,
                code="VALIDATION_ERROR",
                message="Hay datos inválidos en la solicitud. Revisa los campos marcados.",
            )
        limit = dose["scheduled_at"] + timedelta(hours=4)
        if payload.postponed_until > limit:
            raise ApiError(
                status_code=400,
                code="INVALID_POSTPONE_TIME",
                message="La dosis solo puede posponerse hasta 4 horas.",
            )
        postponed_until = payload.postponed_until

    await db.execute(
        text(
            """
            UPDATE scheduled_doses
            SET status = :status,
                logged_by = :uid,
                logged_at = now(),
                reason = :reason,
                postponed_until = :postponed_until
            WHERE id = :did
            """
        ),
        {
            "status": payload.status,
            "uid": user.user_id,
            "reason": payload.reason,
            "postponed_until": postponed_until,
            "did": dose_id,
        },
    )
    await db.commit()

    return DoseLogOut(dose_id=dose_id, status=payload.status, alert_triggered=False)


# --------------------------------------------------------------------------
# 6.7 Métricas de adherencia
# --------------------------------------------------------------------------
@router.get("/patients/{patient_id}/adherence", response_model=AdherenceOut)
async def adherence(
    date_from: date = Query(...),
    date_to: date = Query(...),
    ctx: PatientContext = Depends(get_patient_member()),
    db: AsyncSession = Depends(get_db),
):
    rows = (
        await db.execute(
            text(
                """
                SELECT sd.medication_id, m.name AS medication_name,
                       sd.status, sd.scheduled_at::date AS day
                FROM scheduled_doses sd
                JOIN medications m ON m.id = sd.medication_id
                WHERE sd.patient_id = :pid
                  AND sd.scheduled_at::date BETWEEN :df AND :dt
                """
            ),
            {"pid": ctx.patient_id, "df": date_from, "dt": date_to},
        )
    ).mappings().all()

    taken = 0
    missed = 0
    skipped = 0

    # Acumuladores por medicamento y por día.
    per_med: dict[str, dict] = {}
    per_day: dict[date, dict] = {}

    for r in rows:
        status_val = r["status"]
        mid = str(r["medication_id"])
        day = r["day"]

        if status_val == "taken":
            taken += 1
        elif status_val == "missed":
            missed += 1
        elif status_val == "skipped":
            skipped += 1

        med = per_med.setdefault(
            mid, {"name": r["medication_name"], "taken": 0, "not_taken": 0}
        )
        if status_val == "taken":
            med["taken"] += 1
        elif status_val in ("missed", "skipped"):
            med["not_taken"] += 1

        d = per_day.setdefault(day, {"taken": 0, "missed": 0, "pending": 0})
        if status_val == "taken":
            d["taken"] += 1
        elif status_val in ("missed", "skipped"):
            d["missed"] += 1
        elif status_val == "pending":
            d["pending"] += 1

    def _pct(taken_n: int, not_taken_n: int) -> float:
        denom = taken_n + not_taken_n
        if denom == 0:
            return 100.0
        return round(taken_n / denom * 100, 2)

    # missed + skipped cuentan como no tomadas para el porcentaje global.
    adherence_pct = _pct(taken, missed + skipped)

    by_medication = [
        AdherenceByMedication(
            medication_id=mid,
            name=data["name"],
            adherence_pct=_pct(data["taken"], data["not_taken"]),
        )
        for mid, data in per_med.items()
    ]

    daily = [
        AdherenceDaily(
            date=day,
            taken=data["taken"],
            missed=data["missed"],
            pending=data["pending"],
        )
        for day, data in sorted(per_day.items())
    ]

    return AdherenceOut(
        adherence_pct=adherence_pct,
        taken=taken,
        missed=missed,
        by_medication=by_medication,
        daily=daily,
    )
