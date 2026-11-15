"""El personal de AgeCare no crea adultos mayores; el familiar sigue pudiendo.

La cuenta del personal se guarda como tipo "family" (la tabla no tiene otro
tipo para ella). Sin esta regla, la app movil la trataba como una familia mas
y le ofrecia "Agregar adulto mayor".
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
from datetime import datetime, timedelta, timezone  # noqa: E402

import httpx  # noqa: E402
from fastapi import FastAPI  # noqa: E402
from jose import jwt  # noqa: E402
from sqlalchemy import text as _t  # noqa: E402

from app.config import get_settings  # noqa: E402
from app.db import engine as _eng  # noqa: E402
from app.errors import register_error_handlers  # noqa: E402
from app.routers import auth, patients  # noqa: E402

app = FastAPI()
register_error_handlers(app)
app.include_router(auth.router)
app.include_router(patients.router)

CUIDADORA = "22222222-2222-4222-8222-222222222222"
n = ok = 0

CUERPO = {
    "first_name": "Prueba", "last_name": "Sinalta", "rut": "11.111.111-1",
    "birth_date": "1950-01-01", "sex": "female",
    "address": "Calle Falsa 123, Concepción",
    "emergency_contact": {"first_name": "Ana", "last_name": "Perez",
                          "relationship": "Hija", "phone": "+56912345678"},
}


def token(uid):
    cfg = get_settings()
    t = jwt.encode({"sub": uid, "type": "access",
                    "exp": int((datetime.now(timezone.utc) + timedelta(minutes=10)).timestamp())},
                   cfg.jwt_secret, algorithm=cfg.jwt_algorithm)
    return {"Authorization": f"Bearer {t}"}


def check(nombre, cond, detalle=""):
    global n, ok
    n += 1
    if cond:
        ok += 1
        print(f"  OK   {nombre}")
    else:
        print(f"  FALLA {nombre}  {detalle}")


async def run():
    async with _eng.begin() as c:
        admin = (await c.execute(_t(
            "SELECT id FROM users WHERE lower(email)='administrador@agecare.cl'"))).scalar()
    if admin is None:
        print("  (no hay cuenta administrador@agecare.cl: se omite)")
        return 0

    transport = httpx.ASGITransport(app=app)
    async with httpx.AsyncClient(transport=transport, base_url="http://t") as client:
        r = await client.post("/api/v1/patients", json=CUERPO, headers=token(str(admin)))
        check("el personal no crea adultos mayores: 403", r.status_code == 403, r.text[:120])
        check("con su codigo propio",
              r.json().get("error", {}).get("code") == "STAFF_CANNOT_CREATE_PATIENTS"
              or r.json().get("code") == "STAFF_CANNOT_CREATE_PATIENTS", r.text[:160])

        r = await client.post("/api/v1/patients", json=CUERPO, headers=token(CUIDADORA))
        check("la cuidadora tampoco: 403", r.status_code == 403, r.text[:120])

        r = await client.post("/api/v1/auth/login",
                              json={"email": "administrador@agecare.cl",
                                    "password": "agecare123"})
        check("el login informa is_staff=true para el personal",
              r.status_code == 200 and r.json()["user"]["is_staff"] is True, r.text[:160])

        r = await client.post("/api/v1/auth/login",
                              json={"email": "familiar@agecare.cl",
                                    "password": "agecare123"})
        check("el familiar entra con is_staff=false",
              r.status_code == 200 and r.json()["user"]["is_staff"] is False, r.text[:160])

        r = await client.get("/api/v1/users/me", headers=token(str(admin)))
        check("/users/me tambien lo informa",
              r.status_code == 200 and r.json()["is_staff"] is True, r.text[:160])

    await _eng.dispose()
    print(f"\nresultado: {ok} de {n}")
    return 0 if ok == n else 1


import sys  # noqa: E402

sys.exit(asyncio.run(run()))
