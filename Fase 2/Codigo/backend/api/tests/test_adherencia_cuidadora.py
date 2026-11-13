"""La adherencia del resumen de la cuidadora (GET /caregiver/today).

Una dosis puede colgar de un medicamento suelto o de una indicacion de un
tratamiento. El resumen solo miraba las primeras, asi que un paciente con
su esquema en tratamientos aparecia sin adherencia. Esta prueba agrega una
dosis de tratamiento vencida y comprueba que el resumen la cuenta.
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
from datetime import datetime, timedelta, timezone  # noqa: E402

import httpx  # noqa: E402
from fastapi import FastAPI  # noqa: E402
from jose import jwt  # noqa: E402
from sqlalchemy import text as _t  # noqa: E402

from app.config import get_settings  # noqa: E402
from app.db import engine as _eng  # noqa: E402
from app.errors import register_error_handlers  # noqa: E402
from app.routers import caregiver  # noqa: E402

app = FastAPI()
register_error_handlers(app)
app.include_router(caregiver.router)

PACIENTE = "33333333-3333-4333-8333-333333333333"
n = ok = 0

# Lo que deberia dar, calculado aparte: todas las dosis vencidas de los
# ultimos siete dias, vengan de un medicamento o de un tratamiento.
ESPERADA = """
    SELECT round(100.0 * count(*) FILTER (WHERE d.status = 'taken')
                 / nullif(count(*), 0), 1)
    FROM scheduled_doses d
    LEFT JOIN medications m ON m.id = d.medication_id
    LEFT JOIN treatment_items ti ON ti.id = d.treatment_item_id
    LEFT JOIN treatments tr ON tr.id = ti.treatment_id
    WHERE COALESCE(m.patient_id, tr.patient_id) = CAST(:pid AS uuid)
      AND d.scheduled_at >= now() - interval '7 days'
      AND d.scheduled_at <= now()
"""


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


async def cuidadora():
    async with _eng.begin() as c:
        r = await c.execute(_t("SELECT user_id FROM patient_members "
                               "WHERE patient_id=:p AND role='caregiver' "
                               "AND removed_at IS NULL LIMIT 1"), {"p": PACIENTE})
        return str(r.scalar())


async def esperada(pid):
    async with _eng.begin() as c:
        v = (await c.execute(_t(ESPERADA), {"pid": pid})).scalar()
        return float(v) if v is not None else None


async def main(client, uid):
    print("--- adherencia del resumen de la cuidadora ---")
    r = await client.get("/api/v1/caregiver/today", headers=token(uid))
    comprobar("devuelve el resumen", r.status_code == 200, r.text[:160])
    if r.status_code != 200:
        return
    pid = r.json()["patient_id"]

    async with _eng.begin() as c:
        item = (await c.execute(_t(
            "SELECT ti.id FROM treatment_items ti "
            "JOIN treatments t ON t.id = ti.treatment_id "
            "WHERE t.patient_id = CAST(:pid AS uuid) LIMIT 1"), {"pid": pid})).scalar()
    if item is None:
        print("  (el paciente no tiene tratamientos: se omite)")
        return

    creadas = []
    try:
        async with _eng.begin() as c:
            # Una toma de tratamiento que vencio hace un rato y no se dio.
            # La hora rara evita chocar con una dosis real del mismo item.
            creadas.append(str((await c.execute(_t(
                "INSERT INTO scheduled_doses (treatment_item_id, scheduled_at, status) "
                "VALUES (:item, now() - interval '2 hours 3 minutes 7 seconds', 'missed') "
                "RETURNING id"), {"item": item})).scalar()))

        r = await client.get("/api/v1/caregiver/today", headers=token(uid))
        dada = r.json().get("adherence_pct")
        debe = await esperada(pid)
        comprobar("cuenta las dosis de los tratamientos", dada is not None,
                  f"dio {dada}")
        comprobar("coincide con el calculo con medicamentos y tratamientos",
                  dada == debe, f"dio {dada} y debia {debe}")
    finally:
        async with _eng.begin() as c:
            for d in creadas:
                await c.execute(_t("DELETE FROM scheduled_doses WHERE id = CAST(:d AS uuid)"),
                                {"d": d})


async def run():
    uid = await cuidadora()
    transport = httpx.ASGITransport(app=app)
    async with httpx.AsyncClient(transport=transport, base_url="http://testserver") as cl:
        await main(cl, uid)
    await _eng.dispose()
    print()
    print(f"resultado: {ok} de {n}")
    return 0 if ok == n else 1


import sys  # noqa: E402

sys.exit(asyncio.run(run()))
