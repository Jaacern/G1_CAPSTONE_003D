"""Módulo 6b: Tratamientos e indicaciones (DEF-007/008/006/014).

Un tratamiento es el conjunto de indicaciones vigentes que el médico define en
un momento dado. Cambiar el esquema NO edita en el lugar: cierra el vigente y
crea uno nuevo versionando cada indicación. Así queda el historial
("losartán 50 → 100 → 80") consultable.

Decisión confirmada: SOLO el médico define tratamiento. La cuidadora y el
familiar lo leen; la cuidadora además registra la administración de cada dosis
(eso vive en medications.py / scheduled_doses).
"""
from datetime import date, datetime, time
from uuid import UUID

from fastapi import APIRouter, Depends
from pydantic import BaseModel, Field
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

from app.db import get_db
from app.deps import CurrentUser, PatientContext, get_current_user, get_patient_member
from app.errors import ApiError

router = APIRouter(prefix="/api/v1", tags=["treatments"])

_DEFAULT_DAYS = list(range(1, 8))

# Topes de cordura ABSOLUTOS por unidad (seguridad del paciente). Última red
# cuando el fármaco es texto libre y no tiene rango del catálogo. Ningún número
# por sobre esto entra, pase lo que pase. No reemplaza al rango por fármaco.
_SANITY_MAX = {
    "mg": 5000.0, "g": 10.0, "mcg": 2000.0, "ml": 100.0, "UI": 500.0,
    "gotas": 60.0, "puff": 10.0, "comprimido": 10.0, "cápsula": 10.0,
    "parche": 5.0, "gotas ": 60.0,
}


async def _validar_dosis_segura(db: AsyncSession, it: "ItemIn") -> None:
    """Valida unidad y dosis contra el catálogo (si hay drug_code) o, en su
    defecto, contra los topes de cordura por unidad. Rechaza con 422.

    Es la barrera de SEGURIDAD del paciente en el backend: aunque la UI o una
    petición manipulada envíen un disparate, aquí se frena y no se guarda.
    """
    if it.drug_code:
        row = (
            await db.execute(
                text("SELECT unit, dose_min, dose_max FROM drug_catalog WHERE code = :c"),
                {"c": it.drug_code},
            )
        ).mappings().first()
        if row is None:
            raise ApiError(status_code=422, code="VALIDATION_ERROR",
                           message=f"El fármaco '{it.drug_code}' no está en el catálogo.")
        # La unidad la manda el fármaco: debe coincidir con la del catálogo.
        if it.dose_unit != row["unit"]:
            raise ApiError(status_code=422, code="INVALID_DOSE_UNIT",
                           message=f"{it.name} se mide en {row['unit']}, no en {it.dose_unit}.")
        if not (float(row["dose_min"]) <= it.dose_amount <= float(row["dose_max"])):
            raise ApiError(status_code=422, code="DOSE_OUT_OF_RANGE",
                           message=f"La dosis de {it.name} debe estar entre "
                                   f"{_fmt(row['dose_min'])} y {_fmt(row['dose_max'])} {row['unit']}.")
        return

    # Sin catálogo: al menos el tope de cordura por unidad.
    tope = _SANITY_MAX.get(it.dose_unit)
    if tope is not None and it.dose_amount > tope:
        raise ApiError(status_code=422, code="DOSE_OUT_OF_RANGE",
                       message=f"La dosis de {it.name} ({_fmt(it.dose_amount)} {it.dose_unit}) "
                               "supera el máximo razonable. Revisa la unidad.")


def _fmt(v) -> str:
    f = float(v)
    return str(int(f)) if f == int(f) else str(f)


async def _chequear_alergias(db: AsyncSession, patient_id: str,
                             items: 'list[ItemIn]') -> list[dict]:
    """Devuelve los choques entre los fármacos a prescribir y las alergias a
    medicamentos vigentes del paciente. Cada choque: {drug, allergen, severity}.

    El cruce es por principio activo: el fármaco del catálogo tiene
    active_ingredient; el alérgeno de medicamento también (via allergen_catalog).
    Es una ADVERTENCIA, no un bloqueo: el médico decide si confirma (ver endpoint).
    """
    codes = [it.drug_code for it in items if it.drug_code]
    if not codes:
        return []
    rows = (
        await db.execute(
            text(
                """
                SELECT dc.label AS drug_label, dc.active_ingredient,
                       pa.substance, pa.severity,
                       COALESCE(ac.label, pa.substance) AS allergen_label
                FROM drug_catalog dc
                JOIN patient_allergies pa
                     ON pa.patient_id = :pid
                    AND pa.deleted_at IS NULL
                    AND pa.category = 'medicamento'
                LEFT JOIN allergen_catalog ac ON ac.code = pa.substance
                WHERE dc.code = ANY(:codes)
                  AND lower(dc.active_ingredient) = lower(
                        COALESCE(ac.active_ingredient, pa.substance))
                """
            ),
            {"pid": patient_id, "codes": codes},
        )
    ).mappings().all()
    return [
        {
            "drug": r["drug_label"],
            "allergen": r["allergen_label"],
            "severity": r["severity"],
        }
        for r in rows
    ]


