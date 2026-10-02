"""Módulo 6: Medicamentos y adherencia (endpoints 6.1–6.7).

Cambios 2FN aplicados:
- medications: times/days_of_week JSON eliminados → medication_times + medication_days.
- scheduled_doses: patient_id eliminado; todas las queries filtran por paciente
  haciendo JOIN medications.patient_id.
"""
from datetime import date, datetime, timedelta

from fastapi import APIRouter, Depends, Query, Response, status
from pydantic import BaseModel, Field
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

from app.db import get_db
from app.deps import CurrentUser, PatientContext, get_current_user, get_patient_member
from app.errors import ApiError

router = APIRouter(prefix="/api/v1", tags=["medications"])


# --------------------------------------------------------------------------
# Schemas
# --------------------------------------------------------------------------
class MedicationCreateIn(BaseModel):
    name:             str = Field(min_length=2, max_length=120)
    dose:             str = Field(min_length=1, max_length=60)
    instructions:     str | None = None
    times:            list[str] = Field(min_length=1, max_length=8)   # ["HH:MM", ...]
    days_of_week:     list[int] | None = None                          # 1–7, None = todos
    start_date:       date
    end_date:         date | None = None
    grace_window_min: int = Field(default=60, ge=5, le=240)


class MedicationCreateOut(BaseModel):
    medication_id: str
    name:          str
    prescribed_by: str | None = None
    created_at:    datetime


class MedicationPatchIn(BaseModel):
    name:             str | None = Field(default=None, min_length=2, max_length=120)
    dose:             str | None = Field(default=None, min_length=1, max_length=60)
    instructions:     str | None = None
    times:            list[str] | None = Field(default=None, min_length=1, max_length=8)
    days_of_week:     list[int] | None = None
    start_date:       date | None = None
    end_date:         date | None = None
    grace_window_min: int | None = Field(default=None, ge=5, le=240)


class MedicationItem(BaseModel):
    medication_id: str
    name:          str
    dose:          str
    instructions:  str | None = None
    times:         list[str]
    days_of_week:  list[int]
    start_date:    date
    end_date:      date | None = None
    prescribed_by: str | None = None
    is_active:     bool


class MedicationListOut(BaseModel):
    items: list[MedicationItem]


class DoseItem(BaseModel):
    dose_id:         str
    medication_id:   str
    medication_name: str
    dose:            str
    scheduled_at:    datetime
    status:          str
    logged_by:       str | None = None
    logged_at:       datetime | None = None
    reason:          str | None = None


class DosesListOut(BaseModel):
    items:     list[DoseItem]
    next_dose: DoseItem | None = None


class DoseLogIn(BaseModel):
    status:          str
    postponed_until: datetime | None = None
    reason:          str | None = None


class DoseLogOut(BaseModel):
    dose_id:         str
    status:          str
    alert_triggered: bool = False


class AdherenceByMedication(BaseModel):
    medication_id:  str
    name:           str
    adherence_pct:  float


class AdherenceDaily(BaseModel):
    date:    date
    taken:   int
    missed:  int
    pending: int


class AdherenceOut(BaseModel):
    adherence_pct:  float
    taken:          int
    missed:         int
    by_medication:  list[AdherenceByMedication]
    daily:          list[AdherenceDaily]


# --------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------
_DEFAULT_DAYS = list(range(1, 8))


async def _load_times(db: AsyncSession, medication_id: str) -> list[str]:
    rows = (
        await db.execute(
            text("SELECT to_char(time_of_day, 'HH24:MI') AS t "
                 "FROM medication_times WHERE medication_id = :mid ORDER BY time_of_day"),
            {"mid": medication_id},
        )
    ).scalars().all()
    return list(rows)


async def _load_days(db: AsyncSession, medication_id: str) -> list[int]:
    rows = (
        await db.execute(
            text("SELECT day_of_week FROM medication_days "
                 "WHERE medication_id = :mid ORDER BY day_of_week"),
            {"mid": medication_id},
        )
    ).scalars().all()
    return list(rows)


