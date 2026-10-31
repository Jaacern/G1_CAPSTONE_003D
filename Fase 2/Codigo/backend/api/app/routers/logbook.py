"""Bitacora de cuidado: observaciones, incidentes, relevo y turno.

Cubre los endpoints que la aplicacion ya consume:

    GET  /patients/{id}/observations
    POST /patients/{id}/observations
    POST /patients/{id}/incidents
    GET  /patients/{id}/handover-notes
    POST /patients/{id}/handover-notes
    POST /patients/{id}/checkin

La aplicacion manda las categorias y los tipos con la etiqueta que muestra
en pantalla, en espanol, mientras la base guarda codigos de una lista
cerrada. La traduccion ocurre aca: el CHECK del motor es lo que mantiene la
columna analizable, y la pantalla no tiene por que saber de codigos.
"""
import re
from datetime import datetime, timezone
from uuid import UUID

from fastapi import APIRouter, Depends, Request
from pydantic import BaseModel, Field
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

from app.db import get_db
from app.deps import PatientContext, get_patient_member
from app.errors import ApiError

router = APIRouter(prefix="/api/v1", tags=["logbook"])

_UUID = re.compile(
    r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-"
    r"[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
)


# ---------------------------------------------------------------------------
# Traduccion entre lo que manda la aplicacion y lo que guarda la base
# ---------------------------------------------------------------------------
def _sin_tildes(s: str) -> str:
    """Minusculas, sin tildes y sin enes, para comparar etiquetas.

    La pantalla manda 'Alimentación' con tilde y 'Sueño' con ene. Comparar
    el texto crudo obligaria a repetir cada etiqueta con y sin acento, y
    cualquier cambio de mayuscula en la pantalla romperia el mapeo sin que
    nadie se entere.
    """
    tabla = str.maketrans("áàäâãéèëêíìïîóòöôõúùüûñç",
                          "aaaaaeeeeiiiiooooouuuunc")
    return s.strip().lower().translate(tabla)


_CATEGORIA = {
    "alimentacion": "food",
    "animo":        "mood",
    "sueno":        "sleep",
    "movilidad":    "mobility",
    "higiene":      "hygiene",
    "general":      "other",
    "dolor":        "pain",
    "medicacion":   "medication",
    "visita":       "visit",
}
_CATEGORIAS_BASE = {"mood", "food", "hygiene", "sleep", "mobility", "pain",
                    "medication", "visit", "other"}


def _resolver_categoria(valor: str | None) -> str:
    if valor is None or not valor.strip():
        return "other"
    plano = _sin_tildes(valor)
    if plano in _CATEGORIAS_BASE:
        return plano
    resuelta = _CATEGORIA.get(plano)
    if resuelta is None:
        raise ApiError(
            status_code=422, code="VALIDATION_ERROR",
            message="Esa categoria de observacion no existe.",
            details=[{"field": "category", "message": f"Valor recibido: {valor}."}],
        )
    return resuelta


# ---------------------------------------------------------------------------
# Piezas compartidas
# ---------------------------------------------------------------------------
async def _registrar_lectura(db: AsyncSession, ctx: PatientContext,
                             request: Request, *, seccion: str,
                             entity_id: str | None = None) -> None:
    """Deja constancia de una lectura del expediente (RNF-14)."""
    await db.execute(
        text(
            """
            INSERT INTO record_access_log (
                patient_id, user_id, role, section, entity_id,
                ip_address, user_agent
            ) VALUES (:pid, :uid, :role, :sec, :eid, :ip, :ua)
            """
        ),
        {
            "pid": ctx.patient_id, "uid": ctx.user.user_id, "role": ctx.role,
            "sec": seccion, "eid": entity_id,
            "ip": request.client.host if request.client else None,
            "ua": (request.headers.get("user-agent") or "")[:300] or None,
        },
    )


