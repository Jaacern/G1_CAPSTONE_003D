"""Aplicador de archivos SQL, con registro de lo que ya corrio.

EL PROBLEMA QUE RESUELVE
    docker-entrypoint-initdb.d ejecuta los .sql una sola vez, cuando se crea
    el volumen de la base. Quien ya tenia la base levantada nunca corrio los
    archivos que se agregaron despues, y su aplicacion falla al tocar una
    tabla que en su maquina no existe.

    Volver a correrlos todos no es opcion: un CREATE TABLE sobre una tabla
    que ya esta revienta, y recrear el volumen borra los datos de todos.

COMO SE USA
    Primera vez, en una base que YA esta al dia:
        python -m app.migrate --baseline
    Eso anota todos los archivos actuales como aplicados sin ejecutarlos.

    De ahi en adelante, cada vez que alguien agregue archivos:
        python -m app.migrate
    Corre solo los que faltan, en orden, y cada uno dentro de su propia
    transaccion: si uno falla, ese queda sin aplicar y los anteriores se
    conservan.

    Para ver que haria sin tocar nada:
        python -m app.migrate --dry-run

    Y la que usa el contenedor al arrancar, que no necesita que nadie
    decida nada:
        python -m app.migrate --auto

Se guarda el sha256 de cada archivo. Si uno que ya corrio cambia despues,
se avisa: editar un archivo ya aplicado significa que la base de quien lo
corrio antes y la de quien lo corre ahora no quedan iguales, y eso es de
las cosas que cuesta semanas descubrir.
"""
from __future__ import annotations

import asyncio
import hashlib
import os
import sys
from pathlib import Path

from sqlalchemy import text

from app.db import engine

# Los .sql viven fuera del paquete, en backend/sql, que es la carpeta que
# docker-compose monta en la base.
CARPETA = Path(os.environ.get("AGECARE_SQL_DIR",
                              Path(__file__).resolve().parents[2] / "sql"))

_TABLA = """
CREATE TABLE IF NOT EXISTS schema_migrations (
    filename   varchar(200) PRIMARY KEY,
    checksum   char(64)     NOT NULL,
    applied_at timestamptz  NOT NULL DEFAULT now()
)
"""


def _archivos() -> list[Path]:
    """Los .sql de la carpeta, en el mismo orden que usa la base.

    Se ordenan por nombre porque es el orden en que los corre
    docker-entrypoint-initdb.d, y los archivos estan numerados justamente
    para eso. La subcarpeta schema/ queda fuera: ahi vive el volcado
    completo, que es una foto del esquema y no un paso a aplicar.
    """
    return sorted(p for p in CARPETA.glob("*.sql") if p.is_file())


def _firma(p: Path) -> str:
    return hashlib.sha256(p.read_bytes()).hexdigest()


async def _aplicados(conn) -> dict[str, str]:
    filas = (
        await conn.execute(text("SELECT filename, checksum FROM schema_migrations"))
    ).all()
    return {f[0]: f[1] for f in filas}


async def correr(*, baseline: bool = False, dry_run: bool = False) -> int:
    archivos = _archivos()
    if not archivos:
        print(f"No hay archivos .sql en {CARPETA}")
        return 1

    async with engine.begin() as conn:
        await conn.execute(text(_TABLA))
        ya = await _aplicados(conn)

    pendientes = [p for p in archivos if p.name not in ya]
    cambiados = [p for p in archivos
                 if p.name in ya and ya[p.name] != _firma(p)]

    if cambiados:
        print("AVISO: estos archivos cambiaron despues de haberse aplicado.")
        print("       Las bases que los corrieron antes no quedaron iguales")
        print("       a las que los corran ahora.")
        for p in cambiados:
            print(f"       - {p.name}")
        print()

    if baseline:
        if dry_run:
            print(f"[dry-run] anotaria {len(pendientes)} archivos sin ejecutarlos")
            for p in pendientes:
                print(f"          {p.name}")
            return 0
        async with engine.begin() as conn:
            for p in pendientes:
                await conn.execute(
                    text("INSERT INTO schema_migrations (filename, checksum) "
                         "VALUES (:f, :c) ON CONFLICT (filename) DO NOTHING"),
                    {"f": p.name, "c": _firma(p)},
                )
        print(f"Anotados {len(pendientes)} archivos como aplicados, sin ejecutarlos.")
        print("La base queda registrada como al dia.")
        return 0

    if not pendientes:
        print(f"Nada que aplicar. Los {len(archivos)} archivos ya estan.")
        return 0

    print(f"Pendientes: {len(pendientes)} de {len(archivos)}")
    for p in pendientes:
        print(f"   {p.name}")
    if dry_run:
        print("\n[dry-run] no se ejecuto nada")
        return 0
    print()

    for p in pendientes:
        sql = p.read_text(encoding="utf-8")
        try:
            # Cada archivo en su propia transaccion. Si uno falla, los
            # anteriores quedan aplicados y anotados, y se puede corregir
            # ese y volver a correr sin repetir los otros.
            async with engine.begin() as conn:
                # Se usa la conexion cruda de asyncpg y no exec_driver_sql:
                # esta ultima prepara la sentencia, y una sentencia
                # preparada admite UN comando. Todos los archivos tienen
                # varios, asi que por ahi no entra ninguno. El execute de
                # asyncpg usa el protocolo simple, que si acepta un script
                # completo, y corre dentro de la transaccion que abrio
                # SQLAlchemy.
                cruda = await conn.get_raw_connection()
                await cruda.driver_connection.execute(sql)
                await conn.execute(
                    text("INSERT INTO schema_migrations (filename, checksum) "
                         "VALUES (:f, :c)"),
                    {"f": p.name, "c": _firma(p)},
                )
        except Exception as e:  # noqa: BLE001
            print(f"FALLO en {p.name}")
            print(f"   {str(e).splitlines()[0]}")
            print("\nSe detiene aca. Los anteriores quedaron aplicados.")
            return 1
        print(f"OK  {p.name}")

    print(f"\nListo. {len(pendientes)} archivos aplicados.")
    return 0


