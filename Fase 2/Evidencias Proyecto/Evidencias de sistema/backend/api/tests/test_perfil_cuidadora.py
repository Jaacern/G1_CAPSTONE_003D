"""Perfil profesional de la cuidadora: registro por rol, identidad, publicación
en el marketplace e informes por rango."""
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
from datetime import datetime, timedelta, timezone  # noqa: E402

import httpx  # noqa: E402
from fastapi import FastAPI  # noqa: E402
from jose import jwt  # noqa: E402
from sqlalchemy import text as _t  # noqa: E402

from app.config import get_settings  # noqa: E402
from app.db import engine as _eng  # noqa: E402
from app.errors import register_error_handlers  # noqa: E402
from app.routers import auth, caregiver, caregiver_profile, marketplace  # noqa: E402

app = FastAPI()
register_error_handlers(app)
app.include_router(auth.router)
app.include_router(caregiver.router)
app.include_router(caregiver_profile.router)
app.include_router(marketplace.router)

FAMILIAR = "11111111-1111-4111-8111-111111111111"
CUIDADORA = "22222222-2222-4222-8222-222222222222"
MARCA = "prueba-perfil-cuidadora"
n = ok = 0


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
        print(f"  ok   {nombre}")
    else:
        print(f"  FALLA {nombre} {detalle}")


def codigo(r):
    try:
        return r.json()["error"]["code"]
    except Exception:  # noqa: BLE001
        return None


def campos(r):
    try:
        return {d["field"] for d in r.json()["error"]["details"]}
    except Exception:  # noqa: BLE001
        return set()


async def limpiar():
    async with _eng.begin() as c:
        uids = [str(x) for x in (await c.execute(_t(
            "SELECT id FROM users WHERE email LIKE :m"), {"m": f"%@{MARCA}.cl"})).scalars()]
        for u in uids:
            pid = (await c.execute(_t(
                "SELECT id FROM caregiver_profiles WHERE user_id=:u"), {"u": u})).scalar()
            if pid:
                for t in ("caregiver_specialties", "caregiver_languages", "caregiver_zones"):
                    await c.execute(_t(f"DELETE FROM {t} WHERE profile_id=:p"), {"p": str(pid)})
                await c.execute(_t("DELETE FROM caregiver_profiles WHERE id=:p"), {"p": str(pid)})
            await c.execute(_t("DELETE FROM refresh_tokens WHERE user_id=:u"), {"u": u})
            await c.execute(_t("DELETE FROM users WHERE id=:u"), {"u": u})


def correo(nombre):
    return f"{nombre}-{uuid.uuid4().hex[:6]}@{MARCA}.cl"


BASE = {"first_name": "Marta", "last_name": "Pérez", "password": "Clave1234"}


