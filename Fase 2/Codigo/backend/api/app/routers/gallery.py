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
