"""Origen unico de cada dosis (hallazgo 3, migracion 973).

Una dosis nace de UNA indicacion: o un medicamento (modelo viejo) o un item de
tratamiento (modelo vigente), nunca los dos. Esta prueba comprueba que:
  1. no quedo ninguna dosis con doble origen en los datos,
  2. ningun medicamento quedo "activo" en un paciente que ya tiene tratamiento
     vigente (el generador no los usa; 973 los discontinuo),
  3. ck_scheduled_doses_origen RECHAZA una dosis con dos origenes,
  4. tambien rechaza una dosis sin ningun origen,
  5. y ADMITE una dosis con un unico origen.
Para los casos 3 y 5 se usan un medicamento y un item REALES, de modo que las
claves foraneas pasen y el unico que pueda rechazar sea el CHECK. Cada INSERT
de prueba se deshace siempre: no deja basura en la base.
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


def check(nombre, condicion, extra=None):
    global n, ok
    n += 1
    if condicion:
        ok += 1
        print(f"  OK   {nombre}")
    else:
        print(f"  FALLA {nombre}" + (f"  {extra}" if extra is not None else ""))


async def escalar(q, **p):
    async with _eng.begin() as c:
        return (await c.execute(_t(q), p)).scalar()


class _Deshacer(Exception):
    """Se lanza aposta para deshacer un INSERT que SI entro."""


async def intentar(cols, vals, params):
    """Corre un INSERT y SIEMPRE lo deshace.

    Devuelve None si la base lo acepto (y se revirtio), o el texto del error
    si la base lo rechazo. Nunca deja una fila escrita.
    """
    try:
        async with _eng.begin() as c:
            await c.execute(
                _t(f"INSERT INTO scheduled_doses ({cols}) VALUES ({vals})"),
                params,
            )
            raise _Deshacer()
    except _Deshacer:
        return None
    except Exception as e:  # noqa: BLE001
        return str(e)


async def main():
    print("--- origen unico de cada dosis (973) ---")

    # 1. Datos ya consolidados: cero dosis con doble origen.
    dobles = await escalar(
        "SELECT count(*) FROM scheduled_doses "
        "WHERE medication_id IS NOT NULL AND treatment_item_id IS NOT NULL")
    check("no quedan dosis con doble origen", dobles == 0, f"hay {dobles}")

    # 2. Ningun medicamento activo en paciente con tratamiento vigente.
    activos = await escalar(
        "SELECT count(*) FROM medications m WHERE m.discontinued_at IS NULL "
        "AND EXISTS (SELECT 1 FROM treatments tr "
        "            WHERE tr.patient_id = m.patient_id AND tr.status='vigente')")
    check("ningun medicamento migrado quedo activo", activos == 0,
          f"hay {activos}")

    med = await escalar("SELECT id FROM medications LIMIT 1")
    item = await escalar("SELECT id FROM treatment_items LIMIT 1")

    # 4. Sin ningun origen -> rechazado por el CHECK (no hay FK en juego).
    err = await intentar("scheduled_at, status", "now(), 'pending'", {})
    check("rechaza una dosis sin ningun origen", err is not None)
    check("y la rechaza por ck_scheduled_doses_origen",
          err is not None and "ck_scheduled_doses_origen" in err,
          (err or "")[:160])

    # 3 y 5. Necesitan un medicamento y un item reales.
    if med is not None and item is not None:
        # 3. Doble origen con FK validas -> solo el CHECK puede rechazarlo.
        err = await intentar(
            "medication_id, treatment_item_id, scheduled_at, status",
            ":m, :i, now(), 'pending'", {"m": str(med), "i": str(item)})
        check("rechaza una dosis con dos origenes", err is not None)
        check("y la rechaza por ck_scheduled_doses_origen (no por una FK)",
              err is not None and "ck_scheduled_doses_origen" in err,
              (err or "")[:160])

        # 5. Un unico origen (item real, hora lejana para no chocar el slot).
        err = await intentar(
            "treatment_item_id, scheduled_at, status",
            ":i, now() + interval '400 days', 'pending'", {"i": str(item)})
        check("admite una dosis con un unico origen", err is None, err)
    else:
        print("  (no hay medicamento o item de ejemplo: se omiten 3 y 5)")

    print(f"\n{ok}/{n} comprobaciones ok")
    return 0 if ok == n else 1


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
