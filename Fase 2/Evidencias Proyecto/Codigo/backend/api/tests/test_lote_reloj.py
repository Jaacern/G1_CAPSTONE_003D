"""Pruebas de la alerta al recibir un lote de mediciones del reloj.

Antes una medicion del reloj fuera de rango no avisaba al llegar: esperaba a
la pasada horaria del mantenimiento. La misma medicion tomada a mano si
avisaba al instante. Aqui se comprueba que el lote avisa al entrar, por las
dos puertas (la del telefono y la del propio reloj), y sobre todo lo que NO
debe avisar: un lote reenviado, mediciones viejas que el reloj traia
guardadas, y un valor malo que ya fue seguido por uno bueno.
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
from app.maintenance import alertar_vitales_fuera_de_rango  # noqa: E402
from app.ratelimit import limiter  # noqa: E402
from app.routers import devices, vitals  # noqa: E402

app = FastAPI()
app.state.limiter = limiter
register_error_handlers(app)
app.include_router(vitals.router)
app.include_router(devices.router)

CUIDADORA = "22222222-2222-4222-8222-222222222222"
PACIENTE  = "33333333-3333-4333-8333-333333333333"
HUELLA    = "PRUEBA-LOTE-RELOJ-0001"

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


def lectura(tipo, valor, cuando):
    return {"type": tipo, "value": valor, "measured_at": cuando.isoformat(),
            "meta": {"origin": "FIXTURE-LOTE"}}


async def limpiar():
    async with engine.begin() as c:
        # Primero los avisos: el lote reparte la alerta al telefono, y una
        # alerta con entregas no se puede borrar directo.
        await c.execute(text(
            "DELETE FROM alert_deliveries WHERE alert_id IN ("
            "  SELECT id FROM alerts WHERE payload ->> 'reading_id' IN "
            "  (SELECT CAST(id AS text) FROM vital_readings "
            "    WHERE meta ->> 'origin' = 'FIXTURE-LOTE'))"))
        await c.execute(text(
            "DELETE FROM alerts WHERE payload ->> 'reading_id' IN "
            "(SELECT CAST(id AS text) FROM vital_readings "
            "  WHERE meta ->> 'origin' = 'FIXTURE-LOTE')"))
        await c.execute(text(
            "DELETE FROM vital_readings WHERE meta ->> 'origin' = 'FIXTURE-LOTE'"))
        await c.execute(text(
            "DELETE FROM elder_devices WHERE device_fingerprint = :h"), {"h": HUELLA})
        await c.execute(text(
            "DELETE FROM wearables WHERE serial_number = :h"), {"h": HUELLA})


async def alertas_de(tipo):
    """Alertas nacidas de las mediciones de esta prueba, para un tipo."""
    async with engine.begin() as c:
        return (await c.execute(text(
            "SELECT a.title, a.detail, a.dedup_key, a.status, a.severity "
            "FROM alerts a JOIN vital_readings vr "
            "  ON CAST(vr.id AS text) = a.payload ->> 'reading_id' "
            "WHERE vr.meta ->> 'origin' = 'FIXTURE-LOTE' AND vr.type = :t "
            "ORDER BY a.created_at"), {"t": tipo})).mappings().all()


async def main(client):
    await limpiar()
    async with engine.begin() as c:
        ventana = (await c.execute(text(
            "SELECT value FROM system_parameters "
            "WHERE key = 'alert_dedup_minutes'"))).scalar()
        # Sin ventana, para que cada caso se mida solo. La ventana tiene su
        # propio caso al final.
        await c.execute(text("UPDATE system_parameters SET value = '0' "
                             "WHERE key = 'alert_dedup_minutes'"))
        # El motor mira solo la ultima medicion de cada tipo, asi que las de
        # la prueba tienen que ser posteriores a todo lo que haya.
        base = (await c.execute(text(
            "SELECT greatest(now(), coalesce(max(measured_at), now())) "
            "FROM vital_readings WHERE patient_id = :p"), {"p": PACIENTE})).scalar()
    # Se drena lo que ya estuviera fuera de rango en la base.
    await alertar_vitales_fuera_de_rango(verbose=False)

    url = f"/api/v1/patients/{PACIENTE}/vitals/batch"
    h = token(CUIDADORA)
    try:
        # ---------------- avisa al llegar ----------------
        print("--- lote desde el telefono ---")
        lote = {"readings": [lectura("spo2", 85, base + timedelta(seconds=1))]}
        r = await client.post(url, json=lote, headers=h)
        check("200 al recibir el lote", r.status_code == 200,
              f"{r.status_code} {r.text[:120]}")
        d = r.json() if r.status_code == 200 else {}
        check("una medicion fuera de rango avisa en el mismo request",
              d.get("alerts_triggered") == 1, d)
        a = await alertas_de("spo2")
        check("la alerta quedo guardada", len(a) == 1, len(a))
        if a:
            check("con el mismo titulo que usa el mantenimiento",
                  a[0]["title"] == "Saturación O₂ bajo el mínimo", a[0]["title"])
            check("y la misma clave de la condicion",
                  a[0]["dedup_key"] == "spo2_low", a[0]["dedup_key"])
            check("nace activa", a[0]["status"] == "active", a[0]["status"])

        # ---------------- lo que no debe avisar ----------------
        print("--- lo que no debe avisar ---")
        r = await client.post(url, json=lote, headers=h)
        d = r.json()
        check("un lote reenviado no vuelve a avisar",
              d.get("accepted") == 0 and d.get("alerts_triggered") == 0
              and len(await alertas_de("spo2")) == 1, d)

        res = await alertar_vitales_fuera_de_rango(verbose=False)
        check("el mantenimiento reconoce la alerta y no la repite",
              len(await alertas_de("spo2")) == 1, res)

        r = await client.post(url, headers=h, json={"readings": [
            lectura("heart_rate", 72, base + timedelta(seconds=2))]})
        check("un valor en rango no avisa",
              r.json().get("alerts_triggered") == 0, r.json())

        # El reloj estuvo sin senal y manda lo que traia guardado.
        r = await client.post(url, headers=h, json={"readings": [
            lectura("temperature", 39.9, base - timedelta(hours=5))]})
        check("mediciones viejas que el reloj traia guardadas no avisan",
              r.json().get("accepted") == 1
              and r.json().get("alerts_triggered") == 0, r.json())

        # Un valor malo seguido de uno bueno en el mismo lote: manda el ultimo.
        r = await client.post(url, headers=h, json={"readings": [
            lectura("heart_rate", 150, base + timedelta(seconds=3)),
            lectura("heart_rate", 80, base + timedelta(seconds=4))]})
        check("si el ultimo valor del lote esta en rango, no avisa",
              r.json().get("alerts_triggered") == 0
              and len(await alertas_de("heart_rate")) == 0, r.json())

        # ---------------- la ventana ----------------
        print("--- ventana de repeticion ---")
        async with engine.begin() as c:
            await c.execute(text("UPDATE system_parameters SET value = '30' "
                                 "WHERE key = 'alert_dedup_minutes'"))
        r = await client.post(url, headers=h, json={"readings": [
            lectura("spo2", 84, base + timedelta(seconds=5))]})
        check("la misma condicion dentro de la ventana no abre otra alerta",
              r.json().get("alerts_triggered") == 0
              and len(await alertas_de("spo2")) == 1, r.json())
        async with engine.begin() as c:
            await c.execute(text("UPDATE system_parameters SET value = '0' "
                                 "WHERE key = 'alert_dedup_minutes'"))

        # ---------------- la puerta del propio reloj ----------------
        print("--- lote desde el reloj ---")
        r = await client.post(f"/api/v1/patients/{PACIENTE}/device-link-codes",
                              headers=h)
        check("la cuidadora genera el codigo de vinculacion",
              r.status_code == 201, f"{r.status_code} {r.text[:120]}")
        if r.status_code == 201:
            r = await client.post("/api/v1/devices/link", json={
                "code": r.json()["code"], "device_fingerprint": HUELLA})
            check("el reloj se vincula con el codigo", r.status_code == 201,
                  f"{r.status_code} {r.text[:120]}")
            if r.status_code == 201:
                hd = {"Authorization": f"Bearer {r.json()['device_token']}"}
                r = await client.post("/api/v1/devices/vitals/batch", headers=hd,
                                      json={"readings": [lectura(
                                          "heart_rate", 141,
                                          base + timedelta(seconds=6))]})
                check("200 al recibir el lote del reloj", r.status_code == 200,
                      f"{r.status_code} {r.text[:120]}")
                a = await alertas_de("heart_rate")
                check("el lote del reloj tambien avisa al llegar",
                      len(a) == 1 and a[0]["dedup_key"] == "heart_rate_high",
                      [dict(x) for x in a])
                r = await client.post("/api/v1/devices/vitals/batch", headers=hd,
                                      json={"readings": [lectura(
                                          "heart_rate", 141,
                                          base + timedelta(seconds=6))]})
                check("y reenviado no duplica",
                      len(await alertas_de("heart_rate")) == 1)
    finally:
        async with engine.begin() as c:
            await c.execute(text("UPDATE system_parameters SET value = :v "
                                 "WHERE key = 'alert_dedup_minutes'"),
                            {"v": ventana})
        await limpiar()


async def correr():
    transport = httpx.ASGITransport(app=app, raise_app_exceptions=False)
    async with httpx.AsyncClient(transport=transport,
                                 base_url="http://testserver") as client:
        await main(client)
    await engine.dispose()
    print(f"\n{ok}/{n} comprobaciones")
    return 0 if ok == n and n > 0 else 1


if __name__ == "__main__":
    raise SystemExit(asyncio.run(correr()))