async def _replace_times(db: AsyncSession, medication_id: str, times: list[str]) -> None:
    await db.execute(
        text("DELETE FROM medication_times WHERE medication_id = :mid"), {"mid": medication_id}
    )
    for t in times:
        await db.execute(
            text("INSERT INTO medication_times (medication_id, time_of_day) "
                 "VALUES (:mid, :t::time) ON CONFLICT (medication_id, time_of_day) DO NOTHING"),
            {"mid": medication_id, "t": t},
        )


async def _replace_days(db: AsyncSession, medication_id: str, days: list[int]) -> None:
    await db.execute(
        text("DELETE FROM medication_days WHERE medication_id = :mid"), {"mid": medication_id}
    )
    for d in days:
        await db.execute(
            text("INSERT INTO medication_days (medication_id, day_of_week) "
                 "VALUES (:mid, :d) ON CONFLICT (medication_id, day_of_week) DO NOTHING"),
            {"mid": medication_id, "d": d},
        )


async def _build_medication_item(db: AsyncSession, row) -> MedicationItem:
    mid = str(row["id"])
    times    = await _load_times(db, mid)
    days     = await _load_days(db, mid)
    return MedicationItem(
        medication_id=mid,
        name=row["name"],
        dose=row["dose"],
        instructions=row["instructions"],
        times=times,
        days_of_week=days,
        start_date=row["start_date"],
        end_date=row["end_date"],
        prescribed_by=str(row["prescribed_by"]) if row["prescribed_by"] else None,
        is_active=row["discontinued_at"] is None,
    )


async def _load_medication(db: AsyncSession, patient_id: str,
                           medication_id: str) -> MedicationItem:
    row = (
        await db.execute(
            text(
                "SELECT id, name, dose, instructions, start_date, end_date, "
                "prescribed_by, discontinued_at "
                "FROM medications WHERE id = :mid AND patient_id = :pid"
            ),
            {"mid": medication_id, "pid": patient_id},
        )
    ).mappings().first()
    if row is None:
        raise ApiError(status_code=404, code="NOT_FOUND",
                       message="El recurso solicitado no existe o no está disponible.")
    return await _build_medication_item(db, row)


# --------------------------------------------------------------------------
# 6.1 Crear medicamento
# --------------------------------------------------------------------------
@router.post("/patients/{patient_id}/medications",
             response_model=MedicationCreateOut, status_code=201)
async def create_medication(
    payload: MedicationCreateIn,
    ctx: PatientContext = Depends(get_patient_member(roles=["caregiver", "doctor"])),
    db: AsyncSession = Depends(get_db),
):
    if payload.end_date is not None and payload.end_date < payload.start_date:
        raise ApiError(status_code=400, code="INVALID_DATE_RANGE",
                       message="La fecha de fin no puede ser anterior a la de inicio.")

    days = payload.days_of_week if payload.days_of_week else _DEFAULT_DAYS
    prescribed_by = ctx.user.user_id if ctx.role == "doctor" else None

    row = (
        await db.execute(
            text(
                "INSERT INTO medications "
                "(patient_id, name, dose, instructions, start_date, end_date, "
                " grace_window_min, prescribed_by) "
                "VALUES (:pid, :name, :dose, :instructions, :start_date, :end_date, "
                "        :grace, :prescribed_by) "
                "RETURNING id, name, prescribed_by, created_at"
            ),
            {
                "pid": ctx.patient_id, "name": payload.name, "dose": payload.dose,
                "instructions": payload.instructions,
                "start_date": payload.start_date, "end_date": payload.end_date,
                "grace": payload.grace_window_min, "prescribed_by": prescribed_by,
            },
        )
    ).mappings().first()

    mid = str(row["id"])
    await _replace_times(db, mid, payload.times)
    await _replace_days(db, mid, days)
    await db.commit()

    return MedicationCreateOut(
        medication_id=mid,
        name=row["name"],
        prescribed_by=str(row["prescribed_by"]) if row["prescribed_by"] else None,
        created_at=row["created_at"],
    )


