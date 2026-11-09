"""Módulo 4: Pacientes, roles y onboarding (endpoints 4.1–4.10).

Cambios 2FN aplicados al esquema:
- patients.full_name es ahora GENERATED (first_name || last_name): lectura directa OK,
  escritura usa first_name + last_name por separado.
- patients.conditions eliminado → tabla patient_conditions.
- sex API (female|male|other) ↔ BD (F|M|O): mapeo conservado.
- scheduled_doses ya no tiene patient_id: las consultas por paciente hacen JOIN.
"""
import json
from datetime import date, datetime, timedelta, timezone

from fastapi import APIRouter, Depends, Response, status
from pydantic import BaseModel, EmailStr, Field
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

from app.db import get_db
from app.deps import CurrentUser, PatientContext, get_current_user, get_patient_member
from app.errors import ApiError
from app.security import generate_refresh_token, hash_token

router = APIRouter(prefix="/api/v1", tags=["patients"])

INVITATION_TTL_DAYS = 7
WEARABLE_STALE_AFTER = timedelta(hours=2)

_SEX_API_TO_DB = {"female": "F", "male": "M", "other": "O"}
_SEX_DB_TO_API = {v: k for k, v in _SEX_API_TO_DB.items()}


# --------------------------------------------------------------------------
# Schemas
# --------------------------------------------------------------------------
class PatientCreateIn(BaseModel):
    first_name: str = Field(min_length=1, max_length=60)
    last_name:  str = Field(min_length=1, max_length=60)
    birth_date: date
    sex: str                        # female | male | other
    photo_url: str | None = None
    conditions: list[str] | None = None
    allergies: list["AllergyIn"] | None = None


class AllergyIn(BaseModel):
    """Una alergia a registrar. substance = code del catálogo o texto libre."""
    substance: str = Field(min_length=2, max_length=80)
    category:  str = "otra"          # medicamento|alimento|ambiental|otra
    severity:  str = "moderada"      # leve|moderada|severa|anafilaxia
    reaction:  str | None = Field(default=None, max_length=200)
    source:    str = "reportada"     # reportada|test|reaccion_tratamiento
    noted_on:  date | None = None


class ImmunizationIn(BaseModel):
    """Una vacuna a registrar (aplicada o programada)."""
    vaccine:         str = Field(min_length=2, max_length=30)   # code del catálogo
    kind:            str | None = None     # hereda del catálogo si no viene
    administered_on: date | None = None
    dose_number:     int | None = Field(default=None, ge=1)
    exposure_event:  str | None = Field(default=None, max_length=200)
    note:            str | None = Field(default=None, max_length=200)


class EmergencyContactIn(BaseModel):
    """Alta de un contacto de emergencia eligiendo un miembro del grupo. No lleva
    prioridad: en un SOS se avisa a todos por igual."""
    member_user_id: str
    notes:          str | None = Field(default=None, max_length=200)


class EmergencyContactPatchIn(BaseModel):
    """Activa/desactiva un contacto (rotación). Sin orden/prioridad."""
    is_active: bool | None = None


class PatientCreateOut(BaseModel):
    patient_id: str
    full_name:  str
    created_at: datetime


class PatientPatchIn(BaseModel):
    first_name:     str | None = Field(default=None, min_length=1, max_length=60)
    last_name:      str | None = Field(default=None, min_length=1, max_length=60)
    birth_date:     date | None = None
    sex:            str | None = None
    photo_url:      str | None = None
    conditions:     list[str] | None = None
    # Perfil clínico ampliado (Fase 2).
    address:        str | None = Field(default=None, max_length=200)
    marital_status: str | None = None
    insurance:      str | None = None
    rcv_level:      str | None = None
    complexity:     str | None = None   # baja|moderada|alta (Fase 6)
    priority:       str | None = None   # baja|media|alta (Fase 6)


class PatientListItem(BaseModel):
    patient_id:       str
    full_name:        str
    photo_url:        str | None = None
    role:             str
    wellbeing_status: str
    # Contexto clínico para la vista del médico (triage): edad y enfermedades
    # junto al nombre, y señales de criticidad para ordenar la lista.
    age:              int | None = None
    conditions:       list[str] = []
    active_alerts_count: int = 0
    critical_alerts_count: int = 0
    top_reason:       str | None = None
    # Desempate cuando coinciden nombre y apellido (dos "Elena Rosales"): RUT,
    # sexo y domicilio. Con eso el médico distingue a dos "Juanito Pérez".
    rut:              str | None = None
    sex:              str | None = None
    address:          str | None = None
    # Contexto clínico de un vistazo (Fase 6): nombres legibles de las
    # enfermedades, alergias (graves primero), complejidad, prioridad y previsión.
    conditions_labels: list[str] = []
    allergies:        list[dict] = []     # [{label, severity}]
    complexity:       str | None = None
    priority:         str | None = None
    insurance:        str | None = None
    # Mini-resumen de signos vitales: últimas lecturas por tipo, para que el
    # médico reconozca al paciente de un vistazo sin abrir la ficha. Cada
    # elemento trae measured_at para mostrar qué tan reciente es.
    vitals_summary:   list[dict] = []


class PatientListOut(BaseModel):
    items: list[PatientListItem]


class WearableSummary(BaseModel):
    wearable_id:  str
    model:        str | None = None
    last_sync_at: datetime | None = None
    battery_pct:  int | None = None


class MeasurementOut(BaseModel):
    weight_kg:   float | None = None
    height_cm:   float | None = None
    bmi:         float | None = None     # calculado (peso/altura²), no almacenado
    measured_at: date


class PatientDetailOut(BaseModel):
    patient_id:     str
    full_name:      str
    first_name:     str
    last_name:      str
    birth_date:     date
    sex:            str
    photo_url:      str | None = None
    conditions:     list[str]
    conditions_detail: list[dict] = []   # [{condition, system, label}]
    allergies:      list[dict] = []      # alergias vigentes (detalle, Fase 6)
    immunizations:  list[dict] = []      # vacunas (carnet, Fase 6)
    wearable:       WearableSummary | None = None
    # Perfil clínico ampliado (Fase 2).
    rut:            str | None = None
    address:        str | None = None
    marital_status: str | None = None
    insurance:      str | None = None
    rcv_level:      str | None = None
    complexity:     str | None = None    # baja|moderada|alta (Fase 6)
    priority:       str | None = None    # baja|media|alta (Fase 6)
    last_seen_by:   dict | None = None    # último médico que lo atendió (Fase 6)
    latest_measurement: MeasurementOut | None = None


class InvitationCreateIn(BaseModel):
    role:         str
    email:        EmailStr | None = None
    profession:   str | None = None   # rol clínico real (kinesiologo, enfermera...)
    relationship: str | None = None   # parentesco (hijo, hija, conyuge...) (Fase 6)


class InvitationCreateOut(BaseModel):
    invitation_id: str
    token:         str
    invite_url:    str
    expires_at:    datetime


class InvitationAcceptIn(BaseModel):
    token: str


class InvitationAcceptOut(BaseModel):
    patient_id: str
    role:       str


class MemberOut(BaseModel):
    user_id:      str
    full_name:    str
    email:        str
    role:         str
    profession:   str | None = None
    relationship: str | None = None   # parentesco (Fase 6)
    is_owner:     bool = False
    joined_at:    datetime


class PendingInvitationOut(BaseModel):
    invitation_id: str
    email:         str
    role:          str
    profession:    str | None = None
    expires_at:    datetime


class MembersListOut(BaseModel):
    members:             list[MemberOut]
    pending_invitations: list[PendingInvitationOut]


class WearableLinkIn(BaseModel):
    serial_number: str
    model:         str


class WearableLinkOut(BaseModel):
    wearable_id: str
    linked_at:   datetime


class WearableStatusOut(BaseModel):
    wearable_id:  str | None = None
    last_sync_at: datetime | None = None
    battery_pct:  int | None = None
    is_stale:     bool


