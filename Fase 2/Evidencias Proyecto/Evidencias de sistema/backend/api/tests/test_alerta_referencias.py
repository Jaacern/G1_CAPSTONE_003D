"""Las referencias de la alerta viven en columnas propias (migracion 970).

Antes 'dose_id' y 'reading_id' vivian solo en alerts.payload y el codigo los
cruzaba desde ahi, pese a que el comentario decia que no se consultaban. Ahora
son columnas con FK/indice y unicidad real. Esta prueba comprueba, contra el
esquema vivo, que:

  - existen las columnas dose_id y reading_id,
  - no se puede crear dos alertas del mismo tipo para la misma dosis,
  - si se puede crear dos alertas de tipos distintos para la misma dosis,
  - no se puede apuntar dose_id a una dosis que no existe (FK).

Solo toca filas de prueba que ella misma inserta y borra al final.
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
import uuid  # noqa: E402

from sqlalchemy import text as _t  # noqa: E402
from sqlalchemy.exc import IntegrityError  # noqa: E402

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


async def _columnas(conn):
    r = await conn.execute(_t(
        "SELECT column_name FROM information_schema.columns "
        "WHERE table_name='alerts' AND column_name IN ('dose_id','reading_id')"))
    return {row[0] for row in r}


async def _insertar_alerta(conn, patient_id, dose_id, tipo):
    return (await conn.execute(_t(
        "INSERT INTO alerts (patient_id, type, severity, title, status, dose_id) "
        "VALUES (CAST(:p AS uuid), :tipo, 'warning', 'Prueba 970', 'active', "
        "CAST(:d AS uuid)) RETURNING id"),
        {"p": str(patient_id), "tipo": tipo, "d": str(dose_id)})).scalar()


async def main():
    creadas = []
    # Una dosis que todavia no tiene ninguna alerta, para partir limpio.
    async with _eng.begin() as c:
        cols = await _columnas(c)
        comprobar("existen las columnas dose_id y reading_id",
                  cols == {"dose_id", "reading_id"}, str(cols))

        fila = (await c.execute(_t(
            """
            SELECT sd.id AS dose_id,
                   COALESCE(m.patient_id, tr.patient_id) AS patient_id
            FROM scheduled_doses sd
            LEFT JOIN medications m ON m.id = sd.medication_id
            LEFT JOIN treatment_items ti ON ti.id = sd.treatment_item_id
            LEFT JOIN treatments tr ON tr.id = ti.treatment_id
            WHERE COALESCE(m.patient_id, tr.patient_id) IS NOT NULL
              AND NOT EXISTS (SELECT 1 FROM alerts a WHERE a.dose_id = sd.id)
            LIMIT 1
            """))).mappings().first()

    if fila is None:
        print("  (no hay una dosis libre para probar: se omite)")
        return
    dose_id, patient_id = fila["dose_id"], fila["patient_id"]

    try:
        # Primera alerta de dosis omitida: debe entrar.
        async with _eng.begin() as c:
            creadas.append(await _insertar_alerta(c, patient_id, dose_id, "missed_dose"))
        comprobar("se crea la primera alerta de la dosis", True)

        # Segunda del MISMO tipo para la MISMA dosis: debe fallar (unico).
        duplicado_rechazado = False
        try:
            async with _eng.begin() as c:
                await _insertar_alerta(c, patient_id, dose_id, "missed_dose")
        except IntegrityError:
            duplicado_rechazado = True
        comprobar("no deja dos alertas 'missed_dose' para la misma dosis",
                  duplicado_rechazado)

        # Otro TIPO (incident) para la misma dosis: debe entrar (unico por tipo).
        otro_tipo_ok = False
        try:
            async with _eng.begin() as c:
                creadas.append(await _insertar_alerta(c, patient_id, dose_id, "incident"))
            otro_tipo_ok = True
        except IntegrityError as e:
            otro_tipo_ok = False
            print(f"       (detalle: {str(e).splitlines()[0]})")
        comprobar("si deja una alerta de otro tipo para la misma dosis", otro_tipo_ok)

        # dose_id inexistente: la FK lo rechaza.
        fk_rechaza = False
        try:
            async with _eng.begin() as c:
                await _insertar_alerta(c, patient_id, uuid.uuid4(), "missed_dose")
        except IntegrityError:
            fk_rechaza = True
        comprobar("la FK rechaza una dosis que no existe", fk_rechaza)
    finally:
        async with _eng.begin() as c:
            for a in creadas:
                await c.execute(_t("DELETE FROM alerts WHERE id = CAST(:a AS uuid)"),
                                {"a": str(a)})


async def run():
    await main()
    await _eng.dispose()
    print()
    print(f"resultado: {ok} de {n}")
    return 0 if ok == n else 1


import sys  # noqa: E402

sys.exit(asyncio.run(run()))
