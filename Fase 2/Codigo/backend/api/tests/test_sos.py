"""Pruebas del boton de emergencia, contra la base real.

Es el flujo que menos se puede romper de toda la aplicacion y estuvo roto
sin que nadie lo viera: desde que los contactos de emergencia pasaron a ser
miembros del grupo (406), el endpoint respondia 500 en cuanto el paciente
tenia uno, y lo hacia DESPUES de guardar la alerta. La persona veia un error
con el SOS ya registrado.

Por eso aqui no basta con mirar el codigo de respuesta: cada caso comprueba
tambien cuantas alertas quedaron en la base.
"""
import os
os.environ.setdefault("POSTGRES_HOST", "127.0.0.1")
os.environ.setdefault("POSTGRES_PORT", "5432")

import pathlib as _pl
import sys as _sys
_sys.path.insert(0, str(_pl.Path(__file__).resolve().parents[1]))

import asyncio  # noqa: E402
from datetime import datetime, timedelta, timezone  # noqa: E402

import httpx  # noqa: E402
from fastapi import FastAPI  # noqa: E402
from jose import jwt  # noqa: E402
from sqlalchemy import text  # noqa: E402

from app.config import get_settings  # noqa: E402
from app.db import engine  # noqa: E402
from app.errors import register_error_handlers  # noqa: E402
from app.routers import alerts  # noqa: E402

app = FastAPI()
register_error_handlers(app)
app.include_router(alerts.router)

FAMILIAR  = "11111111-1111-4111-8111-111111111111"   # Javier, familiar de los dos
CUIDADORA = "22222222-2222-4222-8222-222222222222"   # Rosa, cuidadora de los dos
ADULTO    = "99999999-9999-4999-8999-999999999999"   # Elena, la propia paciente
from _ajeno import AJENO  # noqa: E402  (cuenta fuera del circulo, creada por la prueba)
ELENA = "33333333-3333-4333-8333-333333333333"       # contactos libres
LUIS  = "33333333-3333-4333-8333-333333333334"       # contacto que es miembro

MARCA = "PRUEBA-SOS"

n = ok = 0


def check(nombre, cond, detalle=""):
    global n, ok
    n += 1
    if cond:
        ok += 1
        print(f"  OK   {nombre}")
    else:
        print(f"  FALLA {nombre}   {detalle}")


def token(uid: str) -> dict:
    cfg = get_settings()
    t = jwt.encode(
        {"sub": uid, "type": "access",
         "exp": int((datetime.now(timezone.utc) + timedelta(minutes=10)).timestamp())},
        cfg.jwt_secret, algorithm=cfg.jwt_algorithm)
    return {"Authorization": f"Bearer {t}"}


async def limpiar():
    async with engine.begin() as c:
        await c.execute(text(
            "DELETE FROM sos_events WHERE note LIKE :m"), {"m": MARCA + "%"})
        # Los avisos antes que la alerta: el SOS se reparte al telefono y
        # una alerta con entregas no se puede borrar directo.
        await c.execute(text(
            "DELETE FROM alert_deliveries WHERE alert_id IN (SELECT id "
            "  FROM alerts WHERE type = 'sos' AND detail LIKE :m)"),
            {"m": MARCA + "%"})
        await c.execute(text(
            "DELETE FROM alerts WHERE type = 'sos' AND detail LIKE :m"),
            {"m": MARCA + "%"})
        await c.execute(text(
            "DELETE FROM emergency_contacts WHERE notes = :m"), {"m": MARCA})


async def cuantas(paciente: str) -> int:
    async with engine.begin() as c:
        return (await c.execute(text(
            "SELECT count(*) FROM alerts WHERE patient_id = :p AND type = 'sos' "
            "  AND detail LIKE :m"), {"p": paciente, "m": MARCA + "%"})).scalar()


async def sos(client, paciente, uid, nota="caso"):
    return await client.post(f"/api/v1/patients/{paciente}/sos",
                             json={"note": f"{MARCA} {nota}"},
                             headers=token(uid))


