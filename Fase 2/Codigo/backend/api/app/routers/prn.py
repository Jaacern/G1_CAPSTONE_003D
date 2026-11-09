"""Indicaciones SOS ("solo si se necesita"): verlas y registrar cada uso.

Una indicacion SOS (treatment_items.is_prn) no genera dosis en la agenda, asi
que hasta ahora nadie veia cuando se uso ni cuantas veces. Este modulo la hace
operable para quien cuida:

  GET  /patients/{id}/prn                  SOS vigentes con su estado
  POST /patients/{id}/prn/{item_id}/uses   registrar un uso
  GET  /patients/{id}/prn/uses             historial de usos

El conteo es por farmaco y paciente, no por fila de indicacion: si el medico
versiona el tratamiento, los usos de la version anterior siguen contando para
el maximo de 24 h y para el intervalo.
"""
import os
from datetime import datetime, timedelta, timezone
from uuid import UUID
from zoneinfo import ZoneInfo

from fastapi import APIRouter, Depends, Query
from pydantic import BaseModel, Field
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

from app.db import get_db
from app.deps import PatientContext, get_patient_member
from app.errors import ApiError

router = APIRouter(prefix="/api/v1", tags=["prn"])

# Mismo farmaco aunque cambie la fila de la indicacion (versionado).
_CLAVE = "COALESCE({a}.drug_code, lower({a}.name))"
_USOS_DEL_FARMACO = (
    "FROM treatment_item_prn_uses u "
    "JOIN treatment_items ti2 ON ti2.id = u.treatment_item_id "
    "JOIN treatments t2 ON t2.id = ti2.treatment_id "
    "WHERE t2.patient_id = t.patient_id "
    f"AND {_CLAVE.format(a='ti2')} = {_CLAVE.format(a='ti')}"
)
_ESTADO_SQL = f"""
SELECT ti.id, ti.name, ti.dose_text, ti.dose_amount, ti.dose_unit,
       ti.instructions, ti.schedule_label, ti.prn_min_interval_min,
       t.specialty, dc.max_daily,
       (SELECT max(u.administered_at) {_USOS_DEL_FARMACO}) AS last_used_at,
       (SELECT count(*) {_USOS_DEL_FARMACO}
           AND u.administered_at > now() - interval '24 hours') AS uses_24h,
       (SELECT COALESCE(sum(ti2.dose_amount), 0) {_USOS_DEL_FARMACO}
           AND u.administered_at > now() - interval '24 hours') AS amount_24h
FROM treatments t
JOIN treatment_items ti ON ti.treatment_id = t.id
LEFT JOIN drug_catalog dc ON dc.code = ti.drug_code
WHERE t.patient_id = :pid
  AND t.status = 'vigente'
  AND ti.is_prn = true
  AND ti.action <> 'removed'
"""


def _hora_local(dt: datetime) -> str:
    """HH:MM en la zona de la operacion, para los mensajes a quien cuida."""
    try:
        zona = ZoneInfo(os.environ.get("TIMEZONE", "America/Santiago"))
    except Exception:
        zona = timezone.utc
    return dt.astimezone(zona).strftime("%H:%M")


def _intervalo_txt(minutos: int) -> str:
    return f"{minutos // 60} h" if minutos % 60 == 0 else f"{minutos} min"

class PrnItemOut(BaseModel):
    item_id:          str
    name:             str
    dose:             str
    dose_amount:      float
    dose_unit:        str
    specialty:        str
    instructions:     str | None = None
    schedule_label:   str | None = None
    min_interval_min: int | None = None
    max_daily:        float | None = None    # del catalogo, en la unidad de la dosis
    last_used_at:     datetime | None = None
    next_allowed_at:  datetime | None = None
    uses_last_24h:    int = 0
    used_last_24h:    float = 0              # cantidad dada en 24 h


async def _estado(db: AsyncSession, patient_id: str, item_id: str | None = None):
    sql = _ESTADO_SQL + (" AND ti.id = :iid" if item_id else "") + " ORDER BY ti.name"
    params = {"pid": patient_id}
    if item_id:
        params["iid"] = item_id
    return (await db.execute(text(sql), params)).mappings().all()


def _item_out(r) -> PrnItemOut:
    intervalo = r["prn_min_interval_min"]
    ultimo = r["last_used_at"]
    return PrnItemOut(
        item_id=str(r["id"]), name=r["name"], dose=r["dose_text"],
        dose_amount=float(r["dose_amount"]), dose_unit=r["dose_unit"],
        specialty=r["specialty"], instructions=r["instructions"],
        schedule_label=r["schedule_label"], min_interval_min=intervalo,
        max_daily=float(r["max_daily"]) if r["max_daily"] is not None else None,
        last_used_at=ultimo,
        next_allowed_at=(ultimo + timedelta(minutes=intervalo)
                         if ultimo and intervalo else None),
        uses_last_24h=int(r["uses_24h"]),
        used_last_24h=float(r["amount_24h"]),
    )


