"""Pruebas del asistente."""
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
from app.routers import assistant  # noqa: E402
from app import assistant_provider as ap  # noqa: E402


class ProveedorFalso(ap.AssistantProvider):
    """Proveedor de prueba. El adaptador existe justamente para esto."""

    def __init__(self):
        self.llamadas = []
        self.falla = False

    @property
    def disponible(self):
        return True

    async def responder(self, *, pregunta, contexto, rol, historial):
        self.llamadas.append({"pregunta": pregunta, "contexto": contexto,
                              "rol": rol, "historial": historial})
        if self.falla:
            raise RuntimeError("el proveedor se cayo")
        return ap.Respuesta(texto=f"Respuesta a: {pregunta}")


FALSO = ProveedorFalso()

app = FastAPI()
register_error_handlers(app)
app.include_router(assistant.router)

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
        print(f"       {resp.text[:170]}")


async def roles():
    async with _eng.begin() as c:
        return {m["role"]: str(m["user_id"]) for m in (await c.execute(_t(
            "SELECT user_id, role FROM patient_members WHERE patient_id=:p "
            "AND removed_at IS NULL"), {"p": PACIENTE})).mappings().all()}


async def main(client, rr):
    global n, ok
    familiar, cuidadora = rr["family"], rr["caregiver"]

    async with _eng.begin() as c:
        await c.execute(_t("DELETE FROM assistant_citations WHERE query_id IN "
                           "(SELECT id FROM assistant_queries WHERE query_text LIKE 'PRUEBA%')"))
        await c.execute(_t("DELETE FROM assistant_queries WHERE query_text LIKE 'PRUEBA%'"))

    print("--- listar conversaciones ---")
    r = await client.get(f"/api/v1/patients/{PACIENTE}/assistant/conversations",
                         headers=token(familiar))
    check("lista sin reventar aunque no haya ninguna", 200, r, campo="items")
    antes = len(r.json().get("items", []))

    async with _eng.begin() as c:
        existe = (await c.execute(_t(
            "SELECT id FROM conversations WHERE patient_id=:p AND type='assistant' "
            "AND user_id=:u"), {"p": PACIENTE, "u": familiar})).scalar()
        if existe is None:
            existe = (await c.execute(_t(
                "INSERT INTO conversations (patient_id, type, user_id, title, last_message_at) "
                "VALUES (:p,'assistant',:u,'PRUEBA sobre sus remedios', now()) RETURNING id"),
                {"p": PACIENTE, "u": familiar})).scalar()
        else:
            await c.execute(_t("UPDATE conversations SET title='PRUEBA sobre sus remedios' "
                               "WHERE id=:i"), {"i": str(existe)})

    r = await client.get(f"/api/v1/patients/{PACIENTE}/assistant/conversations",
                         headers=token(familiar))
    check("la trae", 200, r)
    if r.status_code == 200:
        items = r.json()["items"]
        n += 1
        if any(i["title"] == "PRUEBA sobre sus remedios" for i in items):
            ok += 1; print(f"  OK   con su titulo ({len(items)} conversacion)")
        else:
            print(f"  FALLA titulos {[i['title'] for i in items]}")

    # la de otra persona no se ve
    r2 = await client.get(f"/api/v1/patients/{PACIENTE}/assistant/conversations",
                          headers=token(cuidadora))
    n += 1
    if all(i["id"] != str(existe) for i in r2.json()["items"]):
        ok += 1; print("  OK   la conversacion de otra persona no se ve")
    else:
        print("  FALLA se filtro la conversacion ajena")

    # sin titulo cae en el valor por defecto
    async with _eng.begin() as c:
        await c.execute(_t("UPDATE conversations SET title=NULL WHERE id=:i"),
                        {"i": str(existe)})
    r = await client.get(f"/api/v1/patients/{PACIENTE}/assistant/conversations",
                         headers=token(familiar))
    n += 1
    if any(i["title"] == "Conversacion" for i in r.json()["items"]):
        ok += 1; print("  OK   una sin titulo sale como 'Conversacion', no vacia")
    else:
        print(f"  FALLA {[i['title'] for i in r.json()['items']]}")
    async with _eng.begin() as c:
        await c.execute(_t("UPDATE conversations SET title='PRUEBA sobre sus remedios' "
                           "WHERE id=:i"), {"i": str(existe)})

    print("--- preguntar: sin proveedor ---")
    ap.get_assistant.cache_clear()
    r = await client.post(f"/api/v1/patients/{PACIENTE}/assistant/messages",
                          json={"text": "PRUEBA como durmio anoche"},
                          headers=token(familiar))
    check("sin proveedor responde 503, no una respuesta inventada", 503, r)
    if r.status_code == 503:
        n += 1
        if r.json()["error"]["code"] == "ASSISTANT_UNAVAILABLE":
            ok += 1; print("  OK   con un codigo que la pantalla puede distinguir")
        else:
            print(f"  FALLA codigo {r.json()['error']['code']}")
        async with _eng.begin() as c:
            guardadas = (await c.execute(_t(
                "SELECT count(*) FROM assistant_queries WHERE query_text LIKE 'PRUEBA%'"))).scalar()
        n += 1
        if guardadas == 0:
            ok += 1; print("  OK   no guarda nada si no pudo responder")
        else:
            print(f"  FALLA guardo {guardadas}")

    print("--- preguntar: con proveedor ---")
    assistant_mod = assistant
    ap.get_assistant = lambda: FALSO

    # la cuidadora de demo tiene premium, con cupo de 200 al mes
    async with _eng.begin() as c:
        await c.execute(_t("DELETE FROM assistant_citations WHERE query_id IN "
                           "(SELECT id FROM assistant_queries WHERE query_text LIKE 'PRUEBA%')"))
        await c.execute(_t("DELETE FROM assistant_queries WHERE query_text LIKE 'PRUEBA%'"))
        sid = (await c.execute(_t(
            "SELECT id FROM subscriptions WHERE user_id=:u"), {"u": cuidadora})).scalar()
        await c.execute(_t("DELETE FROM usage_counters WHERE subscription_id=:s"),
                        {"s": str(sid)})

    r = await client.post(f"/api/v1/patients/{PACIENTE}/assistant/messages",
                          json={"text": "PRUEBA que medicamentos toma"},
                          headers=token(cuidadora))
    check("responde", 201, r, campo="message")
    if r.status_code == 201:
        d = r.json()
        print(f"       respuesta: {d['message']['text'][:60]}")
        print(f"       fuentes  : {[c['label'] for c in d['message']['citations']]}")
        n += 1
        if d["message"]["role"] == "assistant" and d["message"]["text"]:
            ok += 1; print("  OK   viene con rol assistant y texto")
        else:
            print(f"  FALLA {d['message']}")
        n += 1
        ctxt = FALSO.llamadas[-1]["contexto"]
        if "Medicamentos vigentes" in ctxt and "Paciente:" in ctxt:
            ok += 1; print("  OK   el contexto trae el expediente armado")
        else:
            print(f"  FALLA contexto: {ctxt[:120]}")
        n += 1
        if FALSO.llamadas[-1]["rol"] == "caregiver":
            ok += 1; print("  OK   le pasa el rol de quien pregunta")
        else:
            print(f"  FALLA rol {FALSO.llamadas[-1]['rol']}")
        n += 1
        etiquetas = [c["label"] for c in d["message"]["citations"]]
        if etiquetas and len(etiquetas) == len(set(etiquetas)):
            ok += 1; print("  OK   cita cada fuente una sola vez")
        else:
            print(f"  FALLA citas {etiquetas}")

        async with _eng.begin() as c:
            fila = (await c.execute(_t(
                "SELECT frozen_role_name, latency_ms FROM assistant_queries "
                "WHERE query_text='PRUEBA que medicamentos toma'"))).mappings().first()
            citas = (await c.execute(_t(
                "SELECT count(*) FROM assistant_citations ac JOIN assistant_queries q "
                "ON q.id=ac.query_id WHERE q.query_text='PRUEBA que medicamentos toma'"))).scalar()
        n += 1
        if fila and fila["frozen_role_name"] == "caregiver" and fila["latency_ms"] >= 0:
            ok += 1; print(f"  OK   guarda el rol congelado y la latencia ({fila['latency_ms']} ms)")
        else:
            print(f"  FALLA {dict(fila) if fila else None}")
        n += 1
        if citas > 0:
            ok += 1; print(f"  OK   guarda las fuentes en assistant_citations ({citas})")
        else:
            print("  FALLA sin citas guardadas")

        conv_id = d["conversation_id"]
        # la segunda pregunta usa la misma conversacion y manda historial
        r2 = await client.post(f"/api/v1/patients/{PACIENTE}/assistant/messages",
                               json={"text": "PRUEBA y como durmio",
                                     "conversation_id": conv_id},
                               headers=token(cuidadora))
        n += 1
        if r2.status_code == 201 and r2.json()["conversation_id"] == conv_id:
            ok += 1; print("  OK   sigue en la misma conversacion")
        else:
            print(f"  FALLA {r2.status_code}")
        # La conversacion puede traer consultas previas de los datos de
        # demo, asi que se mide que el historial haya CRECIDO en el par de
        # la pregunta anterior, no que valga exactamente dos.
        n += 1
        crecio = len(FALSO.llamadas[-1]["historial"]) - len(FALSO.llamadas[-2]["historial"])
        if crecio == 2 and len(FALSO.llamadas[-1]["historial"]) % 2 == 0:
            ok += 1; print("  OK   le manda la pregunta y respuesta anteriores")
        else:
            print(f"  FALLA el historial crecio en {crecio}")

        async with _eng.begin() as c:
            titulo = (await c.execute(_t(
                "SELECT title FROM conversations WHERE id=:i"), {"i": conv_id})).scalar()
        n += 1
        if titulo and "medicamentos" in titulo:
            ok += 1; print(f"  OK   el titulo salio de la primera pregunta ('{titulo}')")
        else:
            print(f"  FALLA titulo '{titulo}'")

    check("conversacion de otra persona", 404,
          await client.post(f"/api/v1/patients/{PACIENTE}/assistant/messages",
                            json={"text": "PRUEBA x", "conversation_id": str(existe)},
                            headers=token(cuidadora)))
    check("pregunta de solo espacios", 422,
          await client.post(f"/api/v1/patients/{PACIENTE}/assistant/messages",
                            json={"text": "   "}, headers=token(cuidadora)))
    check("preguntar desde fuera del circulo", 404,
          await client.post(f"/api/v1/patients/{PACIENTE}/assistant/messages",
                            json={"text": "PRUEBA x"}, headers=token(AJENO)))

    # el plan gratis no incluye asistente
    async with _eng.begin() as c:
        libre = (await c.execute(_t(
            "SELECT pm.user_id FROM patient_members pm WHERE pm.patient_id=:p "
            "AND pm.removed_at IS NULL AND pm.user_id NOT IN "
            "(SELECT user_id FROM subscriptions) LIMIT 1"), {"p": PACIENTE})).scalar()
    if libre:
        check("sin suscripcion no hay cupo", 402,
              await client.post(f"/api/v1/patients/{PACIENTE}/assistant/messages",
                                json={"text": "PRUEBA x"}, headers=token(str(libre))))

    # cupo agotado
    async with _eng.begin() as c:
        pid_plan = (await c.execute(_t(
            "SELECT plan_id FROM subscriptions WHERE user_id=:u"), {"u": cuidadora})).scalar()
        tope = (await c.execute(_t(
            "SELECT limit_value FROM plan_limits WHERE plan_id=:p "
            "AND limit_key='ai_queries_month'"), {"p": str(pid_plan)})).scalar()
        await c.execute(_t(
            "UPDATE usage_counters SET used_value=:v WHERE subscription_id=:s "
            "AND limit_key='ai_queries_month'"), {"v": tope, "s": str(sid)})
    r = await client.post(f"/api/v1/patients/{PACIENTE}/assistant/messages",
                          json={"text": "PRUEBA pasada de cupo"}, headers=token(cuidadora))
    check(f"con el cupo agotado ({tope}) responde 402", 402, r)
    async with _eng.begin() as c:
        quedo = (await c.execute(_t(
            "SELECT used_value FROM usage_counters WHERE subscription_id=:s "
            "AND limit_key='ai_queries_month'"), {"s": str(sid)})).scalar()
    n += 1
    if quedo == tope:
        ok += 1; print("  OK   un intento rechazado no sube el contador")
    else:
        print(f"  FALLA contador quedo en {quedo}, tope {tope}")

    # el proveedor se cae
    async with _eng.begin() as c:
        await c.execute(_t("UPDATE usage_counters SET used_value=0 WHERE subscription_id=:s"),
                        {"s": str(sid)})
    FALSO.falla = True
    r = await client.post(f"/api/v1/patients/{PACIENTE}/assistant/messages",
                          json={"text": "PRUEBA con proveedor caido"},
                          headers=token(cuidadora))
    check("si el proveedor se cae responde 503, no 500", 503, r)
    async with _eng.begin() as c:
        gastado = (await c.execute(_t(
            "SELECT coalesce(sum(used_value),0) FROM usage_counters "
            "WHERE subscription_id=:s AND limit_key='ai_queries_month'"),
            {"s": str(sid)})).scalar()
        guardadas = (await c.execute(_t(
            "SELECT count(*) FROM assistant_queries "
            "WHERE query_text='PRUEBA con proveedor caido'"))).scalar()
    n += 1
    if gastado == 0:
        ok += 1; print("  OK   una falla del proveedor no gasta cupo del plan")
    else:
        print(f"  FALLA quedo gastado {gastado}")
    n += 1
    if guardadas == 0:
        ok += 1; print("  OK   y no deja la consulta a medias en la base")
    else:
        print(f"  FALLA guardo {guardadas}")
    FALSO.falla = False

    async with _eng.begin() as c:
        await c.execute(_t("DELETE FROM assistant_citations WHERE query_id IN "
                           "(SELECT id FROM assistant_queries WHERE query_text LIKE 'PRUEBA%')"))
        await c.execute(_t("DELETE FROM assistant_queries WHERE query_text LIKE 'PRUEBA%'"))
        await c.execute(_t("DELETE FROM usage_counters WHERE subscription_id=:s"),
                        {"s": str(sid)})

    print("--- historial de una conversacion ---")
    ap.get_assistant = lambda: FALSO
    r = await client.post(f"/api/v1/patients/{PACIENTE}/assistant/messages",
                          json={"text": "PRUEBA pregunta del historial"},
                          headers=token(cuidadora))
    conv_h = r.json()["conversation_id"]

    rh = await client.get(f"/api/v1/assistant/conversations/{conv_h}/messages",
                          headers=token(cuidadora))
    check("trae el historial", 200, rh, campo="items")
    if rh.status_code == 200:
        items = rh.json()["items"]
        print(f"       mensajes: {len(items)}")
        n += 1
        if len(items) % 2 == 0 and len(items) >= 2:
            ok += 1; print("  OK   cada consulta se abre en dos mensajes")
        else:
            print(f"  FALLA {len(items)} mensajes")
        n += 1
        roles_ = [i["role"] for i in items]
        if roles_ == ["user", "assistant"] * (len(items) // 2):
            ok += 1; print("  OK   alternan persona y asistente, en ese orden")
        else:
            print(f"  FALLA {roles_}")
        n += 1
        fechas = [i["created_at"] for i in items]
        if fechas == sorted(fechas):
            ok += 1; print("  OK   del mas viejo al mas nuevo, como se lee un chat")
        else:
            print("  FALLA no viene ordenado")
        asistente = [i for i in items if i["role"] == "assistant"]
        n += 1
        if any(i["citations"] for i in asistente):
            etq = [c["label"] for c in asistente[-1]["citations"]]
            ok += 1; print(f"  OK   las respuestas traen sus fuentes con nombre legible {etq[:3]}")
        else:
            print("  FALLA sin citas")
        n += 1
        if all(i["citations"] == [] for i in items if i["role"] == "user"):
            ok += 1; print("  OK   las preguntas no traen fuentes")
        else:
            print("  FALLA la pregunta trae fuentes")

    check("historial de la conversacion de otra persona", 404,
          await client.get(f"/api/v1/assistant/conversations/{existe}/messages",
                           headers=token(cuidadora)))
    check("conversacion inexistente", 404,
          await client.get("/api/v1/assistant/conversations/"
                           "99999999-9999-4999-8999-999999999991/messages",
                           headers=token(cuidadora)))
    check("historial sin autenticar", 401,
          await client.get(f"/api/v1/assistant/conversations/{conv_h}/messages"))

    async with _eng.begin() as c:
        await c.execute(_t("DELETE FROM assistant_citations WHERE query_id IN "
                           "(SELECT id FROM assistant_queries WHERE query_text LIKE 'PRUEBA%')"))
        await c.execute(_t("DELETE FROM assistant_queries WHERE query_text LIKE 'PRUEBA%'"))
        await c.execute(_t("DELETE FROM usage_counters WHERE subscription_id=:s"),
                        {"s": str(sid)})

    check("desde fuera del circulo", 404,
          await client.get(f"/api/v1/patients/{PACIENTE}/assistant/conversations",
                           headers=token(AJENO)))
    check("sin autenticar", 401,
          await client.get(f"/api/v1/patients/{PACIENTE}/assistant/conversations"))


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
