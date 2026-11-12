"""Módulo 6: Medicamentos y adherencia (endpoints 6.1–6.7).

Cambios 2FN aplicados:
- medications: times/days_of_week JSON eliminados → medication_times + medication_days.
- scheduled_doses: patient_id eliminado; todas las queries filtran por paciente
  haciendo JOIN medications.patient_id.
"""
import json
from datetime import date, datetime, time, timedelta

from fastapi import APIRouter, BackgroundTasks, Depends, Query, Response, status
from pydantic import BaseModel, Field
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

from app.avisos import despachar
from app.db import get_db
from app.deps import CurrentUser, PatientContext, get_current_user, get_patient_member
from app.errors import ApiError
from app.ocr_provider import OcrFallo, OcrNotConfigured, get_ocr
from app.plan_dosis import cancelar_futuras_de_medicamento
from app.receta_lector import leer_receta
from app.routers.logbook import _archivo_del_paciente
from app.storage import get_storage

router = APIRouter(prefix="/api/v1", tags=["medications"])


# --------------------------------------------------------------------------
# Schemas
# --------------------------------------------------------------------------
class MedicationCreateIn(BaseModel):
    name:             str = Field(min_length=2, max_length=120)
    dose_amount:      float = Field(gt=0)
    dose_unit:        str = Field(min_length=1, max_length=20)
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
    dose_amount:      float | None = Field(default=None, gt=0)
    dose_unit:        str | None = Field(default=None, min_length=1, max_length=20)
    instructions:     str | None = None
    times:            list[str] | None = Field(default=None, min_length=1, max_length=8)
    days_of_week:     list[int] | None = None
    start_date:       date | None = None
    end_date:         date | None = None
    grace_window_min: int | None = Field(default=None, ge=5, le=240)


class MedicationItem(BaseModel):
    medication_id: str
    name:          str
    dose:          str          # presentación: dose_text (dose_amount + dose_unit)
    dose_amount:   float
    dose_unit:     str
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
    administered_at: datetime | None = None
    logged_by:       str | None = None
    logged_at:       datetime | None = None
    reason:          str | None = None


class DosesListOut(BaseModel):
    items:     list[DoseItem]
    next_dose: DoseItem | None = None


class DoseLogIn(BaseModel):
    status:          str
    administered_at: datetime | None = None   # hora real de administración (si taken)
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
        # asyncpg requiere un objeto time nativo, no el string "HH:MM".
        parsed = t if isinstance(t, time) else time.fromisoformat(t)
        await db.execute(
            text("INSERT INTO medication_times (medication_id, time_of_day) "
                 "VALUES (:mid, :t) ON CONFLICT (medication_id, time_of_day) DO NOTHING"),
            {"mid": medication_id, "t": parsed},
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
        dose=row["dose_text"],
        dose_amount=float(row["dose_amount"]),
        dose_unit=row["dose_unit"],
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
                "SELECT id, name, dose_amount, dose_unit, dose_text, instructions, "
                "start_date, end_date, prescribed_by, discontinued_at "
                "FROM medications WHERE id = :mid AND patient_id = :pid"
            ),
            {"mid": medication_id, "pid": patient_id},
        )
    ).mappings().first()
    if row is None:
        raise ApiError(status_code=404, code="NOT_FOUND",
                       message="El recurso solicitado no existe o no está disponible.")
    return await _build_medication_item(db, row)


async def _exigir_sin_tratamiento_vigente(db: AsyncSession, patient_id: str) -> None:
    """Corta el camino viejo cuando el paciente ya está en el modelo de tratamientos.

    El modelo vigente es el de tratamientos (306 y 960): catálogo de fármacos,
    rango de dosis, cruce de alergias y versionado. Si el paciente tiene un
    tratamiento vigente, el generador de dosis ignora la tabla medications, así
    que un medicamento creado o editado aquí quedaba en el plan pero NUNCA
    generaba dosis, y nadie se enteraba. Mejor un 409 que lo diga.
    """
    vigente = (
        await db.execute(
            text("SELECT 1 FROM treatments WHERE patient_id = :pid "
                 "AND status = 'vigente' LIMIT 1"),
            {"pid": patient_id},
        )
    ).first()
    if vigente:
        raise ApiError(
            status_code=409,
            code="USE_TREATMENTS",
            message=("Este paciente tiene tratamiento vigente. Los medicamentos "
                     "se indican y se cambian desde Tratamientos."),
        )