# --------------------------------------------------------------------------
# Schemas
# --------------------------------------------------------------------------
class ItemIn(BaseModel):
    # Si continues_item_id viene, esta indicación continúa un fármaco anterior
    # (cambio de dosis/horario). Si no, es nueva en el esquema.
    name:             str = Field(min_length=2, max_length=120)
    dose_amount:      float = Field(gt=0)
    dose_unit:        str = Field(min_length=1, max_length=20)
    # Si el fármaco viene del catálogo, su code permite validar unidad y rango
    # de dosis seguros (seguridad del paciente). Opcional: texto libre si no.
    drug_code:        str | None = None
    instructions:     str | None = None
    times:            list[str] = Field(default_factory=list, max_length=8)
    days_of_week:     list[int] | None = None
    grace_window_min: int = Field(default=60, ge=5, le=720)
    continues_item_id: str | None = None   # item del tratamiento vigente que continúa
    is_prn:           bool = False          # SOS/condicional: no genera agenda
    schedule_label:   str | None = Field(default=None, max_length=40)


class TreatmentCreateIn(BaseModel):
    items:          list[ItemIn] = Field(min_length=1, max_length=30)
    note:           str | None = Field(default=None, max_length=500)
    specialty:      str = Field(default="general", max_length=40)
    review_date:    date | None = None        # None = permanente; con fecha = temporal
    effective_from: datetime | None = None   # puede fecharse en el pasado, no futuro
    # El médico confirma prescribir pese a una alergia detectada (ver cruce de
    # alergias). Sin esto, un fármaco que choca con una alergia se frena con 409.
    confirm_allergy: bool = False


class ItemOut(BaseModel):
    item_id:       str
    name:          str
    dose:          str
    dose_amount:   float
    dose_unit:     str
    instructions:  str | None = None
    times:         list[str]
    days_of_week:  list[int]
    grace_window_min: int
    action:        str
    continues_item_id: str | None = None
    is_prn:        bool = False
    schedule_label: str | None = None
    drug_code:     str | None = None   # fármaco del catálogo, si vino de ahí


class TreatmentOut(BaseModel):
    treatment_id:    str
    patient_id:      str
    status:          str
    specialty:       str
    prescribed_by:   str
    prescriber_name: str | None = None
    prescriber_role: str
    effective_from:  datetime
    effective_to:    datetime | None = None
    review_date:     date | None = None
    supersedes_id:   str | None = None
    note:            str | None = None
    items:           list[ItemOut]


class SpecialtyGroup(BaseModel):
    specialty: str
    current:   TreatmentOut | None = None
    history:   list[TreatmentOut] = []


class TreatmentListOut(BaseModel):
    # Compatibilidad: current/history del esquema anterior (especialidad general
    # o la primera vigente). La vista nueva usa `by_specialty`.
    current:      TreatmentOut | None = None
    history:      list[TreatmentOut] = []
    by_specialty: list[SpecialtyGroup] = []


# --------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------
async def _item_times(db: AsyncSession, item_id: str) -> list[str]:
    rows = (
        await db.execute(
            text("SELECT to_char(time_of_day,'HH24:MI') t FROM treatment_item_times "
                 "WHERE treatment_item_id = :iid ORDER BY time_of_day"),
            {"iid": item_id},
        )
    ).scalars().all()
    return list(rows)


async def _item_days(db: AsyncSession, item_id: str) -> list[int]:
    rows = (
        await db.execute(
            text("SELECT day_of_week FROM treatment_item_days "
                 "WHERE treatment_item_id = :iid ORDER BY day_of_week"),
            {"iid": item_id},
        )
    ).scalars().all()
    return list(rows)