_VALID_INVITE_ROLES = ("family", "caregiver", "doctor", "elder")
_VALID_RELATIONSHIPS = (
    "hijo", "hija", "conyuge", "hermano", "hermana", "nieto", "nieta",
    "sobrino", "sobrina", "yerno", "nuera", "cuidador", "otro",
)
_VALID_PROFESSIONS = (
    "medico_general", "medico_especialista", "kinesiologo", "enfermera",
    "podologa", "nutricionista", "fonoaudiologo", "terapeuta_ocupacional",
    "psicologo", "trabajador_social", "cuidadora", "familiar",
)


# --------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------
async def _load_conditions(db: AsyncSession, patient_id: str) -> list[str]:
    rows = (
        await db.execute(
            text("SELECT condition FROM patient_conditions WHERE patient_id = :pid "
                 "AND deleted_at IS NULL ORDER BY condition"),
            {"pid": patient_id},
        )
    ).scalars().all()
    return list(rows)


async def _load_conditions_detail(db: AsyncSession, patient_id: str) -> list[dict]:
    """Condiciones vigentes con su sistema y etiqueta legible (del catálogo si
    existe; si es texto libre, se humaniza el código)."""
    rows = (
        await db.execute(
            text(
                """
                SELECT pc.condition, pc.system,
                       cc.label AS catalog_label, cc.system AS catalog_system
                FROM patient_conditions pc
                LEFT JOIN condition_catalog cc ON cc.code = pc.condition
                WHERE pc.patient_id = :pid AND pc.deleted_at IS NULL
                ORDER BY pc.system, pc.condition
                """
            ),
            {"pid": patient_id},
        )
    ).mappings().all()
    out = []
    for r in rows:
        label = r["catalog_label"] or r["condition"].replace("_", " ").capitalize()
        system = r["catalog_system"] or r["system"] or "otras"
        out.append({"condition": r["condition"], "system": system, "label": label})
    return out


async def _replace_conditions(db: AsyncSession, patient_id: str, conditions: list[str]) -> None:
    """Deja vigentes exactamente las condiciones recibidas, por baja lógica.

    patient_conditions usa baja lógica (deleted_at) para conservar el histórico
    clínico, y su unicidad es un índice PARCIAL: ux_patient_condition sobre
    (patient_id, condition) WHERE deleted_at IS NULL. Por eso:
      · No se puede DELETE físico (perdería el histórico y viola el diseño).
      · ON CONFLICT (patient_id, condition) a secas NO calza con el índice
        parcial y lanza 'no unique or exclusion constraint matching...' (DEF-001).
        Hay que nombrar el mismo predicado parcial en el ON CONFLICT.

    Estrategia: normalizar la lista, dar de baja las que ya no están, y por cada
    una vigente reactivar (si existía dada de baja) o insertar.
    """
    # Normaliza y deduplica conservando orden, descartando vacíos.
    limpias: list[str] = []
    vistas: set[str] = set()
    for cond in conditions:
        c = cond.strip()
        if len(c) >= 2 and c.lower() not in vistas:
            vistas.add(c.lower())
            limpias.append(c)

    # Baja lógica de las condiciones vigentes que ya no vienen en la lista.
    await db.execute(
        text(
            "UPDATE patient_conditions SET deleted_at = now() "
            "WHERE patient_id = :pid AND deleted_at IS NULL "
            "AND NOT (condition = ANY(:keep))"
        ),
        {"pid": patient_id, "keep": limpias},
    )

    # Alta o reactivación de cada condición vigente.
    for cond in limpias:
        reactivada = (
            await db.execute(
                text(
                    "UPDATE patient_conditions SET deleted_at = NULL "
                    "WHERE patient_id = :pid AND condition = :cond AND deleted_at IS NOT NULL"
                ),
                {"pid": patient_id, "cond": cond},
            )
        ).rowcount
        if reactivada:
            continue
        # ON CONFLICT con el MISMO predicado del índice parcial: así calza.
        # El sistema se hereda del catálogo si la condición existe ahí; si es
        # texto libre, queda 'otras'.
        await db.execute(
            text(
                "INSERT INTO patient_conditions (patient_id, condition, system) "
                "VALUES (:pid, CAST(:cond AS varchar), "
                "  COALESCE((SELECT system FROM condition_catalog "
                "            WHERE code = CAST(:cond AS varchar)), 'otras')) "
                "ON CONFLICT (patient_id, condition) WHERE deleted_at IS NULL DO NOTHING"
            ),
            {"pid": patient_id, "cond": cond},
        )


# --- Alergias (Fase 6) --------------------------------------------------
_ALLERGY_CATEGORIES = {"medicamento", "alimento", "ambiental", "otra"}
_ALLERGY_SEVERITIES = {"leve", "moderada", "severa", "anafilaxia"}
_ALLERGY_SOURCES = {"reportada", "test", "reaccion_tratamiento"}


async def _load_allergies_detail(db: AsyncSession, patient_id: str) -> list[dict]:
    """Alergias vigentes con etiqueta legible (del catálogo si existe). Las más
    graves primero, para que salten a la vista en la ficha."""
    rows = (
        await db.execute(
            text(
                """
                SELECT pa.substance, pa.category, pa.severity, pa.reaction,
                       pa.source, pa.noted_on, ac.label AS catalog_label
                FROM patient_allergies pa
                LEFT JOIN allergen_catalog ac ON ac.code = pa.substance
                WHERE pa.patient_id = :pid AND pa.deleted_at IS NULL
                ORDER BY
                    CASE pa.severity
                        WHEN 'anafilaxia' THEN 0 WHEN 'severa' THEN 1
                        WHEN 'moderada' THEN 2 ELSE 3 END,
                    pa.category, pa.substance
                """
            ),
            {"pid": patient_id},
        )
    ).mappings().all()
    out = []
    for r in rows:
        label = r["catalog_label"] or r["substance"].replace("_", " ").capitalize()
        out.append({
            "substance": r["substance"],
            "label": label,
            "category": r["category"],
            "severity": r["severity"],
            "reaction": r["reaction"],
            "source": r["source"],
            "noted_on": r["noted_on"].isoformat() if r["noted_on"] else None,
        })
    return out


def _normaliza_alergia(a: "AllergyIn") -> dict:
    """Valida los enums de una alergia (422 antes de la BD) y, si la sustancia
    está en el catálogo, hereda su categoría. Devuelve params listos para INSERT."""
    if a.category not in _ALLERGY_CATEGORIES:
        raise ApiError(status_code=422, code="VALIDATION_ERROR",
                       message=f"Categoría de alergia no válida: {a.category}.")
    if a.severity not in _ALLERGY_SEVERITIES:
        raise ApiError(status_code=422, code="VALIDATION_ERROR",
                       message=f"Severidad de alergia no válida: {a.severity}.")
    if a.source not in _ALLERGY_SOURCES:
        raise ApiError(status_code=422, code="VALIDATION_ERROR",
                       message=f"Origen de alergia no válido: {a.source}.")
    return {
        "substance": a.substance.strip(),
        "category": a.category,
        "severity": a.severity,
        "reaction": (a.reaction or None),
        "source": a.source,
        "noted_on": a.noted_on,
    }


