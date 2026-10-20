"""Healthcheck: comprueba que la API responde y que la BD está accesible."""
from fastapi import APIRouter, Depends
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

from app.db import get_db

router = APIRouter(tags=["health"])


@router.get("/health")
async def health():
    """Liveness: la API está arriba."""
    return {"status": "ok"}


@router.get("/health/db")
async def health_db(db: AsyncSession = Depends(get_db)):
    """Readiness: verifica que la BD responde con un SELECT 1."""
    result = await db.execute(text("SELECT 1"))
    result.scalar_one()
    return {"status": "ok", "database": "up"}