async def _archivo_del_paciente(db: AsyncSession, media_url: str | None,
                                patient_id: str) -> str | None:
    """Traduce el media_url que manda la aplicacion al id del archivo.

    La aplicacion guarda la URL que recibio al subir, no el id. Se exige que
    el archivo exista, este almacenado y sea de ESTE paciente: sin eso una
    observacion podria quedar apuntando a la foto del expediente de otro.
    """
    if media_url is None or not media_url.strip():
        return None

    encontrado = _UUID.search(media_url)
    if encontrado is None:
        raise ApiError(
            status_code=422, code="VALIDATION_ERROR",
            message="La referencia del archivo adjunto no es valida.",
            details=[{"field": "media_url", "message": f"Valor recibido: {media_url}."}],
        )
    file_id = encontrado.group(0)

    fila = (
        await db.execute(
            text(
                """
                SELECT 1
                FROM files
                WHERE id = :fid
                  AND patient_id = :pid
                  AND scope = 'patient'
                  AND status = 'stored'
                """
            ),
            {"fid": file_id, "pid": patient_id},
        )
    ).first()
    if fila is None:
        raise ApiError(
            status_code=422, code="VALIDATION_ERROR",
            message="El archivo adjunto no existe o no pertenece a este paciente.",
            details=[{"field": "media_url", "message": f"Archivo: {file_id}."}],
        )
    return file_id


def _media_url(file_id: str | None) -> str | None:
    if file_id is None:
        return None
    from app.storage import get_storage
    return get_storage().file_url(file_id=str(file_id), storage_key="")


# ---------------------------------------------------------------------------
# Observaciones (RF-34, RF-35)
# ---------------------------------------------------------------------------
class ObservationOut(BaseModel):
    id:          UUID
    text:        str
    category:    str
    media_url:   str | None
    created_at:  datetime
    author_name: str


class ObservationsOut(BaseModel):
    items: list[ObservationOut]


class ObservationIn(BaseModel):
    text:      str = Field(min_length=1, max_length=1000)
    category:  str | None = None
    media_url: str | None = None


@router.get("/patients/{patient_id}/observations",
            response_model=ObservationsOut)
async def list_observations(
    request: Request,
    ctx: PatientContext = Depends(get_patient_member()),
    db: AsyncSession = Depends(get_db),
):
    """Bitacora del paciente, lo mas reciente primero (RF-35)."""
    filas = (
        await db.execute(
            text(
                """
                SELECT o.id, o.note, o.category, o.photo_file_id,
                       o.observed_at, u.full_name
                FROM care_observations o
                JOIN users u ON u.id = o.author_id
                WHERE o.patient_id = :pid
                  AND o.deleted_at IS NULL
                ORDER BY o.observed_at DESC
                LIMIT 200
                """
            ),
            {"pid": ctx.patient_id},
        )
    ).mappings().all()

    await _registrar_lectura(db, ctx, request, seccion="logbook")
    await db.commit()

    return ObservationsOut(items=[
        ObservationOut(
            id=f["id"],
            text=f["note"],
            category=f["category"],
            media_url=_media_url(f["photo_file_id"]),
            created_at=f["observed_at"],
            author_name=f["full_name"],
        )
        for f in filas
    ])


@router.post("/patients/{patient_id}/observations",
             response_model=ObservationOut, status_code=201)
async def create_observation(
    payload: ObservationIn,
    ctx: PatientContext = Depends(get_patient_member(["caregiver", "family"])),
    db: AsyncSession = Depends(get_db),
):
    """Registra una observacion en la bitacora (RF-34)."""
    categoria = _resolver_categoria(payload.category)
    file_id = await _archivo_del_paciente(db, payload.media_url, ctx.patient_id)

    fila = (
        await db.execute(
            text(
                """
                INSERT INTO care_observations (
                    patient_id, author_id, category, note,
                    photo_file_id, observed_at
                ) VALUES (
                    :pid, :uid, :cat, :nota, :fid, now()
                )
                RETURNING id, note, category, photo_file_id, observed_at
                """
            ),
            {
                "pid": ctx.patient_id, "uid": ctx.user.user_id,
                "cat": categoria, "nota": payload.text.strip(), "fid": file_id,
            },
        )
    ).mappings().first()
    await db.commit()

    return ObservationOut(
        id=fila["id"],
        text=fila["note"],
        category=fila["category"],
        media_url=_media_url(fila["photo_file_id"]),
        created_at=fila["observed_at"],
        author_name=ctx.user.full_name,
    )
