"""Pruebas de la idempotencia de reenvios (RF-81).

La app guarda las acciones que no pudo mandar y las reintenta cuando vuelve la
senal. Lo que estas pruebas cuidan es que ese reintento no deje dos tomas
registradas ni dos mensajes en el chat, y que al mismo tiempo no cambie nada
para una peticion normal, que no manda clave.
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
import inspect  # noqa: E402
import uuid  # noqa: E402
from datetime import datetime, timedelta, timezone  # noqa: E402

import httpx  # noqa: E402
from fastapi import FastAPI  # noqa: E402
from jose import jwt  # noqa: E402
from sqlalchemy import text as _t  # noqa: E402

from app.config import get_settings  # noqa: E402
from app.db import engine as _eng  # noqa: E402
from app.errors import register_error_handlers  # noqa: E402
from app.idempotencia import Idem  # noqa: E402
from app.routers import chat, checkins, files, logbook, medications, tasks  # noqa: E402

app = FastAPI()
register_error_handlers(app)
for r in (files.router, logbook.router, chat.router, tasks.router,
          checkins.router, medications.router):
    app.include_router(r)

PACIENTE = "33333333-3333-4333-8333-333333333333"
MARCA = "PRUEBA-IDEM"

n = ok = 0


def check(nombre, condicion, extra=None):
    global n, ok
    n += 1
    if condicion:
        ok += 1
        print(f"  ok   {nombre}")
    else:
        print(f"  FALLA {nombre}" + (f"  {extra}" if extra is not None else ""))


def token(uid):
    cfg = get_settings()
    t = jwt.encode({"sub": uid, "type": "access",
                    "exp": int((datetime.now(timezone.utc)
                                + timedelta(minutes=10)).timestamp())},
                   cfg.jwt_secret, algorithm=cfg.jwt_algorithm)
    return {"Authorization": f"Bearer {t}"}


def clave():
    return str(uuid.uuid4())


async def sql(q, **p):
    async with _eng.begin() as c:
        return await c.execute(_t(q), p)


async def cuantas(tabla, donde, **p):
    r = await sql(f"SELECT count(*) FROM {tabla} WHERE {donde}", **p)
    return r.scalar()


async def miembros():
    r = await sql("SELECT user_id, role FROM patient_members "
                  " WHERE patient_id = :p AND removed_at IS NULL", p=PACIENTE)
    return {m["role"]: str(m["user_id"]) for m in r.mappings().all()}


async def limpiar():
    await sql("DELETE FROM idempotency_keys WHERE path LIKE '%' || :p || '%'",
              p=PACIENTE)
    await sql("DELETE FROM care_observations WHERE note LIKE :m", m=f"%{MARCA}%")
    # Los acuses van antes que el mensaje: la FK es RESTRICT.
    await sql("DELETE FROM message_receipts WHERE message_id IN "
              " (SELECT id FROM messages WHERE body LIKE :m)", m=f"%{MARCA}%")
    await sql("DELETE FROM messages WHERE body LIKE :m", m=f"%{MARCA}%")
    await sql("DELETE FROM care_tasks WHERE title LIKE :m", m=f"%{MARCA}%")


# ---------------------------------------------------------------------------
# Las rutas que la cola de la app reenvia tienen que aceptar la clave. Si
# alguien agrega una accion a la cola y olvida esto, el reenvio duplica en
# silencio, que es exactamente el modo de falla que nadie nota hasta que hay
# dos tomas registradas en el expediente.
# ---------------------------------------------------------------------------
RUTAS_DE_LA_COLA = [
    ("POST", "/api/v1/doses/{dose_id}/log"),
    ("POST", "/api/v1/patients/{patient_id}/observations"),
    ("POST", "/api/v1/patients/{patient_id}/incidents"),
    ("POST", "/api/v1/patients/{patient_id}/handover-notes"),
    ("POST", "/api/v1/patients/{patient_id}/tasks"),
    ("POST", "/api/v1/tasks/{task_id}/status"),
    ("PUT",  "/api/v1/patients/{patient_id}/checkins/today"),
    ("POST", "/api/v1/patients/{patient_id}/chat/messages"),
]


def revisar_rutas():
    print("--- las rutas de la cola aceptan clave de reenvio ---")
    porRuta = {}
    for r in app.routes:
        for m in getattr(r, "methods", []) or []:
            porRuta[(m, r.path)] = r.endpoint
    for metodo, ruta in RUTAS_DE_LA_COLA:
        fn = porRuta.get((metodo, ruta))
        if fn is None:
            check(f"{metodo} {ruta} existe", False, "la ruta no esta montada")
            continue
        tiene = any(p.annotation is Idem
                    for p in inspect.signature(fn).parameters.values())
        check(f"{metodo} {ruta}", tiene, "le falta la dependencia idempotencia")


async def main(client, roles):
    cuidadora = roles.get("caregiver")
    familiar = roles.get("family")
    anciano = roles.get("elder")
    if not cuidadora or not familiar:
        check("el paciente tiene cuidadora y familiar", False, sorted(roles))
        return

    hc = token(cuidadora)
    hf = token(familiar)
    await limpiar()

    print("--- sin clave, el comportamiento es el de antes ---")
    cuerpo = {"text": f"{MARCA} sin clave", "category": "General"}
    r1 = await client.post(f"/api/v1/patients/{PACIENTE}/observations",
                           json=cuerpo, headers=hc)
    r2 = await client.post(f"/api/v1/patients/{PACIENTE}/observations",
                           json=cuerpo, headers=hc)
    check("dos envios sin clave dejan dos observaciones",
          r1.status_code == 201 and r2.status_code == 201
          and r1.json()["id"] != r2.json()["id"],
          (r1.status_code, r2.status_code))

    print("--- con la misma clave, el reenvio no repite ---")
    k = clave()
    cuerpo = {"text": f"{MARCA} con clave", "category": "General"}
    r1 = await client.post(f"/api/v1/patients/{PACIENTE}/observations",
                           json=cuerpo, headers={**hc, "Idempotency-Key": k})
    r2 = await client.post(f"/api/v1/patients/{PACIENTE}/observations",
                           json=cuerpo, headers={**hc, "Idempotency-Key": k})
    check("el primer envio la registra", r1.status_code == 201, r1.text[:120])
    check("el reenvio responde igual que el primero",
          r2.status_code == 201 and r2.json() == r1.json(), r2.text[:120])
    check("y no quedo una segunda observacion",
          await cuantas("care_observations", "note = :t",
                        t=f"{MARCA} con clave") == 1)

    print("--- el cuerpo distinto no vuelve a escribir ---")
    # Caso real de la cola: el usuario corrigio el texto y la cola alcanzo a
    # mandar el primero. La clave manda, no el cuerpo.
    r3 = await client.post(f"/api/v1/patients/{PACIENTE}/observations",
                           json={"text": f"{MARCA} otro texto",
                                 "category": "Higiene"},
                           headers={**hc, "Idempotency-Key": k})
    check("se devuelve la respuesta de la primera vez",
          r3.status_code == 201 and r3.json() == r1.json(), r3.text[:120])
    check("y no se escribio el texto nuevo",
          await cuantas("care_observations", "note = :t",
                        t=f"{MARCA} otro texto") == 0)

    print("--- la clave es de quien la uso ---")
    k2 = clave()
    cuerpo = {"text": f"{MARCA} de cada uno", "category": "General"}
    a = await client.post(f"/api/v1/patients/{PACIENTE}/observations",
                          json=cuerpo, headers={**hc, "Idempotency-Key": k2})
    b = await client.post(f"/api/v1/patients/{PACIENTE}/observations",
                          json=cuerpo, headers={**hf, "Idempotency-Key": k2})
    check("la misma clave de otra persona no devuelve su respuesta",
          a.status_code == 201 and b.status_code == 201
          and a.json()["id"] != b.json()["id"],
          (a.status_code, b.status_code))

    print("--- una clave no sirve para otra accion ---")
    k3 = clave()
    await client.post(f"/api/v1/patients/{PACIENTE}/observations",
                      json={"text": f"{MARCA} reuso", "category": "General"},
                      headers={**hc, "Idempotency-Key": k3})
    r = await client.post(f"/api/v1/patients/{PACIENTE}/chat/messages",
                          json={"type": "text", "text": f"{MARCA} reuso"},
                          headers={**hc, "Idempotency-Key": k3})
    check("reusar la clave en otra ruta da 422",
          r.status_code == 422
          and r.json().get("error", {}).get("code") == "IDEMPOTENCY_KEY_REUSED",
          r.text[:140])
    check("y no mando el mensaje",
          await cuantas("messages", "body = :t", t=f"{MARCA} reuso") == 0)

    print("--- claves mal formadas ---")
    for mala, como in [("", "vacia"), ("x" * 81, "demasiado larga"),
                       ("   ", "solo espacios")]:
        r = await client.post(f"/api/v1/patients/{PACIENTE}/observations",
                              json={"text": f"{MARCA} mala", "category": "General"},
                              headers={**hc, "Idempotency-Key": mala})
        check(f"una clave {como} da 422",
              r.status_code == 422
              and r.json().get("error", {}).get("code") == "INVALID_IDEMPOTENCY_KEY",
              r.text[:120])

    print("--- si la accion falla, la clave no se quema ---")
    k4 = clave()
    r = await client.post(f"/api/v1/patients/{PACIENTE}/observations",
                          json={"text": "", "category": "General"},
                          headers={**hc, "Idempotency-Key": k4})
    check("un cuerpo invalido se rechaza", r.status_code == 422, r.status_code)
    r = await client.post(f"/api/v1/patients/{PACIENTE}/observations",
                          json={"text": f"{MARCA} reintento bueno",
                                "category": "General"},
                          headers={**hc, "Idempotency-Key": k4})
    check("y el reintento con la misma clave si entra",
          r.status_code == 201, r.text[:140])

    print("--- el chat tampoco duplica ---")
    k5 = clave()
    envio = {"type": "text", "text": f"{MARCA} hola"}
    m1 = await client.post(f"/api/v1/patients/{PACIENTE}/chat/messages",
                           json=envio, headers={**hc, "Idempotency-Key": k5})
    m2 = await client.post(f"/api/v1/patients/{PACIENTE}/chat/messages",
                           json=envio, headers={**hc, "Idempotency-Key": k5})
    check("el mensaje se manda una vez",
          m1.status_code == 201 and m2.status_code == 201
          and m1.json()["id"] == m2.json()["id"],
          (m1.status_code, m2.status_code))
    check("y hay un solo mensaje en la conversacion",
          await cuantas("messages", "body = :t", t=f"{MARCA} hola") == 1)

    print("--- las tareas tampoco ---")
    k6 = clave()
    envio = {"title": f"{MARCA} regar las plantas", "category": "activity"}
    t1 = await client.post(f"/api/v1/patients/{PACIENTE}/tasks",
                           json=envio, headers={**hc, "Idempotency-Key": k6})
    t2 = await client.post(f"/api/v1/patients/{PACIENTE}/tasks",
                           json=envio, headers={**hc, "Idempotency-Key": k6})
    check("la tarea se crea una vez",
          t1.status_code == 201 and t2.status_code == 201
          and t1.json()["id"] == t2.json()["id"],
          (t1.status_code, t2.status_code))
    check("y hay una sola tarea",
          await cuantas("care_tasks", "title = :t", t=envio["title"]) == 1)

    print("--- el check-in del dia no se pisa con un reenvio tardio ---")
    if anciano:
        antes = (await sql(
            "SELECT mood, pain_level, slept_well, ate_well, note, source "
            "  FROM daily_checkins "
            " WHERE patient_id = :p AND checkin_date = current_date",
            p=PACIENTE)).mappings().first()
        try:
            he = token(anciano)
            k7 = clave()
            viejo = {"mood": "bad", "pain_level": 5, "slept_well": False,
                     "ate_well": False}
            c1 = await client.put(
                f"/api/v1/patients/{PACIENTE}/checkins/today",
                json=viejo, headers={**he, "Idempotency-Key": k7})
            # La persona corrige su respuesta en la pantalla, sin clave.
            await client.put(f"/api/v1/patients/{PACIENTE}/checkins/today",
                             json={"mood": "good", "pain_level": 0,
                                   "slept_well": True, "ate_well": True},
                             headers=he)
            # Y recien entonces la cola logra mandar el primero.
            c2 = await client.put(
                f"/api/v1/patients/{PACIENTE}/checkins/today",
                json=viejo, headers={**he, "Idempotency-Key": k7})
            check("el reenvio devuelve la respuesta vieja sin escribir",
                  c1.status_code == 200 and c2.status_code == 200
                  and c2.json() == c1.json(),
                  (c1.status_code, c2.status_code))
            ahora = (await sql(
                "SELECT mood FROM daily_checkins "
                " WHERE patient_id = :p AND checkin_date = current_date",
                p=PACIENTE)).scalar()
            check("y la correccion de la persona sigue en pie",
                  ahora == "good", ahora)
        finally:
            if antes is None:
                await sql("DELETE FROM daily_checkins WHERE patient_id = :p "
                          "  AND checkin_date = current_date", p=PACIENTE)
            else:
                await sql(
                    "UPDATE daily_checkins "
                    "   SET mood = :m, pain_level = :pl, slept_well = :s, "
                    "       ate_well = :a, note = :nota, source = :src "
                    " WHERE patient_id = :p AND checkin_date = current_date",
                    p=PACIENTE, m=antes["mood"], pl=antes["pain_level"],
                    s=antes["slept_well"], a=antes["ate_well"],
                    nota=antes["note"], src=antes["source"])
    else:
        check("el paciente tiene cuenta de adulto mayor", False, sorted(roles))

    print("--- el barrido borra las viejas y deja las nuevas ---")
    from app.maintenance import (DIAS_CLAVES_DE_REENVIO,
                                 barrer_claves_de_reenvio)
    await sql(
        "INSERT INTO idempotency_keys (user_id, idem_key, method, path, "
        "    status_code, response_body, created_at) "
        "VALUES (:u, :k, 'POST', :ruta, 201, '{}'::jsonb, "
        "        now() - make_interval(days => :d))",
        u=cuidadora, k=clave(), ruta=f"/vieja/{PACIENTE}",
        d=DIAS_CLAVES_DE_REENVIO + 1)
    nuevas_antes = await cuantas(
        "idempotency_keys", "path LIKE '%' || :p || '%' "
        "  AND created_at > now() - make_interval(days => :d)",
        p=PACIENTE, d=DIAS_CLAVES_DE_REENVIO)
    await barrer_claves_de_reenvio(verbose=False)
    check("la vieja se borro",
          await cuantas("idempotency_keys", "path = :ruta",
                        ruta=f"/vieja/{PACIENTE}") == 0)
    check("las de hoy siguen ahi",
          await cuantas(
              "idempotency_keys", "path LIKE '%' || :p || '%' "
              "  AND created_at > now() - make_interval(days => :d)",
              p=PACIENTE, d=DIAS_CLAVES_DE_REENVIO) == nuevas_antes
          and nuevas_antes > 0, nuevas_antes)

    await limpiar()


async def run():
    revisar_rutas()
    roles = await miembros()
    transport = httpx.ASGITransport(app=app)
    async with httpx.AsyncClient(transport=transport,
                                 base_url="http://testserver") as cl:
        try:
            await main(cl, roles)
        finally:
            await limpiar()
    await _eng.dispose()
    print()
    print(f"{ok} ok, {n - ok} fallas")
    return 0 if ok == n else 1


_sys.exit(asyncio.run(run()))
