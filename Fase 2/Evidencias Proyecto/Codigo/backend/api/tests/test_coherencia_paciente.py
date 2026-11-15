"""Un archivo no puede adjuntarse a la ficha de otro paciente (migracion 971).

Comprueba, contra el esquema vivo, que la FK compuesta
(file_id, patient_id) -> files(id, patient_id) de medical_documents impide
adjuntar a un paciente un archivo que es de otro. Solo inserta una fila de
prueba (que debe ser RECHAZADA) y no deja nada.
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


async def main():
    async with _eng.begin() as c:
        existe = (await c.execute(_t(
            "SELECT 1 FROM pg_constraint WHERE conname = 'uq_files_id_patient'"))).first()
        comprobar("existe la clave unica files(id, patient_id)", existe is not None)

        # Un archivo de paciente que todavia no este adjunto a ningun documento.
        archivo = (await c.execute(_t(
            """
            SELECT f.id AS file_id, f.patient_id AS p1
            FROM files f
            WHERE f.scope = 'patient' AND f.patient_id IS NOT NULL
              AND f.id NOT IN (SELECT file_id FROM medical_documents)
            LIMIT 1
            """))).mappings().first()
        otro = None
        if archivo is not None:
            otro = (await c.execute(_t(
                """
                SELECT p.id AS p2,
                       (SELECT user_id FROM patient_members
                         WHERE patient_id = p.id AND removed_at IS NULL LIMIT 1) AS u
                FROM patients p
                WHERE p.id <> CAST(:p1 AS uuid) AND p.deleted_at IS NULL
                LIMIT 1
                """), {"p1": str(archivo["p1"])})).mappings().first()

    if archivo is None or otro is None or otro["u"] is None:
        print("  (no hay 2 pacientes con un archivo libre para probar: se omite)")
        return

    # Adjuntar a OTRO paciente un archivo que es del primero: debe fallar.
    rechazado = False
    try:
        async with _eng.begin() as c:
            await c.execute(_t(
                "INSERT INTO medical_documents (patient_id, file_id, category, title, added_by) "
                "VALUES (CAST(:p2 AS uuid), CAST(:f AS uuid), 'other', 'Prueba 971', "
                "CAST(:u AS uuid))"),
                {"p2": str(otro["p2"]), "f": str(archivo["file_id"]), "u": str(otro["u"])})
    except IntegrityError:
        rechazado = True
    finally:
        # Por si (indebidamente) hubiera entrado, no dejar basura.
        async with _eng.begin() as c:
            await c.execute(_t("DELETE FROM medical_documents WHERE title = 'Prueba 971'"))

    comprobar("no deja adjuntar a un paciente el archivo de otro", rechazado)


async def run():
    await main()
    await _eng.dispose()
    print()
    print(f"resultado: {ok} de {n}")
    return 0 if ok == n else 1


import sys  # noqa: E402

sys.exit(asyncio.run(run()))