# --------------------------------------------------------------------------
# 6.2 Listar plan de medicamentos
# --------------------------------------------------------------------------
@router.get("/patients/{patient_id}/medications", response_model=MedicationListOut)
async def list_medications(
    active_only: bool = Query(default=True),
    ctx: PatientContext = Depends(get_patient_member()),
    db: AsyncSession = Depends(get_db),
):
    sql = ("SELECT id, name, dose, instructions, start_date, end_date, "
           "prescribed_by, discontinued_at FROM medications WHERE patient_id = :pid")
    if active_only:
        sql += " AND discontinued_at IS NULL"
    sql += " ORDER BY name"

    rows = (await db.execute(text(sql), {"pid": ctx.patient_id})).mappings().all()
    items = [await _build_medication_item(db, r) for r in rows]
    return MedicationListOut(items=items)


# --------------------------------------------------------------------------
# 6.3 Actualizar medicamento
# --------------------------------------------------------------------------
@router.patch("/patients/{patient_id}/medications/{medication_id}",
              response_model=MedicationItem)
async def update_medication(
    medication_id: str,
    payload: MedicationPatchIn,
    ctx: PatientContext = Depends(get_patient_member(roles=["caregiver", "doctor"])),
    db: AsyncSession = Depends(get_db),
):
    current = await _load_medication(db, ctx.patient_id, medication_id)
    fields  = payload.model_dump(exclude_unset=True)

    new_start = fields.get("start_date", current.start_date)
    new_end   = fields["end_date"] if "end_date" in fields else current.end_date
    if new_end is not None and new_end < new_start:
        raise ApiError(status_code=400, code="INVALID_DATE_RANGE",
                       message="La fecha de fin no puede ser anterior a la de inicio.")

    sets: list[str] = []
    params: dict = {"mid": medication_id, "pid": ctx.patient_id}

    simple_cols = ["name", "dose", "instructions", "start_date", "end_date"]
    for col in simple_cols:
        if col in fields:
            sets.append(f"{col} = :{col}"); params[col] = fields[col]
    if "grace_window_min" in fields:
        sets.append("grace_window_min = :grace"); params["grace"] = fields["grace_window_min"]

    if sets:
        await db.execute(
            text(f"UPDATE medications SET {', '.join(sets)} "
                 "WHERE id = :mid AND patient_id = :pid"),
            params,
        )

    if "times" in fields:
        await _replace_times(db, medication_id, fields["times"])
    if "days_of_week" in fields:
        days = fields["days_of_week"] if fields["days_of_week"] else _DEFAULT_DAYS
        await _replace_days(db, medication_id, days)

    await db.commit()
    return await _load_medication(db, ctx.patient_id, medication_id)


# --------------------------------------------------------------------------
# 6.4 Descontinuar medicamento
# --------------------------------------------------------------------------
@router.delete("/patients/{patient_id}/medications/{medication_id}", status_code=204)
async def discontinue_medication(
    medication_id: str,
    ctx: PatientContext = Depends(get_patient_member(roles=["caregiver", "doctor"])),
    db: AsyncSession = Depends(get_db),
):
    await _load_medication(db, ctx.patient_id, medication_id)
    await db.execute(
        text("UPDATE medications SET discontinued_at = now() "
             "WHERE id = :mid AND patient_id = :pid AND discontinued_at IS NULL"),
        {"mid": medication_id, "pid": ctx.patient_id},
    )
    await db.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)


# --------------------------------------------------------------------------
# 6.5 Dosis del día (sin patient_id en scheduled_doses → JOIN medications)
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
                WHERE m.patient_id = :pid
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

    next_dose = next((it for it in items if it.status == "pending"), None)
    return DosesListOut(items=items, next_dose=next_dose)


