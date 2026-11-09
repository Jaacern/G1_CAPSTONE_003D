"""Pruebas de las tareas de cuidado."""
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
from app.routers import tasks  # noqa: E402

app = FastAPI()
register_error_handlers(app)
app.include_router(tasks.router)

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
        print(f"       {resp.text[:150]}")


async def roles():
    async with _eng.begin() as c:
        r = await c.execute(_t("SELECT user_id, role FROM patient_members "
                               "WHERE patient_id=:p AND removed_at IS NULL"), {"p": PACIENTE})
        return {m["role"]: str(m["user_id"]) for m in r.mappings().all()}


async def main(client, rr):
    global n, ok
    cuidadora = rr.get("caregiver")

    # datos de prueba directos en la tabla
    async with _eng.begin() as c:
        await c.execute(_t("DELETE FROM care_tasks WHERE title LIKE 'PRUEBA%'"))
        await c.execute(_t("""
            INSERT INTO care_tasks (patient_id, assigned_to_user_id, created_by_user_id,
                                    title, description, due_date, due_time, status,
                                    category, completed_at)
            VALUES (:p,:u,:u,'PRUEBA con hora','desc','2026-10-31','09:30','pending','hygiene',NULL),
                   (:p,:u,:u,'PRUEBA sin hora',NULL,'2026-10-31',NULL,'in_progress','medication',NULL),
                   (:p,:u,:u,'PRUEBA completada',NULL,'2026-10-30','08:00','completed',NULL,now()),
                   (:p,:u,:u,'PRUEBA borrada',NULL,'2026-10-31','07:00','pending',NULL,NULL)
        """), {"p": PACIENTE, "u": cuidadora})
        await c.execute(_t("UPDATE care_tasks SET deleted_at = now() WHERE title='PRUEBA borrada'"))

    print("--- listar tareas ---")
    r = await client.get(f"/api/v1/patients/{PACIENTE}/tasks", headers=token(cuidadora))
    check("lista las tareas", 200, r, campo="items")
    if r.status_code == 200:
        items = {i["title"]: i for i in r.json()["items"] if i["title"].startswith("PRUEBA")}
        n += 1
        if len(items) == 3:
            ok += 1; print("  OK   trae 3 y deja fuera la borrada")
        else:
            print(f"  FALLA trae {len(items)}: {sorted(items)}")
        n += 1
        if items.get("PRUEBA completada", {}).get("status") == "done":
            ok += 1; print("  OK   'completed' se devuelve como 'done'")
        else:
            print(f"  FALLA estado: {items.get('PRUEBA completada', {}).get('status')}")
        n += 1
        if items.get("PRUEBA con hora", {}).get("due", "").startswith("2026-10-31T09:30"):
            ok += 1; print("  OK   junta fecha y hora en 'due'")
        else:
            print(f"  FALLA due: {items.get('PRUEBA con hora', {}).get('due')}")
        n += 1
        if items.get("PRUEBA sin hora", {}).get("due", "").startswith("2026-10-31T00:00"):
            ok += 1; print("  OK   sin hora devuelve el inicio del dia")
        else:
            print(f"  FALLA due sin hora: {items.get('PRUEBA sin hora', {}).get('due')}")
        n += 1
        if items.get("PRUEBA con hora", {}).get("category") == "hygiene":
            ok += 1; print("  OK   devuelve la categoria")
        else:
            print(f"  FALLA categoria: {items.get('PRUEBA con hora', {}).get('category')}")
        n += 1
        fechas = [i["due"] for i in r.json()["items"]]
        if fechas == sorted(fechas):
            ok += 1; print("  OK   viene ordenado, lo mas proximo primero")
        else:
            print(f"  FALLA no viene ordenado: {fechas}")

    check("listar desde fuera del circulo", 404,
          await client.get(f"/api/v1/patients/{PACIENTE}/tasks", headers=token(AJENO)))
    check("sin autenticar", 401,
          await client.get(f"/api/v1/patients/{PACIENTE}/tasks"))

    print("--- crear tareas ---")
    familiar = rr.get("family")

    r = await client.post(f"/api/v1/patients/{PACIENTE}/tasks",
                          json={"title": "PRUEBA nueva con hora",
                                "description": "cambiar sabanas",
                                "due": "2026-11-05T15:45:00Z",
                                "category": "Higiene"},
                          headers=token(cuidadora))
    check("la cuidadora crea una tarea", 201, r, campo="id")
    if r.status_code == 201:
        d = r.json()
        n += 1
        if d["category"] == "hygiene":
            ok += 1; print("  OK   'Higiene' -> 'hygiene'")
        else:
            print(f"  FALLA categoria {d['category']}")
        n += 1
        if d["due"].startswith("2026-11-05T15:45") and d["status"] == "pending":
            ok += 1; print("  OK   guarda fecha y hora, nace pendiente")
        else:
            print(f"  FALLA {d['due']} / {d['status']}")

    for etiqueta, codigo in [("Medicación", "medication"), ("Alimentación", "food"),
                             ("Actividad física", "activity"), ("Compañía", "company"),
                             ("Otros", "other")]:
        rr2 = await client.post(f"/api/v1/patients/{PACIENTE}/tasks",
                                json={"title": f"PRUEBA {etiqueta}", "category": etiqueta},
                                headers=token(cuidadora))
        n += 1
        if rr2.status_code == 201 and rr2.json()["category"] == codigo:
            ok += 1; print(f"  OK   '{etiqueta}' -> '{codigo}'")
        else:
            print(f"  FALLA '{etiqueta}': {rr2.status_code} {rr2.text[:80]}")

    r = await client.post(f"/api/v1/patients/{PACIENTE}/tasks",
                          json={"title": "PRUEBA sin fecha"}, headers=token(cuidadora))
    check("sin fecha queda para hoy", 201, r)
    if r.status_code == 201:
        hoy = datetime.now(timezone.utc).date().isoformat()
        n += 1
        if r.json()["due"].startswith(hoy):
            ok += 1; print(f"  OK   la deja en el dia de hoy ({hoy})")
        else:
            print(f"  FALLA due {r.json()['due']}")

    r = await client.post(f"/api/v1/patients/{PACIENTE}/tasks",
                          json={"title": "PRUEBA medianoche",
                                "due": "2026-11-06T00:00:00Z"}, headers=token(cuidadora))
    check("fecha a medianoche se guarda sin hora", 201, r)
    if r.status_code == 201:
        async with _eng.begin() as c:
            hora = (await c.execute(_t(
                "SELECT due_time FROM care_tasks WHERE title='PRUEBA medianoche'"))).scalar()
        n += 1
        if hora is None:
            ok += 1; print("  OK   due_time quedo en NULL, no en 00:00")
        else:
            print(f"  FALLA due_time {hora}")

    check("categoria inventada", 422,
          await client.post(f"/api/v1/patients/{PACIENTE}/tasks",
                            json={"title": "x", "category": "Telequinesis"},
                            headers=token(cuidadora)))
    check("titulo de solo espacios", 422,
          await client.post(f"/api/v1/patients/{PACIENTE}/tasks",
                            json={"title": "   "}, headers=token(cuidadora)))
    check("crear desde fuera del circulo", 404,
          await client.post(f"/api/v1/patients/{PACIENTE}/tasks",
                            json={"title": "x"}, headers=token(AJENO)))

    if familiar:
        r = await client.post(f"/api/v1/patients/{PACIENTE}/tasks",
                              json={"title": "PRUEBA pedida por la familia"},
                              headers=token(familiar))
        check("el familiar crea una tarea", 201, r)
        if r.status_code == 201:
            async with _eng.begin() as c:
                asignada = (await c.execute(_t(
                    "SELECT assigned_to_user_id FROM care_tasks WHERE id=:i"),
                    {"i": r.json()["id"]})).scalar()
            n += 1
            if str(asignada) == cuidadora:
                ok += 1; print("  OK   queda asignada a la cuidadora del circulo")
            else:
                print(f"  FALLA quedo asignada a {asignada}")

    print("--- cambiar estado ---")
    r = await client.post(f"/api/v1/patients/{PACIENTE}/tasks",
                          json={"title": "PRUEBA para estados"}, headers=token(cuidadora))
    tid = r.json()["id"]

    for enviado, esperado in [("in_progress", "in_progress"), ("done", "done"),
                              ("pending", "pending"), ("cancelled", "cancelled")]:
        rs = await client.post(f"/api/v1/tasks/{tid}/status",
                               json={"status": enviado}, headers=token(cuidadora))
        n += 1
        if rs.status_code == 200 and rs.json()["status"] == esperado:
            ok += 1; print(f"  OK   '{enviado}' queda como '{esperado}'")
        else:
            print(f"  FALLA '{enviado}': {rs.status_code} {rs.text[:90]}")

    await client.post(f"/api/v1/tasks/{tid}/status", json={"status": "done"},
                      headers=token(cuidadora))
    async with _eng.begin() as c:
        fecha = (await c.execute(_t("SELECT completed_at FROM care_tasks WHERE id=:i"),
                                 {"i": tid})).scalar()
    n += 1
    if fecha is not None:
        ok += 1; print("  OK   al completar se llena completed_at")
    else:
        print("  FALLA completed_at quedo en NULL")

    await client.post(f"/api/v1/tasks/{tid}/status", json={"status": "pending"},
                      headers=token(cuidadora))
    async with _eng.begin() as c:
        fecha = (await c.execute(_t("SELECT completed_at FROM care_tasks WHERE id=:i"),
                                 {"i": tid})).scalar()
    n += 1
    if fecha is None:
        ok += 1; print("  OK   al volver a pendiente se limpia completed_at")
    else:
        print(f"  FALLA completed_at quedo en {fecha}")

    check("estado inventado", 422,
          await client.post(f"/api/v1/tasks/{tid}/status", json={"status": "terminadisima"},
                            headers=token(cuidadora)))
    check("tarea de un paciente ajeno al usuario", 404,
          await client.post(f"/api/v1/tasks/{tid}/status", json={"status": "done"},
                            headers=token(AJENO)))
    check("tarea inexistente", 404,
          await client.post("/api/v1/tasks/99999999-9999-4999-8999-999999999991/status",
                            json={"status": "done"}, headers=token(cuidadora)))
    check("sin autenticar", 401,
          await client.post(f"/api/v1/tasks/{tid}/status", json={"status": "done"}))

    # una tarea borrada no se puede marcar
    async with _eng.begin() as c:
        await c.execute(_t("UPDATE care_tasks SET deleted_at=now() WHERE id=:i"), {"i": tid})
    check("tarea borrada", 404,
          await client.post(f"/api/v1/tasks/{tid}/status", json={"status": "done"},
                            headers=token(cuidadora)))

    async with _eng.begin() as c:
        await c.execute(_t("DELETE FROM care_tasks WHERE title LIKE 'PRUEBA%'"))


async def run():
    rr = await roles()
    transport = httpx.ASGITransport(app=app)
    async with httpx.AsyncClient(transport=transport, base_url="http://testserver") as cl:
        await main(cl, rr)
    await _eng.dispose()
    print()
    print(f"resultado: {ok} de {n}")
    # Codigo de salida para que el CI lo vea.
    return 0 if ok == n else 1


import sys  # noqa: E402

sys.exit(asyncio.run(run()))
