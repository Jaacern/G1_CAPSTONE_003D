"""Prueba del barrido de subidas vencidas."""
import os
os.environ.setdefault("POSTGRES_HOST", "127.0.0.1")
os.environ.setdefault("POSTGRES_PORT", "5432")
os.environ.setdefault("STORAGE_LOCAL_DIR", "/tmp/agecare-files-test")
os.environ.setdefault("STORAGE_PUBLIC_BASE_URL", "http://testserver")

# El paquete app vive un nivel mas arriba, en backend/api. Sin esta linea,
# ejecutar "python tests/test_x.py" deja solo tests/ en el path de busqueda y
# el import de app falla. Va aqui arriba, junto a las variables de entorno,
# porque tiene que pasar antes de importar cualquier cosa de la aplicacion.
import pathlib as _pl
import sys as _sys
_sys.path.insert(0, str(_pl.Path(__file__).resolve().parents[1]))


import asyncio  # noqa: E402
from datetime import datetime, timezone  # noqa: E402
from sqlalchemy import text  # noqa: E402

from app.db import engine  # noqa: E402
from app.maintenance import barrer_subidas_vencidas  # noqa: E402
from app.storage import get_storage  # noqa: E402

PAC = "33333333-3333-4333-8333-333333333333"
USR = "11111111-1111-4111-8111-111111111111"

INS = text("""
INSERT INTO files (patient_id, uploaded_by, storage_key, original_name, mime_type,
                   size_bytes, status, upload_expires_at, stored_at, scope)
VALUES (:pid, :uid, :key, 'x.pdf', 'application/pdf', 100, :st, :exp, :sa, 'patient')
RETURNING id
""")


async def run():
    n = ok = 0

    def check(nombre, cond):
        nonlocal n, ok
        n += 1
        if cond:
            ok += 1; print(f"  OK   {nombre}")
        else:
            print(f"  FALLA {nombre}")

    storage = get_storage()
    async with engine.begin() as c:
        await c.execute(text("DELETE FROM files WHERE storage_key LIKE 'barrido/%'"))
        vieja = (await c.execute(INS, {"pid": PAC, "uid": USR, "key": "barrido/vieja.pdf",
                 "st": "pending", "exp": datetime(2026,1,1,tzinfo=timezone.utc), "sa": None})).scalar()
        reciente = (await c.execute(INS, {"pid": PAC, "uid": USR, "key": "barrido/reciente.pdf",
                 "st": "pending", "exp": datetime(2099,1,1,tzinfo=timezone.utc), "sa": None})).scalar()
        # vencida hace 5 minutos: dentro de la gracia de 30
        gracia = (await c.execute(text("""
            INSERT INTO files (patient_id, uploaded_by, storage_key, original_name, mime_type,
                               size_bytes, status, upload_expires_at, scope)
            VALUES (:pid,:uid,'barrido/gracia.pdf','x.pdf','application/pdf',100,'pending',
                    now() - interval '5 minutes','patient') RETURNING id"""),
            {"pid": PAC, "uid": USR})).scalar()
        guardada = (await c.execute(INS, {"pid": PAC, "uid": USR, "key": "barrido/guardada.pdf",
                 "st": "stored", "exp": datetime(2026,1,1,tzinfo=timezone.utc), "sa": datetime(2026,1,1,tzinfo=timezone.utc)})).scalar()

    # binario huerfano para la fila vieja
    await storage.save(storage_key="barrido/vieja.pdf", data=b"basura")
    check("hay un binario huerfano antes del barrido",
          storage.exists(storage_key="barrido/vieja.pdf"))

    print("--- barrido ---")
    r = await barrer_subidas_vencidas()

    async def estado(i):
        async with engine.begin() as c:
            return (await c.execute(text("SELECT status FROM files WHERE id=:i"),
                                    {"i": str(i)})).scalar()

    check("la subida vencida hace meses queda expired", await estado(vieja) == "expired")
    check("la subida con enlace vivo sigue pending", await estado(reciente) == "pending")
    check("la vencida hace 5 min sigue pending (margen de gracia)",
          await estado(gracia) == "pending")
    check("el archivo ya guardado no se toca", await estado(guardada) == "stored")
    check("el binario huerfano se borro del disco",
          not storage.exists(storage_key="barrido/vieja.pdf"))
    # Hay mas pending vencidas de las pruebas del router, asi que se exige
    # que haya marcado al menos la propia y que el huerfano sea el unico.
    check(f"informa lo que hizo (marcadas={r['marcadas']}, huerfanos={r['huerfanos']})",
          r["marcadas"] >= 1 and r["huerfanos"] == 1)

    print("--- segunda corrida, no debe hacer nada ---")
    r2 = await barrer_subidas_vencidas()
    check("es idempotente", r2["marcadas"] == 0 and r2["huerfanos"] == 0)

    async with engine.begin() as c:
        await c.execute(text("DELETE FROM files WHERE storage_key LIKE 'barrido/%'"))
    await engine.dispose()
    print()
    print(f"resultado: {ok} de {n}")
    # Codigo de salida para que el CI lo vea.
    return 0 if ok == n else 1


import sys  # noqa: E402

sys.exit(asyncio.run(run()))
