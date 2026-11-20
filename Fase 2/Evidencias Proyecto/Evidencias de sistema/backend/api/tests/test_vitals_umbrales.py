"""Pruebas de los umbrales por HTTP.

PUT /patients/{id}/thresholds/{type} no se habia probado nunca, y devolvia
500 en todas sus llamadas: el indice unico de la tabla es parcial y el
ON CONFLICT no repetia su condicion, asi que Postgres rechazaba la
sentencia sin llegar a mirar si habia conflicto.
"""
import os
os.environ.setdefault("POSTGRES_HOST", "127.0.0.1")
os.environ.setdefault("POSTGRES_PORT", "5432")

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
from app.routers import vitals  # noqa: E402

app = FastAPI()
register_error_handlers(app)
app.include_router(vitals.router)

PACIENTE = "33333333-3333-4333-8333-333333333333"
n = ok = 0


def token(uid):
    cfg = get_settings()
    t = jwt.encode({"sub": uid, "type": "access",
                    "exp": int((datetime.now(timezone.utc)
                                + timedelta(minutes=10)).timestamp())},
                   cfg.jwt_secret, algorithm=cfg.jwt_algorithm)
    return {"Authorization": f"Bearer {t}"}


def check(nombre, esperado, resp, campo=None, valor=None):
    global n, ok
    n += 1
    bien = resp.status_code == esperado
    if bien and campo is not None:
        cuerpo = resp.json()
        bien = campo in cuerpo and (valor is None or cuerpo[campo] == valor)
    if bien:
        ok += 1
        print(f"  OK   {esperado}  {nombre}")
    else:
        print(f"  FALLA esperaba {esperado} y dio {resp.status_code}  {nombre}")
        print(f"       {resp.text[:200]}")


async def roles():
    async with _eng.begin() as c:
        r = await c.execute(_t("SELECT user_id, role FROM patient_members "
                               "WHERE patient_id=:p AND removed_at IS NULL"),
                            {"p": PACIENTE})
        return {m["role"]: str(m["user_id"]) for m in r.mappings().all()}


async def main(cl, rr):
    fam = token(rr["family"])
    base = f"/api/v1/patients/{PACIENTE}/vitals/thresholds"

    async with _eng.begin() as c:
        # Solo se limpia el tipo que usa la prueba. Reactivar en bloque
        # choca con el indice parcial si ya hay una fila vigente de ese
        # tipo, que es exactamente lo que el indice esta impidiendo.
        await c.execute(_t("DELETE FROM vital_thresholds "
                           "WHERE patient_id = :p AND type = 'glucose'"),
                        {"p": PACIENTE})

    # Crear uno nuevo.
    check("crea un umbral que no existia", 200,
          await cl.put(f"{base}/glucose", headers=fam,
                       json={"min_value": 70, "max_value": 180}),
          "max_value", 180.0)

    # Actualizar el que acaba de crear. Este es el camino que reventaba.
    r = await cl.put(f"{base}/glucose", headers=fam,
                     json={"min_value": 80, "max_value": 160})
    check("actualiza un umbral existente", 200, r, "min_value", 80.0)

    # Sigue habiendo una sola fila vigente.
    async with _eng.begin() as c:
        cuantas = (await c.execute(_t(
            "SELECT count(*) FROM vital_thresholds WHERE patient_id = :p "
            "  AND type = 'glucose' AND deleted_at IS NULL"),
            {"p": PACIENTE})).scalar()
    n_ = globals()
    n_["n"] += 1
    if cuantas == 1:
        n_["ok"] += 1
        print("  OK   ---  deja una sola fila vigente por tipo")
    else:
        print(f"  FALLA deja {cuantas} filas vigentes, deberia ser 1")

    # El listado lo devuelve.
    r = await cl.get(base, headers=fam)
    check("el listado incluye el umbral", 200, r, "items")
    globals()["n"] += 1
    tipos = [i["type"] for i in r.json().get("items", [])]
    if "glucose" in tipos:
        globals()["ok"] += 1
        print("  OK   ---  glucose aparece en el listado")
    else:
        print(f"  FALLA glucose no aparece: {tipos}")

    # Dado de baja, el listado deja de mostrarlo y volver a fijarlo
    # inserta una fila vigente nueva, dejando la anterior como historia.
    async with _eng.begin() as c:
        await c.execute(_t("UPDATE vital_thresholds SET deleted_at = now() "
                           "WHERE patient_id = :p AND type = 'glucose'"),
                        {"p": PACIENTE})
    r = await cl.get(base, headers=fam)
    globals()["n"] += 1
    if "glucose" not in [i["type"] for i in r.json().get("items", [])]:
        globals()["ok"] += 1
        print("  OK   ---  el listado omite el umbral dado de baja")
    else:
        print("  FALLA el listado sigue mostrando el umbral dado de baja")

    check("volver a fijarlo tras la baja funciona", 200,
          await cl.put(f"{base}/glucose", headers=fam,
                       json={"min_value": 75, "max_value": 150}),
          "min_value", 75.0)
    async with _eng.begin() as c:
        vig = (await c.execute(_t(
            "SELECT count(*) FROM vital_thresholds WHERE patient_id = :p "
            "  AND type = 'glucose' AND deleted_at IS NULL"),
            {"p": PACIENTE})).scalar()
        histo = (await c.execute(_t(
            "SELECT count(*) FROM vital_thresholds WHERE patient_id = :p "
            "  AND type = 'glucose' AND deleted_at IS NOT NULL"),
            {"p": PACIENTE})).scalar()
    globals()["n"] += 1
    if (vig, histo) == (1, 1):
        globals()["ok"] += 1
        print("  OK   ---  queda uno vigente y el de baja como historia")
    else:
        print(f"  FALLA vigentes={vig} de baja={histo}, esperaba 1 y 1")

    # Validaciones que ya existian, para no romperlas.
    check("rechaza un umbral vacio", 400,
          await cl.put(f"{base}/glucose", headers=fam, json={}))
    check("rechaza el minimo mayor que el maximo", 400,
          await cl.put(f"{base}/glucose", headers=fam,
                       json={"min_value": 200, "max_value": 100}))
    # Este endpoint responde 403 y no 404 como otros: el permiso por rol
    # lo resuelve get_patient_member, que distingue "no es tuyo" de "es
    # tuyo pero no con tu rol".
    check("la cuidadora no configura umbrales", 403,
          await cl.put(f"{base}/glucose", headers=token(rr["caregiver"]),
                       json={"min_value": 70, "max_value": 180}))
    check("sin autenticar", 401,
          await cl.put(f"{base}/glucose", json={"min_value": 70}))

    async with _eng.begin() as c:
        await c.execute(_t("DELETE FROM vital_thresholds "
                           "WHERE patient_id = :p AND type = 'glucose'"),
                        {"p": PACIENTE})


async def run():
    rr = await roles()
    transport = httpx.ASGITransport(app=app)
    async with httpx.AsyncClient(transport=transport,
                                 base_url="http://testserver") as cl:
        await main(cl, rr)
    await _eng.dispose()
    print()
    print(f"resultado: {ok} de {n}")
    # Codigo de salida para que el CI lo vea.
    return 0 if ok == n else 1


import sys  # noqa: E402

sys.exit(asyncio.run(run()))
