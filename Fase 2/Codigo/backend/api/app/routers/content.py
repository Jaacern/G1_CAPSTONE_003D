"""Contenido para el adulto mayor.

Endpoint que la aplicacion ya consume:

    GET /content/feed

El feed "Para ti" son tarjetas de texto que la pantalla muestra en grande
y lee en voz alta. No depende de un paciente: es contenido comun, igual
para todos, asi que no lleva paciente en la ruta ni control por circulo,
solo sesion.
"""
from uuid import UUID

from fastapi import APIRouter, Depends, Query
from pydantic import BaseModel
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

from app.db import get_db
from app.deps import CurrentUser, get_current_user
from app.errors import ApiError
from app.storage import get_storage

router = APIRouter(prefix="/api/v1/content", tags=["content"])

_TIPOS = {"news", "joke", "memory", "exercise", "tip"}


class FeedItemOut(BaseModel):
    id:        UUID
    type:      str
    title:     str
    body:      str
    image_url: str | None


class FeedOut(BaseModel):
    items: list[FeedItemOut]


@router.get("/feed", response_model=FeedOut)
async def feed(
    category: str | None = Query(default=None, max_length=12),
    user: CurrentUser = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Tarjetas del feed, mezcladas por tipo.

    No vienen ordenadas por fecha. Si lo estuvieran, al publicar diez
    consejos seguidos el adulto mayor abriria la aplicacion y encontraria
    diez consejos: el feed se veria igual todos los dias hasta que alguien
    publique otra cosa.

    Se alternan los tipos, tomando uno de cada uno por vuelta y dentro de
    cada tipo lo mas nuevo primero. Asi la primera pantalla siempre trae
    un chiste, un recuerdo y un consejo, que es lo que esa pantalla
    intenta ser.
    """
    if category is not None and category not in _TIPOS:
        raise ApiError(
            status_code=422, code="VALIDATION_ERROR",
            message="Ese tipo de contenido no existe.",
            details=[{"field": "category",
                      "message": f"Valores aceptados: {', '.join(sorted(_TIPOS))}."}],
        )

    filas = (
        await db.execute(
            text(
                """
                SELECT id, type, title, body, image_file_id
                FROM (
                    SELECT f.*,
                           row_number() OVER (PARTITION BY f.type
                                              ORDER BY f.published_at DESC) AS vuelta
                    FROM elder_feed_items f
                    WHERE f.status = 'published'
                      AND f.deleted_at IS NULL
                      AND (CAST(:tipo AS text) IS NULL
                           OR f.type = CAST(:tipo AS text))
                ) t
                ORDER BY vuelta, type
                LIMIT 60
                """
            ),
            {"tipo": category},
        )
    ).mappings().all()

    storage = get_storage()
    return FeedOut(items=[
        FeedItemOut(
            id=f["id"],
            type=f["type"],
            title=f["title"],
            body=f["body"],
            image_url=(storage.file_url(file_id=str(f["image_file_id"]),
                                        storage_key="")
                       if f["image_file_id"] else None),
        )
        for f in filas
    ])