async def _add_allergies(db: AsyncSession, patient_id: str,
                         allergies: list["AllergyIn"], recorded_by: str | None) -> None:
    """Agrega alergias nuevas (no reemplaza: la lista crece). Si la sustancia ya
    está vigente, no la duplica; si estaba de baja, la reactiva. La categoría se
    hereda del catálogo cuando la sustancia existe ahí."""
    for a in allergies:
        p = _normaliza_alergia(a)
        if len(p["substance"]) < 2:
            continue
        p["pid"] = patient_id
        p["uid"] = recorded_by
        # Reactiva si existía dada de baja.
        reactivada = (
            await db.execute(
                text("UPDATE patient_allergies SET deleted_at = NULL "
                     "WHERE patient_id = :pid AND substance = :substance "
                     "AND deleted_at IS NOT NULL"),
                {"pid": patient_id, "substance": p["substance"]},
            )
        ).rowcount
        if reactivada:
            continue
        # La categoría del catálogo manda si la sustancia está catalogada.
        await db.execute(
            text(
                """
                INSERT INTO patient_allergies
                    (patient_id, substance, category, severity, reaction, source,
                     noted_on, recorded_by)
                VALUES (:pid, CAST(:substance AS varchar),
                    COALESCE((SELECT category FROM allergen_catalog
                              WHERE code = CAST(:substance AS varchar)), :category),
                    :severity, :reaction, :source,
                    COALESCE(:noted_on, CURRENT_DATE), :uid)
                ON CONFLICT (patient_id, substance) WHERE deleted_at IS NULL DO NOTHING
                """
            ),
            p,
        )


# --- Inmunizaciones / vacunas (Fase 6) ---------------------------------
_IMMUNIZATION_KINDS = {"preventiva", "post_exposicion"}


def _sumar_meses(d: date, meses: int) -> date:
    """Suma meses a una fecha sin dependencias externas (evita day overflow)."""
    import calendar
    m = d.month - 1 + meses
    y = d.year + m // 12
    m = m % 12 + 1
    day = min(d.day, calendar.monthrange(y, m)[1])
    return date(y, m, day)


async def _load_immunizations(db: AsyncSession, patient_id: str) -> list[dict]:
    """Carnet de vacunas vigentes, con la etiqueta del catálogo. Las aplicadas
    más recientes primero; las solo-programadas (sin fecha) al final."""
    rows = (
        await db.execute(
            text(
                """
                SELECT pi.vaccine, pi.kind, pi.administered_on, pi.next_due_on,
                       pi.dose_number, pi.exposure_event, pi.note,
                       vc.label AS catalog_label
                FROM patient_immunizations pi
                JOIN vaccine_catalog vc ON vc.code = pi.vaccine
                WHERE pi.patient_id = :pid AND pi.deleted_at IS NULL
                ORDER BY pi.administered_on DESC NULLS LAST, vc.label
                """
            ),
            {"pid": patient_id},
        )
    ).mappings().all()
    return [
        {
            "vaccine": r["vaccine"],
            "label": r["catalog_label"],
            "kind": r["kind"],
            "administered_on": r["administered_on"].isoformat() if r["administered_on"] else None,
            "next_due_on": r["next_due_on"].isoformat() if r["next_due_on"] else None,
            "dose_number": r["dose_number"],
            "exposure_event": r["exposure_event"],
            "note": r["note"],
        }
        for r in rows
    ]


async def _add_immunization(db: AsyncSession, patient_id: str,
                            im: "ImmunizationIn", recorded_by: str | None) -> None:
    """Registra una vacuna. La naturaleza (kind) y la próxima dosis se derivan
    del catálogo: si es recurrente, con intervalo y hay fecha de aplicación,
    calcula next_due_on. Valida contra el catálogo (422 si no existe)."""
    cat = (
        await db.execute(
            text("SELECT kind_default, is_recurrent, interval_months "
                 "FROM vaccine_catalog WHERE code = :c"),
            {"c": im.vaccine},
        )
    ).mappings().first()
    if cat is None:
        raise ApiError(status_code=422, code="VALIDATION_ERROR",
                       message=f"La vacuna '{im.vaccine}' no está en el catálogo.")

    kind = im.kind or cat["kind_default"]
    if kind not in _IMMUNIZATION_KINDS:
        raise ApiError(status_code=422, code="VALIDATION_ERROR",
                       message=f"Naturaleza de vacuna no válida: {kind}.")

    # Debe tener al menos una fecha: o se aplicó, o queda programada. Se valida
    # en Python para responder 422 (no 500 por el CHECK de la BD).
    if im.administered_on is None:
        raise ApiError(status_code=422, code="VALIDATION_ERROR",
                       message="Indica la fecha de aplicación de la vacuna.")

    # Próxima dosis: solo preventivas recurrentes con intervalo y fecha aplicada.
    next_due = None
    if (kind == "preventiva" and cat["is_recurrent"]
            and cat["interval_months"] and im.administered_on):
        next_due = _sumar_meses(im.administered_on, int(cat["interval_months"]))

    await db.execute(
        text(
            """
            INSERT INTO patient_immunizations
                (patient_id, vaccine, kind, administered_on, next_due_on,
                 dose_number, exposure_event, note, recorded_by)
            VALUES (:pid, :vaccine, :kind, :adm, :due, :dose, :evt, :note, :uid)
            """
        ),
        {
            "pid": patient_id, "vaccine": im.vaccine, "kind": kind,
            "adm": im.administered_on, "due": next_due,
            "dose": im.dose_number, "evt": im.exposure_event,
            "note": im.note, "uid": recorded_by,
        },
    )


# --- Contactos de emergencia (Fase 6) ----------------------------------
async def _load_emergency_contacts(db: AsyncSession, patient_id: str) -> list[dict]:
    """Contactos de emergencia vigentes. Los que son miembros del grupo toman
    nombre/teléfono del perfil del usuario (una sola fuente). Activos primero,
    luego por orden de escalamiento."""
    rows = (
        await db.execute(
            text(
                """
                SELECT ec.id, ec.member_user_id, ec.is_active, ec.notes,
                       COALESCE(u.full_name, ec.full_name) AS nombre,
                       COALESCE(u.phone, ec.phone)         AS telefono,
                       u.avatar_url
                FROM emergency_contacts ec
                LEFT JOIN users u ON u.id = ec.member_user_id
                WHERE ec.patient_id = :pid AND ec.deleted_at IS NULL
                ORDER BY ec.is_active DESC, nombre
                """
            ),
            {"pid": patient_id},
        )
    ).mappings().all()
    return [
        {
            "id": str(r["id"]),
            "member_user_id": str(r["member_user_id"]) if r["member_user_id"] else None,
            "name": r["nombre"],
            "phone": r["telefono"],
            "avatar_url": r["avatar_url"],
            "is_active": r["is_active"],
            "notes": r["notes"],
        }
        for r in rows
    ]


# --- Último médico que vio al paciente (Fase 6) ------------------------
async def _load_last_seen_by(db: AsyncSession, patient_id: str) -> dict | None:
    """Último médico que atendió al paciente. Mientras no exista el módulo de
    controles/citas, se deriva del tratamiento más reciente (quién lo prescribió
    y cuándo empezó a regir). Devuelve {name, specialty, date} o None."""
    row = (
        await db.execute(
            text(
                """
                SELECT u.full_name AS nombre, t.specialty, t.effective_from
                FROM treatments t
                JOIN users u ON u.id = t.prescribed_by
                WHERE t.patient_id = :pid
                ORDER BY t.effective_from DESC
                LIMIT 1
                """
            ),
            {"pid": patient_id},
        )
    ).mappings().first()
    if row is None:
        return None
    return {
        "name": row["nombre"],
        "specialty": row["specialty"],
        "date": row["effective_from"].isoformat() if row["effective_from"] else None,
    }


def _default_thresholds_for_age(age_years: int) -> list[tuple[str, float | None, float | None]]:
    """Umbrales de partida para un paciente recién creado (DEF-004, DEF-005).

    Sin umbrales, el motor de alertas nunca evalúa un signo fuera de rango: un
    paciente nuevo quedaba sin vigilancia. Estos valores son un punto de partida
    razonable para adulto mayor y el médico los ajusta después (RF-21). La
    frecuencia cardíaca se abre un poco en el muy anciano, donde la bradicardia
    de reposo es más frecuente; no reemplaza el criterio clínico.
    """
    if age_years >= 85:
        hr_min, hr_max = 45.0, 115.0
    elif age_years >= 70:
        hr_min, hr_max = 50.0, 110.0
    else:
        hr_min, hr_max = 55.0, 105.0
    return [
        ("heart_rate", hr_min, hr_max),
        ("spo2", 92.0, None),          # solo piso: por debajo de 92% se alerta
    ]


