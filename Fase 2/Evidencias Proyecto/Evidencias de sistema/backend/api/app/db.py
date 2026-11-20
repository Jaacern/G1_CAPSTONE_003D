"""Conexión asíncrona a la base de datos PostgreSQL existente.

La API NO crea ni modifica el esquema: las tablas ya las gestiona el SQL
de la carpeta ../sql. Aquí solo abrimos un pool de conexiones y damos
una sesión por request.

LA ZONA HORARIA DE LA CONEXIÓN
    Se fija explícitamente y no se deja en la que traiga el servidor. El
    contenedor de Postgres corre en UTC, y en UTC se calculaba mal todo lo
    que preguntara por un día.

    Un timestamptz es un instante, no un día. Convertirlo a día
    (scheduled_at::date) o preguntar qué día es hoy (current_date) usa la
    zona de la sesión. Con la sesión en UTC, desde las nueve de la noche en
    Chile ya era mañana: las dosis de hoy eran las de mañana, la adherencia
    partía los días en el lugar equivocado y un turno que empezaba a las
    21:30 quedaba registrado al día siguiente.

    Puesta acá, la corrección vale para toda consulta que pregunte por un
    día, incluidas las que se escriban después. Lo que NO cambia es la
    comparación entre instantes: un timestamptz sigue siendo absoluto y
    "antes" sigue siendo antes. Solo cambia a qué día pertenece cada uno.
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
    # server_settings se aplica al abrir cada conexión del pool, así que
    # no hay forma de usar una conexión sin la zona puesta.
    connect_args={"server_settings": {"timezone": settings.timezone}},
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
