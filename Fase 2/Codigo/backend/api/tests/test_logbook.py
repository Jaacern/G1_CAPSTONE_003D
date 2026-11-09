"""Pruebas de la bitacora."""
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
from app.routers import files, logbook  # noqa: E402

app = FastAPI()
register_error_handlers(app)
app.include_router(files.router)
app.include_router(logbook.router)

PACIENTE = "33333333-3333-4333-8333-333333333333"
AJENO = "eeeeeee1-0000-4000-8000-000000000001"

n = ok = 0


def token(uid):
    cfg = get_settings()
    t = jwt.encode({"sub": uid, "type": "access",
                    "exp": int((datetime.now(timezone.utc) + timedelta(minutes=10)).timestamp())},
                   cfg.jwt_secret, algorithm=cfg.jwt_algorithm)
    return {"Authorization": f"Bearer {t}"}


def check(nombre, esperado, resp, campo=None):
    global n, ok
    n += 1
    bien = resp.status_code == esperado
    if bien and campo:
        bien = campo in resp.json()
    if bien:
        ok += 1
        print(f"  OK   {esperado}  {nombre}")
    else:
        print(f"  FALLA esperaba {esperado} y dio {resp.status_code}  {nombre}")
        print(f"       {resp.text[:140]}")


async def miembros():
    async with _eng.begin() as c:
        r = await c.execute(_t(
            "SELECT user_id, role FROM patient_members "
            "WHERE patient_id=:p AND removed_at IS NULL"), {"p": PACIENTE})
        return {m["role"]: str(m["user_id"]) for m in r.mappings().all()}