# Marca que un archivo .sql puede volver a ejecutarse sin romper nada
# (usa IF NOT EXISTS, ON CONFLICT DO NOTHING y similares).
#
# Existe por un caso concreto: la base de alguien que levanto el proyecto
# antes de que hubiera registro de migraciones. Su esquema esta al dia
# hasta cierto archivo y nadie sabe cual, asi que los archivos viejos se
# anotan sin ejecutar y los que llevan esta marca se corren igual. Como son
# repetibles, correrlos de mas no hace dano, y asi la base se pone al dia
# sola sin que nadie tenga que averiguar en que version estaba.
#
# Todo archivo nuevo deberia escribirse asi y llevar la marca.
MARCA_IDEMPOTENTE = "-- MIGRACION IDEMPOTENTE"


async def _aplicar_idempotentes() -> int:
    """Corre los archivos marcados como repetibles, sin tocar el registro."""
    repetibles = [p for p in _archivos()
                  if MARCA_IDEMPOTENTE in p.read_text(encoding="utf-8")]
    if not repetibles:
        return 0
    print(f"\nSe vuelven a correr {len(repetibles)} archivos repetibles, "
          "por si faltaba alguno:")
    for p in repetibles:
        try:
            async with engine.begin() as conn:
                cruda = await conn.get_raw_connection()
                await cruda.driver_connection.execute(
                    p.read_text(encoding="utf-8"))
        except Exception as e:  # noqa: BLE001
            print(f"   FALLO {p.name}: {str(e).splitlines()[0]}")
            return 1
        print(f"   OK  {p.name}")
    return 0


async def auto() -> int:
    """Deja la base al dia sin que nadie tenga que decidir nada.

    Es lo que corre el contenedor al arrancar, y tiene que portarse bien en
    los tres estados en que se puede encontrar la base.

    BASE RECIEN CREADA
        docker-entrypoint-initdb.d ya ejecuto todos los .sql al crear el
        volumen. El esquema esta completo y no hay registro de migraciones,
        asi que se anotan todos como aplicados sin volver a ejecutarlos.

    BASE QUE YA VENIA FUNCIONANDO, SIN REGISTRO
        Es el caso de quien levanto el proyecto antes de que esto
        existiera. No hay forma de saber hasta que archivo llego su
        esquema, asi que se anotan todos como aplicados y despues se
        corren solo los marcados como repetibles. Se evaluo reintentarlos
        todos y tolerar los errores de "ya existe", y se descarto: entre
        crear tablas, transformar columnas y sembrar datos, cada archivo
        falla distinto, y la lista de errores a tolerar crecia tapando
        tambien los errores de verdad.

    BASE CON REGISTRO
        El caso normal de todos los dias: se corren los que falten.
    """
    async with engine.begin() as conn:
        hay_registro = await conn.scalar(
            text("SELECT to_regclass('public.schema_migrations') IS NOT NULL"))
        hay_esquema = await conn.scalar(
            text("SELECT to_regclass('public.users') IS NOT NULL"))

    if hay_registro:
        return await correr()
    if not hay_esquema:
        # Base vacia de verdad: se aplica todo desde cero.
        return await correr()

    print("Base con esquema y sin registro de migraciones.")
    print("Se anota lo existente y se corren los archivos repetibles.\n")
    r = await correr(baseline=True)
    return r or await _aplicar_idempotentes()


async def _main(argv: list[str]) -> int:
    validas = ("--baseline", "--dry-run", "--auto")
    desconocidas = [a for a in argv if a not in validas]
    if desconocidas:
        print(__doc__)
        return 2
    try:
        if "--auto" in argv:
            return await auto()
        return await correr(baseline="--baseline" in argv,
                            dry_run="--dry-run" in argv)
    finally:
        await engine.dispose()


if __name__ == "__main__":
    sys.exit(asyncio.run(_main(sys.argv[1:])))