@router.get("/patients/{patient_id}/prn", response_model=list[PrnItemOut])
async def list_prn(
    ctx: PatientContext = Depends(get_patient_member()),
    db: AsyncSession = Depends(get_db),
):
    """SOS vigentes del paciente con ultimo uso, lo usado en 24 h y desde cuando
    corresponde el siguiente. Cualquier miembro del circulo puede verlos."""
    return [_item_out(r) for r in await _estado(db, ctx.patient_id)]


class PrnUseIn(BaseModel):
    reason:           str = Field(min_length=3, max_length=200)
    administered_at:  datetime | None = None   # None = ahora
    confirm_interval: bool = False


class PrnUseOut(BaseModel):
    use_id:            str
    item_id:           str
    name:              str
    dose:              str
    administered_at:   datetime
    reason:            str
    logged_by_name:    str | None = None
    overrode_interval: bool = False


_USOS_SQL = """
SELECT u.id, u.treatment_item_id, ti.name, ti.dose_text, u.administered_at,
       u.reason, u.overrode_interval,
       usr.first_name || ' ' || usr.last_name AS logged_by_name
FROM treatment_item_prn_uses u
JOIN treatment_items ti ON ti.id = u.treatment_item_id
JOIN treatments t ON t.id = ti.treatment_id
LEFT JOIN users usr ON usr.id = u.logged_by
WHERE t.patient_id = :pid
"""


def _uso_out(r) -> PrnUseOut:
    return PrnUseOut(
        use_id=str(r["id"]), item_id=str(r["treatment_item_id"]), name=r["name"],
        dose=r["dose_text"], administered_at=r["administered_at"],
        reason=r["reason"], logged_by_name=r["logged_by_name"],
        overrode_interval=r["overrode_interval"],
    )


@router.post("/patients/{patient_id}/prn/{item_id}/uses",
             response_model=PrnUseOut, status_code=201)
async def register_prn_use(
    item_id: UUID,
    payload: PrnUseIn,
    ctx: PatientContext = Depends(
        get_patient_member(roles=["caregiver", "family", "doctor"])),
    db: AsyncSession = Depends(get_db),
):
    """Registra que se dio una dosis SOS: cuando, por que y quien lo anota."""
    filas = await _estado(db, ctx.patient_id, str(item_id))
    if not filas:
        raise ApiError(status_code=404, code="NOT_FOUND",
                       message="Esa indicación SOS no está vigente para este paciente.")
    it = filas[0]
    reason = payload.reason.strip()
    if len(reason) < 3:
        raise ApiError(status_code=422, code="VALIDATION_ERROR",
                       message="Indica el motivo del uso (por ejemplo, crisis de disnea).")

    ahora = datetime.now(timezone.utc)
    adm = payload.administered_at or ahora
    if adm.tzinfo is None:
        adm = adm.replace(tzinfo=timezone.utc)
    if adm > ahora + timedelta(minutes=5):
        raise ApiError(status_code=422, code="VALIDATION_ERROR",
                       message="La hora del uso no puede estar en el futuro.")
    if adm < ahora - timedelta(hours=12):
        raise ApiError(status_code=422, code="VALIDATION_ERROR",
                       message="Solo se registran usos de las últimas 12 horas.")

    # Maximo de 24 h del farmaco: bloqueo duro. Pasarlo no es una decision de
    # quien cuida; se le pide llamar al medico.
    if it["max_daily"] is not None:
        tras = float(it["amount_24h"]) + float(it["dose_amount"])
        maximo = float(it["max_daily"])
        if tras > maximo:
            raise ApiError(
                status_code=422, code="PRN_MAX_DAILY",
                message=(f"Con este uso serían {tras:g} {it['dose_unit']} en 24 h y "
                         f"el máximo de {it['name']} es {maximo:g}. No registres "
                         "otra dosis: consulta al médico."))

    overrode = False
    # Intervalo minimo de la indicacion: advertencia que se puede confirmar
    # (puede haber una orden medica de repetir antes). Queda marcado.
    intervalo = it["prn_min_interval_min"]
    if intervalo and it["last_used_at"]:
        desde = it["last_used_at"] + timedelta(minutes=intervalo)
        if adm < desde:
            if not payload.confirm_interval:
                raise ApiError(
                    status_code=409, code="PRN_TOO_SOON",
                    message=(f"El último uso fue a las {_hora_local(it['last_used_at'])} y la "
                             f"indicación es cada {_intervalo_txt(intervalo)}. Lo siguiente "
                             f"sería desde las {_hora_local(desde)}. Confirma solo si el "
                             "médico lo autorizó."))
            overrode = True

    row = (
        await db.execute(
            text("INSERT INTO treatment_item_prn_uses "
                 "(treatment_item_id, administered_at, reason, overrode_interval, logged_by) "
                 "VALUES (:iid, :adm, :reason, :ovr, :uid) RETURNING id"),
            {"iid": str(item_id), "adm": adm, "reason": reason,
             "ovr": overrode, "uid": ctx.user.user_id},
        )
    ).mappings().first()
    await db.commit()
    uso = (
        await db.execute(text(_USOS_SQL + " AND u.id = :uid2"),
                         {"pid": ctx.patient_id, "uid2": str(row["id"])})
    ).mappings().first()
    return _uso_out(uso)