_TREATMENT_COLS = (
    "t.id, t.patient_id, t.status, t.specialty, t.prescribed_by, "
    "t.prescriber_role, t.effective_from, t.effective_to, t.review_date, "
    "t.supersedes_id, t.note, "
    "u.first_name || ' ' || u.last_name AS prescriber_name"
)


async def _load_treatment(db: AsyncSession, row) -> TreatmentOut:
    items_rows = (
        await db.execute(
            text("SELECT id, name, dose_text, dose_amount, dose_unit, instructions, "
                 "grace_window_min, action, continues_item_id, is_prn, schedule_label, "
                 "drug_code "
                 "FROM treatment_items WHERE treatment_id = :tid ORDER BY is_prn, name"),
            {"tid": str(row["id"])},
        )
    ).mappings().all()
    items = []
    for it in items_rows:
        iid = str(it["id"])
        items.append(ItemOut(
            item_id=iid,
            name=it["name"],
            dose=it["dose_text"],
            dose_amount=float(it["dose_amount"]),
            dose_unit=it["dose_unit"],
            instructions=it["instructions"],
            times=await _item_times(db, iid),
            days_of_week=await _item_days(db, iid),
            grace_window_min=it["grace_window_min"],
            action=it["action"],
            continues_item_id=str(it["continues_item_id"]) if it["continues_item_id"] else None,
            is_prn=it["is_prn"],
            schedule_label=it["schedule_label"],
            drug_code=it["drug_code"],
        ))
    return TreatmentOut(
        treatment_id=str(row["id"]),
        patient_id=str(row["patient_id"]),
        status=row["status"],
        specialty=row["specialty"],
        prescribed_by=str(row["prescribed_by"]),
        prescriber_name=row["prescriber_name"],
        prescriber_role=row["prescriber_role"],
        effective_from=row["effective_from"],
        effective_to=row["effective_to"],
        review_date=row["review_date"],
        supersedes_id=str(row["supersedes_id"]) if row["supersedes_id"] else None,
        note=row["note"],
        items=items,
    )


async def _treatment_row(db: AsyncSession, treatment_id: str):
    return (
        await db.execute(
            text(f"SELECT {_TREATMENT_COLS} FROM treatments t "
                 "LEFT JOIN users u ON u.id = t.prescribed_by WHERE t.id = :tid"),
            {"tid": treatment_id},
        )
    ).mappings().first()


# --------------------------------------------------------------------------
# 6b.1 Ver tratamiento vigente (+ historial opcional)
# --------------------------------------------------------------------------
@router.get("/patients/{patient_id}/treatments", response_model=TreatmentListOut)
async def get_treatments(
    include: str | None = None,   # include=history para traer la cadena completa
    ctx: PatientContext = Depends(get_patient_member()),
    db: AsyncSession = Depends(get_db),
):
    # Todos los tratamientos del paciente, de todas las especialidades. Se
    # agrupan en memoria: un paciente puede tener varios vigentes a la vez (uno
    # por especialidad: cardiología, traumatología...), cada uno con su historial.
    rows = (
        await db.execute(
            text(f"SELECT {_TREATMENT_COLS} FROM treatments t "
                 "LEFT JOIN users u ON u.id = t.prescribed_by "
                 "WHERE t.patient_id = :pid "
                 "ORDER BY t.specialty, t.effective_from DESC"),
            {"pid": ctx.patient_id},
        )
    ).mappings().all()

    cargados = [await _load_treatment(db, r) for r in rows]

    grupos: dict[str, SpecialtyGroup] = {}
    for tr in cargados:
        g = grupos.setdefault(tr.specialty, SpecialtyGroup(specialty=tr.specialty))
        if tr.status == "vigente":
            g.current = tr
        elif include == "history":
            g.history.append(tr)

    by_specialty = sorted(grupos.values(), key=lambda g: g.specialty)

    # Compatibilidad hacia atrás: current/history planos. Se prioriza 'general'
    # y, si no hay, la primera especialidad con vigente.
    current = None
    history: list[TreatmentOut] = []
    if "general" in grupos and grupos["general"].current:
        current = grupos["general"].current
        history = grupos["general"].history
    else:
        for g in by_specialty:
            if g.current:
                current = g.current
                history = g.history
                break

    return TreatmentListOut(
        current=current, history=history, by_specialty=by_specialty)


# --------------------------------------------------------------------------
# 6b.2 Crear un tratamiento nuevo (reemplaza al vigente). SOLO médico.
# --------------------------------------------------------------------------
@router.post("/patients/{patient_id}/treatments",
             response_model=TreatmentOut, status_code=201)
