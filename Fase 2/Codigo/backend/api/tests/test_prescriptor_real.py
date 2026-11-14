"""Ningun tratamiento queda con un prescriptor falso (migracion 972).

960 podia dejar un tratamiento de arranque con prescriber_role='doctor' aunque
el prescriptor fuera el familiar owner. Esta prueba comprueba que, tras 972, no
queda ningun tratamiento marcado 'doctor' cuyo prescriptor sea en realidad un
familiar o una cuidadora. Solo lee, no cambia nada.
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

n = ok = 0


def comprobar(nombre, bien, detalle=""):
    global n, ok
    n += 1
    if bien:
        ok += 1
        print(f"  OK   {nombre}")
    else:
        print(f"  FALLA {nombre}  {detalle}")


async def main():
    async with _eng.begin() as c:
        admite = (await c.execute(_t(
            "SELECT pg_get_constraintdef(oid) FROM pg_constraint "
            "WHERE conname = 'ck_treatments_role'"))).scalar()
        comprobar("el rol del prescriptor admite 'family'",
                  admite is not None and "family" in admite, str(admite))

        falsos = (await c.execute(_t(
            """
            SELECT count(*)
            FROM treatments t
            JOIN patient_members pm
              ON pm.patient_id = t.patient_id
             AND pm.user_id    = t.prescribed_by
             AND pm.removed_at IS NULL
            WHERE t.prescriber_role = 'doctor'
              AND pm.role IN ('family', 'caregiver')
            """))).scalar()
        comprobar("no queda ningun prescriptor 'doctor' que sea familiar/cuidadora",
                  falsos == 0, f"quedan {falsos}")


async def run():
    await main()
    await _eng.dispose()
    print()
    print(f"resultado: {ok} de {n}")
    return 0 if ok == n else 1


import sys  # noqa: E402

sys.exit(asyncio.run(run()))