async def _seed_default_thresholds(db: AsyncSession, patient_id: str,
                                   birth_date: date, updated_by: str) -> None:
    today = date.today()
    age = today.year - birth_date.year - (
        (today.month, today.day) < (birth_date.month, birth_date.day)
    )
    for vtype, vmin, vmax in _default_thresholds_for_age(age):
        await db.execute(
            text(
                "INSERT INTO vital_thresholds (patient_id, type, min_value, max_value, updated_by) "
                "VALUES (:pid, :type, :vmin, :vmax, :uid) "
                "ON CONFLICT (patient_id, type) WHERE deleted_at IS NULL DO NOTHING"
            ),
            {"pid": patient_id, "type": vtype, "vmin": vmin, "vmax": vmax, "uid": updated_by},
        )


async def _load_patient_detail(db: AsyncSession, patient_id: str) -> PatientDetailOut:
    patient = (
        await db.execute(
            text(
                """
                SELECT id, first_name, last_name, full_name,
                       birth_date, sex, photo_url,
                       rut_number, rut_dv, address, marital_status,
                       insurance, rcv_level, complexity, priority
                FROM patients
                WHERE id = :pid AND deleted_at IS NULL
                """
            ),
            {"pid": patient_id},
        )
    ).mappings().first()

    if patient is None:
        raise ApiError(status_code=404, code="NOT_FOUND",
                       message="El recurso solicitado no existe o no está disponible.")

    wearable_row = (
        await db.execute(
            text(
                "SELECT id, model, last_sync_at, battery_pct "
                "FROM wearables WHERE patient_id = :pid AND unlinked_at IS NULL"
            ),
            {"pid": patient_id},
        )
    ).mappings().first()

    wearable = None
    if wearable_row:
        wearable = WearableSummary(
            wearable_id=str(wearable_row["id"]),
            model=wearable_row["model"],
            last_sync_at=wearable_row["last_sync_at"],
            battery_pct=wearable_row["battery_pct"],
        )

    conditions = await _load_conditions(db, patient_id)
    conditions_detail = await _load_conditions_detail(db, patient_id)
    allergies = await _load_allergies_detail(db, patient_id)
    immunizations = await _load_immunizations(db, patient_id)
    last_seen_by = await _load_last_seen_by(db, patient_id)

    # Última medición antropométrica (si hay). El IMC se calcula aquí, no se guarda.
    med_row = (
        await db.execute(
            text(
                "SELECT weight_kg, height_cm, measured_at "
                "FROM patient_measurements WHERE patient_id = :pid "
                "ORDER BY measured_at DESC, created_at DESC LIMIT 1"
            ),
            {"pid": patient_id},
        )
    ).mappings().first()

    latest_measurement = None
    if med_row:
        peso = float(med_row["weight_kg"]) if med_row["weight_kg"] is not None else None
        altura = float(med_row["height_cm"]) if med_row["height_cm"] is not None else None
        bmi = None
        if peso and altura and altura > 0:
            m = altura / 100.0
            bmi = round(peso / (m * m), 1)
        latest_measurement = MeasurementOut(
            weight_kg=peso, height_cm=altura, bmi=bmi,
            measured_at=med_row["measured_at"],
        )

    rut = None
    if patient["rut_number"] is not None:
        n = f"{patient['rut_number']:,}".replace(",", ".")
        rut = f"{n}-{patient['rut_dv']}" if patient["rut_dv"] else n

    return PatientDetailOut(
        patient_id=str(patient["id"]),
        first_name=patient["first_name"],
        last_name=patient["last_name"],
        full_name=patient["full_name"],
        birth_date=patient["birth_date"],
        sex=_SEX_DB_TO_API.get(patient["sex"], patient["sex"]),
        photo_url=patient["photo_url"],
        conditions=conditions,
        conditions_detail=conditions_detail,
        allergies=allergies,
        immunizations=immunizations,
        wearable=wearable,
        rut=rut,
        address=patient["address"],
        marital_status=patient["marital_status"],
        insurance=patient["insurance"],
        rcv_level=patient["rcv_level"],
        complexity=patient["complexity"],
        priority=patient["priority"],
        last_seen_by=last_seen_by,
        latest_measurement=latest_measurement,
    )


# --------------------------------------------------------------------------
# 4.0 Catálogo de patologías (para el selector agrupado por sistema)
# --------------------------------------------------------------------------
class CatalogItem(BaseModel):
    code:   str
    label:  str
    system: str