async def create_treatment(
    payload: TreatmentCreateIn,
    ctx: PatientContext = Depends(get_patient_member(roles=["doctor"])),
    db: AsyncSession = Depends(get_db),
):
    now = datetime.now()
    effective_from = payload.effective_from or now
    if effective_from > now:
        raise ApiError(status_code=400, code="INVALID_DATE_RANGE",
                       message="El tratamiento no puede comenzar en el futuro.")

    especialidad = (payload.specialty or "general").strip().lower() or "general"

    # CRUCE DE ALERGIAS: si algún fármaco choca con una alergia a medicamento
    # del paciente, se ADVIERTE y se exige que el médico confirme (confirm_allergy).
    # Responsabilidad clínica en el médico, nunca en la cuidadora.
    if not payload.confirm_allergy:
        choques = await _chequear_alergias(db, ctx.patient_id, payload.items)
        if choques:
            detalle = "; ".join(
                f"{c['drug']} (alergia a {c['allergen']}, {c['severity']})"
                for c in choques
            )
            raise ApiError(
                status_code=409, code="ALLERGY_WARNING",
                message=f"El paciente tiene alergia que choca con: {detalle}. "
                        "Confirma para prescribir de todas formas.",
                details=choques,
            )

    # Tratamiento vigente actual DE ESA ESPECIALIDAD (el que este reemplaza).
    # Los de otras especialidades (otro médico, otra área) no se tocan.
    anterior = (
        await db.execute(
            text("SELECT id FROM treatments WHERE patient_id = :pid "
                 "AND specialty = :sp AND status = 'vigente'"),
            {"pid": ctx.patient_id, "sp": especialidad},
        )
    ).mappings().first()
    anterior_id = str(anterior["id"]) if anterior else None

    # continues_item_id válidos: items del tratamiento anterior.
    items_anteriores: set[str] = set()
    if anterior_id:
        rows = (
            await db.execute(
                text("SELECT id FROM treatment_items WHERE treatment_id = :tid"),
                {"tid": anterior_id},
            )
        ).scalars().all()
        items_anteriores = {str(r) for r in rows}

    for it in payload.items:
        if it.continues_item_id and it.continues_item_id not in items_anteriores:
            raise ApiError(status_code=422, code="VALIDATION_ERROR",
                           message="Una indicación dice continuar un fármaco que no está en el tratamiento vigente.")

    # Cierra el vigente (si lo hay).
    if anterior_id:
        await db.execute(
            text("UPDATE treatments SET status = 'superseded', effective_to = :ts "
                 "WHERE id = :tid"),
            {"ts": effective_from, "tid": anterior_id},
        )

    # Crea el nuevo vigente.
    nuevo = (
        await db.execute(
            text("INSERT INTO treatments "
                 "(patient_id, status, specialty, prescribed_by, prescriber_role, "
                 " effective_from, review_date, supersedes_id, note) "
                 "VALUES (:pid, 'vigente', :sp, :uid, 'doctor', :ef, :rev, :sup, :note) "
                 "RETURNING id"),
            {"pid": ctx.patient_id, "sp": especialidad, "uid": ctx.user.user_id,
             "ef": effective_from, "rev": payload.review_date,
             "sup": anterior_id, "note": payload.note},
        )
    ).mappings().first()
    tid = str(nuevo["id"])

    # Items del nuevo tratamiento, con su acción (added/kept/changed).
    for it in payload.items:
        # SEGURIDAD: valida unidad y dosis contra el catálogo / topes de cordura
        # ANTES de guardar. Frena "loperamida 2 kg" o "ipratropio 100 ml".
        await _validar_dosis_segura(db, it)
        # Un item programado necesita al menos un horario; uno SOS/condicional
        # (is_prn) no lleva horario porque no genera agenda.
        if not it.is_prn and not it.times:
            raise ApiError(status_code=422, code="VALIDATION_ERROR",
                           message=f"La indicación de {it.name} necesita al menos un horario "
                                   "(o márcala como 'solo si se necesita').")
        action = "added"
        if it.continues_item_id:
            # ¿cambió algo respecto del anterior? dosis u horarios.
            prev = (
                await db.execute(
                    text("SELECT dose_amount, dose_unit FROM treatment_items WHERE id = :iid"),
                    {"iid": it.continues_item_id},
                )
            ).mappings().first()
            prev_times = set(await _item_times(db, it.continues_item_id))
            cambio_dosis = prev and (float(prev["dose_amount"]) != it.dose_amount
                                     or prev["dose_unit"] != it.dose_unit)
            cambio_horas = prev_times != set(it.times)
            action = "changed" if (cambio_dosis or cambio_horas) else "kept"

        item = (
            await db.execute(
                text("INSERT INTO treatment_items "
                     "(treatment_id, name, dose_amount, dose_unit, instructions, "
                     " grace_window_min, continues_item_id, action, is_prn, schedule_label, "
                     " drug_code) "
                     "VALUES (:tid, :name, :da, :du, :ins, :grace, :cont, :action, :prn, :lbl, "
                     " :drug) "
                     "RETURNING id"),
                {"tid": tid, "name": it.name, "da": it.dose_amount, "du": it.dose_unit,
                 "ins": it.instructions, "grace": it.grace_window_min,
                 "cont": it.continues_item_id, "action": action,
                 "prn": it.is_prn, "lbl": it.schedule_label,
                 "drug": it.drug_code},
            )
        ).mappings().first()
        iid = str(item["id"])

        for t in it.times:
            parsed = t if isinstance(t, time) else time.fromisoformat(t)
            await db.execute(
                text("INSERT INTO treatment_item_times (treatment_item_id, time_of_day) "
                     "VALUES (:iid, :t) ON CONFLICT (treatment_item_id, time_of_day) DO NOTHING"),
                {"iid": iid, "t": parsed},
            )
        for d in (it.days_of_week or _DEFAULT_DAYS):
            await db.execute(
                text("INSERT INTO treatment_item_days (treatment_item_id, day_of_week) "
                     "VALUES (:iid, :d) ON CONFLICT DO NOTHING"),
                {"iid": iid, "d": d},
            )

    await db.commit()
    return await _load_treatment(db, await _treatment_row(db, tid))


