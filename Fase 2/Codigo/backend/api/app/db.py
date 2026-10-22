"""Conexión asíncrona a la base de datos PostgreSQL existente.

La API NO crea ni modifica el esquema: las tablas ya las gestiona el SQL
de la carpeta ../sql. Aquí solo abrimos un pool de conexiones y damos
una sesión por request.
"""
from collections.abc import AsyncGenerator

from sqlalchemy.ext.asyncio import (
    AsyncSession,
    async_sessionmaker,
    create_async_engine,
)

from app.config import get_settings

settings = get_settings()

engine = create_async_engine(
    settings.database_url,
    echo=False,
    pool_pre_ping=True,  # revive conexiones muertas antes de usarlas
)

SessionLocal = async_sessionmaker(
    bind=engine,
    class_=AsyncSession,
    expire_on_commit=False,
)


async def get_db() -> AsyncGenerator[AsyncSession, None]:
    """Dependencia de FastAPI: entrega una sesión y la cierra al terminar."""
    async with SessionLocal() as session:
        yield session
