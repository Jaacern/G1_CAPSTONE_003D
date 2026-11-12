"""Check-in diario del adulto mayor (RF-38).

    PUT /patients/{patient_id}/checkins/today   responder o corregir el de hoy
    GET /patients/{patient_id}/checkins/today   el de hoy, o null
    GET /patients/{patient_id}/checkins         los ultimos dias, para el circulo

QUIEN RESPONDE
    RF-38 dice que el check-in es del adulto mayor. La tabla (514) admite
    ademas que lo ingrese la cuidadora, cuando el adulto mayor no puede usar
    su pantalla y se lo pregunta en voz alta: por eso el origen queda
    registrado (source elder | caregiver). La familia y el medico lo leen,
    no lo responden: no son quienes saben como se siente.

UNO POR DIA
    Lo impone el motor con UNIQUE (patient_id, checkin_date). Responder otra
    vez el mismo dia corrige el de hoy en vez de fallar: un adulto mayor que
    toca "Bien" y despues "Mal" se equivoco o cambio de idea, y lo que vale
    es lo ultimo que dijo. El dia es el de la zona de la sesion (America/
    Santiago, ver app/db.py), no el de UTC.

QUE PASA CON "MAL"
    Un check-in "bad" de hoy pone el semaforo del paciente en amarillo, con
    su motivo (RF-22). Asi la familia lo ve en su pantalla. No crea una
    alerta: RF-44 enumera los tipos de alerta y este no es uno de ellos.
"""
from datetime import date, datetime
from typing import Literal

from fastapi import APIRouter, Depends, Query
from pydantic import BaseModel, Field, field_validator
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

from app.db import get_db
from app.deps import PatientContext, get_patient_member
from app.idempotencia import Idem, idempotencia

router = APIRouter(prefix="/api/v1", tags=["checkins"])


class CheckinIn(BaseModel):
    mood:       Literal["good", "regular", "bad"]
    pain_level: int | None = Field(default=None, ge=0, le=10)
    slept_well: bool | None = None
    ate_well:   bool | None = None
    note:       str | None = Field(default=None, max_length=500)

    @field_validator("note")
    @classmethod
    def _nota(cls, v: str | None) -> str | None:
        if v is None:
            return None
        v = " ".join(v.split())
        return v or None


class CheckinOut(BaseModel):
    id:           str
    checkin_date: date
    mood:         str
    pain_level:   int | None
    slept_well:   bool | None
    ate_well:     bool | None
    note:         str | None
    source:       str
    updated_at:   datetime


class CheckinTodayOut(BaseModel):
    checkin: CheckinOut | None


class CheckinListOut(BaseModel):
    items: list[CheckinOut]


_COLUMNAS = """id, checkin_date, mood, pain_level, slept_well, ate_well,
               note, source, updated_at"""


def _salida(f) -> CheckinOut:
    return CheckinOut(
        id=str(f["id"]), checkin_date=f["checkin_date"], mood=f["mood"],
        pain_level=f["pain_level"], slept_well=f["slept_well"],
        ate_well=f["ate_well"], note=f["note"], source=f["source"],
        updated_at=f["updated_at"],
    )


@router.put("/patients/{patient_id}/checkins/today", response_model=CheckinOut)
async def responder_hoy(
    payload: CheckinIn,
    ctx: PatientContext = Depends(get_patient_member(["elder", "caregiver"])),
    db: AsyncSession = Depends(get_db),
    idem: Idem = Depends(idempotencia),
):
    # Reenvio de la cola de la app (RF-81): si esta accion ya se registro
    # con esta clave, se devuelve la misma respuesta sin repetirla.
    # Aca importa de verdad: el check-in es uno por dia y se reemplaza, asi
    # que un reenvio tardio de la cola pisaria una respuesta mas nueva que la
    # persona ya corrigio en la pantalla.
    previa = await idem.previa(db, ctx.user.user_id, CheckinOut)
    if previa is not None:
        return previa

    source = "elder" if ctx.role == "elder" else "caregiver"
    fila = (
        await db.execute(
            text(
                f"""
                INSERT INTO daily_checkins
                    (patient_id, checkin_date, mood, pain_level, slept_well,
                     ate_well, note, source)
                VALUES (:pid, current_date, :mood, :pain, :slept, :ate, :note, :src)
                ON CONFLICT (patient_id, checkin_date) DO UPDATE
                   SET mood       = EXCLUDED.mood,
                       pain_level = EXCLUDED.pain_level,
                       slept_well = EXCLUDED.slept_well,
                       ate_well   = EXCLUDED.ate_well,
                       note       = EXCLUDED.note,
                       source     = EXCLUDED.source
                RETURNING {_COLUMNAS}
                """
            ),
            {"pid": ctx.patient_id, "mood": payload.mood,
             "pain": payload.pain_level, "slept": payload.slept_well,
             "ate": payload.ate_well, "note": payload.note, "src": source},
        )
    ).mappings().first()
    salida = _salida(fila)
    await idem.guardar(db, ctx.user.user_id, salida, status_code=200)
    await db.commit()
    return salida


@router.get("/patients/{patient_id}/checkins/today", response_model=CheckinTodayOut)
async def ver_hoy(
    ctx: PatientContext = Depends(get_patient_member()),
    db: AsyncSession = Depends(get_db),
):
    fila = (
        await db.execute(
            text(f"SELECT {_COLUMNAS} FROM daily_checkins "
                 "WHERE patient_id = :pid AND checkin_date = current_date"),
            {"pid": ctx.patient_id},
        )
    ).mappings().first()
    return CheckinTodayOut(checkin=_salida(fila) if fila else None)


@router.get("/patients/{patient_id}/checkins", response_model=CheckinListOut)
async def historial(
    days: int = Query(default=14, ge=1, le=90),
    ctx: PatientContext = Depends(get_patient_member()),
    db: AsyncSession = Depends(get_db),
):
    filas = (
        await db.execute(
            text(
                f"""
                SELECT {_COLUMNAS} FROM daily_checkins
                WHERE patient_id = :pid
                  AND checkin_date > current_date - CAST(:dias AS int)
                ORDER BY checkin_date DESC
                """
            ),
            {"pid": ctx.patient_id, "dias": days},
        )
    ).mappings().all()
    return CheckinListOut(items=[_salida(f) for f in filas])


async def mal_hoy(db: AsyncSession, patient_id: str) -> bool:
    """El adulto mayor dijo hoy que se siente mal. Lo usa el semaforo."""
    return (
        await db.execute(
            text("SELECT 1 FROM daily_checkins WHERE patient_id = :pid "
                 "AND checkin_date = current_date AND mood = 'bad'"),
            {"pid": patient_id},
        )
    ).first() is not None


MOTIVO_MAL_HOY = "Hoy dijo sentirse mal"
