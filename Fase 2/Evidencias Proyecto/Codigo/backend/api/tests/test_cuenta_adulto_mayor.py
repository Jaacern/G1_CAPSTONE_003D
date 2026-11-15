"""Crear el perfil de un adulto mayor junto con su cuenta.

Al crear el perfil, la familia puede dar un correo y una contrasena para el
adulto mayor. La prueba comprueba que se crea la cuenta, que queda en el
circulo con el rol 'elder', que con ella se puede iniciar sesion, y que un
correo repetido o una contrasena debil no dejan un perfil a medias.

Cada corrida usa un RUT y un correo nuevos, y al final da de baja lo que
creo (la baja es logica, como en la aplicacion).
"""
import os
os.environ.setdefault("POSTGRES_HOST", "127.0.0.1")
os.environ.setdefault("POSTGRES_PORT", "5432")
os.environ.setdefault("STORAGE_LOCAL_DIR", "/tmp/agecare-files-test")
os.environ.setdefault("STORAGE_PUBLIC_BASE_URL", "http://testserver")

# El paquete app vive un nivel mas arriba, en backend/api.
import pathlib as _pl
import sys as _sys
_sys.path.insert(0, str(_pl.Path(__file__).resolve().parents[1]))


import asyncio  # noqa: E402
import random  # noqa: E402
import uuid  # noqa: E402
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

PACIENTE = "33333333-3333-4333-8333-333333333333"
n = ok = 0


def token(uid):
    cfg = get_settings()
    t = jwt.encode({"sub": uid, "type": "access",
                    "exp": int((datetime.now(timezone.utc) + timedelta(minutes=10)).timestamp())},
                   cfg.jwt_secret, algorithm=cfg.jwt_algorithm)
    return {"Authorization": f"Bearer {t}"}


def comprobar(nombre, bien, detalle=""):
    global n, ok
    n += 1
    if bien:
        ok += 1
        print(f"  OK   {nombre}")
    else:
        print(f"  FALLA {nombre}  {detalle}")


def rut_nuevo():
    """Un RUT valido al azar (modulo 11)."""
    numero = random.randint(30_000_000, 39_999_999)
    suma, factor = 0, 2
    for d in reversed(str(numero)):
        suma += int(d) * factor
        factor = 2 if factor == 7 else factor + 1
    resto = 11 - suma % 11
    dv = "0" if resto == 11 else "K" if resto == 10 else str(resto)
    return f"{numero}-{dv}"


def perfil(**extra):
    return {
        "first_name": "Prueba",
        "last_name": "Cuenta",
        "rut": rut_nuevo(),
        "birth_date": "1945-05-20",
        "sex": "female",
        "address": "Calle de prueba 123, Concepción",
        "emergency_contact": {"first_name": "Ana", "last_name": "Cuenta",
                              "relationship": "hija", "phone": "+56912345678"},
        **extra,
    }


async def familiar():
    async with _eng.begin() as c:
        r = await c.execute(_t(
            "SELECT pm.user_id FROM patient_members pm JOIN users u ON u.id = pm.user_id "
            "WHERE pm.patient_id = :p AND pm.role = 'family' AND pm.removed_at IS NULL "
            "AND u.account_type = 'family' AND NOT u.is_staff LIMIT 1"), {"p": PACIENTE})
        return str(r.scalar())


async def main(client, fam):
    print("--- perfil del adulto mayor con su cuenta ---")
    correo = f"am-{uuid.uuid4().hex[:10]}@prueba.agecare.cl"
    clave = "Abuela2026"
    creados = []

    try:
        r = await client.post("/api/v1/patients", headers=token(fam),
                              json=perfil(elder_account={"email": correo, "password": clave}))
        comprobar("crea el perfil con la cuenta", r.status_code == 201, r.text[:200])
        if r.status_code != 201:
            return
        d = r.json()
        creados.append(d["patient_id"])
        comprobar("devuelve la cuenta del adulto mayor", d.get("elder_user_id") is not None)

        async with _eng.begin() as c:
            fila = (await c.execute(_t(
                "SELECT u.account_type, pm.role, pm.is_owner FROM users u "
                "JOIN patient_members pm ON pm.user_id = u.id "
                "WHERE u.id = CAST(:u AS uuid) AND pm.patient_id = CAST(:p AS uuid)"),
                {"u": d["elder_user_id"], "p": d["patient_id"]})).mappings().first()
        comprobar("la cuenta es de adulto mayor y esta en su circulo",
                  fila is not None and fila["account_type"] == "elder"
                  and fila["role"] == "elder" and not fila["is_owner"], str(fila))

        r = await client.post("/api/v1/auth/login", json={"email": correo, "password": clave})
        comprobar("el adulto mayor puede iniciar sesion", r.status_code == 200, r.text[:200])

        # El mismo correo para otro perfil: 409 y sin dejar el perfil creado.
        datos = perfil(elder_account={"email": correo.upper(), "password": clave})
        r = await client.post("/api/v1/patients", headers=token(fam), json=datos)
        comprobar("un correo que ya existe se rechaza", r.status_code == 409, r.text[:200])
        async with _eng.begin() as c:
            numero = int(datos["rut"].split("-")[0])
            quedo = (await c.execute(_t(
                "SELECT 1 FROM patients WHERE rut_number = :n AND deleted_at IS NULL"),
                {"n": numero})).first()
        comprobar("y no queda un perfil a medias", quedo is None)

        r = await client.post("/api/v1/patients", headers=token(fam),
                              json=perfil(elder_account={
                                  "email": f"otro-{correo}", "password": "corta"}))
        comprobar("una contrasena debil se rechaza", r.status_code == 400, r.text[:200])

        r = await client.post("/api/v1/patients", headers=token(fam),
                              json=perfil(elder_account={"email": "no-es-correo",
                                                         "password": clave}))
        comprobar("un correo mal escrito se rechaza", r.status_code == 422, r.text[:200])

        # Sin cuenta sigue funcionando como antes.
        r = await client.post("/api/v1/patients", headers=token(fam), json=perfil())
        comprobar("sin cuenta se crea solo el perfil", r.status_code == 201
                  and r.json().get("elder_user_id") is None, r.text[:200])
        if r.status_code == 201:
            creados.append(r.json()["patient_id"])
    finally:
        async with _eng.begin() as c:
            for pid in creados:
                await c.execute(_t(
                    "UPDATE users SET deleted_at = now(), is_active = false WHERE id IN ("
                    "SELECT user_id FROM patient_members WHERE patient_id = CAST(:p AS uuid) "
                    "AND role = 'elder')"), {"p": pid})
                await c.execute(_t(
                    "UPDATE patient_members SET removed_at = now() "
                    "WHERE patient_id = CAST(:p AS uuid) AND removed_at IS NULL"), {"p": pid})
                await c.execute(_t(
                    "UPDATE patients SET deleted_at = now() WHERE id = CAST(:p AS uuid)"),
                    {"p": pid})


async def run():
    fam = await familiar()
    transport = httpx.ASGITransport(app=app)
    async with httpx.AsyncClient(transport=transport, base_url="http://testserver") as cl:
        await main(cl, fam)
    await _eng.dispose()
    print()
    print(f"resultado: {ok} de {n}")
    return 0 if ok == n else 1


import sys  # noqa: E402

sys.exit(asyncio.run(run()))
