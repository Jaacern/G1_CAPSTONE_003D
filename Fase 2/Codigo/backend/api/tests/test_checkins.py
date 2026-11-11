"""Check-in diario del adulto mayor (RF-38) y su efecto en el semaforo (RF-22)."""
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
from app.routers import checkins, patients, vitals  # noqa: E402

app = FastAPI()
register_error_handlers(app)
app.include_router(checkins.router)
app.include_router(patients.router)
app.include_router(vitals.router)

PACIENTE = "33333333-3333-4333-8333-333333333333"
from _ajeno import AJENO  # noqa: E402  (cuenta sin circulo, creada y borrada por la prueba)
n = ok = 0


def token(uid):
    cfg = get_settings()
    t = jwt.encode({"sub": uid, "type": "access",
                    "exp": int((datetime.now(timezone.utc) + timedelta(minutes=10)).timestamp())},
                   cfg.jwt_secret, algorithm=cfg.jwt_algorithm)
    return {"Authorization": f"Bearer {t}"}


def check(nombre, esperado, resp, cond=True):
    global n, ok
    n += 1
    bien = resp.status_code == esperado and cond
    if bien:
        ok += 1
        print(f"  OK   {esperado}  {nombre}")
    else:
        print(f"  FALLA esperaba {esperado} y dio {resp.status_code}  {nombre}")
        print(f"       {resp.text[:160]}")


async def roles():
    async with _eng.begin() as c:
        return {m["role"]: str(m["user_id"]) for m in (await c.execute(_t(
            "SELECT user_id, role FROM patient_members WHERE patient_id=:p "
            "AND removed_at IS NULL"), {"p": PACIENTE})).mappings().all()}


async def run():
    global n, ok
    rr = await roles()
    elder, familiar, cuidadora = rr.get("elder"), rr.get("family"), rr.get("caregiver")

    # Guardar lo que haya hoy para dejarlo igual al final.
    async with _eng.begin() as c:
        antes = (await c.execute(_t(
            "SELECT mood, pain_level, slept_well, ate_well, note, source "
            "FROM daily_checkins WHERE patient_id=:p AND checkin_date=current_date"),
            {"p": PACIENTE})).mappings().first()
        await c.execute(_t("DELETE FROM daily_checkins "
                           "WHERE patient_id=:p AND checkin_date=current_date"),
                        {"p": PACIENTE})

    transport = httpx.ASGITransport(app=app)
    async with httpx.AsyncClient(transport=transport, base_url="http://t") as client:
        base = f"/api/v1/patients/{PACIENTE}/checkins"

        r = await client.get(f"{base}/today", headers=token(familiar))
        check("sin responder, hoy es null", 200, r, r.json().get("checkin") is None)

        if elder:
            r = await client.put(f"{base}/today", json={"mood": "good"}, headers=token(elder))
            check("el adulto mayor responde", 200, r,
                  r.json().get("mood") == "good" and r.json().get("source") == "elder")

            r = await client.put(f"{base}/today", json={"mood": "bad", "note": "  me duele  la cadera "},
                                 headers=token(elder))
            check("responder otra vez corrige el de hoy", 200, r,
                  r.json().get("mood") == "bad" and r.json().get("note") == "me duele la cadera")

            async with _eng.begin() as c:
                cuantos = (await c.execute(_t(
                    "SELECT count(*) FROM daily_checkins "
                    "WHERE patient_id=:p AND checkin_date=current_date"), {"p": PACIENTE})).scalar()
            n_ok = cuantos == 1
            n += 1
            ok += n_ok
            print(f"  {'OK  ' if n_ok else 'FALLA'} uno por dia (hay {cuantos})")

            r = await client.get(f"/api/v1/patients/{PACIENTE}/summary/today",
                                 headers=token(familiar))
            check("'mal' pone el motivo en el semaforo", 200, r,
                  checkins.MOTIVO_MAL_HOY in r.json().get("status_reasons", [])
                  and r.json().get("wellbeing_status") in ("warning", "attention"))

            r = await client.get("/api/v1/patients", headers=token(familiar))
            fila = next((i for i in r.json().get("items", []) if i["patient_id"] == PACIENTE), {})
            check("la lista de la familia lo refleja", 200, r,
                  fila.get("wellbeing_status") in ("warning", "attention"))

        if cuidadora:
            r = await client.put(f"{base}/today", json={"mood": "regular"}, headers=token(cuidadora))
            check("la cuidadora puede ingresarlo por el", 200, r,
                  r.json().get("source") == "caregiver")

        if familiar:
            check("la familia lo lee pero no lo responde", 403,
                  await client.put(f"{base}/today", json={"mood": "good"}, headers=token(familiar)))

        check("animo que no existe", 422,
              await client.put(f"{base}/today", json={"mood": "feliz"},
                               headers=token(elder or cuidadora)))
        check("dolor fuera de escala", 422,
              await client.put(f"{base}/today", json={"mood": "good", "pain_level": 11},
                               headers=token(elder or cuidadora)))

        r = await client.get(f"{base}?days=7", headers=token(familiar))
        check("historial de la semana", 200, r, len(r.json().get("items", [])) >= 1)

        check("fuera del circulo", 404,
              await client.get(f"{base}/today", headers=token(AJENO)))
        check("sin autenticar", 401, await client.get(f"{base}/today"))

    # Dejar el dia como estaba.
    async with _eng.begin() as c:
        await c.execute(_t("DELETE FROM daily_checkins "
                           "WHERE patient_id=:p AND checkin_date=current_date"),
                        {"p": PACIENTE})
        if antes:
            await c.execute(_t(
                "INSERT INTO daily_checkins (patient_id, checkin_date, mood, pain_level, "
                "slept_well, ate_well, note, source) VALUES (:p, current_date, :mood, "
                ":pain_level, :slept_well, :ate_well, :note, :source)"),
                {"p": PACIENTE, **dict(antes)})
    await _eng.dispose()

    print(f"\nresultado: {ok} de {n}")
    return 0 if ok == n else 1


import sys  # noqa: E402

sys.exit(asyncio.run(run()))
