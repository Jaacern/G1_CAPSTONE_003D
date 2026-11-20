"""Cuenta sin circulo de cuidado, para probar el 404 de "no es tuyo".

POR QUE EXISTE
    Hay dos respuestas que se confunden facil:

        401  no hay sesion, o el token no vale
        404  la sesion vale, pero esta persona no tiene nada que ver con este
             paciente, y por eso el recurso ni se admite que exista

    La segunda protege los datos de un paciente de cualquier usuario
    registrado y solo se puede comprobar con una cuenta real: un token firmado
    para un id inexistente da 401 antes de mirar el circulo.

POR QUE NO VIVE EN EL SEMBRADO
    Antes era una cuenta mas de la base de desarrollo. Una demo con cuentas de
    prueba sobrando no es una demo limpia, asi que ahora la crea la prueba que
    la necesita y la borra al terminar. Importar este modulo basta:

        from _ajeno import AJENO

    Se usa un motor propio y se cierra, en vez del de la aplicacion: cada
    asyncio.run crea su propio ciclo de eventos y un pool no se puede
    compartir entre ciclos.
"""
from __future__ import annotations

import asyncio
import atexit
import pathlib
import subprocess
import sys

# Cuando corre como proceso aparte (borrar) nadie le puso app en el path.
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))

from sqlalchemy import text  # noqa: E402
from sqlalchemy.ext.asyncio import create_async_engine  # noqa: E402

from app.config import get_settings  # noqa: E402

AJENO = "eeeeeee1-0000-4000-8000-000000000001"

_HASH = "$2b$12$PhFlUg1xEBTGKQuSYaBy.ODxdKlWAShWRiJxT0w85tC15kZaSNK/."


async def _ejecutar(sql: str, **params) -> None:
    s = get_settings()
    eng = create_async_engine(
        s.database_url,
        connect_args={"server_settings": {"timezone": s.timezone}},
    )
    try:
        async with eng.begin() as conn:
            await conn.execute(text(sql), params)
    finally:
        await eng.dispose()


def _crear() -> None:
    asyncio.run(_ejecutar(
        """
        INSERT INTO users (id, email, password_hash, first_name, last_name, phone, locale)
        VALUES (:id, 'externo@agecare.cl', :h, 'Externo', 'Sin Circulo', '+56900000001', 'es')
        ON CONFLICT DO NOTHING
        """,
        id=AJENO, h=_HASH,
    ))


def _borrar() -> None:
    try:
        asyncio.run(_ejecutar("DELETE FROM users WHERE id = :id", id=AJENO))
    except Exception as e:  # no tapar el resultado de la prueba por la limpieza
        print(f"(no se pudo borrar la cuenta ajena de prueba: {e})")


def _borrar_al_salir() -> None:
    # Al salir el interprete ya no deja crear tareas en el pool de hilos que
    # usa asyncio (resolver el host), asi que el borrado va en un proceso
    # aparte y no dentro del atexit.
    subprocess.run([sys.executable, __file__, "borrar"], check=False)


if __name__ == "__main__":
    if sys.argv[1:] == ["borrar"]:
        _borrar()
else:
    _crear()
    atexit.register(_borrar_al_salir)