# --------------------------------------------------------------------------
# 6b.3 Adjuntar la receta formal al tratamiento (DEF-014). Médico.
# --------------------------------------------------------------------------
class AttachDocIn(BaseModel):
    document_id: str


@router.post("/patients/{patient_id}/treatments/{treatment_id}/documents",
             status_code=201)
async def attach_document(
    treatment_id: str,
    payload: AttachDocIn,
    ctx: PatientContext = Depends(get_patient_member(roles=["doctor", "caregiver"])),
    db: AsyncSession = Depends(get_db),
):
    tr = await _treatment_row(db, treatment_id)
    if tr is None or str(tr["patient_id"]) != ctx.patient_id:
        raise ApiError(status_code=404, code="NOT_FOUND",
                       message="El recurso solicitado no existe o no está disponible.")

    doc = (
        await db.execute(
            text("SELECT id FROM medical_documents "
                 "WHERE id = :did AND patient_id = :pid AND deleted_at IS NULL"),
            {"did": payload.document_id, "pid": ctx.patient_id},
        )
    ).mappings().first()
    if doc is None:
        raise ApiError(status_code=404, code="NOT_FOUND",
                       message="El documento no existe o no pertenece a este paciente.")

    await db.execute(
        text("INSERT INTO treatment_documents (treatment_id, document_id) "
             "VALUES (:tid, :did) ON CONFLICT DO NOTHING"),
        {"tid": treatment_id, "did": payload.document_id},
    )
    await db.commit()
    return {"treatment_id": treatment_id, "document_id": payload.document_id}


# --------------------------------------------------------------------------
# 6b.4 Catálogo de fármacos (para prescribir con unidad y rango seguros)
# --------------------------------------------------------------------------
class DrugCatalogItem(BaseModel):
    code:              str
    active_ingredient: str
    label:             str
    form:              str
    route:             str
    unit:              str
    dose_min:          float
    dose_max:          float
    max_daily:         float | None = None


@router.get("/drugs/catalog", response_model=list[DrugCatalogItem])
async def drugs_catalog(
    user: CurrentUser = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    rows = (
        await db.execute(
            text("SELECT code, active_ingredient, label, form, route, unit, "
                 "dose_min, dose_max, max_daily FROM drug_catalog ORDER BY label")
        )
    ).mappings().all()
    return [
        DrugCatalogItem(
            code=r["code"], active_ingredient=r["active_ingredient"],
            label=r["label"], form=r["form"], route=r["route"], unit=r["unit"],
            dose_min=float(r["dose_min"]), dose_max=float(r["dose_max"]),
            max_daily=float(r["max_daily"]) if r["max_daily"] is not None else None,
        )
        for r in rows
    ]
