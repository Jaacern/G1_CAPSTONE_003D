"""Pruebas del registro de una dosis que todavia no resolvio una persona.

Cubre el caso que dejaba la dosis trabada: el endpoint rechazaba con 409
todo lo que no estuviera 'pending', asi que una dosis pospuesta no se
podia marcar nunca mas. Ahora que el front manda 'postponed' con su
'postponed_until', ese caso llega de verdad desde la aplicacion.
"""
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
from datetime import datetime, timedelta, timezone  # noqa: E402

import httpx  # noqa: E402
from fastapi import FastAPI  # noqa: E402
from jose import jwt  # noqa: E402
from sqlalchemy import text as _t  # noqa: E402

from app.config import get_settings  # noqa: E402
from app.db import engine as _eng  # noqa: E402
from app.errors import register_error_handlers  # noqa: E402
from app.routers import medications  # noqa: E402

app = FastAPI()
register_error_handlers(app)
app.include_router(medications.router)

MED = "77777777-7777-4777-8777-777777777777"
CUIDADORA = "22222222-2222-4222-8222-222222222222"
MARCA = "FIXTURE-POSPUESTA"
n = ok = 0


def token(uid):
    cfg = get_settings()
    t = jwt.encode({"sub": uid, "type": "access",
                    "exp": int((datetime.now(timezone.utc)
                                + timedelta(minutes=10)).timestamp())},
                   cfg.jwt_secret, algorithm=cfg.jwt_algorithm)
    return {"Authorization": f"Bearer {t}"}


def check(nombre, esperado, resp):
    global n, ok
    n += 1
    if resp.status_code == esperado:
        ok += 1
        print(f"  OK   {esperado}  {nombre}")
    else:
        print(f"  FALLA esperaba {esperado} y dio {resp.status_code}  {nombre}")
        print(f"       {resp.text[:200]}")


def comprueba(nombre, condicion, detalle=""):
    """Para lo que no es un codigo de respuesta sino el estado de la fila."""
    global n, ok
    n += 1
    if condicion:
        ok += 1
        print(f"  OK        {nombre}")
    else:
        print(f"  FALLA     {nombre}  {detalle}")


async def limpiar():
    async with _eng.begin() as c:
        await c.execute(_t("DELETE FROM scheduled_doses WHERE reason = :r"),
                        {"r": MARCA})


async def crear(**campos):
    """Crea una dosis de prueba y devuelve su id."""
    campos.setdefault("status", "pending")
    cols = ", ".join(campos) + ", medication_id, scheduled_at, reason"
    vals = ", ".join(f":{k}" for k in campos) + \
           ", :med, now() - interval '3 hours', :marca"
    async with _eng.begin() as c:
        return str((await c.execute(
            _t(f"INSERT INTO scheduled_doses ({cols}) VALUES ({vals}) "
               "RETURNING id"),
            {**campos, "med": MED, "marca": MARCA})).scalar())


async def estado(did):
    async with _eng.begin() as c:
        return (await c.execute(_t(
            "SELECT status, logged_by, administered_at FROM scheduled_doses "
            "WHERE id = :i"), {"i": did})).mappings().first()


async def main():
    await limpiar()
    h = token(CUIDADORA)
    transporte = httpx.ASGITransport(app=app)
    async with httpx.AsyncClient(transport=transporte,
                                 base_url="http://testserver") as cli:

        async def registrar(did, cuerpo):
            return await cli.post(f"/api/v1/doses/{did}/log", json=cuerpo,
                                  headers=h)

        # El caso que estaba roto. Una dosis pospuesta se puede registrar.
        pospuesta = await crear(
            status="postponed",
            postponed_until=datetime.now(timezone.utc) - timedelta(hours=1))
        r = await registrar(pospuesta, {"status": "taken"})
        check("una dosis pospuesta se puede marcar como administrada", 200, r)
        e = await estado(pospuesta)
        comprueba("y la fila queda administrada de verdad",
                  e["status"] == "taken" and e["administered_at"] is not None,
                  dict(e))

        # La que marco el proceso de mantenimiento, sin responsable.
        delproceso = await crear(status="missed")
        r = await registrar(delproceso, {"status": "taken"})
        check("una dosis vencida por el proceso se puede registrar tarde",
              200, r)
        e = await estado(delproceso)
        comprueba("y queda con la cuidadora como responsable",
                  e["status"] == "taken" and str(e["logged_by"]) == CUIDADORA,
                  dict(e))

        # Lo que una persona ya declaro no se pisa.
        tomada = await crear(
            status="taken", logged_by=CUIDADORA,
            logged_at=datetime.now(timezone.utc),
            administered_at=datetime.now(timezone.utc) - timedelta(hours=2))
        r = await registrar(tomada, {"status": "missed", "note": "no se dio"})
        check("no se puede pisar una dosis ya administrada", 409, r)

        omitida = await crear(status="skipped", logged_by=CUIDADORA,
                              logged_at=datetime.now(timezone.utc))
        r = await registrar(omitida, {"status": "taken"})
        check("no se puede pisar una omision de la cuidadora", 409, r)

        amano = await crear(status="missed", logged_by=CUIDADORA,
                            logged_at=datetime.now(timezone.utc))
        r = await registrar(amano, {"status": "taken"})
        check("no se puede pisar un 'no se dio' con responsable", 409, r)

        # Y el camino normal sigue andando.
        pendiente = await crear()
        r = await registrar(pendiente, {"status": "taken"})
        check("una dosis pendiente se registra como siempre", 200, r)

        # Posponer sigue exigiendo su hora y su limite de cuatro horas.
        otra = await crear()
        r = await registrar(otra, {"status": "postponed"})
        check("posponer sin hora se rechaza", 422, r)
        r = await registrar(otra, {
            "status": "postponed",
            "postponed_until": (datetime.now(timezone.utc)
                                + timedelta(hours=9)).isoformat()})
        check("posponer mas de cuatro horas se rechaza", 400, r)

    await limpiar()
    await _eng.dispose()
    print(f"\nresultado: {ok} de {n}")
    return 1 if ok != n else 0


import sys  # noqa: E402
sys.exit(asyncio.run(main()))