async def main(client):
    await limpiar()

    # ---------------- el caso que estaba roto ----------------
    print("--- contacto que es miembro del grupo ---")
    async with engine.begin() as c:
        perfil = (await c.execute(text(
            "SELECT full_name, phone FROM users WHERE id = :u"),
            {"u": FAMILIAR})).mappings().first()
    r = await sos(client, LUIS, CUIDADORA, "miembro")
    check("201 con un contacto que es miembro del grupo", r.status_code == 201,
          f"{r.status_code} {r.text[:120]}")
    check("la alerta quedo guardada una sola vez", await cuantas(LUIS) == 1,
          await cuantas(LUIS))
    if r.status_code == 201:
        cs = r.json()["emergency_contacts"]
        check("devuelve al miembro como contacto", len(cs) == 1, cs)
        if cs:
            check("el nombre sale del perfil del usuario",
                  cs[0]["full_name"] == perfil["full_name"], cs[0])
            check("el telefono sale del perfil del usuario",
                  cs[0]["phone"] == perfil["phone"], cs[0])

    # ---------------- contactos libres, como antes ----------------
    print("--- contactos libres ---")
    r = await sos(client, ELENA, ADULTO, "libres")
    check("201 cuando lo aprieta la propia paciente", r.status_code == 201,
          f"{r.status_code} {r.text[:120]}")
    if r.status_code == 201:
        d = r.json()
        nombres = [c["full_name"] for c in d["emergency_contacts"]]
        check("los contactos libres siguen saliendo con su nombre",
              "Javier Cerna" in nombres and len(nombres) >= 3, nombres)
        check("y con su telefono",
              all(c["phone"] for c in d["emergency_contacts"]),
              d["emergency_contacts"])
        check("conservan el parentesco",
              any(c["role"] == "Hijo" for c in d["emergency_contacts"]),
              d["emergency_contacts"])
        check("sin orden de escalamiento: van por nombre",
              nombres == sorted(nombres), nombres)
        async with engine.begin() as c:
            fila = (await c.execute(text(
                "SELECT a.severity, a.status, a.type, s.triggered_by "
                "FROM alerts a JOIN sos_events s ON s.alert_id = a.id "
                "WHERE a.id = :a"), {"a": d["alert_id"]})).mappings().first()
        check("la alerta nace critica y activa, con su evento SOS",
              fila is not None and fila["severity"] == "critical"
              and fila["status"] == "active" and fila["type"] == "sos"
              and str(fila["triggered_by"]) == ADULTO, dict(fila) if fila else None)

    # ---------------- la rotacion ----------------
    print("--- contactos desactivados ---")
    async with engine.begin() as c:
        await c.execute(text(
            "INSERT INTO emergency_contacts (patient_id, first_name, last_name, "
            "  phone, relationship, is_active, notes) "
            "VALUES (:p, 'Vecina', 'Inactiva', '+56900000001', 'Vecina', false, :m)"),
            {"p": ELENA, "m": MARCA})
    r = await sos(client, ELENA, CUIDADORA, "rotacion")
    check("201 con un contacto desactivado en la lista", r.status_code == 201,
          r.status_code)
    if r.status_code == 201:
        nombres = [c["full_name"] for c in r.json()["emergency_contacts"]]
        check("un contacto desactivado no sale: no es a quien llamar hoy",
              "Vecina Inactiva" not in nombres, nombres)

    # ---------------- un miembro sin telefono en el perfil ----------------
    print("--- miembro sin telefono ---")
    async with engine.begin() as c:
        tel = (await c.execute(text(
            "SELECT phone FROM users WHERE id = :u"), {"u": FAMILIAR})).scalar()
        await c.execute(text("UPDATE users SET phone = NULL WHERE id = :u"),
                        {"u": FAMILIAR})
    try:
        antes = await cuantas(LUIS)
        r = await sos(client, LUIS, CUIDADORA, "sin telefono")
        check("201 aunque el miembro no tenga telefono", r.status_code == 201,
              f"{r.status_code} {r.text[:120]}")
        check("y la alerta se guarda igual", await cuantas(LUIS) == antes + 1)
        if r.status_code == 201:
            cs = r.json()["emergency_contacts"]
            check("el contacto sale igual, con el telefono vacio",
                  len(cs) == 1 and cs[0]["phone"] is None, cs)
    finally:
        async with engine.begin() as c:
            await c.execute(text("UPDATE users SET phone = :t WHERE id = :u"),
                            {"t": tel, "u": FAMILIAR})

    # ---------------- quien puede ----------------
    print("--- permisos ---")
    antes = await cuantas(ELENA)
    r = await sos(client, ELENA, FAMILIAR, "familiar")
    check("403 para el familiar: el boton es del paciente y de quien lo cuida",
          r.status_code == 403, r.status_code)
    r = await sos(client, ELENA, AJENO, "ajeno")
    check("404 para alguien fuera del circulo", r.status_code == 404, r.status_code)
    r = await client.post(f"/api/v1/patients/{ELENA}/sos", json={})
    check("401 sin sesion", r.status_code == 401, r.status_code)
    check("ningun rechazo deja una alerta", await cuantas(ELENA) == antes,
          (antes, await cuantas(ELENA)))

    await limpiar()


async def correr():
    transport = httpx.ASGITransport(app=app, raise_app_exceptions=False)
    async with httpx.AsyncClient(transport=transport,
                                 base_url="http://testserver") as client:
        try:
            await main(client)
        finally:
            await limpiar()
    await engine.dispose()
    print(f"\n{ok}/{n} comprobaciones")
    return 0 if ok == n and n > 0 else 1


if __name__ == "__main__":
    raise SystemExit(asyncio.run(correr()))