async def main(client, roles):
    cuidadora = roles.get("caregiver")
    familiar = roles.get("family")
    print(f"  (roles disponibles: {sorted(roles)})")

    print("--- observaciones: crear ---")
    r = await client.post(f"/api/v1/patients/{PACIENTE}/observations",
                          json={"text": "Almorzo completo y camino en el patio.",
                                "category": "Alimentación"},
                          headers=token(cuidadora))
    check("la cuidadora registra una observacion", 201, r, campo="id")
    if r.status_code == 201:
        d = r.json()
        global n, ok
        n += 1
        if d["category"] == "food":
            ok += 1; print("  OK   'Alimentación' se guarda como 'food'")
        else:
            print(f"  FALLA categoria quedo como {d['category']}")
        n += 1
        if d["author_name"]:
            ok += 1; print(f"  OK   devuelve el autor ({d['author_name']})")
        else:
            print("  FALLA no devuelve autor")

    for etiqueta, codigo in [("Ánimo", "mood"), ("Sueño", "sleep"),
                             ("Movilidad", "mobility"), ("Higiene", "hygiene"),
                             ("General", "other")]:
        rr = await client.post(f"/api/v1/patients/{PACIENTE}/observations",
                               json={"text": f"nota de {etiqueta}", "category": etiqueta},
                               headers=token(cuidadora))
        n += 1
        if rr.status_code == 201 and rr.json()["category"] == codigo:
            ok += 1; print(f"  OK   '{etiqueta}' -> '{codigo}'")
        else:
            print(f"  FALLA '{etiqueta}' dio {rr.status_code} {rr.text[:80]}")

    check("sin categoria queda en 'other'", 201,
          await client.post(f"/api/v1/patients/{PACIENTE}/observations",
                            json={"text": "sin categoria"}, headers=token(cuidadora)))
    check("categoria inventada", 422,
          await client.post(f"/api/v1/patients/{PACIENTE}/observations",
                            json={"text": "x", "category": "Telepatía"},
                            headers=token(cuidadora)))
    check("texto de solo espacios", 422,
          await client.post(f"/api/v1/patients/{PACIENTE}/observations",
                            json={"text": "    "}, headers=token(cuidadora)))
    check("texto vacio", 422,
          await client.post(f"/api/v1/patients/{PACIENTE}/observations",
                            json={"text": ""}, headers=token(cuidadora)))
    check("usuario fuera del circulo", 404,
          await client.post(f"/api/v1/patients/{PACIENTE}/observations",
                            json={"text": "x"}, headers=token(AJENO)))
    check("sin autenticar", 401,
          await client.post(f"/api/v1/patients/{PACIENTE}/observations",
                            json={"text": "x"}))
    if familiar:
        check("el familiar tambien puede registrar", 201,
              await client.post(f"/api/v1/patients/{PACIENTE}/observations",
                                json={"text": "lo vi animado hoy"},
                                headers=token(familiar)))

    print("--- observaciones: adjunto ---")
    # archivo valido de este paciente
    up = await client.post("/api/v1/uploads",
                           json={"filename": "f.jpg", "content_type": "image/jpeg",
                                 "kind": "photo", "size": 20, "patient_id": PACIENTE},
                           headers=token(cuidadora))
    datos = up.json()
    await client.put(datos["upload_url"].replace("http://testserver", ""),
                     content=b"\xff\xd8\xff\xe0" + b"x" * 15 + b"\xff\xd9",
                     headers={"Content-Type": "image/jpeg"})
    r = await client.post(f"/api/v1/patients/{PACIENTE}/observations",
                          json={"text": "con foto", "media_url": datos["file_url"]},
                          headers=token(cuidadora))
    check("acepta un adjunto de este paciente", 201, r, campo="media_url")
    check("rechaza un media_url que no es una referencia valida", 422,
          await client.post(f"/api/v1/patients/{PACIENTE}/observations",
                            json={"text": "x", "media_url": "https://ejemplo.com/foto.jpg"},
                            headers=token(cuidadora)))
    check("rechaza un archivo que no existe", 422,
          await client.post(f"/api/v1/patients/{PACIENTE}/observations",
                            json={"text": "x",
                                  "media_url": "http://testserver/api/v1/files/"
                                               "99999999-9999-4999-8999-999999999991"},
                            headers=token(cuidadora)))

    print("--- observaciones: listar ---")
    rl = await client.get(f"/api/v1/patients/{PACIENTE}/observations",
                          headers=token(cuidadora))
    check("lista la bitacora", 200, rl, campo="items")
    if rl.status_code == 200:
        items = rl.json()["items"]
        n += 1
        if len(items) >= 8:
            ok += 1; print(f"  OK   devuelve las observaciones ({len(items)})")
        else:
            print(f"  FALLA solo {len(items)} observaciones")
        fechas = [i["created_at"] for i in items]
        n += 1
        if fechas == sorted(fechas, reverse=True):
            ok += 1; print("  OK   lo mas reciente primero")
        else:
            print("  FALLA no viene ordenado")
    check("listar desde fuera del circulo", 404,
          await client.get(f"/api/v1/patients/{PACIENTE}/observations",
                           headers=token(AJENO)))

    print("--- incidentes ---")
    ri = await client.post(f"/api/v1/patients/{PACIENTE}/incidents",
                           json={"type": "Caída", "severity": "medium",
                                 "description": "Resbalo en el baño, sin golpe visible."},
                           headers=token(cuidadora))
    check("reporta un incidente", 201, ri, campo="id")
    if ri.status_code == 201:
        d = ri.json()
        n += 1
        if d["type"] == "fall" and d["severity"] == "moderate":
            ok += 1; print("  OK   'Caída'/'medium' -> 'fall'/'moderate'")
        else:
            print(f"  FALLA quedo {d['type']}/{d['severity']}")

    for etiqueta, codigo in [("Reacción adversa", "adverse_reaction"),
                             ("Fuga / desorientación", "wandering"),
                             ("Golpe o lesión", "injury"),
                             ("Emergencia médica", "medical_emergency"),
                             ("Otro", "other")]:
        rr = await client.post(f"/api/v1/patients/{PACIENTE}/incidents",
                               json={"type": etiqueta, "severity": "low",
                                     "description": f"caso de {etiqueta}"},
                               headers=token(cuidadora))
        n += 1
        if rr.status_code == 201 and rr.json()["type"] == codigo:
            ok += 1; print(f"  OK   '{etiqueta}' -> '{codigo}'")
        else:
            print(f"  FALLA '{etiqueta}' dio {rr.status_code} {rr.text[:90]}")

    for sev in ["low", "high"]:
        rr = await client.post(f"/api/v1/patients/{PACIENTE}/incidents",
                               json={"type": "Otro", "severity": sev,
                                     "description": "x"}, headers=token(cuidadora))
        n += 1
        if rr.status_code == 201 and rr.json()["severity"] == sev:
            ok += 1; print(f"  OK   severidad '{sev}' pasa tal cual")
        else:
            print(f"  FALLA severidad '{sev}': {rr.status_code}")

    check("tipo inventado", 422,
          await client.post(f"/api/v1/patients/{PACIENTE}/incidents",
                            json={"type": "Invasión alienígena", "severity": "low",
                                  "description": "x"}, headers=token(cuidadora)))
    check("severidad critical se rechaza mientras no exista el flujo de alertas", 422,
          await client.post(f"/api/v1/patients/{PACIENTE}/incidents",
                            json={"type": "Caída", "severity": "critical",
                                  "description": "x"}, headers=token(cuidadora)))
    check("descripcion vacia", 422,
          await client.post(f"/api/v1/patients/{PACIENTE}/incidents",
                            json={"type": "Caída", "severity": "low",
                                  "description": "   "}, headers=token(cuidadora)))
    check("incidente desde fuera del circulo", 404,
          await client.post(f"/api/v1/patients/{PACIENTE}/incidents",
                            json={"type": "Caída", "severity": "low",
                                  "description": "x"}, headers=token(AJENO)))

    print("--- notas de relevo ---")
    async with _eng.begin() as c:
        await c.execute(_t("DELETE FROM shift_notes WHERE patient_id=:p"), {"p": PACIENTE})

    rh = await client.post(f"/api/v1/patients/{PACIENTE}/handover-notes",
                           json={"text": "Tomo todos sus remedios. Queda durmiendo."},
                           headers=token(cuidadora))
    check("deja la nota de relevo", 201, rh, campo="id")
    if rh.status_code == 201:
        d = rh.json()
        n += 1
        if d["shift"] in ("morning", "afternoon", "night") and d["shift_date"]:
            ok += 1; print(f"  OK   deduce el turno ({d['shift']}, {d['shift_date']})")
        else:
            print(f"  FALLA turno/fecha: {d}")
        primera = d["id"]

        r2 = await client.post(f"/api/v1/patients/{PACIENTE}/handover-notes",
                               json={"text": "Corrijo: tomo todo menos la del almuerzo."},
                               headers=token(cuidadora))
        check("un segundo envio en el mismo turno reemplaza", 201, r2)
        if r2.status_code == 201:
            n += 1
            if r2.json()["id"] == primera:
                ok += 1; print("  OK   es la misma nota, no una duplicada")
            else:
                print("  FALLA creo una nota nueva en el mismo turno")
            n += 1
            if "Corrijo" in r2.json()["text"]:
                ok += 1; print("  OK   quedo el texto corregido")
            else:
                print("  FALLA no se actualizo el texto")

    if familiar:
        check("entregar el relevo a alguien del circulo", 201,
              await client.post(f"/api/v1/patients/{PACIENTE}/handover-notes",
                                json={"text": "te dejo a cargo", "to_user_id": familiar},
                                headers=token(cuidadora)))
    check("entregar el relevo a alguien de fuera", 422,
          await client.post(f"/api/v1/patients/{PACIENTE}/handover-notes",
                            json={"text": "x", "to_user_id": AJENO},
                            headers=token(cuidadora)))
    check("nota de solo espacios", 422,
          await client.post(f"/api/v1/patients/{PACIENTE}/handover-notes",
                            json={"text": "   "}, headers=token(cuidadora)))

    rlh = await client.get(f"/api/v1/patients/{PACIENTE}/handover-notes",
                           headers=token(cuidadora))
    check("lista las notas de relevo", 200, rlh, campo="items")
    if rlh.status_code == 200:
        n += 1
        if len(rlh.json()["items"]) == 1:
            ok += 1; print("  OK   hay una sola nota para este turno")
        else:
            print(f"  FALLA hay {len(rlh.json()['items'])} notas")
    check("listar relevo desde fuera del circulo", 404,
          await client.get(f"/api/v1/patients/{PACIENTE}/handover-notes",
                           headers=token(AJENO)))

    print("--- turno: entrada y salida ---")
    async with _eng.begin() as c:
        await c.execute(_t("DELETE FROM care_shifts"))

    ri = await client.post(f"/api/v1/patients/{PACIENTE}/checkin",
                           json={"type": "in", "lat": -36.9731, "lng": -73.0500},
                           headers=token(cuidadora))
    check("marca entrada", 200, ri, campo="shift_status")
    if ri.status_code == 200:
        d = ri.json()
        n += 1
        if d["shift_status"] == "checked_in" and d["checked_out_at"] is None:
            ok += 1; print("  OK   queda en turno")
        else:
            print(f"  FALLA {d}")
        turno = d["shift_id"]

        r2 = await client.post(f"/api/v1/patients/{PACIENTE}/checkin",
                               json={"type": "in"}, headers=token(cuidadora))
        n += 1
        if r2.status_code == 200 and r2.json()["shift_id"] == turno:
            ok += 1; print("  OK   entrar dos veces no abre otro turno")
        else:
            print(f"  FALLA entrada repetida: {r2.status_code} {r2.text[:90]}")

        async with _eng.begin() as c:
            cuantos = (await c.execute(_t(
                "SELECT count(*) FROM care_shifts WHERE caregiver_id=:u"),
                {"u": cuidadora})).scalar()
        n += 1
        if cuantos == 1:
            ok += 1; print("  OK   hay un solo turno en la tabla")
        else:
            print(f"  FALLA hay {cuantos} turnos")

    import asyncio as _a
    await _a.sleep(1.1)
    ro = await client.post(f"/api/v1/patients/{PACIENTE}/checkin",
                           json={"type": "out", "lat": -36.9731, "lng": -73.0500},
                           headers=token(cuidadora))
    check("marca salida", 200, ro)
    if ro.status_code == 200:
        d = ro.json()
        n += 1
        if d["shift_status"] == "checked_out" and d["checked_out_at"]:
            ok += 1; print("  OK   queda fuera de turno")
        else:
            print(f"  FALLA {d}")
        n += 1
        if d["duration_seconds"] is not None and d["duration_seconds"] >= 1:
            ok += 1; print(f"  OK   calcula la duracion ({d['duration_seconds']}s)")
        else:
            print(f"  FALLA duracion: {d['duration_seconds']}")

    r3 = await client.post(f"/api/v1/patients/{PACIENTE}/checkin",
                           json={"type": "out"}, headers=token(cuidadora))
    n += 1
    if r3.status_code == 200 and r3.json()["shift_status"] == "checked_out":
        ok += 1; print("  OK   salir dos veces no da error")
    else:
        print(f"  FALLA salida repetida: {r3.status_code}")

    check("tipo de marca inventado", 422,
          await client.post(f"/api/v1/patients/{PACIENTE}/checkin",
                            json={"type": "quizas"}, headers=token(cuidadora)))
    check("solo latitud, sin longitud", 422,
          await client.post(f"/api/v1/patients/{PACIENTE}/checkin",
                            json={"type": "in", "lat": -36.9}, headers=token(cuidadora)))
    check("latitud fuera de rango", 422,
          await client.post(f"/api/v1/patients/{PACIENTE}/checkin",
                            json={"type": "in", "lat": 200, "lng": 10},
                            headers=token(cuidadora)))
    if familiar:
        check("el familiar no marca turno", 403,
              await client.post(f"/api/v1/patients/{PACIENTE}/checkin",
                                json={"type": "in"}, headers=token(familiar)))
    check("marcar turno desde fuera del circulo", 404,
          await client.post(f"/api/v1/patients/{PACIENTE}/checkin",
                            json={"type": "in"}, headers=token(AJENO)))

    # turno abierto con otro paciente. Si la cuidadora no atiende a otro, se
    # le agrega la membresia para probar la rama y se saca al final.
    agregada = False
    creado = None
    async with _eng.begin() as c:
        otro_p = (await c.execute(_t(
            "SELECT patient_id FROM patient_members WHERE user_id=:u "
            "AND patient_id <> :p AND role='caregiver' AND removed_at IS NULL LIMIT 1"),
            {"u": cuidadora, "p": PACIENTE})).scalar()
        if otro_p is None:
            otro_p = (await c.execute(_t(
                "SELECT id FROM patients WHERE id <> :p AND deleted_at IS NULL LIMIT 1"),
                {"p": PACIENTE})).scalar()
            if otro_p is None:
                otro_p = (await c.execute(_t(
                    "INSERT INTO patients (first_name, last_name, birth_date, sex) "
                    "VALUES ('Paciente', 'De Prueba', '1940-05-05', 'F') "
                    "RETURNING id"))).scalar()
                creado = str(otro_p)
            if otro_p:
                await c.execute(_t(
                    "INSERT INTO patient_members (patient_id, user_id, role, is_owner) "
                    "VALUES (:p, :u, 'caregiver', false) "
                    "ON CONFLICT DO NOTHING"), {"p": str(otro_p), "u": cuidadora})
                agregada = True
    if otro_p:
        await client.post(f"/api/v1/patients/{otro_p}/checkin",
                          json={"type": "in"}, headers=token(cuidadora))
        check("entrar con un turno abierto en otro paciente", 409,
              await client.post(f"/api/v1/patients/{PACIENTE}/checkin",
                                json={"type": "in"}, headers=token(cuidadora)))
        await client.post(f"/api/v1/patients/{otro_p}/checkin",
                          json={"type": "out"}, headers=token(cuidadora))
        if agregada:
            async with _eng.begin() as c:
                await c.execute(_t("DELETE FROM care_shifts WHERE patient_id=:p"),
                                {"p": str(otro_p)})
                await c.execute(_t(
                    "DELETE FROM patient_members WHERE patient_id=:p AND user_id=:u"),
                    {"p": str(otro_p), "u": cuidadora})
                if creado:
                    await c.execute(_t("DELETE FROM patients WHERE id=:p"),
                                    {"p": creado})
    else:
        print("  (la cuidadora solo tiene un paciente, no se prueba el 409)")

    print("--- RNF-14 ---")
    async with _eng.begin() as c:
        cuenta = (await c.execute(_t(
            "SELECT count(*) FROM record_access_log "
            "WHERE patient_id=:p AND section='logbook'"), {"p": PACIENTE})).scalar()
    n += 1
    if cuenta >= 1:
        ok += 1; print(f"  OK   la lectura de la bitacora queda registrada ({cuenta})")
    else:
        print("  FALLA no quedo registro de lectura")


async def run():
    roles = await miembros()
    async with _eng.begin() as c:
        await c.execute(_t("DELETE FROM record_access_log WHERE section='logbook'"))
    transport = httpx.ASGITransport(app=app)
    async with httpx.AsyncClient(transport=transport, base_url="http://testserver") as cl:
        await main(cl, roles)
    await _eng.dispose()
    print()
    print(f"resultado: {ok} de {n}")
    # Codigo de salida para que el CI lo vea.
    return 0 if ok == n else 1


import sys  # noqa: E402

sys.exit(asyncio.run(run()))