# --------------------------------------------------------------------------
# 6.6 Registrar administración de dosis
# --------------------------------------------------------------------------
@router.post("/doses/{dose_id}/log", response_model=DoseLogOut)
async def log_dose(
    dose_id: str,
    payload: DoseLogIn,
    user: CurrentUser = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    # scheduled_doses no tiene patient_id → obtenemos el paciente por JOIN
    dose = (
        await db.execute(
            text(
                """
                SELECT sd.id, m.patient_id, sd.scheduled_at, sd.status
                FROM scheduled_doses sd
                JOIN medications m ON m.id = sd.medication_id
                WHERE sd.id = :did
                """
            ),
            {"did": dose_id},
        )
    ).mappings().first()

    if dose is None:
        raise ApiError(status_code=404, code="NOT_FOUND",
                       message="El recurso solicitado no existe o no está disponible.")

    membership = (
        await db.execute(
            text(
                "SELECT pm.role FROM patient_members pm JOIN patients p ON p.id = pm.patient_id "
                "WHERE pm.patient_id = :pid AND pm.user_id = :uid AND pm.role = 'caregiver' "
                "AND pm.removed_at IS NULL AND p.deleted_at IS NULL"
            ),
            {"pid": str(dose["patient_id"]), "uid": user.user_id},
        )
    ).mappings().first()

    if membership is None:
        raise ApiError(status_code=404, code="NOT_FOUND",
                       message="El recurso solicitado no existe o no está disponible.")

    if dose["status"] != "pending":
        raise ApiError(status_code=409, code="DOSE_ALREADY_LOGGED",
                       message="Esta dosis ya fue registrada.")

    if payload.status not in ("taken", "postponed", "missed"):
        raise ApiError(status_code=422, code="VALIDATION_ERROR",
                       message="Hay datos inválidos en la solicitud. Revisa los campos marcados.")

    if payload.status == "missed" and not payload.reason:
        raise ApiError(status_code=400, code="MISSING_REASON",
                       message="Debes indicar el motivo cuando la dosis se marca como omitida.")

    postponed_until = None
    if payload.status == "postponed":
        if payload.postponed_until is None:
            raise ApiError(status_code=422, code="VALIDATION_ERROR",
                           message="Hay datos inválidos en la solicitud. Revisa los campos marcados.")
        limit = dose["scheduled_at"] + timedelta(hours=4)
        if payload.postponed_until > limit:
            raise ApiError(status_code=400, code="INVALID_POSTPONE_TIME",
                           message="La dosis solo puede posponerse hasta 4 horas.")
        postponed_until = payload.postponed_until

    await db.execute(
        text(
            "UPDATE scheduled_doses SET status = :status, logged_by = :uid, "
            "logged_at = now(), reason = :reason, postponed_until = :postponed_until "
            "WHERE id = :did"
        ),
        {"status": payload.status, "uid": user.user_id, "reason": payload.reason,
         "postponed_until": postponed_until, "did": dose_id},
    )
    await db.commit()
    return DoseLogOut(dose_id=dose_id, status=payload.status, alert_triggered=False)


# --------------------------------------------------------------------------
# 6.7 Métricas de adherencia (JOIN medications para obtener patient_id)
# --------------------------------------------------------------------------
@router.get("/patients/{patient_id}/adherence", response_model=AdherenceOut)
async def adherence(
    date_from: date = Query(...),
    date_to:   date = Query(...),
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
                WHERE m.patient_id = :pid
                  AND sd.scheduled_at::date BETWEEN :df AND :dt
                """
            ),
            {"pid": ctx.patient_id, "df": date_from, "dt": date_to},
        )
    ).mappings().all()

    taken = missed = skipped = 0
    per_med: dict[str, dict] = {}
    per_day: dict[date, dict] = {}

    for r in rows:
        s   = r["status"]
        mid = str(r["medication_id"])
        day = r["day"]

        if s == "taken":   taken   += 1
        elif s == "missed": missed  += 1
        elif s == "skipped": skipped += 1

        med = per_med.setdefault(mid, {"name": r["medication_name"], "taken": 0, "not_taken": 0})
        if s == "taken":              med["taken"]     += 1
        elif s in ("missed","skipped"): med["not_taken"] += 1

        d = per_day.setdefault(day, {"taken": 0, "missed": 0, "pending": 0})
        if s == "taken":               d["taken"]   += 1
        elif s in ("missed","skipped"): d["missed"]  += 1
        elif s == "pending":            d["pending"] += 1

    def _pct(t: int, nt: int) -> float:
        return round(t / (t + nt) * 100, 2) if (t + nt) > 0 else 100.0

    return AdherenceOut(
        adherence_pct=_pct(taken, missed + skipped),
        taken=taken,
        missed=missed,
        by_medication=[AdherenceByMedication(medication_id=mid, name=d["name"],
                                             adherence_pct=_pct(d["taken"], d["not_taken"]))
                       for mid, d in per_med.items()],
        daily=[AdherenceDaily(date=day, taken=d["taken"], missed=d["missed"], pending=d["pending"])
               for day, d in sorted(per_day.items())],
    )
