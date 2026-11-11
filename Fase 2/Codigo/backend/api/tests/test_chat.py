"""Pruebas del chat del circulo de cuidado."""
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
from app.routers import chat, files  # noqa: E402

app = FastAPI()
register_error_handlers(app)
app.include_router(files.router)
app.include_router(chat.router)

PACIENTE = "33333333-3333-4333-8333-333333333333"
from _ajeno import AJENO  # noqa: E402  (cuenta sin circulo, creada y borrada por la prueba)
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
        print(f"       {resp.text[:160]}")


async def roles():
    async with _eng.begin() as c:
        return {m["role"]: str(m["user_id"]) for m in (await c.execute(_t(
            "SELECT user_id, role FROM patient_members WHERE patient_id=:p "
            "AND removed_at IS NULL"), {"p": PACIENTE})).mappings().all()}


async def main(client, rr):
    global n, ok
    familiar, cuidadora = rr["family"], rr["caregiver"]

    # mensajes de prueba directo en la tabla
    async with _eng.begin() as c:
        conv = (await c.execute(_t(
            "SELECT id FROM conversations WHERE patient_id=:p AND type='human'"),
            {"p": PACIENTE})).scalar()
        if conv is None:
            conv = (await c.execute(_t(
                "INSERT INTO conversations (patient_id, type) VALUES (:p,'human') "
                "RETURNING id"), {"p": PACIENTE})).scalar()
        await c.execute(_t("DELETE FROM message_receipts WHERE message_id IN "
                           "(SELECT id FROM messages WHERE body LIKE 'PRUEBA%')"))
        await c.execute(_t("DELETE FROM messages WHERE body LIKE 'PRUEBA%'"))
        ids = []
        for i, (quien, txt) in enumerate([
                (familiar, "PRUEBA hola, como amanecio hoy"),
                (cuidadora, "PRUEBA bien, desayuno completo"),
                (familiar, "PRUEBA que bueno, gracias")]):
            mid = (await c.execute(_t(
                "INSERT INTO messages (conversation_id, sender_id, kind, body, created_at) "
                "VALUES (:c,:s,'text',:b, now() - make_interval(mins => :m)) RETURNING id"),
                {"c": str(conv), "s": quien, "b": txt, "m": 10 - i * 3})).scalar()
            ids.append(str(mid))
        # el primero leido por la cuidadora
        await c.execute(_t(
            "INSERT INTO message_receipts (message_id, recipient_id, read_at) "
            "VALUES (:m,:u,now())"), {"m": ids[0], "u": cuidadora})

    print("--- leer el chat ---")
    r = await client.get(f"/api/v1/patients/{PACIENTE}/chat/messages",
                         headers=token(familiar))
    check("lista los mensajes", 200, r, campo="items")
    if r.status_code == 200:
        items = [i for i in r.json()["items"] if (i["text"] or "").startswith("PRUEBA")]
        print(f"       mensajes de prueba: {len(items)}")
        for i in items:
            print(f"       [{i['sender_role']:9}] {i['sender_name']:14} {i['text'][:34]}")
        n += 1
        if len(items) == 3:
            ok += 1; print("  OK   trae los tres")
        else:
            print(f"  FALLA trae {len(items)}")
        fechas = [i["created_at"] for i in items]
        n += 1
        if fechas == sorted(fechas, reverse=True):
            ok += 1; print("  OK   del mas nuevo al mas viejo")
        else:
            print("  FALLA no viene ordenado")
        n += 1
        if all(i["sender_role"] in ("family", "caregiver", "doctor", "elder") for i in items):
            ok += 1; print("  OK   trae el rol de cada emisor")
        else:
            print(f"  FALLA roles {[i['sender_role'] for i in items]}")
        viejo = [i for i in items if "amanecio" in (i["text"] or "")][0]
        n += 1
        if cuidadora in viejo["read_by"]:
            ok += 1; print("  OK   dice quien ya lo leyo")
        else:
            print(f"  FALLA read_by {viejo['read_by']}")
        n += 1
        nuevos = [i for i in items if "gracias" in (i["text"] or "")]
        if nuevos and nuevos[0]["read_by"] == []:
            ok += 1; print("  OK   uno sin leer trae la lista vacia, no nulo")
        else:
            print("  FALLA read_by del no leido")

    # paginacion
    r = await client.get(f"/api/v1/patients/{PACIENTE}/chat/messages?limit=2",
                         headers=token(familiar))
    n += 1
    if len(r.json()["items"]) == 2:
        ok += 1; print("  OK   respeta el limite")
    else:
        print(f"  FALLA limite: {len(r.json()['items'])}")

    primera = r.json()["items"]
    corte = primera[-1]["created_at"]
    r2 = await client.get(f"/api/v1/patients/{PACIENTE}/chat/messages?before={corte}",
                          headers=token(familiar))
    n += 1
    ids_1 = {i["id"] for i in primera}
    ids_2 = {i["id"] for i in r2.json()["items"]}
    if not (ids_1 & ids_2) and r2.json()["items"]:
        ok += 1; print("  OK   'before' pagina hacia atras sin repetir")
    else:
        print(f"  FALLA paginacion: {len(ids_1 & ids_2)} repetidos")

    print("--- enviar mensajes ---")
    r = await client.post(f"/api/v1/patients/{PACIENTE}/chat/messages",
                          json={"type": "text", "text": "PRUEBA voy en camino"},
                          headers=token(cuidadora))
    check("envia un mensaje de texto", 201, r, campo="id")
    if r.status_code == 201:
        d = r.json()
        n += 1
        if d["sender_role"] == "caregiver" and d["text"] == "PRUEBA voy en camino":
            ok += 1; print("  OK   queda con su texto y el rol de quien escribe")
        else:
            print(f"  FALLA {d}")
        async with _eng.begin() as c:
            acuses = (await c.execute(_t(
                "SELECT count(*) FROM message_receipts WHERE message_id=:m"),
                {"m": d["id"]})).scalar()
            miembros = (await c.execute(_t(
                "SELECT count(*) FROM patient_members WHERE patient_id=:p "
                "AND removed_at IS NULL AND user_id <> :u"),
                {"p": PACIENTE, "u": cuidadora})).scalar()
        n += 1
        if acuses == miembros and acuses > 0:
            ok += 1; print(f"  OK   crea un acuse por cada otro miembro ({acuses})")
        else:
            print(f"  FALLA {acuses} acuses para {miembros} miembros")
        n += 1
        if d["read_by"] == []:
            ok += 1; print("  OK   nace sin leer por nadie")
        else:
            print(f"  FALLA read_by {d['read_by']}")

    # foto
    up = await client.post("/api/v1/uploads",
                           json={"filename": "chat.jpg", "content_type": "image/jpeg",
                                 "kind": "photo", "size": 24, "patient_id": PACIENTE},
                           headers=token(familiar))
    du = up.json()
    await client.put(du["upload_url"].replace("http://testserver", ""),
                     content=b"\xff\xd8\xff\xe0" + b"x" * 18 + b"\xff\xd9",
                     headers={"Content-Type": "image/jpeg"})
    r = await client.post(f"/api/v1/patients/{PACIENTE}/chat/messages",
                          json={"type": "photo", "media_url": du["file_url"]},
                          headers=token(familiar))
    check("envia una foto", 201, r)
    if r.status_code == 201:
        n += 1
        if r.json()["media_url"] and r.json()["type"] == "photo":
            ok += 1; print("  OK   la foto vuelve con su url")
        else:
            print(f"  FALLA {r.json()}")
        async with _eng.begin() as c:
            await c.execute(_t("UPDATE messages SET body='PRUEBA foto' WHERE id=:i"),
                            {"i": r.json()["id"]})

    check("texto vacio", 422,
          await client.post(f"/api/v1/patients/{PACIENTE}/chat/messages",
                            json={"type": "text", "text": "   "}, headers=token(familiar)))
    check("texto sin texto", 422,
          await client.post(f"/api/v1/patients/{PACIENTE}/chat/messages",
                            json={"type": "text"}, headers=token(familiar)))
    check("foto sin archivo", 422,
          await client.post(f"/api/v1/patients/{PACIENTE}/chat/messages",
                            json={"type": "photo"}, headers=token(familiar)))
    check("nota de voz sin archivo", 422,
          await client.post(f"/api/v1/patients/{PACIENTE}/chat/messages",
                            json={"type": "voice"}, headers=token(familiar)))
    check("tipo inventado", 422,
          await client.post(f"/api/v1/patients/{PACIENTE}/chat/messages",
                            json={"type": "telepatia", "text": "x"},
                            headers=token(familiar)))
    check("archivo de otro paciente", 422,
          await client.post(f"/api/v1/patients/{PACIENTE}/chat/messages",
                            json={"type": "photo",
                                  "media_url": "http://testserver/api/v1/files/"
                                               "99999999-9999-4999-8999-999999999991"},
                            headers=token(familiar)))
    check("enviar desde fuera del circulo", 404,
          await client.post(f"/api/v1/patients/{PACIENTE}/chat/messages",
                            json={"type": "text", "text": "x"}, headers=token(AJENO)))

    print("--- marcar como leido ---")
    async with _eng.begin() as c:
        pend_antes = (await c.execute(_t(
            "SELECT count(*) FROM message_receipts mr JOIN messages m ON m.id=mr.message_id "
            "JOIN conversations cv ON cv.id=m.conversation_id "
            "WHERE cv.patient_id=:p AND mr.recipient_id=:u AND mr.read_at IS NULL"),
            {"p": PACIENTE, "u": familiar})).scalar()

    r = await client.post(f"/api/v1/patients/{PACIENTE}/chat/read",
                          headers=token(familiar))
    check("marca el chat como leido", 200, r, campo="marked")
    if r.status_code == 200:
        n += 1
        if r.json()["marked"] == pend_antes and pend_antes > 0:
            ok += 1; print(f"  OK   marco los {pend_antes} que estaban sin leer")
        else:
            print(f"  FALLA marco {r.json()['marked']} de {pend_antes}")

        async with _eng.begin() as c:
            quedan = (await c.execute(_t(
                "SELECT count(*) FROM message_receipts mr JOIN messages m ON m.id=mr.message_id "
                "JOIN conversations cv ON cv.id=m.conversation_id "
                "WHERE cv.patient_id=:p AND mr.recipient_id=:u AND mr.read_at IS NULL"),
                {"p": PACIENTE, "u": familiar})).scalar()
        n += 1
        if quedan == 0:
            ok += 1; print("  OK   no queda ninguno pendiente")
        else:
            print(f"  FALLA quedan {quedan}")

        # la segunda vez no mueve nada
        async with _eng.begin() as c:
            antes_h = (await c.execute(_t(
                "SELECT max(mr.read_at) FROM message_receipts mr "
                "JOIN messages m ON m.id=mr.message_id "
                "JOIN conversations cv ON cv.id=m.conversation_id "
                "WHERE cv.patient_id=:p AND mr.recipient_id=:u"),
                {"p": PACIENTE, "u": familiar})).scalar()
        r2 = await client.post(f"/api/v1/patients/{PACIENTE}/chat/read",
                               headers=token(familiar))
        async with _eng.begin() as c:
            despues_h = (await c.execute(_t(
                "SELECT max(mr.read_at) FROM message_receipts mr "
                "JOIN messages m ON m.id=mr.message_id "
                "JOIN conversations cv ON cv.id=m.conversation_id "
                "WHERE cv.patient_id=:p AND mr.recipient_id=:u"),
                {"p": PACIENTE, "u": familiar})).scalar()
        n += 1
        if r2.json()["marked"] == 0 and antes_h == despues_h:
            ok += 1; print("  OK   marcar de nuevo no mueve la hora de lectura")
        else:
            print(f"  FALLA marco {r2.json()['marked']}, hora {antes_h} -> {despues_h}")

        # y el chat lo refleja
        lista = (await client.get(f"/api/v1/patients/{PACIENTE}/chat/messages",
                                  headers=token(cuidadora))).json()["items"]
        suyos = [i for i in lista if i["sender_id"] == cuidadora]
        n += 1
        if suyos and familiar in suyos[0]["read_by"]:
            ok += 1; print("  OK   el chat muestra que el familiar ya lo leyo")
        else:
            print("  FALLA no aparece en read_by")

    check("marcar desde fuera del circulo", 404,
          await client.post(f"/api/v1/patients/{PACIENTE}/chat/read", headers=token(AJENO)))
    check("marcar sin autenticar", 401,
          await client.post(f"/api/v1/patients/{PACIENTE}/chat/read"))

    check("limite fuera de rango", 422,
          await client.get(f"/api/v1/patients/{PACIENTE}/chat/messages?limit=5000",
                           headers=token(familiar)))
    check("leer desde fuera del circulo", 404,
          await client.get(f"/api/v1/patients/{PACIENTE}/chat/messages",
                           headers=token(AJENO)))
    check("sin autenticar", 401,
          await client.get(f"/api/v1/patients/{PACIENTE}/chat/messages"))


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
