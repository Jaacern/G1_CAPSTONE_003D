"""Galeria familiar del adulto mayor.

Endpoints que la aplicacion ya consume:

    GET    /patients/{id}/photos
    POST   /patients/{id}/photos
    DELETE /photos/{id}
    POST   /photos/{id}/reactions
"""
from datetime import datetime
from uuid import UUID

from fastapi import APIRouter, Depends
from pydantic import BaseModel, Field
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

from app.db import get_db
from app.deps import CurrentUser, PatientContext, get_current_user, get_patient_member
from app.errors import ApiError
from app.routers.logbook import _archivo_del_paciente
from app.storage import get_storage

router = APIRouter(prefix="/api/v1", tags=["gallery"])

_NO_EXISTE = ApiError(
    status_code=404, code="NOT_FOUND",
    message="El recurso solicitado no existe o no esta disponible.",
)


class PhotoOut(BaseModel):
    id:         UUID
    url:        str
    caption:    str | None
    from_name:  str
    created_at: datetime
    reactions:  dict[str, int]


class PhotosOut(BaseModel):
    items: list[PhotoOut]


def _salida(f) -> PhotoOut:
    return PhotoOut(
        id=f["id"],
        url=get_storage().file_url(file_id=str(f["file_id"]), storage_key=""),
        caption=f["caption"],
        from_name=f["full_name"],
        created_at=f["created_at"],
        # La pantalla cuenta por tipo con reactionCount('love'), asi que
        # necesita el diccionario completo aunque este en cero.
        reactions=dict(f["reacciones"]) if f.get("reacciones") else {},
    )


@router.get("/patients/{patient_id}/photos", response_model=PhotosOut)
async def list_photos(
    ctx: PatientContext = Depends(get_patient_member()),
    db: AsyncSession = Depends(get_db),
):
    """Fotos que la familia comparte con el adulto mayor.

    Los conteos de reacciones se traen agregados en la misma consulta. La
    pantalla del adulto mayor muestra las fotos en grande y de corrido, asi
    que una consulta por foto se notaria.
    """
    filas = (
        await db.execute(
            text(
                """
                SELECT g.id, g.file_id, g.caption, g.created_at, u.full_name,
                       coalesce(r.reacciones, '{}'::jsonb) AS reacciones
                FROM gallery_photos g
                JOIN users u ON u.id = g.published_by_user_id
                LEFT JOIN LATERAL (
                    SELECT jsonb_object_agg(t.reaction_type, t.cuantas) AS reacciones
                    FROM (
                        SELECT reaction_type, count(*) AS cuantas
                        FROM photo_reactions
                        WHERE photo_id = g.id
                        GROUP BY reaction_type
                    ) t
                ) r ON true
                WHERE g.patient_id = :pid
                  AND g.deleted_at IS NULL
                ORDER BY g.display_order, g.created_at DESC
                LIMIT 200
                """
            ),
            {"pid": ctx.patient_id},
        )
    ).mappings().all()

    return PhotosOut(items=[_salida(f) for f in filas])


class PhotoIn(BaseModel):
    file_url: str = Field(min_length=1)
    caption:  str | None = Field(default=None, max_length=500)


@router.post("/patients/{patient_id}/photos", response_model=PhotoOut,
             status_code=201)
async def add_photo(
    payload: PhotoIn,
    ctx: PatientContext = Depends(get_patient_member(["family", "caregiver"])),
    db: AsyncSession = Depends(get_db),
):
    """Comparte una foto con el adulto mayor.

    La foto nueva se pone primero. display_order es ascendente, asi que la
    que entra toma el menor valor que haya menos uno: la familia comparte
    para que se vea ahora, no al final de la fila.
    """
    file_id = await _archivo_del_paciente(db, payload.file_url, ctx.patient_id)
    if file_id is None:
        raise ApiError(
            status_code=422, code="VALIDATION_ERROR",
            message="Falta la foto.",
            details=[{"field": "file_url", "message": "No puede ir vacio."}],
        )

    repetida = (
        await db.execute(
            text(
                """
                SELECT g.id, g.file_id, g.caption, g.created_at, u.full_name
                FROM gallery_photos g
                JOIN users u ON u.id = g.published_by_user_id
                WHERE g.file_id = :fid AND g.deleted_at IS NULL
                """
            ),
            {"fid": file_id},
        )
    ).mappings().first()
    if repetida is not None:
        # La misma foto ya esta en la galeria. Es un reintento de la
        # pantalla, no una foto nueva.
        return _salida({**dict(repetida), "reacciones": {}})

    caption = (payload.caption or "").strip() or None

    fila = (
        await db.execute(
            text(
                """
                INSERT INTO gallery_photos (
                    patient_id, published_by_user_id, file_id, caption,
                    display_order
                )
                SELECT :pid, :uid, :fid, :cap,
                       coalesce(min(display_order), 0) - 1
                FROM gallery_photos
                WHERE patient_id = :pid AND deleted_at IS NULL
                RETURNING id, file_id, caption, created_at
                """
            ),
            {"pid": ctx.patient_id, "uid": ctx.user.user_id,
             "fid": file_id, "cap": caption},
        )
    ).mappings().first()
    await db.commit()

    return _salida({**dict(fila), "full_name": ctx.user.full_name,
                    "reacciones": {}})