async def main(cl: httpx.AsyncClient):
    print("--- registro por tipo de cuenta ---")
    r = await cl.post("/api/v1/auth/register", json={
        **BASE, "email": correo("sinrut"), "account_type": "caregiver"})
    check("cuidadora sin RUT ni telefono -> 422", r.status_code == 422, r.text[:120])
    check("  y marca los dos campos", campos(r) == {"rut", "phone"}, campos(r))

    r = await cl.post("/api/v1/auth/register", json={
        **BASE, "email": correo("dvmalo"), "account_type": "caregiver",
        "rut": "12.345.678-9", "phone": "912345678"})
    check("RUT con digito malo -> 422", r.status_code == 422, r.text[:120])

    email_c = correo("cuidadora")
    r = await cl.post("/api/v1/auth/register", json={
        **BASE, "second_name": "Inés", "second_last_name": "Soto",
        "email": email_c, "account_type": "caregiver",
        "rut": "11.111.111-1", "phone": "+56 9 1234 5678"})
    check("cuidadora completa -> 201", r.status_code == 201, r.text[:160])
    uid_c = r.json().get("user_id") if r.status_code == 201 else None

    r = await cl.post("/api/v1/auth/register", json={
        **BASE, "email": correo("duplicada"), "account_type": "caregiver",
        "rut": "11111111-1", "phone": "912345679"})
    check("RUT de otra cuenta -> 409", r.status_code == 409 and codigo(r) == "RUT_ALREADY_EXISTS",
          r.text[:120])

    r = await cl.post("/api/v1/auth/register", json={
        **BASE, "email": correo("familiar"), "account_type": "family"})
    check("familiar sin RUT -> 201", r.status_code == 201, r.text[:120])

    if not uid_c:
        return
    r = await cl.get("/api/v1/users/me", headers=token(uid_c))
    me = r.json()
    check("el nombre se guarda en cuatro partes",
          me["second_name"] == "Inés" and me["second_last_name"] == "Soto"
          and me["full_name"] == "Marta Inés Pérez Soto", me)
    check("el RUT vuelve con puntos y guion", me["rut"] == "11.111.111-1", me.get("rut"))

    print("--- perfil y publicacion ---")
    r = await cl.get("/api/v1/caregiver/profile", headers=token(FAMILIAR))
    check("un familiar no tiene perfil profesional -> 403", r.status_code == 403, r.status_code)

    r = await cl.get("/api/v1/caregiver/profile/options", headers=token(uid_c))
    opciones = r.json()
    check("las opciones traen el catalogo de especialidades",
          r.status_code == 200 and len(opciones["specialties"]) > 0, r.text[:120])
    especialidad = opciones["specialties"][0]["label"]

    r = await cl.get("/api/v1/caregiver/profile", headers=token(uid_c))
    d = r.json()
    check("perfil nuevo en borrador con su identidad",
          d["status"] == "draft" and d["rut"] == "11.111.111-1" and d["first_name"] == "Marta", d)
    check("dice lo que falta para publicar", len(d["missing_for_publish"]) >= 4,
          d["missing_for_publish"])

    r = await cl.put("/api/v1/caregiver/profile", headers=token(uid_c),
                     json={"headline": "Cuidadora de día", "published": True})
    check("publicar incompleto -> 422 PROFILE_INCOMPLETE",
          r.status_code == 422 and codigo(r) == "PROFILE_INCOMPLETE", r.text[:160])
    r = await cl.get("/api/v1/caregiver/profile", headers=token(uid_c))
    check("  y no guarda nada a medias", r.json()["headline"] == "", r.json()["headline"])

    completo = {
        "first_name": "Marta", "second_name": "Inés", "last_name": "Pérez",
        "second_last_name": "Soto", "rut": "11.111.111-1", "phone": "912345678",
        "headline": "Cuidadora de día con experiencia en demencias",
        "bio": "Acompaño a adultos mayores hace seis años, en domicilio y residencia.",
        "years_experience": 6, "hourly_rate": 6500, "availability": "full_time",
        "accepts_overnight": True, "specialties": [especialidad],
        "languages": ["es"], "zones": ["13101"], "published": True,
    }
    r = await cl.put("/api/v1/caregiver/profile", headers=token(uid_c), json=completo)
    d = r.json() if r.status_code == 200 else {}
    check("publicar completo -> 200 publicado",
          r.status_code == 200 and d.get("status") == "published", r.text[:200])
    check("guarda tarifa, disponibilidad y noches",
          d.get("hourly_rate") == 6500 and d.get("availability") == "full_time"
          and d.get("accepts_overnight") is True, d)
    check("sin pendientes", d.get("missing_for_publish") == [], d.get("missing_for_publish"))

    r = await cl.get("/api/v1/marketplace/caregivers", headers=token(FAMILIAR), params={"zone": "13101"})
    nombres = [x.get("name", "") for x in r.json().get("items", [])]
    check("la familia la encuentra en el marketplace",
          any("Marta" in x for x in nombres), nombres)

    r = await cl.put("/api/v1/caregiver/profile", headers=token(uid_c),
                     json={**completo, "published": False})
    check("retirarla la deja en borrador", r.json().get("status") == "draft", r.text[:120])
    r = await cl.get("/api/v1/marketplace/caregivers", headers=token(FAMILIAR), params={"zone": "13101"})
    nombres = [x.get("name", "") for x in r.json().get("items", [])]
    check("  y deja de salir en la busqueda", not any("Marta Inés" in x for x in nombres), nombres)

    r = await cl.put("/api/v1/caregiver/profile", headers=token(uid_c),
                     json={**completo, "rut": "15234567-0", "published": None})
    check("RUT mal escrito en el perfil -> 422", r.status_code == 422, r.text[:120])

    print("--- informes por rango ---")
    r = await cl.get("/api/v1/caregiver/reports", headers=token(uid_c), params={"days": 5})
    check("un rango que no existe -> 422", r.status_code == 422, r.status_code)
    r = await cl.get("/api/v1/caregiver/reports", headers=token(uid_c), params={"days": 30})
    check("30 dias en plan gratuito -> 402 PREMIUM_REQUIRED",
          r.status_code == 402 and codigo(r) == "PREMIUM_REQUIRED", r.text[:120])
    r = await cl.get("/api/v1/caregiver/reports", headers=token(uid_c))
    check("7 dias en plan gratuito -> 200 con 7 puntos",
          r.status_code == 200 and len(r.json()["weekly_tasks"]) == 7, r.text[:120])

    plan = (await cl.get("/api/v1/caregiver/plan", headers=token(CUIDADORA))).json()
    if plan.get("tier") != "free":
        r30 = await cl.get("/api/v1/caregiver/reports", headers=token(CUIDADORA),
                           params={"days": 30})
        r90 = await cl.get("/api/v1/caregiver/reports", headers=token(CUIDADORA),
                           params={"days": 90})
        check("premium: 30 dias trae 30 puntos",
              r30.status_code == 200 and len(r30.json()["weekly_tasks"]) == 30, r30.text[:120])
        check("premium: 90 dias se agrupa en 13 semanas",
              r90.status_code == 200 and len(r90.json()["weekly_tasks"]) == 13, r90.text[:120])
    else:
        print("  (la cuidadora de la semilla no es premium: se omite el rango largo)")


async def run():
    await limpiar()
    transport = httpx.ASGITransport(app=app)
    try:
        async with httpx.AsyncClient(transport=transport, base_url="http://testserver") as cl:
            await main(cl)
    finally:
        await limpiar()
        await _eng.dispose()
    print(f"\n{ok} ok, {n - ok} fallas")
    return 0 if ok == n else 1


sys_exit = _sys.exit
sys_exit(asyncio.run(run()))
