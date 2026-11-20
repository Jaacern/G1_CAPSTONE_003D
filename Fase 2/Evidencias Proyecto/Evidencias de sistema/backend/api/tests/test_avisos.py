"""Pruebas del reparto de avisos de las alertas (RF-45, RF-52, RNF-04, RNF-05).

Con un proveedor de push falso, que es para lo que existe el adaptador: se
prueba todo el camino menos el salto final a Firebase, y se puede hacer que
ese salto falle de cada una de las formas en que falla de verdad.

Lo que mas se cuida no es que avise, sino que no avise de mas ni a quien no
corresponde: dos veces por la misma alerta, a quien apago ese aviso, a quien
apreto el boton, o por una emergencia de hace tres horas.
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

from app import avisos  # noqa: E402
from app.config import get_settings  # noqa: E402
from app.db import engine  # noqa: E402
from app.errors import register_error_handlers  # noqa: E402
from app.push_provider import Envio, NotConfigured, PushProvider  # noqa: E402
from app.ratelimit import limiter  # noqa: E402
from app.routers import alerts, devices  # noqa: E402

app = FastAPI()
app.state.limiter = limiter
register_error_handlers(app)
app.include_router(alerts.router)
app.include_router(devices.router)

JAVIER = "11111111-1111-4111-8111-111111111111"   # familiar
ROSA   = "22222222-2222-4222-8222-222222222222"   # cuidadora
ELENA_U = "99999999-9999-4999-8999-999999999999"  # la propia paciente
ELENA = "33333333-3333-4333-8333-333333333333"
MARCA = "PRUEBA-AVISOS"
T_J1, T_J2, T_R1 = f"{MARCA}-javier-1", f"{MARCA}-javier-2", f"{MARCA}-rosa-1"
HUELLA = f"{MARCA}-RELOJ-0001"

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


class ProveedorFalso(PushProvider):
    """Anota lo que le piden enviar y responde lo que la prueba le diga."""

    def __init__(self):
        self.envios: list[dict] = []
        self.respuestas: dict[str, Envio] = {}
        self.revienta = False

    @property
    def disponible(self):
        return True

    async def enviar(self, *, token, titulo, cuerpo, datos, canal="alerts",
                     critica=False):
        self.envios.append({"token": token, "titulo": titulo, "cuerpo": cuerpo,
                            "datos": datos, "canal": canal, "critica": critica})
        if self.revienta:
            raise RuntimeError("el proveedor exploto")
        return self.respuestas.get(token, Envio(ok=True))

    def a(self, t):
        return [e for e in self.envios if e["token"] == t]


FALSO = ProveedorFalso()


async def limpiar():
    async with engine.begin() as c:
        mias = ("SELECT id FROM alerts WHERE title LIKE :m OR detail LIKE :m")
        await c.execute(text(
            f"DELETE FROM alert_deliveries WHERE alert_id IN ({mias}) "
            "OR push_device_id IN (SELECT id FROM push_devices "
            "                       WHERE push_token LIKE :m)"), {"m": MARCA + "%"})
        await c.execute(text(
            f"DELETE FROM sos_events WHERE alert_id IN ({mias})"),
            {"m": MARCA + "%"})
        await c.execute(text(
            "DELETE FROM alerts WHERE title LIKE :m OR detail LIKE :m"),
            {"m": MARCA + "%"})
        await c.execute(text(
            "DELETE FROM push_devices WHERE push_token LIKE :m"),
            {"m": MARCA + "%"})
        await c.execute(text(
            "DELETE FROM elder_devices WHERE device_fingerprint = :h"),
            {"h": HUELLA})
        await c.execute(text(
            "DELETE FROM wearables WHERE serial_number = :h"), {"h": HUELLA})


async def alerta(tipo="vital_out_of_range", severidad="warning", nombre="caso",
                 hace_min=0):
    async with engine.begin() as c:
        return str((await c.execute(text(
            "INSERT INTO alerts (patient_id, type, severity, title, detail, "
            "  status, created_at) VALUES (:p, :t, :s, :ti, 'detalle', 'active', "
            "  now() - make_interval(mins => :h)) RETURNING id"),
            {"p": ELENA, "t": tipo, "s": severidad,
             "ti": f"{MARCA} {nombre}", "h": hace_min})).scalar())


async def entregas(aid):
    async with engine.begin() as c:
        return (await c.execute(text(
            "SELECT d.id, d.user_id, d.status, d.error_detail, d.notice_round, "
            "  d.sent_at, d.delivered_at, d.opened_at, pd.push_token "
            "FROM alert_deliveries d LEFT JOIN push_devices pd "
            "  ON pd.id = d.push_device_id "
            "WHERE d.alert_id = :a ORDER BY d.created_at, pd.push_token"),
            {"a": aid})).mappings().all()


async def sql(q, **p):
    async with engine.begin() as c:
        return await c.execute(text(q), p)


async def veces(aid) -> int:
    """Cuantas veces se reaviso de una alerta.

    Los reavisos se comprueban mirando la alerta de la prueba y no el total
    que devuelve la pasada: en una base con uso real puede haber otra critica
    sin atender, y esa tambien se reavisa, como corresponde.
    """
    return (await sql("SELECT renotify_count FROM alerts WHERE id = :a",
                      a=aid)).scalar()


async def main(client):
    await limpiar()
    avisos.get_push = lambda: FALSO

    async with engine.begin() as c:
        prefs = (await c.execute(text(
            "SELECT user_id, alert_type, push_enabled FROM notification_settings "
            "WHERE user_id = ANY(CAST(:u AS uuid[]))"),
            {"u": [JAVIER, ROSA]})).all()
        activos = [r[0] for r in (await c.execute(text(
            "SELECT id FROM push_devices WHERE is_active"))).all()]
        parametros = dict((await c.execute(text(
            "SELECT key, value FROM system_parameters WHERE key IN "
            "('alert_escalation_minutes', 'alert_renotify_max')"))).all())
        # Los telefonos del seed se apagan mientras dura la prueba, para que
        # los unicos que reciban sean los que ella registra.
        await c.execute(text("UPDATE push_devices SET is_active = false"))
        # Y las preferencias parten todas encendidas.
        await c.execute(text(
            "UPDATE notification_settings SET push_enabled = true "
            "WHERE user_id = ANY(CAST(:u AS uuid[]))"), {"u": [JAVIER, ROSA]})
    # Se reparte lo que hubiera pendiente en la base, para partir de cero.
    await avisos.despachar()
    async with engine.begin() as c:
        for uid, tok, plat in ((JAVIER, T_J1, "android"), (JAVIER, T_J2, "ios"),
                               (ROSA, T_R1, "android")):
            await c.execute(text(
                "INSERT INTO push_devices (user_id, push_token, platform) "
                "VALUES (:u, :t, :p)"), {"u": uid, "t": tok, "p": plat})
    FALSO.envios.clear()

    try:
        # ---------------- el reparto ----------------
        print("--- a quien se avisa ---")
        a = await alerta("fall", "critical", "caida")
        r = await avisos.despachar()
        es = await entregas(a)
        check("una entrega por cada telefono de familiar y cuidadora",
              sorted(e["push_token"] for e in es) == [T_J1, T_J2, T_R1],
              [dict(e) for e in es])
        check("todas quedan enviadas, con su hora",
              es and all(e["status"] == "sent" and e["sent_at"] for e in es),
              [e["status"] for e in es])
        check("ni el medico ni la propia paciente reciben el aviso",
              {str(e["user_id"]) for e in es} == {JAVIER, ROSA},
              {str(e["user_id"]) for e in es})
        check("el proveedor recibio los tres envios", len(FALSO.envios) == 3,
              len(FALSO.envios))
        e0 = FALSO.a(T_J1)[0] if FALSO.a(T_J1) else {}
        check("el titulo dice de que paciente se trata",
              e0.get("titulo", "").startswith("Elena · "), e0.get("titulo"))
        check("una caida va por el canal de caidas y marcada critica",
              e0.get("canal") == "falls" and e0.get("critica") is True, e0)
        check("los datos llevan la alerta y la entrega, para abrirla y confirmarla",
              e0.get("datos", {}).get("alert_id") == a
              and e0.get("datos", {}).get("delivery_id")
              and e0.get("datos", {}).get("type") == "alert", e0.get("datos"))
        marca = (await sql("SELECT notified_at FROM alerts WHERE id = :a", a=a)).scalar()
        check("la alerta queda marcada como repartida", marca is not None)

        # ---------------- no avisar dos veces ----------------
        print("--- una sola vez ---")
        FALSO.envios.clear()
        await avisos.despachar()
        check("repetir el despacho no envia de nuevo",
              not FALSO.envios and len(await entregas(a)) == 3, len(FALSO.envios))
        a2 = await alerta("vital_out_of_range", "warning", "simultaneo")
        await asyncio.gather(avisos.despachar(), avisos.despachar(),
                             avisos.despachar(), avisos.despachar())
        check("cuatro despachos a la vez reparten la alerta una sola vez",
              len(await entregas(a2)) == 3 and len(FALSO.envios) == 3,
              (len(await entregas(a2)), len(FALSO.envios)))
        check("una alerta que no es caida va por el canal general de alertas",
              FALSO.envios and FALSO.envios[0]["canal"] == "alerts"
              and FALSO.envios[0]["critica"] is False, FALSO.envios[:1])

        # ---------------- preferencias ----------------
        print("--- preferencias y autor ---")
        await sql("INSERT INTO notification_settings (user_id, alert_type, push_enabled) "
                  "VALUES (:u, 'missed_dose', false) ON CONFLICT (user_id, alert_type) "
                  "DO UPDATE SET push_enabled = false", u=ROSA)
        a3 = await alerta("missed_dose", "warning", "preferencia")
        await avisos.despachar()
        check("quien apago ese tipo de aviso no lo recibe",
              {str(e["user_id"]) for e in await entregas(a3)} == {JAVIER},
              {str(e["user_id"]) for e in await entregas(a3)})
        a4 = await alerta("vital_out_of_range", "warning", "otro tipo")
        await avisos.despachar()
        check("pero sigue recibiendo los demas tipos",
              ROSA in {str(e["user_id"]) for e in await entregas(a4)})

        a5 = await alerta("sos", "critical", "sos de rosa")
        await sql("INSERT INTO sos_events (patient_id, triggered_by, alert_id, note) "
                  "VALUES (:p, :u, :a, :n)", p=ELENA, u=ROSA, a=a5, n=MARCA)
        await avisos.despachar()
        check("a quien apreto el boton no se le avisa de su propio SOS",
              {str(e["user_id"]) for e in await entregas(a5)} == {JAVIER},
              {str(e["user_id"]) for e in await entregas(a5)})

        # ---------------- lo que sale mal ----------------
        print("--- cuando el envio falla ---")
        await sql("UPDATE push_devices SET is_active = false WHERE push_token = :t",
                  t=T_R1)
        a6 = await alerta("fall", "critical", "sin telefono")
        await avisos.despachar()
        de_rosa = [e for e in await entregas(a6) if str(e["user_id"]) == ROSA]
        check("quien no tiene telefono registrado queda anotado como no avisado",
              len(de_rosa) == 1 and de_rosa[0]["status"] == "failed"
              and "telefono registrado" in (de_rosa[0]["error_detail"] or "")
              and de_rosa[0]["push_token"] is None, [dict(e) for e in de_rosa])
        await sql("UPDATE push_devices SET is_active = true WHERE push_token = :t",
                  t=T_R1)

        FALSO.respuestas[T_J2] = Envio(ok=False, token_invalido=True,
                                       error="FCM 404 UNREGISTERED")
        a7 = await alerta("fall", "critical", "token muerto")
        await avisos.despachar()
        por_token = {e["push_token"]: e for e in await entregas(a7)}
        check("un token muerto deja la entrega fallida con el motivo",
              por_token[T_J2]["status"] == "failed"
              and "UNREGISTERED" in por_token[T_J2]["error_detail"],
              dict(por_token[T_J2]))
        check("y no arrastra a las demas entregas",
              por_token[T_J1]["status"] == "sent"
              and por_token[T_R1]["status"] == "sent",
              {k: v["status"] for k, v in por_token.items()})
        vivo = (await sql("SELECT is_active FROM push_devices WHERE push_token = :t",
                          t=T_J2)).scalar()
        check("el aparato del token muerto se deja de usar", vivo is False, vivo)
        a8 = await alerta("fall", "critical", "despues del token muerto")
        await avisos.despachar()
        check("la alerta siguiente ya no intenta con ese aparato",
              T_J2 not in {e["push_token"] for e in await entregas(a8)},
              {e["push_token"] for e in await entregas(a8)})

        FALSO.respuestas[T_J1] = Envio(ok=False, error="FCM 503 UNAVAILABLE")
        a9 = await alerta("fall", "critical", "falla pasajera")
        await avisos.despachar()
        por_token = {e["push_token"]: e for e in await entregas(a9)}
        vivo = (await sql("SELECT is_active FROM push_devices WHERE push_token = :t",
                          t=T_J1)).scalar()
        check("una falla pasajera del servicio no apaga el aparato",
              por_token[T_J1]["status"] == "failed" and vivo is True,
              (por_token[T_J1]["status"], vivo))
        FALSO.respuestas.clear()

        FALSO.revienta = True
        a10 = await alerta("fall", "critical", "proveedor roto")
        r = await avisos.despachar()
        FALSO.revienta = False
        es = await entregas(a10)
        check("un proveedor que revienta no deja la cola trabada",
              es and all(e["status"] == "failed" for e in es)
              and all("Fallo el proveedor" in e["error_detail"] for e in es),
              [dict(e) for e in es])

        avisos.get_push = lambda: NotConfigured()
        a11 = await alerta("fall", "critical", "sin proveedor")
        await avisos.despachar()
        avisos.get_push = lambda: FALSO
        es = await entregas(a11)
        check("sin proveedor configurado no se finge el envio: queda fallida",
              es and all(e["status"] == "failed" and e["sent_at"] is None
                         and "no esta configurado" in e["error_detail"]
                         for e in es), [dict(e) for e in es])

        # ---------------- lo viejo ----------------
        print("--- lo atrasado no sale de golpe ---")
        FALSO.envios.clear()
        a12 = await alerta("fall", "critical", "de hace tres horas", hace_min=180)
        await avisos.despachar()
        marca = (await sql("SELECT notified_at FROM alerts WHERE id = :a", a=a12)).scalar()
        check("una alerta vieja se da por repartida sin enviar nada",
              marca is not None and not await entregas(a12) and not FALSO.envios,
              (marca, len(FALSO.envios)))

        a13 = await alerta("missed_dose", "warning", "cola vencida")
        await avisos.repartir()
        await sql("UPDATE alert_deliveries SET created_at = now() - interval '2 hours' "
                  "WHERE alert_id = :a", a=a13)
        await avisos.enviar_cola()
        es = await entregas(a13)
        check("una entrega que se quedo en cola mas de una hora vence sin enviarse",
              es and all(e["status"] == "failed"
                         and "Vencio" in e["error_detail"] for e in es)
              and not FALSO.envios, [dict(e) for e in es])

        FALSO.envios.clear()
        await alerta("missed_dose", "warning", "normal primero")
        await alerta("fall", "critical", "critica despues")
        await avisos.repartir()
        await avisos.enviar_cola()
        check("si hay cola, las criticas salen primero",
              FALSO.envios and "critica despues" in FALSO.envios[0]["titulo"],
              [e["titulo"] for e in FALSO.envios][:3])

        # ---------------- reaviso (RF-52) ----------------
        print("--- reaviso de criticas sin atender ---")
        await sql("UPDATE system_parameters SET value = '15' "
                  "WHERE key = 'alert_escalation_minutes'")
        await sql("UPDATE system_parameters SET value = '2' "
                  "WHERE key = 'alert_renotify_max'")
        # Las criticas de los casos anteriores se atienden, para que la unica
        # pendiente sea la de este bloque.
        await sql("UPDATE alerts SET status = 'acknowledged', acknowledged_by = :u, "
                  "acknowledged_at = now() WHERE title LIKE :m AND status = 'active'",
                  u=JAVIER, m=MARCA + "%")
        c1 = await alerta("sos", "critical", "nadie atiende")
        w1 = await alerta("missed_dose", "warning", "aviso comun")
        await avisos.despachar()
        FALSO.envios.clear()

        await avisos.reavisar_criticas()
        check("antes del plazo no se insiste", await veces(c1) == 0,
              await veces(c1))

        atras = "UPDATE alerts SET notified_at = notified_at - interval '16 minutes', " \
                "escalated_at = escalated_at - interval '16 minutes' " \
                "WHERE id = ANY(CAST(:i AS uuid[]))"
        await sql(atras, i=[c1, w1])
        await avisos.pasada(verbose=False)
        check("pasado el plazo se vuelve a avisar de la critica",
              await veces(c1) == 1, await veces(c1))
        vuelta1 = [e for e in await entregas(c1) if e["notice_round"] == 1]
        check("el reaviso va a todos, no a un 'siguiente contacto'",
              {str(e["user_id"]) for e in vuelta1} == {JAVIER, ROSA}
              and all(e["status"] == "sent" for e in vuelta1),
              [dict(e) for e in vuelta1])
        check("y el telefono dice que sigue sin atender",
              FALSO.a(T_J1) and all(
                  e["titulo"].startswith("Sin atender · Elena")
                  for e in FALSO.envios if "nadie atiende" in e["titulo"])
              and any("nadie atiende" in e["titulo"] for e in FALSO.envios),
              [e["titulo"] for e in FALSO.envios])
        check("una alerta que no es critica no se reavisa",
              all(e["notice_round"] == 0 for e in await entregas(w1)))
        fila = (await sql("SELECT renotify_count, escalated_at FROM alerts "
                          "WHERE id = :a", a=c1)).mappings().first()
        check("queda anotado cuantas veces se insistio y cuando",
              fila["renotify_count"] == 1 and fila["escalated_at"] is not None,
              dict(fila))

        await avisos.reavisar_criticas()
        check("el plazo corre de nuevo desde el ultimo reaviso",
              await veces(c1) == 1, await veces(c1))

        await sql(atras, i=[c1])
        await avisos.reavisar_criticas()
        check("segundo reaviso al cumplirse otra vez", await veces(c1) == 2,
              await veces(c1))
        await sql(atras, i=[c1])
        await avisos.reavisar_criticas()
        check("el techo de reavisos se respeta", await veces(c1) == 2,
              await veces(c1))

        c2 = await alerta("sos", "critical", "la atienden")
        await avisos.despachar()
        await sql(atras, i=[c2])
        r = await client.post(f"/api/v1/alerts/{c2}/acknowledge", headers=token(JAVIER))
        check("alguien atiende la alerta", r.status_code == 200,
              f"{r.status_code} {r.text[:100]}")
        await avisos.reavisar_criticas()
        check("atenderla corta los reavisos (RF-48)",
              await veces(c2) == 0
              and all(e["notice_round"] == 0 for e in await entregas(c2)),
              await veces(c2))

        # ---------------- confirmar la llegada (RNF-05) ----------------
        print("--- la aplicacion confirma que llego ---")
        a14 = await alerta("fall", "critical", "confirmar")
        await avisos.despachar()
        de_javier = [e for e in await entregas(a14) if e["push_token"] == T_J1][0]
        did = str(de_javier["id"])
        url = f"/api/v1/users/me/deliveries/{did}/ack"
        r = await client.post(url, json={"event": "delivered"}, headers=token(JAVIER))
        e = [x for x in await entregas(a14) if str(x["id"]) == did][0]
        check("la entrega queda marcada como recibida",
              r.status_code == 204 and e["status"] == "delivered"
              and e["delivered_at"] is not None and e["opened_at"] is None,
              (r.status_code, dict(e)))
        check("con lo que se puede medir la latencia de RNF-05",
              e["delivered_at"] and e["sent_at"]
              and (e["delivered_at"] - e["sent_at"]).total_seconds() < 30,
              (e["sent_at"], e["delivered_at"]))
        primera = e["delivered_at"]
        r = await client.post(url, json={"event": "opened"}, headers=token(JAVIER))
        e = [x for x in await entregas(a14) if str(x["id"]) == did][0]
        check("abrirla se guarda aparte y no pisa la hora de llegada",
              r.status_code == 204 and e["status"] == "opened"
              and e["opened_at"] is not None and e["delivered_at"] == primera,
              (r.status_code, dict(e)))
        r = await client.post(url, json={"event": "delivered"}, headers=token(JAVIER))
        e = [x for x in await entregas(a14) if str(x["id"]) == did][0]
        check("repetir la confirmacion no retrocede el estado",
              r.status_code == 204 and e["status"] == "opened", e["status"])
        r = await client.post(url, json={"event": "opened"}, headers=token(ROSA))
        check("nadie confirma la entrega de otra persona", r.status_code == 404,
              r.status_code)
        r = await client.post(url, json={"event": "leida"}, headers=token(JAVIER))
        check("un evento desconocido se rechaza", r.status_code == 422, r.status_code)
        r = await client.post(url, json={"event": "opened"})
        check("sin sesion no se confirma nada", r.status_code == 401, r.status_code)

        # ---------------- de punta a punta ----------------
        print("--- desde el endpoint, sin esperar al repartidor ---")
        FALSO.envios.clear()
        r = await client.post(f"/api/v1/patients/{ELENA}/sos",
                              json={"note": f"{MARCA} de punta a punta"},
                              headers=token(ELENA_U))
        check("la paciente aprieta el boton", r.status_code == 201,
              f"{r.status_code} {r.text[:100]}")
        if r.status_code == 201:
            sid = r.json()["alert_id"]
            es = await entregas(sid)
            check("el aviso ya salio cuando el endpoint termino",
                  {e["push_token"] for e in es} == {T_J1, T_R1}
                  and all(e["status"] == "sent" for e in es),
                  [dict(e) for e in es])
            check("y a ella no se le avisa de su propio SOS",
                  ELENA_U not in {str(e["user_id"]) for e in es})
            check("el endpoint dice a cuantas personas se aviso",
                  r.json()["notified_count"] == 2, r.json()["notified_count"])
            demora = (await sql(
                "SELECT max(d.sent_at) - a.created_at FROM alert_deliveries d "
                "JOIN alerts a ON a.id = d.alert_id WHERE a.id = :a "
                "GROUP BY a.created_at", a=sid)).scalar()
            check("de la alerta al envio pasan menos de diez segundos (RNF-04)",
                  demora is not None and demora.total_seconds() < 10, demora)

        r = await client.post(f"/api/v1/patients/{ELENA}/device-link-codes",
                              headers=token(ROSA))
        if r.status_code == 201:
            r = await client.post("/api/v1/devices/link", json={
                "code": r.json()["code"], "device_fingerprint": HUELLA})
        check("se vincula un reloj para la caida", r.status_code == 201,
              f"{r.status_code} {r.text[:100]}")
        if r.status_code == 201:
            hd = {"Authorization": f"Bearer {r.json()['device_token']}"}
            # Una caida activa anterior haria que el reloj reciba esa misma.
            await sql("UPDATE alerts SET status = 'acknowledged', acknowledged_by = :u, "
                      "acknowledged_at = now() WHERE patient_id = :p AND type = 'fall' "
                      "AND status = 'active'", u=JAVIER, p=ELENA)
            FALSO.envios.clear()
            r = await client.post("/api/v1/devices/fall", headers=hd,
                                  json={"detail": f"{MARCA} caida del reloj"})
            check("el reloj reporta una caida", r.status_code == 201,
                  f"{r.status_code} {r.text[:100]}")
            if r.status_code == 201:
                es = await entregas(r.json()["alert_id"])
                check("la caida del reloj avisa en el momento, por el canal de caidas",
                      len(es) == 2 and all(e["status"] == "sent" for e in es)
                      and FALSO.envios
                      and all(e["canal"] == "falls" for e in FALSO.envios),
                      ([dict(e) for e in es], [e["canal"] for e in FALSO.envios]))
    finally:
        avisos.get_push = lambda: NotConfigured()
        await limpiar()
        async with engine.begin() as c:
            for k, v in parametros.items():
                await c.execute(text(
                    "UPDATE system_parameters SET value = :v WHERE key = :k"),
                    {"k": k, "v": v})
            await c.execute(text(
                "DELETE FROM notification_settings "
                "WHERE user_id = ANY(CAST(:u AS uuid[]))"), {"u": [JAVIER, ROSA]})
            for uid, tipo, on in prefs:
                await c.execute(text(
                    "INSERT INTO notification_settings (user_id, alert_type, "
                    "  push_enabled) VALUES (:u, :t, :o)"),
                    {"u": uid, "t": tipo, "o": on})
            await c.execute(text(
                "UPDATE push_devices SET is_active = true "
                "WHERE id = ANY(:i)"), {"i": activos})


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
