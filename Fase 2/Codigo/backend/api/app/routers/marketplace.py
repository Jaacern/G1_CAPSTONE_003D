"""Marketplace: buscar cuidadoras, contactarlas y resenarlas.

Endpoints que la aplicacion ya consume:

    GET  /marketplace/caregivers
    GET  /marketplace/caregivers/{id}
    POST /marketplace/caregivers/{id}/contact
    POST /marketplace/caregivers/{id}/reviews
    GET  /marketplace/products
    GET  /marketplace/products/{id}
"""
from datetime import datetime
from uuid import UUID

from fastapi import APIRouter, Depends, Query
from pydantic import BaseModel, Field, field_validator
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

from app.db import get_db
from app.deps import CurrentUser, get_current_user
from app.errors import ApiError

router = APIRouter(prefix="/api/v1/marketplace", tags=["marketplace"])

_NO_EXISTE = ApiError(
    status_code=404, code="NOT_FOUND",
    message="El recurso solicitado no existe o no esta disponible.",
)


class CaregiverSummary(BaseModel):
    profile_id:     UUID
    name:           str
    photo_url:      str | None
    headline:       str
    rating:         float
    reviews_count:  int
    zones:          list[str]
    specialties:    list[str]
    price_per_hour: float | None


class CaregiversOut(BaseModel):
    items: list[CaregiverSummary]


@router.get("/caregivers", response_model=CaregiversOut)
async def list_caregivers(
    zone: str | None = Query(default=None, max_length=8),
    specialty: str | None = Query(default=None, max_length=40),
    user: CurrentUser = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Busca cuidadoras publicadas, con filtro por comuna y especialidad.

    Solo salen los perfiles publicados y no suspendidos. Un perfil a medio
    escribir no deberia aparecerle a una familia que esta eligiendo a quien
    le deja a su madre.

    Las dos listas se traen en la misma consulta con agregacion, no una
    consulta por cuidadora: con cien perfiles en pantalla eso serian
    doscientas consultas.
    """
    filas = (
        await db.execute(
            text(
                """
                SELECT cp.id, cp.headline, cp.rating_avg, cp.rating_count,
                       cp.hourly_rate, u.full_name, u.avatar_url,
                       coalesce(z.zonas, ARRAY[]::text[])        AS zonas,
                       coalesce(e.especialidades, ARRAY[]::text[]) AS especialidades
                FROM caregiver_profiles cp
                JOIN users u ON u.id = cp.user_id
                LEFT JOIN LATERAL (
                    SELECT array_agg(cz.commune_code ORDER BY cz.commune_code) AS zonas
                    FROM caregiver_zones cz WHERE cz.profile_id = cp.id
                ) z ON true
                LEFT JOIN LATERAL (
                    SELECT array_agg(s.label ORDER BY s.label) AS especialidades
                    FROM caregiver_specialties cs
                    JOIN specialties s ON s.code = cs.specialty_code
                    WHERE cs.profile_id = cp.id
                ) e ON true
                WHERE cp.status = 'published'
                  AND cp.suspended_at IS NULL
                  AND cp.deleted_at IS NULL
                  AND u.is_active
                  AND u.deleted_at IS NULL
                  -- Los parametros van con CAST: usados solo dentro de un IS NULL
                  -- el motor no tiene como deducir de que tipo son y rechaza
                  -- la consulta. Se escribe CAST(...) y no ::text porque
                  -- text() de SQLAlchemy confunde los dos puntos del cast
                  -- con el inicio de otro parametro.
                  AND (CAST(:zona AS text) IS NULL OR EXISTS (
                        SELECT 1 FROM caregiver_zones cz
                        WHERE cz.profile_id = cp.id
                          AND cz.commune_code = CAST(:zona AS text)))
                  AND (CAST(:esp AS text) IS NULL OR EXISTS (
                        SELECT 1 FROM caregiver_specialties cs
                        JOIN specialties s ON s.code = cs.specialty_code
                        WHERE cs.profile_id = cp.id
                          AND (cs.specialty_code = CAST(:esp AS text)
                               OR lower(s.label) = lower(CAST(:esp AS text)))))
                ORDER BY cp.rating_avg DESC NULLS LAST,
                         cp.rating_count DESC,
                         u.full_name
                LIMIT 100
                """
            ),
            {"zona": zone, "esp": specialty},
        )
    ).mappings().all()

    return CaregiversOut(items=[
        CaregiverSummary(
            profile_id=f["id"],
            name=f["full_name"],
            photo_url=f["avatar_url"],
            headline=f["headline"],
            rating=float(f["rating_avg"] or 0),
            reviews_count=f["rating_count"],
            zones=list(f["zonas"]),
            specialties=list(f["especialidades"]),
            price_per_hour=float(f["hourly_rate"]) if f["hourly_rate"] is not None else None,
        )
        for f in filas
    ])
