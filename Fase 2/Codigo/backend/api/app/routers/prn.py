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
from datetime import datetime, timedelta, timezone
from uuid import UUID

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