@router.get("/conditions/catalog", response_model=list[CatalogItem])
async def conditions_catalog(
    user: CurrentUser = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    rows = (
        await db.execute(
            text("SELECT code, label, system FROM condition_catalog "
                 "ORDER BY system, label")
        )
    ).mappings().all()
    return [CatalogItem(code=r["code"], label=r["label"], system=r["system"])
            for r in rows]


# --------------------------------------------------------------------------
# 4.0b Catálogo de alérgenos + alergias del paciente (Fase 6)
# --------------------------------------------------------------------------
class AllergenCatalogItem(BaseModel):
    code:     str
    label:    str
    category: str


@router.get("/allergens/catalog", response_model=list[AllergenCatalogItem])
async def allergens_catalog(
    user: CurrentUser = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    rows = (
        await db.execute(
            text("SELECT code, label, category FROM allergen_catalog "
                 "ORDER BY category, label")
        )
    ).mappings().all()
    return [AllergenCatalogItem(code=r["code"], label=r["label"],
                                category=r["category"]) for r in rows]


@router.get("/patients/{patient_id}/allergies")
async def list_allergies(
    ctx: PatientContext = Depends(get_patient_member()),
    db: AsyncSession = Depends(get_db),
):
    return {"allergies": await _load_allergies_detail(db, ctx.patient_id)}


@router.post("/patients/{patient_id}/allergies", status_code=201)
async def add_allergy(
    payload: AllergyIn,
    ctx: PatientContext = Depends(
        get_patient_member(roles=["doctor", "caregiver", "family"])),
    db: AsyncSession = Depends(get_db),
):
    """Agrega una alergia descubierta. Puede registrarse en cualquier momento
    (al diagnosticar, por un test, o tras una reacción en tratamiento)."""
    await _add_allergies(db, ctx.patient_id, [payload], ctx.user.user_id)
    await db.commit()
    return {"allergies": await _load_allergies_detail(db, ctx.patient_id)}


@router.delete("/patients/{patient_id}/allergies/{substance}")
async def remove_allergy(
    substance: str,
    ctx: PatientContext = Depends(
        get_patient_member(roles=["doctor", "caregiver", "family"])),
    db: AsyncSession = Depends(get_db),
):
    """Baja lógica de una alergia (conserva el histórico clínico)."""
    await db.execute(
        text("UPDATE patient_allergies SET deleted_at = now() "
             "WHERE patient_id = :pid AND substance = :s AND deleted_at IS NULL"),
        {"pid": ctx.patient_id, "s": substance},
    )
    await db.commit()
    return {"allergies": await _load_allergies_detail(db, ctx.patient_id)}


# --------------------------------------------------------------------------
# 4.0c Catálogo de vacunas + inmunizaciones del paciente (Fase 6)
# --------------------------------------------------------------------------
class VaccineCatalogItem(BaseModel):
    code:            str
    label:           str
    kind_default:    str
    is_recurrent:    bool
    interval_months: int | None = None
    target_group:    str | None = None


@router.get("/vaccines/catalog", response_model=list[VaccineCatalogItem])
async def vaccines_catalog(
    user: CurrentUser = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    rows = (
        await db.execute(
            text("SELECT code, label, kind_default, is_recurrent, "
                 "interval_months, target_group FROM vaccine_catalog "
                 "ORDER BY kind_default DESC, label")
        )
    ).mappings().all()
    return [
        VaccineCatalogItem(
            code=r["code"], label=r["label"], kind_default=r["kind_default"],
            is_recurrent=r["is_recurrent"], interval_months=r["interval_months"],
            target_group=r["target_group"],
        )
        for r in rows
    ]


@router.get("/patients/{patient_id}/immunizations")
async def list_immunizations(
    ctx: PatientContext = Depends(get_patient_member()),
    db: AsyncSession = Depends(get_db),
):
    return {"immunizations": await _load_immunizations(db, ctx.patient_id)}


@router.post("/patients/{patient_id}/immunizations", status_code=201)
async def add_immunization(
    payload: ImmunizationIn,
    ctx: PatientContext = Depends(
        get_patient_member(roles=["doctor", "caregiver", "family"])),
    db: AsyncSession = Depends(get_db),
):
    """Registra una vacuna (aplicada o programada). La próxima dosis se calcula
    sola para las preventivas recurrentes."""
    await _add_immunization(db, ctx.patient_id, payload, ctx.user.user_id)
    await db.commit()
    return {"immunizations": await _load_immunizations(db, ctx.patient_id)}


@router.delete("/patients/{patient_id}/immunizations/{vaccine}")
async def remove_immunization(
    vaccine: str,
    ctx: PatientContext = Depends(
        get_patient_member(roles=["doctor", "caregiver", "family"])),
    db: AsyncSession = Depends(get_db),
):
    """Baja lógica de la última dosis registrada de esa vacuna (conserva histórico)."""
    await db.execute(
        text("UPDATE patient_immunizations SET deleted_at = now() "
             "WHERE id = (SELECT id FROM patient_immunizations "
             "            WHERE patient_id = :pid AND vaccine = :v "
             "              AND deleted_at IS NULL "
             "            ORDER BY administered_on DESC NULLS LAST, created_at DESC "
             "            LIMIT 1)"),
        {"pid": ctx.patient_id, "v": vaccine},
    )
    await db.commit()
    return {"immunizations": await _load_immunizations(db, ctx.patient_id)}


# --------------------------------------------------------------------------
# 4.0d Contactos de emergencia (del grupo familiar, rotativos) — Fase 6
# --------------------------------------------------------------------------
@router.get("/patients/{patient_id}/emergency-contacts")
async def list_emergency_contacts(
    ctx: PatientContext = Depends(get_patient_member()),
    db: AsyncSession = Depends(get_db),
):
    return {"contacts": await _load_emergency_contacts(db, ctx.patient_id)}


@router.post("/patients/{patient_id}/emergency-contacts", status_code=201)
async def add_emergency_contact(
    payload: EmergencyContactIn,
    ctx: PatientContext = Depends(
        get_patient_member(roles=["family"], require_owner=True)),
    db: AsyncSession = Depends(get_db),
):
    """Agrega un contacto de emergencia eligiendo un miembro del grupo. Solo el
    familiar administrador. El miembro debe pertenecer al grupo del paciente."""
    es_miembro = (
        await db.execute(
            text("SELECT 1 FROM patient_members WHERE patient_id = :pid "
                 "AND user_id = :uid AND removed_at IS NULL"),
            {"pid": ctx.patient_id, "uid": payload.member_user_id},
        )
    ).first()
    if es_miembro is None:
        raise ApiError(status_code=422, code="VALIDATION_ERROR",
                       message="El contacto debe ser un miembro del grupo de cuidado.")

    # Sin prioridad: los contactos son una lista (en un SOS se avisa a todos).
    # Reactiva si el mismo miembro ya existía como contacto; si no, inserta.
    reactivado = (
        await db.execute(
            text("UPDATE emergency_contacts "
                 "SET deleted_at = NULL, is_active = true, notes = :notes "
                 "WHERE patient_id = :pid AND member_user_id = :uid "
                 "AND deleted_at IS NOT NULL"),
            {"pid": ctx.patient_id, "uid": payload.member_user_id,
             "notes": payload.notes},
        )
    ).rowcount
    if not reactivado:
        await db.execute(
            text("INSERT INTO emergency_contacts "
                 "(patient_id, member_user_id, notes) "
                 "VALUES (:pid, :uid, :notes) "
                 "ON CONFLICT (patient_id, member_user_id) "
                 "WHERE deleted_at IS NULL AND member_user_id IS NOT NULL "
                 "DO UPDATE SET is_active = true, notes = EXCLUDED.notes"),
            {"pid": ctx.patient_id, "uid": payload.member_user_id,
             "notes": payload.notes},
        )
    await db.commit()
    return {"contacts": await _load_emergency_contacts(db, ctx.patient_id)}


@router.patch("/patients/{patient_id}/emergency-contacts/{contact_id}")
async def update_emergency_contact(
    contact_id: str,
    payload: EmergencyContactPatchIn,
    ctx: PatientContext = Depends(
        get_patient_member(roles=["family"], require_owner=True)),
    db: AsyncSession = Depends(get_db),
):
    """Activa/desactiva un contacto (rotación). No hay orden/prioridad."""
    if payload.is_active is not None:
        await db.execute(
            text("UPDATE emergency_contacts SET is_active = :act "
                 "WHERE id = :cid AND patient_id = :pid AND deleted_at IS NULL"),
            {"act": payload.is_active, "cid": contact_id, "pid": ctx.patient_id},
        )
        await db.commit()
    return {"contacts": await _load_emergency_contacts(db, ctx.patient_id)}


@router.delete("/patients/{patient_id}/emergency-contacts/{contact_id}")
async def remove_emergency_contact(
    contact_id: str,
    ctx: PatientContext = Depends(
        get_patient_member(roles=["family"], require_owner=True)),
    db: AsyncSession = Depends(get_db),
):
    """Baja lógica de un contacto de emergencia."""
    await db.execute(
        text("UPDATE emergency_contacts SET deleted_at = now() "
             "WHERE id = :cid AND patient_id = :pid AND deleted_at IS NULL"),
        {"cid": contact_id, "pid": ctx.patient_id},
    )
    await db.commit()
    return {"contacts": await _load_emergency_contacts(db, ctx.patient_id)}


# --------------------------------------------------------------------------
# 4.1 Crear paciente
# --------------------------------------------------------------------------
@router.post("/patients", response_model=PatientCreateOut, status_code=201)
async def create_patient(
    payload: PatientCreateIn,
    user: CurrentUser = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    sex_db = _SEX_API_TO_DB.get(payload.sex)
    if sex_db is None:
        raise ApiError(status_code=422, code="VALIDATION_ERROR",
                       message="Hay datos inválidos en la solicitud. Revisa los campos marcados.")

    patient = (
        await db.execute(
            text(
                """
                INSERT INTO patients (first_name, last_name, birth_date, sex, photo_url)
                VALUES (:fn, :ln, :bd, :sex, :photo)
                RETURNING id, full_name, created_at
                """
            ),
            {
                "fn":    payload.first_name,
                "ln":    payload.last_name,
                "bd":    payload.birth_date,
                "sex":   sex_db,
                "photo": payload.photo_url,
            },
        )
    ).mappings().first()

    pid = str(patient["id"])

    # Condiciones en tabla normalizada
    if payload.conditions:
        await _replace_conditions(db, pid, payload.conditions)

    # Alergias conocidas al registrar (la lista luego crece con el tiempo).
    if payload.allergies:
        await _add_allergies(db, pid, payload.allergies, user.user_id)

    # Umbrales de partida para que el paciente quede vigilado desde el día 1
    # (DEF-004). El creador queda como updated_by hasta que el médico los ajuste.
    await _seed_default_thresholds(db, pid, payload.birth_date, user.user_id)

    # Creador = familiar administrador
    await db.execute(
        text(
            "INSERT INTO patient_members (patient_id, user_id, role, is_owner) "
            "VALUES (:pid, :uid, 'family', true)"
        ),
        {"pid": pid, "uid": user.user_id},
    )
    await db.commit()

    return PatientCreateOut(
        patient_id=pid,
        full_name=patient["full_name"],
        created_at=patient["created_at"],
    )


# --------------------------------------------------------------------------
# 4.2 Listar mis pacientes
# --------------------------------------------------------------------------
@router.get("/patients", response_model=PatientListOut)
async def list_patients(
    user: CurrentUser = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    # Edad, enfermedades y señales de criticidad de cada paciente en una sola
    # consulta. El semáforo y el motivo salen de las alertas activas: es la
    # misma fuente que usa el dashboard, basta para ordenar por urgencia (triage).
    rows = (
        await db.execute(
            text(
                """
                SELECT p.id, p.full_name, p.photo_url, pm.role,
                       p.rut_number, p.rut_dv, p.sex, p.address,
                       p.complexity, p.priority, p.insurance,
                       date_part('year', age(p.birth_date))::int AS age,
                       COALESCE((
                           SELECT array_agg(pc.condition ORDER BY pc.condition)
                           FROM patient_conditions pc
                           WHERE pc.patient_id = p.id AND pc.deleted_at IS NULL
                       ), ARRAY[]::text[]) AS conditions,
                       COALESCE((
                           SELECT array_agg(COALESCE(cc.label, pc.condition)
                                            ORDER BY pc.condition)
                           FROM patient_conditions pc
                           LEFT JOIN condition_catalog cc ON cc.code = pc.condition
                           WHERE pc.patient_id = p.id AND pc.deleted_at IS NULL
                       ), ARRAY[]::text[]) AS conditions_labels,
                       -- Alergias como "etiqueta|severidad", graves primero.
                       COALESCE((
                           SELECT array_agg(COALESCE(ac.label, pa.substance)
                                            || '|' || pa.severity
                                            ORDER BY CASE pa.severity
                                                WHEN 'anafilaxia' THEN 0
                                                WHEN 'severa' THEN 1
                                                WHEN 'moderada' THEN 2
                                                ELSE 3 END,
                                            pa.substance)
                           FROM patient_allergies pa
                           LEFT JOIN allergen_catalog ac ON ac.code = pa.substance
                           WHERE pa.patient_id = p.id AND pa.deleted_at IS NULL
                       ), ARRAY[]::text[]) AS allergies,
                       COALESCE((
                           SELECT count(*) FROM alerts a
                           WHERE a.patient_id = p.id AND a.status = 'active'
                       ), 0) AS active_alerts,
                       COALESCE((
                           SELECT count(*) FROM alerts a
                           WHERE a.patient_id = p.id AND a.status = 'active'
                             AND a.severity = 'critical'
                       ), 0) AS critical_alerts,
                       (
                           SELECT a.title FROM alerts a
                           WHERE a.patient_id = p.id AND a.status = 'active'
                           ORDER BY CASE a.severity
                                        WHEN 'critical' THEN 0
                                        WHEN 'warning'  THEN 1
                                        ELSE 2 END,
                                    a.created_at DESC
                           LIMIT 1
                       ) AS top_reason
                FROM patient_members pm
                JOIN patients p ON p.id = pm.patient_id
                WHERE pm.user_id = :uid
                  AND pm.removed_at IS NULL
                  AND p.deleted_at IS NULL
                """
            ),
            {"uid": user.user_id},
        )
    ).mappings().all()

    def _wellbeing(r) -> str:
        if r["critical_alerts"] > 0:
            return "attention"
        if r["active_alerts"] > 0:
            return "warning"
        return "ok"

    def _rut(r) -> str | None:
        if r["rut_number"] is None:
            return None
        # Formato chileno con puntos y guión: 5.123.456-K
        n = f"{r['rut_number']:,}".replace(",", ".")
        return f"{n}-{r['rut_dv']}" if r["rut_dv"] else n

    async def _vitals_summary(pid: str) -> list[dict]:
        # Últimas lecturas de los signos más representativos, para el mini
        # resumen de la tarjeta. Sin umbral aquí: es contexto, no evaluación.
        rows = (
            await db.execute(
                text(
                    """
                    SELECT DISTINCT ON (vr.type) vr.type, vr.value,
                           vr.value_secondary, vr.measured_at,
                           COALESCE(vt.unit, '') AS unit
                    FROM vital_readings vr
                    LEFT JOIN vital_types vt ON vt.code = vr.type
                    WHERE vr.patient_id = :pid
                      AND vr.type IN ('heart_rate', 'spo2', 'blood_pressure')
                    ORDER BY vr.type, vr.measured_at DESC
                    """
                ),
                {"pid": pid},
            )
        ).mappings().all()
        return [
            {
                "type": r["type"],
                "value": float(r["value"]),
                "value_secondary": (float(r["value_secondary"])
                                    if r["value_secondary"] is not None else None),
                "unit": r["unit"],
                "measured_at": (r["measured_at"].isoformat()
                                if r["measured_at"] else None),
            }
            for r in rows
        ]

    def _alergias(r) -> list[dict]:
        out = []
        for a in r["allergies"] or []:
            label, _, sev = a.rpartition("|")
            out.append({"label": label, "severity": sev})
        return out

    # Orden de triage: primero quien más atención necesita. Criticas, luego
    # cuántas alertas activas, y a igualdad por nombre para que sea estable.
    _peso = {"attention": 0, "warning": 1, "ok": 2}
    items = []
    for r in rows:
        items.append(PatientListItem(
            patient_id=str(r["id"]),
            full_name=r["full_name"],
            photo_url=r["photo_url"],
            role=r["role"],
            wellbeing_status=_wellbeing(r),
            age=r["age"],
            conditions=list(r["conditions"]),
            active_alerts_count=int(r["active_alerts"]),
            critical_alerts_count=int(r["critical_alerts"]),
            top_reason=r["top_reason"],
            rut=_rut(r),
            sex=_SEX_DB_TO_API.get(r["sex"], r["sex"]),
            address=r["address"],
            conditions_labels=list(r["conditions_labels"]),
            allergies=_alergias(r),
            complexity=r["complexity"],
            priority=r["priority"],
            insurance=r["insurance"],
            vitals_summary=await _vitals_summary(str(r["id"])),
        ))
    items.sort(key=lambda it: (
        _peso[it.wellbeing_status],
        -it.critical_alerts_count,
        -it.active_alerts_count,
        it.full_name.lower(),
    ))

    return PatientListOut(items=items)


# --------------------------------------------------------------------------
# 4.3 Detalle del paciente
# --------------------------------------------------------------------------
@router.get("/patients/{patient_id}", response_model=PatientDetailOut)
async def get_patient(
    ctx: PatientContext = Depends(get_patient_member()),
    db: AsyncSession = Depends(get_db),
):
    return await _load_patient_detail(db, ctx.patient_id)


# --------------------------------------------------------------------------
# 4.3b Mediciones antropométricas (peso / altura) — historial
# --------------------------------------------------------------------------
class MeasurementIn(BaseModel):
    weight_kg: float | None = Field(default=None, gt=0, le=400)
    height_cm: float | None = Field(default=None, gt=0, le=260)
    measured_at: date | None = None


class MeasurementItem(BaseModel):
    weight_kg:   float | None = None
    height_cm:   float | None = None
    bmi:         float | None = None
    measured_at: date


def _bmi(peso: float | None, altura: float | None) -> float | None:
    if peso and altura and altura > 0:
        m = altura / 100.0
        return round(peso / (m * m), 1)
    return None


@router.get("/patients/{patient_id}/measurements",
            response_model=list[MeasurementItem])
async def list_measurements(
    ctx: PatientContext = Depends(get_patient_member()),
    db: AsyncSession = Depends(get_db),
):
    rows = (
        await db.execute(
            text("SELECT weight_kg, height_cm, measured_at FROM patient_measurements "
                 "WHERE patient_id = :pid ORDER BY measured_at DESC, created_at DESC"),
            {"pid": ctx.patient_id},
        )
    ).mappings().all()
    return [
        MeasurementItem(
            weight_kg=float(r["weight_kg"]) if r["weight_kg"] is not None else None,
            height_cm=float(r["height_cm"]) if r["height_cm"] is not None else None,
            bmi=_bmi(
                float(r["weight_kg"]) if r["weight_kg"] is not None else None,
                float(r["height_cm"]) if r["height_cm"] is not None else None,
            ),
            measured_at=r["measured_at"],
        )
        for r in rows
    ]


@router.post("/patients/{patient_id}/measurements",
             response_model=MeasurementItem, status_code=201)
async def add_measurement(
    payload: MeasurementIn,
    ctx: PatientContext = Depends(get_patient_member(roles=["family", "caregiver", "doctor"])),
    db: AsyncSession = Depends(get_db),
):
    if payload.weight_kg is None and payload.height_cm is None:
        raise ApiError(status_code=422, code="VALIDATION_ERROR",
                       message="Indica al menos peso o altura.")
    row = (
        await db.execute(
            text("INSERT INTO patient_measurements "
                 "(patient_id, weight_kg, height_cm, measured_at, recorded_by) "
                 "VALUES (:pid, :w, :h, COALESCE(:d, CURRENT_DATE), :uid) "
                 "RETURNING weight_kg, height_cm, measured_at"),
            {"pid": ctx.patient_id, "w": payload.weight_kg, "h": payload.height_cm,
             "d": payload.measured_at, "uid": ctx.user.user_id},
        )
    ).mappings().first()
    await db.commit()
    peso = float(row["weight_kg"]) if row["weight_kg"] is not None else None
    altura = float(row["height_cm"]) if row["height_cm"] is not None else None
    return MeasurementItem(
        weight_kg=peso, height_cm=altura, bmi=_bmi(peso, altura),
        measured_at=row["measured_at"],
    )


# --------------------------------------------------------------------------
# 4.4 Actualizar paciente
# --------------------------------------------------------------------------
@router.patch("/patients/{patient_id}", response_model=PatientDetailOut)
async def update_patient(
    payload: PatientPatchIn,
    ctx: PatientContext = Depends(get_patient_member(roles=["family"], require_owner=True)),
    db: AsyncSession = Depends(get_db),
):
    fields = payload.model_dump(exclude_unset=True)
    conditions = fields.pop("conditions", None)

    sets: list[str] = []
    params: dict = {"pid": ctx.patient_id}

    if "first_name" in fields:
        sets.append("first_name = :first_name"); params["first_name"] = fields["first_name"]
    if "last_name" in fields:
        sets.append("last_name = :last_name");   params["last_name"]  = fields["last_name"]
    if "birth_date" in fields:
        sets.append("birth_date = :birth_date"); params["birth_date"] = fields["birth_date"]
    if "sex" in fields:
        sex_db = _SEX_API_TO_DB.get(fields["sex"])
        if sex_db is None:
            raise ApiError(status_code=422, code="VALIDATION_ERROR",
                           message="Hay datos inválidos en la solicitud. Revisa los campos marcados.")
        sets.append("sex = :sex"); params["sex"] = sex_db
    if "photo_url" in fields:
        sets.append("photo_url = :photo_url"); params["photo_url"] = fields["photo_url"]
    # Perfil clínico ampliado (Fase 2). Se validan los valores ANTES de la BD
    # para responder 422 en vez de un 500 por violación de CHECK.
    _VALORES = {
        "marital_status": {"soltero", "casado", "viudo", "divorciado",
                            "conviviente", "separado"},
        "insurance": {"fonasa", "isapre", "particular", "otra"},
        "rcv_level": {"bajo", "moderado", "alto"},
        "complexity": {"baja", "moderada", "alta"},
        "priority": {"baja", "media", "alta"},
    }
    for col in ("address", "marital_status", "insurance", "rcv_level",
                "complexity", "priority"):
        if col in fields:
            val = fields[col]
            if val is not None and col in _VALORES and val not in _VALORES[col]:
                raise ApiError(status_code=422, code="VALIDATION_ERROR",
                               message="Hay datos inválidos en la solicitud. Revisa los campos marcados.",
                               details=[{"field": col, "message": f"Valor no permitido: {val}."}])
            sets.append(f"{col} = :{col}"); params[col] = val

    if sets:
        await db.execute(
            text(f"UPDATE patients SET {', '.join(sets)} WHERE id = :pid AND deleted_at IS NULL"),
            params,
        )

    if conditions is not None:
        await _replace_conditions(db, ctx.patient_id, conditions)

    await db.commit()
    return await _load_patient_detail(db, ctx.patient_id)


# --------------------------------------------------------------------------
# 4.5 Invitar miembro
# --------------------------------------------------------------------------
@router.post("/patients/{patient_id}/invitations",
             response_model=InvitationCreateOut, status_code=201)
async def create_invitation(
    payload: InvitationCreateIn,
    ctx: PatientContext = Depends(get_patient_member(roles=["family"], require_owner=True)),
    db: AsyncSession = Depends(get_db),
):
    if payload.role not in _VALID_INVITE_ROLES:
        raise ApiError(status_code=422, code="VALIDATION_ERROR",
                       message="Hay datos inválidos en la solicitud. Revisa los campos marcados.")

    if payload.profession is not None and payload.profession not in _VALID_PROFESSIONS:
        raise ApiError(status_code=422, code="VALIDATION_ERROR",
                       message="Hay datos inválidos en la solicitud. Revisa los campos marcados.",
                       details=[{"field": "profession",
                                 "message": f"Profesión no permitida: {payload.profession}."}])

    if payload.relationship is not None and payload.relationship not in _VALID_RELATIONSHIPS:
        raise ApiError(status_code=422, code="VALIDATION_ERROR",
                       message="Hay datos inválidos en la solicitud. Revisa los campos marcados.",
                       details=[{"field": "relationship",
                                 "message": f"Parentesco no permitido: {payload.relationship}."}])

    if payload.email is not None:
        already = (
            await db.execute(
                text(
                    "SELECT 1 FROM patient_members pm JOIN users u ON u.id = pm.user_id "
                    "WHERE pm.patient_id = :pid AND pm.removed_at IS NULL "
                    "AND lower(u.email) = lower(:email)"
                ),
                {"pid": ctx.patient_id, "email": payload.email},
            )
        ).first()
        if already:
            raise ApiError(status_code=409, code="MEMBER_ALREADY_EXISTS",
                           message="Esta persona ya forma parte del círculo de cuidado del paciente.")

    if payload.role == "elder":
        elder_exists = (
            await db.execute(
                text("SELECT 1 FROM patient_members WHERE patient_id = :pid "
                     "AND role = 'elder' AND removed_at IS NULL"),
                {"pid": ctx.patient_id},
            )
        ).first()
        if elder_exists:
            raise ApiError(status_code=409, code="ELDER_ALREADY_LINKED",
                           message="El paciente ya tiene una cuenta de adulto mayor vinculada.")

    token = generate_refresh_token()
    expires_at = datetime.now(timezone.utc) + timedelta(days=INVITATION_TTL_DAYS)

    invitation = (
        await db.execute(
            text(
                "INSERT INTO invitations (patient_id, email, role, profession, relationship, token_hash, invited_by, expires_at) "
                "VALUES (:pid, :email, :role, :prof, :rel, :th, :inviter, :exp) RETURNING id, expires_at"
            ),
            {
                "pid": ctx.patient_id, "email": payload.email or "",
                "role": payload.role, "prof": payload.profession,
                "rel": payload.relationship,
                "th": hash_token(token),
                "inviter": ctx.user.user_id, "exp": expires_at,
            },
        )
    ).mappings().first()
    await db.commit()

    return InvitationCreateOut(
        invitation_id=str(invitation["id"]),
        token=token,
        invite_url=f"https://app.agecare.app/invite/{token}",
        expires_at=invitation["expires_at"],
    )


# --------------------------------------------------------------------------
# 4.6 Aceptar invitación
# --------------------------------------------------------------------------
@router.post("/invitations/accept", response_model=InvitationAcceptOut)
async def accept_invitation(
    payload: InvitationAcceptIn,
    user: CurrentUser = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    invalid = ApiError(status_code=400, code="INVALID_INVITATION",
                       message="La invitación no existe, ya fue usada o está vencida.")

    invitation = (
        await db.execute(
            text(
                "SELECT id, patient_id, role, profession, relationship FROM invitations "
                "WHERE token_hash = :th AND accepted_at IS NULL "
                "AND revoked_at IS NULL AND expires_at > now()"
            ),
            {"th": hash_token(payload.token)},
        )
    ).mappings().first()

    if invitation is None:
        raise invalid

    # Si el miembro ya existía (reingreso tras removed_at), reactiva y actualiza
    # su profesión; si no, inserta. Copia la profesión de la invitación.
    await db.execute(
        text(
            "INSERT INTO patient_members (patient_id, user_id, role, profession, relationship, is_owner) "
            "VALUES (:pid, :uid, :role, :prof, :rel, false) "
            "ON CONFLICT (patient_id, user_id) DO UPDATE "
            "SET role = EXCLUDED.role, profession = EXCLUDED.profession, "
            "    relationship = EXCLUDED.relationship, removed_at = NULL"
        ),
        {"pid": str(invitation["patient_id"]), "uid": user.user_id,
         "role": invitation["role"], "prof": invitation["profession"],
         "rel": invitation["relationship"]},
    )
    await db.execute(
        text("UPDATE invitations SET accepted_at = now(), accepted_by = :uid WHERE id = :iid"),
        {"uid": user.user_id, "iid": invitation["id"]},
    )
    await db.commit()

    return InvitationAcceptOut(patient_id=str(invitation["patient_id"]), role=invitation["role"])


# --------------------------------------------------------------------------
# 4.7 Listar miembros e invitaciones pendientes
# --------------------------------------------------------------------------
@router.get("/patients/{patient_id}/members", response_model=MembersListOut)
async def list_members(
    ctx: PatientContext = Depends(
        get_patient_member(roles=["family", "doctor", "caregiver"])),
    db: AsyncSession = Depends(get_db),
):
    member_rows = (
        await db.execute(
            text(
                "SELECT u.id AS user_id, u.full_name, u.email, pm.role, "
                "pm.profession, pm.relationship, pm.is_owner, pm.created_at AS joined_at "
                "FROM patient_members pm JOIN users u ON u.id = pm.user_id "
                "WHERE pm.patient_id = :pid AND pm.removed_at IS NULL ORDER BY pm.created_at"
            ),
            {"pid": ctx.patient_id},
        )
    ).mappings().all()

    pending_rows = (
        await db.execute(
            text(
                "SELECT id AS invitation_id, email, role, profession, expires_at FROM invitations "
                "WHERE patient_id = :pid AND accepted_at IS NULL "
                "AND revoked_at IS NULL AND expires_at > now() ORDER BY created_at"
            ),
            {"pid": ctx.patient_id},
        )
    ).mappings().all()

    return MembersListOut(
        members=[MemberOut(user_id=str(r["user_id"]), full_name=r["full_name"],
                           email=r["email"], role=r["role"],
                           profession=r["profession"], relationship=r["relationship"],
                           is_owner=r["is_owner"], joined_at=r["joined_at"])
                 for r in member_rows],
        pending_invitations=[PendingInvitationOut(invitation_id=str(r["invitation_id"]),
                                                  email=r["email"], role=r["role"],
                                                  profession=r["profession"],
                                                  expires_at=r["expires_at"])
                             for r in pending_rows],
    )


# --------------------------------------------------------------------------
# 4.8 Quitar miembro
# --------------------------------------------------------------------------
@router.delete("/patients/{patient_id}/members/{user_id}", status_code=204)
async def remove_member(
    user_id: str,
    ctx: PatientContext = Depends(get_patient_member(roles=["family"], require_owner=True)),
    db: AsyncSession = Depends(get_db),
):
    target = (
        await db.execute(
            text("SELECT is_owner FROM patient_members "
                 "WHERE patient_id = :pid AND user_id = :uid AND removed_at IS NULL"),
            {"pid": ctx.patient_id, "uid": user_id},
        )
    ).mappings().first()

    if target is None:
        raise ApiError(status_code=404, code="NOT_FOUND",
                       message="El recurso solicitado no existe o no está disponible.")
    if target["is_owner"]:
        raise ApiError(status_code=400, code="CANNOT_REMOVE_OWNER",
                       message="No puedes quitar al administrador del paciente.")

    await db.execute(
        text("UPDATE patient_members SET removed_at = now() "
             "WHERE patient_id = :pid AND user_id = :uid AND removed_at IS NULL"),
        {"pid": ctx.patient_id, "uid": user_id},
    )
    await db.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)


# --------------------------------------------------------------------------
# 4.9 Vincular wearable
# --------------------------------------------------------------------------
@router.post("/patients/{patient_id}/wearable",
             response_model=WearableLinkOut, status_code=201)
async def link_wearable(
    payload: WearableLinkIn,
    ctx: PatientContext = Depends(get_patient_member(roles=["family", "caregiver"])),
    db: AsyncSession = Depends(get_db),
):
    in_use = (
        await db.execute(
            text("SELECT 1 FROM wearables WHERE provider = 'simulator' "
                 "AND serial_number = :serial AND unlinked_at IS NULL AND patient_id <> :pid"),
            {"serial": payload.serial_number, "pid": ctx.patient_id},
        )
    ).first()
    if in_use:
        raise ApiError(status_code=409, code="WEARABLE_IN_USE",
                       message="Este dispositivo ya está vinculado a otro paciente.")

    await db.execute(
        text("UPDATE wearables SET unlinked_at = now() "
             "WHERE patient_id = :pid AND unlinked_at IS NULL"),
        {"pid": ctx.patient_id},
    )
    wearable = (
        await db.execute(
            text(
                "INSERT INTO wearables (patient_id, provider, serial_number, model) "
                "VALUES (:pid, 'simulator', :serial, :model) RETURNING id, created_at"
            ),
            {"pid": ctx.patient_id, "serial": payload.serial_number, "model": payload.model},
        )
    ).mappings().first()
    await db.commit()

    return WearableLinkOut(wearable_id=str(wearable["id"]), linked_at=wearable["created_at"])


# --------------------------------------------------------------------------
# 4.10 Estado del wearable
# --------------------------------------------------------------------------
@router.get("/patients/{patient_id}/wearable/status", response_model=WearableStatusOut)
async def wearable_status(
    ctx: PatientContext = Depends(get_patient_member()),
    db: AsyncSession = Depends(get_db),
):
    wearable = (
        await db.execute(
            text("SELECT id, last_sync_at, battery_pct FROM wearables "
                 "WHERE patient_id = :pid AND unlinked_at IS NULL"),
            {"pid": ctx.patient_id},
        )
    ).mappings().first()

    if wearable is None:
        return WearableStatusOut(wearable_id=None, last_sync_at=None,
                                 battery_pct=None, is_stale=True)

    last_sync_at = wearable["last_sync_at"]
    is_stale = (last_sync_at is None or
                last_sync_at < datetime.now(last_sync_at.tzinfo) - WEARABLE_STALE_AFTER)

    return WearableStatusOut(wearable_id=str(wearable["id"]), last_sync_at=last_sync_at,
                             battery_pct=wearable["battery_pct"], is_stale=is_stale)
