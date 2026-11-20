"""Pruebas de las migraciones reversibles (RNF-24).

Dos cosas distintas. Una es la regla: toda migracion que cambia el esquema
trae su revert, y las semillas de datos de ejemplo quedan exentas pero lo
tienen que declarar. La otra es que los reverts de verdad funcionen, asi que
se revierte una contra la base y se vuelve a aplicar.
"""
import os
os.environ.setdefault("POSTGRES_HOST", "127.0.0.1")
os.environ.setdefault("POSTGRES_PORT", "5432")
os.environ.setdefault("STORAGE_LOCAL_DIR", "/tmp/agecare-files-test")
os.environ.setdefault("STORAGE_PUBLIC_BASE_URL", "http://testserver")

import pathlib as _pl
import sys as _sys
_sys.path.insert(0, str(_pl.Path(__file__).resolve().parents[1]))


import asyncio  # noqa: E402

from sqlalchemy import text as _t  # noqa: E402

from app.db import engine as _eng  # noqa: E402
from app.migrate import (  # noqa: E402
    CARPETA_REVERTIR,
    auto,
    MARCA_IDEMPOTENTE,
    MARCA_SEMILLA,
    _archivos,
    archivo_revert,
    correr,
    es_semilla,
    migraciones_de_esquema,
    revertir,
)

n = ok = 0


def check(nombre, condicion, extra=None):
    global n, ok
    n += 1
    if condicion:
        ok += 1
        print(f"  ok   {nombre}")
    else:
        print(f"  FALLA {nombre}" + (f"  {extra}" if extra is not None else ""))


async def sql(q, **p):
    async with _eng.begin() as c:
        return await c.execute(_t(q), p)


def la_regla():
    print("--- la regla: toda migracion de esquema trae su revert ---")
    esquema = migraciones_de_esquema()
    check("hay migraciones de esquema que revisar", len(esquema) > 0,
          len(esquema))

    sin_revert = [p.name for p in esquema if not archivo_revert(p.name).is_file()]
    check(f"las {len(esquema)} tienen su archivo en sql/revertir/",
          not sin_revert, sin_revert)

    vacios = [p.name for p in esquema
              if archivo_revert(p.name).is_file()
              and len(archivo_revert(p.name).read_text(encoding="utf-8").strip()) < 20]
    check("ninguno quedo vacio", not vacios, vacios)

    # Cada revert dice que revierte. Es lo que permite leer la carpeta y
    # entender de que viene cada archivo sin abrir la migracion.
    mudos = [p.name for p in esquema
             if f"Revierte {p.name}" not in
                archivo_revert(p.name).read_text(encoding="utf-8")]
    check("cada revert nombra la migracion que deshace", not mudos, mudos)

    print("--- las semillas quedan exentas, pero lo declaran ---")
    marcadas = [p for p in _archivos()
                if MARCA_IDEMPOTENTE in p.read_text(encoding="utf-8")]
    semillas = [p for p in marcadas if es_semilla(p)]
    check("hay semillas declaradas", len(semillas) > 0, len(semillas))
    check("toda migracion marcada es o de esquema o semilla",
          len(semillas) + len(migraciones_de_esquema()) == len(marcadas),
          (len(semillas), len(migraciones_de_esquema()), len(marcadas)))

    con_revert = [p.name for p in semillas if archivo_revert(p.name).is_file()]
    check("ninguna semilla tiene revert", not con_revert, con_revert)

    print("--- no quedan reverts huerfanos ---")
    nombres = {p.name for p in _archivos()}
    huerfanos = [p.name for p in sorted(CARPETA_REVERTIR.glob("*.sql"))
                 if p.name not in nombres]
    check("todo revert corresponde a una migracion que existe",
          not huerfanos, huerfanos)

    sobran = [p.name for p in sorted(CARPETA_REVERTIR.glob("*.sql"))
              if p.name in nombres and MARCA_SEMILLA in
              (_pl.Path(str(archivo_revert(p.name))).read_text(encoding="utf-8"))]
    check("ningun revert se escribio para una semilla", not sobran, sobran)


async def el_viaje_de_ida_y_vuelta():
    print("--- revertir de verdad y volver a aplicar ---")
    NOMBRE = "969_claves_de_reenvio.sql"

    # Una base recien creada tiene el esquema puesto y el registro vacio, que
    # es uno de los tres estados que auto() sabe resolver. Sin esto no hay
    # nada que revertir, porque para el registro no se aplico nunca.
    await auto()

    existe = lambda: sql(  # noqa: E731
        "SELECT to_regclass('public.idempotency_keys') IS NOT NULL")

    antes = (await existe()).scalar()
    check("la tabla esta antes de revertir", antes is True, antes)
    if not antes:
        return

    r = await revertir(NOMBRE)
    check("el revert termina bien", r == 0, r)
    check("la tabla ya no esta", (await existe()).scalar() is False)
    quedan = (await sql("SELECT count(*) FROM schema_migrations "
                        " WHERE filename = :f", f=NOMBRE)).scalar()
    check("y salio del registro, para poder volver a aplicarse", quedan == 0,
          quedan)

    # Revertir dos veces no tiene sentido y tiene que decirlo, no romper.
    r = await revertir(NOMBRE)
    check("revertir de nuevo avisa en vez de fallar feo", r == 1, r)

    await correr()
    check("al volver a aplicar, la tabla esta de nuevo",
          (await existe()).scalar() is True)
    quedan = (await sql("SELECT count(*) FROM schema_migrations "
                        " WHERE filename = :f", f=NOMBRE)).scalar()
    check("y vuelve a figurar en el registro", quedan == 1, quedan)


async def el_que_no_borra_solo():
    print("--- un revert no decide borrar datos del expediente ---")
    NOMBRE = "968_dosis_cancelada.sql"

    dosis = (await sql(
        "SELECT id, status FROM scheduled_doses "
        " WHERE status = 'pending' ORDER BY scheduled_at DESC LIMIT 1"
    )).mappings().first()
    if dosis is None:
        check("hay una dosis con la que probar", False, "ninguna pendiente")
        return

    await sql("UPDATE scheduled_doses SET status = 'cancelled', "
              "       reason = 'prueba de revert' WHERE id = :i", i=dosis["id"])
    try:
        r = await revertir(NOMBRE)
        check("se detiene si hay tomas canceladas", r == 1, r)
        sigue = (await sql("SELECT status FROM scheduled_doses WHERE id = :i",
                           i=dosis["id"])).scalar()
        check("y no las toco", sigue == "cancelled", sigue)
        quedan = (await sql("SELECT count(*) FROM schema_migrations "
                            " WHERE filename = :f", f=NOMBRE)).scalar()
        check("ni saco la migracion del registro", quedan == 1, quedan)
    finally:
        await sql("UPDATE scheduled_doses SET status = :s, reason = NULL "
                  " WHERE id = :i", i=dosis["id"], s=dosis["status"])


async def run():
    la_regla()
    await el_viaje_de_ida_y_vuelta()
    await el_que_no_borra_solo()
    await _eng.dispose()
    print()
    print(f"{ok} ok, {n - ok} fallas")
    return 0 if ok == n else 1


_sys.exit(asyncio.run(run()))
