"""Pruebas del registro de accesos al expediente (RNF-14).

Dos cosas distintas. Que el registro funcione, y que no tenga huecos. La
segunda es la que mas vale: la primera prueba recorre TODAS las rutas de la
aplicacion y falla si aparece una lectura de paciente que nadie clasifico.
Asi el dia que alguien agregue un endpoint y se olvide del registro, lo que
se rompe es esta prueba y no la auditoria.
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
from datetime import date, datetime, timedelta, timezone  # noqa: E402

import httpx  # noqa: E402
from fastapi.routing import APIRoute  # noqa: E402
from jose import jwt  # noqa: E402
from sqlalchemy import text  # noqa: E402

from app import acceso  # noqa: E402
from app import assistant_provider as ap  # noqa: E402
from app.config import get_settings  # noqa: E402
from app.db import engine  # noqa: E402
from app.main import app  # noqa: E402

FAMILIAR  = "11111111-1111-4111-8111-111111111111"
CUIDADORA = "22222222-2222-4222-8222-222222222222"
AJENO     = "eeeeeee1-0000-4000-8000-000000000001"
ELENA = "33333333-3333-4333-8333-333333333333"
LUIS  = "33333333-3333-4333-8333-333333333334"
BASE = f"/api/v1/patients/{ELENA}"

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
    return {"Authorization": f"Bearer {t}", "User-Agent": "prueba-accesos"}


class ProveedorFalso(ap.AssistantProvider):
    @property
    def disponible(self):
        return True

    async def responder(self, *, pregunta, contexto, rol, historial):
        return ap.Respuesta(texto="Respuesta de prueba.")


def todas_las_rutas(rs):
    for r in rs:
        if isinstance(r, APIRoute):
            yield r
        elif hasattr(r, "original_router"):
            yield from todas_las_rutas(r.original_router.routes)
        elif hasattr(r, "routes"):
            yield from todas_las_rutas(r.routes)


async def borrar_rastro():
    """Deja a los usuarios de prueba sin accesos recientes.

    El registro guarda una fila por persona, paciente y seccion cada pocos
    minutos. Sin esto, correr la prueba dos veces seguidas haria que la
    segunda no encontrara filas nuevas y fallara por haber pasado la primera.
    """
    acceso.olvidar_recientes()
    async with engine.begin() as c:
        await c.execute(text(
            "DELETE FROM record_access_log "
            "WHERE user_id = ANY(CAST(:u AS uuid[])) "
            "  AND accessed_at > now() - interval '1 hour'"),
            {"u": [FAMILIAR, CUIDADORA, AJENO]})


async def filas(uid=FAMILIAR, paciente=ELENA):
    async with engine.begin() as c:
        return (await c.execute(text(
            "SELECT section, role, user_agent FROM record_access_log "
            "WHERE user_id = :u AND patient_id = :p "
            "  AND accessed_at > now() - interval '1 hour' ORDER BY accessed_at"),
            {"u": uid, "p": paciente})).mappings().all()


async def secciones(uid=FAMILIAR, paciente=ELENA):
    return [f["section"] for f in await filas(uid, paciente)]


async def main(client):
    # ---------------- que no haya huecos ----------------
    print("--- todas las lecturas de paciente estan clasificadas ---")
    prefijo = "/api/v1/patients/{patient_id}"
    lecturas = sorted({r.path[len(prefijo):] for r in todas_las_rutas(app.routes)
                       if "GET" in r.methods and r.path.startswith(prefijo)})
    check("la aplicacion tiene lecturas de paciente que revisar",
          len(lecturas) >= 20, len(lecturas))
    conocidas = (set(acceso.SECCIONES) | acceso.YA_REGISTRAN
                 | acceso.NO_ES_EXPEDIENTE)
    sin_clasificar = [s for s in lecturas if s not in conocidas]
    check("ninguna lectura de paciente queda sin clasificar en acceso.py",
          not sin_clasificar, sin_clasificar)
    sobran = sorted(conocidas - set(lecturas))
    check("y acceso.py no nombra rutas que ya no existen", not sobran, sobran)
    repetidas = (set(acceso.SECCIONES) & acceso.YA_REGISTRAN) \
        | (set(acceso.SECCIONES) & acceso.NO_ES_EXPEDIENTE)
    check("ninguna ruta esta en dos listas a la vez", not repetidas, repetidas)

    posts = {r.path[len(prefijo):] for r in todas_las_rutas(app.routes)
             if "POST" in r.methods and r.path.startswith(prefijo)}
    check("las lecturas por POST que se registran existen",
          set(acceso.LECTURAS_POR_POST) <= posts,
          set(acceso.LECTURAS_POR_POST) - posts)

    async with engine.begin() as c:
        validas = (await c.execute(text(
            "SELECT pg_get_constraintdef(oid) FROM pg_constraint "
            "WHERE conname = 'ck_record_access_log_section' LIMIT 1"))).scalar()
    usadas = set(acceso.SECCIONES.values()) | set(acceso.LECTURAS_POR_POST.values())
    check("toda seccion que se registra la admite el CHECK de la tabla",
          all(f"'{s}'" in validas for s in usadas),
          [s for s in usadas if f"'{s}'" not in validas])

    # ---------------- que registre ----------------
    print("--- cada seccion deja su fila ---")
    await borrar_rastro()
    hoy = date.today()
    hace = (hoy - timedelta(days=7)).isoformat()
    casos = [
        ("profile",     "", {}),
        ("vitals",      "/vitals/latest", {}),
        ("medications", "/treatments", {}),
        ("doses",       "/adherence", {"date_from": hace, "date_to": hoy.isoformat()}),
        ("logbook",     "/timeline", {}),
        ("chat",        "/chat/messages", {}),
        ("reports",     "/report", {}),
        ("members",     "/members", {}),
    ]
    h = token(FAMILIAR)
    for seccion, sufijo, params in casos:
        r = await client.get(BASE + sufijo, params=params, headers=h)
        vistas = await secciones()
        check(f"{seccion:<12} GET {sufijo or '/'} ({r.status_code})",
              r.status_code == 200 and vistas.count(seccion) == 1,
              f"{r.status_code} {r.text[:80]} | {vistas}")

    fs = await filas()
    check("la fila guarda el rol con que entro",
          fs and all(f["role"] == "family" for f in fs), [dict(f) for f in fs][:2])
    check("y desde que aparato", fs and fs[0]["user_agent"] == "prueba-accesos",
          dict(fs[0]) if fs else None)

    # ---------------- la ventana ----------------
    print("--- una fila por ventana, no una por consulta ---")
    for _ in range(3):
        await client.get(BASE + "/vitals/latest", headers=h)
    check("consultar lo mismo tres veces seguidas no suma filas",
          (await secciones()).count("vitals") == 1, await secciones())
    # Aunque el proceso pierda la memoria (un reinicio), la base no duplica.
    acceso.olvidar_recientes()
    await client.get(BASE + "/vitals/latest", headers=h)
    check("ni despues de un reinicio del servidor",
          (await secciones()).count("vitals") == 1, await secciones())
    # Otra seccion del mismo grupo cuenta como la misma consulta...
    await client.get(BASE + "/vitals/thresholds", headers=h)
    check("otra pantalla de la misma seccion tampoco",
          (await secciones()).count("vitals") == 1, await secciones())
    # ...pero pasada la ventana es un acceso nuevo.
    async with engine.begin() as c:
        await c.execute(text(
            "UPDATE record_access_log SET accessed_at = accessed_at "
            "  - make_interval(mins => :m) "
            "WHERE user_id = :u AND patient_id = :p AND section = 'vitals' "
            "  AND accessed_at > now() - interval '1 hour'"),
            {"u": FAMILIAR, "p": ELENA, "m": acceso.VENTANA_MINUTOS + 1})
    acceso.olvidar_recientes()
    await client.get(BASE + "/vitals/latest", headers=h)
    check("pasada la ventana, volver a mirar si deja otra fila",
          (await secciones()).count("vitals") == 2, await secciones())

    # ---------------- cada persona, su fila ----------------
    print("--- quien fue ---")
    r = await client.get(BASE + "/vitals/latest", headers=token(CUIDADORA))
    fc = await filas(CUIDADORA)
    check("la cuidadora deja su propia fila, con su rol",
          r.status_code == 200 and len(fc) == 1 and fc[0]["role"] == "caregiver"
          and fc[0]["section"] == "vitals", [dict(f) for f in fc])

    # ---------------- lo que no es una consulta ----------------
    print("--- lo que no se registra ---")
    r = await client.get(BASE + "/vitals/latest", headers=token(AJENO))
    check("un extrano rechazado no figura como que consulto",
          r.status_code == 404 and not await filas(AJENO), await filas(AJENO))
    r = await client.get(BASE + "/vitals/latest")
    check("sin sesion tampoco", r.status_code == 401)
    antes = len(await filas(CUIDADORA))
    r = await client.get(BASE + "/tasks", headers=token(CUIDADORA))
    check("las tareas de cuidado no son expediente clinico",
          r.status_code == 200 and len(await filas(CUIDADORA)) == antes,
          (r.status_code, await secciones(CUIDADORA)))
    acceso.olvidar_recientes()
    async with engine.begin() as c:
        await c.execute(text(
            "DELETE FROM record_access_log WHERE user_id = :u "
            "AND accessed_at > now() - interval '1 hour'"), {"u": CUIDADORA})
    r = await client.post(BASE + "/vitals/manual", headers=token(CUIDADORA),
                          json={"type": "temperature", "value": 36.5})
    check("una escritura no se registra como consulta",
          r.status_code in (200, 201) and not await filas(CUIDADORA),
          (r.status_code, r.text[:80], await secciones(CUIDADORA)))
    async with engine.begin() as c:
        await c.execute(text(
            "DELETE FROM vital_readings WHERE patient_id = :p AND type = 'temperature' "
            "AND source = 'manual' AND value = 36.5 "
            "AND created_at > now() - interval '1 minute'"), {"p": ELENA})

    # ---------------- las que registran por su cuenta ----------------
    print("--- las que ya registraban no quedan con dos filas ---")
    await borrar_rastro()
    r = await client.get(BASE + "/observations", headers=h)
    check("la bitacora sigue dejando una fila, no dos",
          r.status_code == 200 and await secciones() == ["logbook"],
          (r.status_code, await secciones()))

    # ---------------- el centro de alertas ----------------
    print("--- centro de alertas ---")
    await borrar_rastro()
    async with engine.begin() as c:
        con_alertas = [str(x[0]) for x in (await c.execute(text(
            "SELECT DISTINCT a.patient_id FROM alerts a "
            "JOIN patient_members pm ON pm.patient_id = a.patient_id "
            "WHERE pm.user_id = :u AND pm.removed_at IS NULL"),
            {"u": FAMILIAR})).all()]
    r = await client.get("/api/v1/users/me/alerts",
                         params={"status": "all", "page_size": 100}, headers=h)
    en_pagina = {a["patient_id"] for a in r.json().get("items", [])}
    check("el centro de alertas responde", r.status_code == 200 and en_pagina,
          (r.status_code, con_alertas))
    registrados = set()
    for p in en_pagina:
        if "alerts" in await secciones(paciente=p):
            registrados.add(p)
    check("deja una fila por cada paciente cuyas alertas mostro",
          registrados == en_pagina, (registrados, en_pagina))

    # ---------------- el asistente ----------------
    print("--- asistente ---")
    await borrar_rastro()
    # Con la cuidadora, que es quien tiene un plan con consultas al asistente.
    # Se le deja el contador del mes en cero para no depender de cuantas
    # preguntas hicieron las otras pruebas.
    hc = token(CUIDADORA)
    async with engine.begin() as c:
        sub = (await c.execute(text(
            "SELECT id FROM subscriptions WHERE user_id = :u"),
            {"u": CUIDADORA})).scalar()
        await c.execute(text(
            "DELETE FROM usage_counters WHERE subscription_id = :s"), {"s": sub})
        # La pregunta de prueba puede caer en una conversacion que ya existia
        # y ponerle titulo. Se guardan los titulos para devolverlos.
        titulos = (await c.execute(text(
            "SELECT id, title FROM conversations WHERE user_id = :u "
            "AND type = 'assistant'"), {"u": CUIDADORA})).all()
    original = ap.get_assistant
    try:
        ap.get_assistant = lambda: ap.NotConfigured()
        r = await client.post(BASE + "/assistant/messages", headers=hc,
                              json={"text": "PRUEBA-ACCESOS como esta"})
        check("sin proveedor no se leyo nada y no se registra",
              r.status_code == 503
              and "assistant" not in await secciones(CUIDADORA),
              (r.status_code, await secciones(CUIDADORA)))
        ap.get_assistant = lambda: ProveedorFalso()
        r = await client.post(BASE + "/assistant/messages", headers=hc,
                              json={"text": "PRUEBA-ACCESOS como esta"})
        check("una pregunta al asistente queda registrada como tal",
              r.status_code == 201
              and (await secciones(CUIDADORA)).count("assistant") == 1,
              (r.status_code, r.text[:100], await secciones(CUIDADORA)))
        if r.status_code == 201:
            conv = r.json()["conversation_id"]
            await borrar_rastro()
            r = await client.get(
                f"/api/v1/assistant/conversations/{conv}/messages", headers=hc)
            check("releer la conversacion tambien",
                  r.status_code == 200
                  and await secciones(CUIDADORA) == ["assistant"],
                  (r.status_code, await secciones(CUIDADORA)))
    finally:
        ap.get_assistant = original
        async with engine.begin() as c:
            # La conversacion tambien se borra, no solo sus preguntas: si
            # queda, la prueba del asistente la encuentra primera en la lista
            # y falla por algo que dejo esta.
            hechas = (await c.execute(text(
                "SELECT id, conversation_id FROM assistant_queries "
                "WHERE query_text LIKE 'PRUEBA-ACCESOS%'"))).all()
            ids = [x[0] for x in hechas]
            if ids:
                await c.execute(text(
                    "DELETE FROM assistant_citations WHERE query_id = ANY(:i)"),
                    {"i": ids})
                await c.execute(text(
                    "DELETE FROM assistant_queries WHERE id = ANY(:i)"), {"i": ids})
                await c.execute(text(
                    "DELETE FROM conversations c WHERE c.id = ANY(:c) "
                    "AND c.type = 'assistant' AND NOT EXISTS (SELECT 1 "
                    "  FROM assistant_queries q WHERE q.conversation_id = c.id)"),
                    {"c": list({x[1] for x in hechas})})
            for cid, titulo in titulos:
                await c.execute(text(
                    "UPDATE conversations SET title = :t WHERE id = :i"),
                    {"t": titulo, "i": cid})
            await c.execute(text(
                "DELETE FROM usage_counters WHERE subscription_id = :s"), {"s": sub})

    await borrar_rastro()


async def correr():
    transport = httpx.ASGITransport(app=app, raise_app_exceptions=False)
    async with httpx.AsyncClient(transport=transport, base_url="http://testserver",
                                 timeout=60) as client:
        await main(client)
    await engine.dispose()
    print(f"\n{ok}/{n} comprobaciones")
    return 0 if ok == n and n > 0 else 1


if __name__ == "__main__":
    raise SystemExit(asyncio.run(correr()))
