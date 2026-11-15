"""Purga del texto OCR al purgar un archivo (RF-43, migracion 974).

Al purgar el binario de un archivo (files.purged_at) su texto extraido en
file_ocr -datos sensibles en claro- tiene que irse con el. Esta prueba:
  1. confirma que el trigger existe,
  2. confirma que hoy no hay archivo purgado que conserve texto OCR,
  3. crea un archivo con texto OCR, lo purga y comprueba que el texto se borro.
Todo el caso 3 va en una transaccion que se deshace: no deja nada escrito.
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
import uuid as _uuid  # noqa: E402

from sqlalchemy import text as _t  # noqa: E402

from app.db import engine as _eng  # noqa: E402

PACIENTE = "33333333-3333-4333-8333-333333333333"
CUIDADORA = "22222222-2222-4222-8222-222222222222"
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
    """Se lanza aposta para deshacer el caso de prueba."""


async def main():
    print("--- purga del texto OCR al purgar un archivo (974) ---")

    # 1. El trigger existe sobre files.
    existe = await escalar(
        "SELECT count(*) FROM pg_trigger "
        "WHERE tgname = 'tg_files_purga_ocr' AND NOT tgisinternal")
    check("el trigger tg_files_purga_ocr existe", existe == 1, f"hay {existe}")

    # 2. Ningun archivo purgado conserva texto OCR.
    colgados = await escalar(
        "SELECT count(*) FROM file_ocr fo JOIN files f ON f.id = fo.file_id "
        "WHERE f.purged_at IS NOT NULL")
    check("ningun archivo purgado conserva texto OCR", colgados == 0,
          f"hay {colgados}")

    # 3. Crear archivo + texto OCR, purgar, y ver que el texto se fue.
    fid = str(_uuid.uuid4())
    skey = f"test/ocr/{fid}.pdf"
    borrado_al_purgar = None
    presente_antes = None
    try:
        async with _eng.begin() as c:
            await c.execute(_t(
                "INSERT INTO files (id, patient_id, uploaded_by, storage_key, "
                "  original_name, mime_type, size_bytes, status, "
                "  upload_expires_at, stored_at) "
                "VALUES (:id, :pac, :sub, :sk, 'receta.pdf', 'application/pdf', "
                "  1000, 'stored', now() + interval '10 minutes', now())"),
                {"id": fid, "pac": PACIENTE, "sub": CUIDADORA, "sk": skey})
            await c.execute(_t(
                "INSERT INTO file_ocr (file_id, texto, motor, caracteres) "
                "VALUES (:id, 'Paracetamol 500 mg cada 8 horas', 'prueba', 31)"),
                {"id": fid})

            presente_antes = (await c.execute(_t(
                "SELECT count(*) FROM file_ocr WHERE file_id = :id"),
                {"id": fid})).scalar()

            # Purgar: el trigger debe borrar el texto OCR.
            await c.execute(_t(
                "UPDATE files SET status = 'purged', purged_at = now() "
                "WHERE id = :id"), {"id": fid})

            borrado_al_purgar = (await c.execute(_t(
                "SELECT count(*) FROM file_ocr WHERE file_id = :id"),
                {"id": fid})).scalar()

            raise _Deshacer()  # deshace todo lo de arriba
    except _Deshacer:
        pass
    except Exception as e:  # noqa: BLE001
        check("el caso de purga corrio sin error de base", False, str(e)[:200])

    check("el texto OCR existia antes de purgar", presente_antes == 1,
          f"habia {presente_antes}")
    check("al purgar el archivo el texto OCR se borra", borrado_al_purgar == 0,
          f"quedaron {borrado_al_purgar}")

    print(f"\n{ok}/{n} comprobaciones ok")
    return 0 if ok == n else 1


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