# --------------------------------------------------------------------------
# 6.1 Crear medicamento
# --------------------------------------------------------------------------
@router.post("/patients/{patient_id}/medications",
             response_model=MedicationCreateOut, status_code=201)
async def create_medication(
    payload: MedicationCreateIn,
    ctx: PatientContext = Depends(get_patient_member(roles=["doctor"])),
    db: AsyncSession = Depends(get_db),
):
    await _exigir_sin_tratamiento_vigente(db, ctx.patient_id)
    if payload.end_date is not None and payload.end_date < payload.start_date:
        raise ApiError(status_code=400, code="INVALID_DATE_RANGE",
                       message="La fecha de fin no puede ser anterior a la de inicio.")

    days = payload.days_of_week if payload.days_of_week else _DEFAULT_DAYS
    # Crear, editar y discontinuar quedan en el medico. La cuidadora registra
    # tomas (6.6), que es otra cosa: puede decir que la dosis se tomo o no,
    # no cambiar lo que esta indicado. Con eso prescribed_by deja de poder
    # quedar nulo, que es lo que permite despues saber quien indico cada cosa.
    prescribed_by = ctx.user.user_id

    row = (
        await db.execute(
            text(
                "INSERT INTO medications "
                "(patient_id, name, dose_amount, dose_unit, instructions, start_date, "
                " end_date, grace_window_min, prescribed_by) "
                "VALUES (:pid, :name, :dose_amount, :dose_unit, :instructions, "
                "        :start_date, :end_date, :grace, :prescribed_by) "
                "RETURNING id, name, prescribed_by, created_at"
            ),
            {
                "pid": ctx.patient_id, "name": payload.name,
                "dose_amount": payload.dose_amount, "dose_unit": payload.dose_unit,
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
    sql = ("SELECT id, name, dose_amount, dose_unit, dose_text, instructions, "
           "start_date, end_date, prescribed_by, discontinued_at "
           "FROM medications WHERE patient_id = :pid")
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
    ctx: PatientContext = Depends(get_patient_member(roles=["doctor"])),
    db: AsyncSession = Depends(get_db),
):
    await _exigir_sin_tratamiento_vigente(db, ctx.patient_id)
    current = await _load_medication(db, ctx.patient_id, medication_id)
    fields  = payload.model_dump(exclude_unset=True)

    new_start = fields.get("start_date", current.start_date)
    new_end   = fields["end_date"] if "end_date" in fields else current.end_date
    if new_end is not None and new_end < new_start:
        raise ApiError(status_code=400, code="INVALID_DATE_RANGE",
                       message="La fecha de fin no puede ser anterior a la de inicio.")

    sets: list[str] = []
    params: dict = {"mid": medication_id, "pid": ctx.patient_id}

    simple_cols = ["name", "dose_amount", "dose_unit", "instructions", "start_date", "end_date"]
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

    # RF-26: modificar regenera SOLO las tomas futuras. Las ya generadas
    # siguen el horario viejo, asi que se cancelan y el generador vuelve a
    # crearlas con el nuevo; las que coincidan con una hora que no cambio las
    # revive tal cual, sin duplicar.
    #
    # Solo si cambio algo que afecte la agenda. Corregir el nombre o las
    # instrucciones no tiene por que mover ninguna toma.
    AGENDA = {"times", "days_of_week", "start_date", "end_date",
              "dose_amount", "dose_unit"}
    if AGENDA & fields.keys():
        await cancelar_futuras_de_medicamento(
            db, medication_id, motivo="Cambió la indicación")

    await db.commit()
    return await _load_medication(db, ctx.patient_id, medication_id)


# --------------------------------------------------------------------------
# 6.4 Descontinuar medicamento
# --------------------------------------------------------------------------
@router.delete("/patients/{patient_id}/medications/{medication_id}", status_code=204)
async def discontinue_medication(
    medication_id: str,
    ctx: PatientContext = Depends(get_patient_member(roles=["doctor"])),
    db: AsyncSession = Depends(get_db),
):
    await _load_medication(db, ctx.patient_id, medication_id)
    await db.execute(
        text("UPDATE medications SET discontinued_at = now() "
             "WHERE id = :mid AND patient_id = :pid AND discontinued_at IS NULL"),
        {"mid": medication_id, "pid": ctx.patient_id},
    )
    # RF-27: descontinuar conserva el historial, pero lo que todavía no pasó
    # deja de corresponder. Sin esto le seguían apareciendo las tomas de un
    # remedio suspendido, el barrido horario las marcaba omitidas y le
    # bajaban la adherencia sin que nadie hiciera nada mal.
    await cancelar_futuras_de_medicamento(
        db, medication_id, motivo="Se descontinuó el medicamento")
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
                SELECT sd.id AS dose_id,
                       COALESCE(sd.medication_id, ti.id) AS medication_id,
                       COALESCE(m.name, ti.name)         AS medication_name,
                       COALESCE(m.dose_text, ti.dose_text) AS dose_text,
                       sd.scheduled_at, sd.status, sd.administered_at,
                       sd.logged_by, sd.logged_at, sd.reason
                FROM scheduled_doses sd
                LEFT JOIN medications m ON m.id = sd.medication_id
                LEFT JOIN treatment_items ti ON ti.id = sd.treatment_item_id
                LEFT JOIN treatments tr ON tr.id = ti.treatment_id
                WHERE COALESCE(m.patient_id, tr.patient_id) = :pid
                  AND sd.scheduled_at::date = :d
                  -- Una toma cancelada dejó de corresponder: no se muestra
                  -- ni se puede registrar. Queda en la tabla por el
                  -- expediente, no para la pantalla del día.
                  AND sd.status <> 'cancelled'
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
            dose=r["dose_text"],
            scheduled_at=r["scheduled_at"],
            status=r["status"],
            administered_at=r["administered_at"],
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
    segundo_plano: BackgroundTasks,
    user: CurrentUser = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    # scheduled_doses no tiene patient_id → obtenemos el paciente por JOIN
    dose = (
        await db.execute(
            text(
                """
                SELECT sd.id,
                       COALESCE(m.patient_id, tr.patient_id) AS patient_id,
                       sd.scheduled_at, sd.status, sd.logged_by,
                       COALESCE(m.name, ti.name)         AS medication_name,
                       COALESCE(m.dose_text, ti.dose_text) AS dose_text
                FROM scheduled_doses sd
                LEFT JOIN medications m ON m.id = sd.medication_id
                LEFT JOIN treatment_items ti ON ti.id = sd.treatment_item_id
                LEFT JOIN treatments tr ON tr.id = ti.treatment_id
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

    # Se puede registrar una dosis que todavia no resolvio una PERSONA.
    #
    #   pending            : nadie la ha tocado.
    #   postponed          : esta esperando su nueva hora. Antes caia aqui y
    #                        devolvia 409, asi que una dosis pospuesta no se
    #                        podia marcar nunca mas: quedaba trabada para
    #                        siempre y no contaba ni a favor ni en contra.
    #   missed sin logged_by: la marco el proceso de mantenimiento porque se
    #                        paso la hora, no una persona. Si la cuidadora
    #                        llega con hora y media de retraso y se la da,
    #                        tiene que poder registrarlo; negarselo es
    #                        guardar que no se administro una dosis que si
    #                        se administro.
    #
    # Lo que no se puede es pisar lo que alguien ya declaro: taken, skipped,
    # adverse, o missed con el motivo que escribio la cuidadora. 'adverse' es
    # terminal: ya gatillo una alerta y dejo constancia del problema, no puede
    # reescribirse como si no hubiera pasado.
    resuelta_por_alguien = (
        dose["status"] in ("taken", "skipped", "adverse")
        or (dose["status"] == "missed" and dose["logged_by"] is not None)
    )
    if resuelta_por_alguien:
        raise ApiError(status_code=409, code="DOSE_ALREADY_LOGGED",
                       message="Esta dosis ya fue registrada.")

    if payload.status not in ("taken", "postponed", "missed", "adverse"):
        raise ApiError(status_code=422, code="VALIDATION_ERROR",
                       message="Hay datos inválidos en la solicitud. Revisa los campos marcados.")

    # missed y adverse exigen motivo: dejan constancia de por qué la dosis no
    # quedó administrada con normalidad. 'adverse' cubre cualquier caso real
    # (la vomitó, la escupió, se atragantó, reacción...) sin estados fijos; el
    # texto libre es donde la cuidadora describe lo que de verdad pasó.
    if payload.status in ("missed", "adverse") and not payload.reason:
        raise ApiError(status_code=400, code="MISSING_REASON",
                       message="Debes indicar el motivo cuando la dosis no se administró con normalidad.")

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

    # Hora REAL de administración (hecho clínico). Para 'taken': la enviada por
    # la cuidadora o, si no la indica, el momento del registro. El CHECK de la BD
    # exige administered_at cuando status='taken' y que no sea anterior a scheduled_at.
    administered_at = None
    if payload.status == "taken":
        administered_at = payload.administered_at or datetime.now(dose["scheduled_at"].tzinfo)
        if administered_at < dose["scheduled_at"]:
            administered_at = dose["scheduled_at"]

    # 'adverse' = se administró pero hubo un problema: el fármaco entró al
    # cuerpo, así que lleva administered_at como 'taken' (hecho clínico).
    if payload.status == "adverse" and administered_at is None:
        administered_at = payload.administered_at or datetime.now(dose["scheduled_at"].tzinfo)
        if administered_at < dose["scheduled_at"]:
            administered_at = dose["scheduled_at"]

    await db.execute(
        text(
            "UPDATE scheduled_doses SET status = :status, logged_by = :uid, "
            "logged_at = now(), administered_at = :administered_at, "
            "reason = :reason, postponed_until = :postponed_until "
            "WHERE id = :did"
        ),
        {"status": payload.status, "uid": user.user_id,
         "administered_at": administered_at, "reason": payload.reason,
         "postponed_until": postponed_until, "did": dose_id},
    )

    # Un evento adverso al administrar avisa a la red de apoyo (DEF-003). Es una
    # alerta 'incident' igual que las de la bitácora: el familiar y el médico
    # tienen que enterarse de que la dosis se dio pero no quedó bien. El texto
    # libre (reason) describe el caso real; el sistema no lo encasilla.
    alert_triggered = False
    if payload.status == "adverse":
        detalle = (f"{dose['medication_name']} {dose['dose_text']}: "
                   f"{payload.reason}")[:500]
        await db.execute(
            text(
                """
                INSERT INTO alerts
                    (patient_id, type, severity, title, detail,
                     payload, dedup_key, status)
                VALUES
                    (:pid, 'incident', 'warning', :title, :detalle,
                     CAST(:payload AS jsonb), NULL, 'active')
                """
            ),
            {
                "pid": str(dose["patient_id"]),
                "title": f"Problema al administrar {dose['medication_name']}",
                "detalle": detalle,
                "payload": json.dumps({
                    "dose_id": dose_id,
                    "medication": dose["medication_name"],
                    "dose": dose["dose_text"],
                    "dose_status": payload.status,
                    "reason": payload.reason,
                }),
            },
        )
        alert_triggered = True

    await db.commit()
    if alert_triggered:
        segundo_plano.add_task(despachar)
    return DoseLogOut(dose_id=dose_id, status=payload.status,
                      alert_triggered=alert_triggered)


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
                SELECT COALESCE(sd.medication_id, ti.id) AS medication_id,
                       COALESCE(m.name, ti.name) AS medication_name,
                       sd.status, sd.scheduled_at::date AS day
                FROM scheduled_doses sd
                LEFT JOIN medications m ON m.id = sd.medication_id
                LEFT JOIN treatment_items ti ON ti.id = sd.treatment_item_id
                LEFT JOIN treatments tr ON tr.id = ti.treatment_id
                WHERE COALESCE(m.patient_id, tr.patient_id) = :pid
                  AND sd.scheduled_at::date BETWEEN :df AND :dt
                """
            ),
            {"pid": ctx.patient_id, "df": date_from, "dt": date_to},
        )
    ).mappings().all()

    taken = missed = skipped = 0
    per_med: dict[str, dict] = {}
    per_day: dict[date, dict] = {}

    # 'adverse' cuenta como "no tomada": el medicamento no quedó administrado
    # con normalidad, así que penaliza la adherencia igual que missed/skipped.
    NO_TOMADA = ("missed", "skipped", "adverse")

    for r in rows:
        s   = r["status"]
        mid = str(r["medication_id"])
        day = r["day"]

        if s == "taken":   taken   += 1
        elif s == "missed": missed  += 1
        elif s == "skipped": skipped += 1
        elif s == "adverse": missed += 1

        med = per_med.setdefault(mid, {"name": r["medication_name"], "taken": 0, "not_taken": 0})
        if s == "taken":              med["taken"]     += 1
        elif s in NO_TOMADA:          med["not_taken"] += 1

        d = per_day.setdefault(day, {"taken": 0, "missed": 0, "pending": 0})
        if s == "taken":               d["taken"]   += 1
        elif s in NO_TOMADA:           d["missed"]  += 1
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


# ---------------------------------------------------------------------------
# Leer una receta fotografiada
#
# La pantalla sube la foto como kind 'prescription' y despues llama aqui. Lo
# que devuelve son BORRADORES: el OCR se equivoca, y de estos campos salen
# las dosis que se le dan a un adulto mayor. Un 50 mg borroso se puede leer
# 500, asi que nada de lo que sale de aqui se guarda solo. El medico revisa
# campo por campo en el formulario y confirma.
#
# No crea medicamentos. Para eso esta 6.1, que exige rol medico.
# ---------------------------------------------------------------------------
class EscaneoIn(BaseModel):
    # La aplicacion guarda la URL que recibio al subir, no el id, igual que
    # en la bitacora y el chat.
    media_url: str = Field(min_length=1)


class BorradorOut(BaseModel):
    name:         str
    dose:         str
    unit:         str
    schedule:     list[str]
    instructions: str
    # La linea tal como la leyo el OCR. La pantalla la muestra junto al campo
    # para que el medico compare sin volver a abrir la foto.
    origen:       str


class EscaneoOut(BaseModel):
    medications: list[BorradorOut]
    # El texto completo, para cuando el lector no encontro nada y la persona
    # necesita ver que si leyo algo, aunque no lo supiera interpretar.
    texto:       str
    confianza:   float | None = None
    # True cuando se leyo pero no salio ninguna indicacion reconocible. La
    # pantalla lo distingue de un error: la foto puede estar bien y la receta
    # ser manuscrita.
    sin_indicaciones: bool


@router.post("/patients/{patient_id}/medications/scan", response_model=EscaneoOut)
async def escanear_receta(
    payload: EscaneoIn,
    ctx: PatientContext = Depends(get_patient_member()),
    db: AsyncSession = Depends(get_db),
):
    """Lee una receta ya subida y propone indicaciones para revisar.

    Cualquier miembro del circulo puede escanear, no solo el medico: el
    familiar que llega de la consulta con el papel en la mano es quien le
    saca la foto. Lo que ninguno de ellos puede hacer es guardar la
    indicacion, y eso lo sigue cuidando 6.1.
    """
    file_id = await _archivo_del_paciente(db, payload.media_url, ctx.patient_id)
    if file_id is None:
        raise ApiError(
            status_code=422, code="VALIDATION_ERROR",
            message="Hay que indicar la foto de la receta.",
            details=[{"field": "media_url", "message": "No puede venir vacio."}],
        )

    row = (
        await db.execute(
            text("SELECT id, storage_key, mime_type, status FROM files "
                 "WHERE id = :fid"),
            {"fid": file_id},
        )
    ).mappings().first()
    if row is None or row["status"] != "stored":
        raise ApiError(
            status_code=404, code="NOT_FOUND",
            message="La foto de la receta no esta disponible.",
        )

    ocr = get_ocr()
    if not ocr.disponible:
        raise ApiError(
            status_code=503, code="OCR_NOT_CONFIGURED",
            message="La lectura de recetas no esta habilitada en este servidor.",
        )

    try:
        contenido = await get_storage().load(storage_key=row["storage_key"])
    except Exception as e:
        raise ApiError(
            status_code=502, code="STORAGE_ERROR",
            message="No se pudo leer la foto almacenada.",
        ) from e

    try:
        extraido = await ocr.extraer(contenido=contenido,
                                     mime_type=row["mime_type"])
    except OcrNotConfigured as e:
        raise ApiError(status_code=503, code="OCR_NOT_CONFIGURED",
                       message=str(e)) from e
    except OcrFallo as e:
        raise ApiError(status_code=422, code="OCR_FAILED",
                       message=str(e)) from e

    # El texto se guarda igual que con cualquier otro archivo, asi que la
    # receta queda buscable y el asistente la puede citar sin volver a
    # procesar la imagen.
    await db.execute(
        text(
            """
            INSERT INTO file_ocr
                (file_id, texto, motor, idioma, confianza, caracteres)
            VALUES (:fid, :txt, :motor, :idioma, :conf, :chars)
            ON CONFLICT (file_id) DO UPDATE SET
                texto       = EXCLUDED.texto,
                motor       = EXCLUDED.motor,
                idioma      = EXCLUDED.idioma,
                confianza   = EXCLUDED.confianza,
                caracteres  = EXCLUDED.caracteres,
                extraido_at = now()
            """
        ),
        {"fid": file_id, "txt": extraido.texto, "motor": extraido.motor,
         "idioma": extraido.idioma, "conf": extraido.confianza,
         "chars": extraido.caracteres},
    )
    await db.commit()

    borradores = leer_receta(extraido.texto)
    return EscaneoOut(
        medications=[BorradorOut(**b.to_json()) for b in borradores],
        texto=extraido.texto,
        confianza=extraido.confianza,
        sin_indicaciones=not borradores,
    )
