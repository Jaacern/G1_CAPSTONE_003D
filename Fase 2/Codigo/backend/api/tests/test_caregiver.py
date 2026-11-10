"""Pruebas del area de la cuidadora."""
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
from app.routers import caregiver, caregiver_profile  # noqa: E402

app = FastAPI()
register_error_handlers(app)
app.include_router(caregiver.router)
app.include_router(caregiver_profile.router)

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
        print(f"       {resp.text[:160]}")


async def roles():
    async with _eng.begin() as c:
        r = await c.execute(_t("SELECT user_id, role FROM patient_members "
                               "WHERE patient_id=:p AND removed_at IS NULL"), {"p": PACIENTE})
        return {m["role"]: str(m["user_id"]) for m in r.mappings().all()}


async def main(client, rr):
    global n, ok
    cuidadora = rr["caregiver"]

    print("--- resumen de hoy ---")
    r = await client.get("/api/v1/caregiver/today", headers=token(cuidadora))
    check("devuelve el resumen", 200, r, campo="patient_id")
    if r.status_code == 200:
        d = r.json()
        print(f"       paciente   : {d['patient_name']}")
        print(f"       turno      : {d['shift_status']}")
        print(f"       bienestar  : {d['wellbeing_status']}")
        print(f"       pendientes : {len(d['pending_tasks'])}")
        print(f"       obs hoy    : {d['observations_count']}")
        print(f"       alertas    : {d['alerts_count']}")
        print(f"       adherencia : {d['adherence_pct']}")
        n += 1
        # La cuidadora puede atender a mas de un paciente (la semilla trae a
        # Elena y a Luis): basta con que el elegido sea de su circulo.
        async with _eng.begin() as c:
            suyos = {str(x) for x in (await c.execute(_t(
                "SELECT patient_id FROM patient_members "
                "WHERE user_id = :u AND removed_at IS NULL"),
                {"u": cuidadora})).scalars().all()}
        if d["patient_id"] in suyos:
            ok += 1; print("  OK   elige el paciente de su circulo")
        else:
            print(f"  FALLA eligio {d['patient_id']}")
        n += 1
        if d["wellbeing_status"] in ("ok", "warning", "attention"):
            ok += 1; print("  OK   el semaforo es un valor que la pantalla sabe leer")
        else:
            print(f"  FALLA semaforo '{d['wellbeing_status']}'")
        n += 1
        if all(t["status"] in ("pending", "in_progress") for t in d["pending_tasks"]):
            ok += 1; print("  OK   solo trae tareas sin terminar")
        else:
            print("  FALLA trae tareas ya cerradas")

    # el turno abierto se refleja
    async with _eng.begin() as c:
        await c.execute(_t("DELETE FROM care_shifts WHERE caregiver_id=:u"), {"u": cuidadora})
        await c.execute(_t("INSERT INTO care_shifts (patient_id, caregiver_id) "
                           "VALUES (:p,:u)"), {"p": PACIENTE, "u": cuidadora})
    r = await client.get("/api/v1/caregiver/today", headers=token(cuidadora))
    n += 1
    if r.json()["shift_status"] == "checked_in":
        ok += 1; print("  OK   con turno abierto dice 'checked_in'")
    else:
        print(f"  FALLA dice {r.json()['shift_status']}")
    async with _eng.begin() as c:
        await c.execute(_t("DELETE FROM care_shifts WHERE caregiver_id=:u"), {"u": cuidadora})

    print("--- plan ---")
    # La cuidadora de demo ya tiene suscripcion premium y billing_events la
    # protege con RESTRICT, asi que no se borra: se guarda su estado, se
    # modifica para cada caso y se deja como estaba al final.
    async with _eng.begin() as c:
        orig = (await c.execute(_t(
            "SELECT status, current_period_end, cancelled_at FROM subscriptions "
            "WHERE user_id=:u"), {"u": cuidadora})).mappings().first()

    # alguien sin suscripcion
    async with _eng.begin() as c:
        libre = (await c.execute(_t(
            "SELECT id FROM users WHERE id NOT IN (SELECT user_id FROM subscriptions) "
            "AND is_active AND deleted_at IS NULL LIMIT 1"))).scalar()
    r = await client.get("/api/v1/caregiver/plan", headers=token(str(libre)))
    check("sin suscripcion devuelve el plan gratis", 200, r, campo="tier")
    if r.status_code == 200:
        d = r.json()
        print(f"       tier    : {d['tier']}")
        print(f"       features: {len(d['features'])}")
        print(f"       limites : {d['limits_text']}")
        n += 1
        if d["tier"] == "free":
            ok += 1; print("  OK   es 'free', que es lo que la pantalla sabe leer")
        else:
            print(f"  FALLA tier {d['tier']}")
        n += 1
        if len(d["features"]) >= 1:
            ok += 1; print("  OK   trae lo que el plan incluye")
        else:
            print("  FALLA sin features")
        n += 1
        if "no incluido" in d["limits_text"]:
            ok += 1; print("  OK   el gratis muestra lo que NO incluye")
        else:
            print(f"  FALLA texto: {d['limits_text']}")

    r = await client.get("/api/v1/caregiver/plan", headers=token(cuidadora))
    n += 1
    if r.status_code == 200 and r.json()["tier"] == "premium":
        ok += 1; print("  OK   con suscripcion activa devuelve premium")
        print(f"       limites : {r.json()['limits_text']}")
        n += 1
        if "sin tope" in r.json()["limits_text"]:
            ok += 1; print("  OK   un limite nulo se lee 'sin tope', no vacio")
        else:
            print("  FALLA no traduce el limite nulo")
    else:
        print(f"  FALLA {r.status_code} {r.text[:90]}")

    async with _eng.begin() as c:
        await c.execute(_t(
            "UPDATE subscriptions SET current_period_end = now() - interval '1 day' "
            "WHERE user_id=:u"), {"u": cuidadora})
    n += 1
    if (await client.get("/api/v1/caregiver/plan", headers=token(cuidadora))).json()["tier"] == "free":
        ok += 1; print("  OK   una suscripcion vencida vuelve a gratis")
    else:
        print("  FALLA la vencida sigue valiendo")

    async with _eng.begin() as c:
        await c.execute(_t(
            "UPDATE subscriptions SET current_period_end = now() + interval '30 days', "
            "status='cancelled', cancelled_at=now() WHERE user_id=:u"), {"u": cuidadora})
    n += 1
    if (await client.get("/api/v1/caregiver/plan", headers=token(cuidadora))).json()["tier"] == "free":
        ok += 1; print("  OK   una suscripcion cancelada vuelve a gratis")
    else:
        print("  FALLA la cancelada sigue valiendo")

    async with _eng.begin() as c:
        await c.execute(_t(
            "UPDATE subscriptions SET status=:s, current_period_end=:e, cancelled_at=:c "
            "WHERE user_id=:u"),
            {"s": orig["status"], "e": orig["current_period_end"],
             "c": orig["cancelled_at"], "u": cuidadora})

    print("--- mejorar el plan ---")
    # usuario sin suscripcion: debe crearla
    r = await client.post("/api/v1/caregiver/plan/upgrade", headers=token(str(libre)))
    check("un usuario sin suscripcion pasa a premium", 200, r, campo="tier")
    if r.status_code == 200:
        n += 1
        if r.json()["tier"] == "premium":
            ok += 1; print("  OK   queda en premium")
        else:
            print(f"  FALLA quedo en {r.json()['tier']}")
        async with _eng.begin() as c:
            fila = (await c.execute(_t(
                "SELECT status, current_period_end FROM subscriptions WHERE user_id=:u"),
                {"u": str(libre)})).mappings().first()
        n += 1
        if fila and fila["status"] == "active" and fila["current_period_end"]:
            ok += 1; print("  OK   crea la suscripcion activa con periodo de un mes")
        else:
            print(f"  FALLA fila: {dict(fila) if fila else None}")

        # idempotente
        r2 = await client.post("/api/v1/caregiver/plan/upgrade", headers=token(str(libre)))
        async with _eng.begin() as c:
            cuantas = (await c.execute(_t(
                "SELECT count(*) FROM subscriptions WHERE user_id=:u"),
                {"u": str(libre)})).scalar()
        n += 1
        if r2.status_code == 200 and cuantas == 1:
            ok += 1; print("  OK   mejorar dos veces no duplica la suscripcion")
        else:
            print(f"  FALLA hay {cuantas} suscripciones")

    # la compra deja la suscripcion marcada y su cobro en el historial
    async with _eng.begin() as c:
        compra = (await c.execute(_t(
            "SELECT s.source, s.provider_ref, "
            "       (SELECT count(*) FROM billing_events b "
            "         WHERE b.subscription_id = s.id AND b.type = 'charge' "
            "           AND b.status = 'succeeded' AND b.amount > 0) AS cobros "
            "FROM subscriptions s WHERE s.user_id=:u"),
            {"u": str(libre)})).mappings().first()
    n += 1
    if compra and compra["source"] == "purchase" and compra["cobros"] == 1 \
            and compra["provider_ref"]:
        ok += 1; print("  OK   la compra queda como purchase con su cobro registrado")
    else:
        print(f"  FALLA compra: {dict(compra) if compra else None}")

    # una cancelada no se reabre: la nueva compra abre otra suscripcion
    async with _eng.begin() as c:
        await c.execute(_t(
            "UPDATE subscriptions SET status='cancelled', cancelled_at=now() "
            "WHERE user_id=:u"), {"u": str(libre)})
    r = await client.post("/api/v1/caregiver/plan/upgrade", headers=token(str(libre)))
    n += 1
    if r.status_code == 200 and r.json()["tier"] == "premium":
        async with _eng.begin() as c:
            total, activas, cobros = (await c.execute(_t(
                "SELECT count(*), count(*) FILTER (WHERE s.status='active'), "
                "       (SELECT count(*) FROM billing_events b "
                "         JOIN subscriptions s2 ON s2.id=b.subscription_id "
                "        WHERE s2.user_id=:u AND b.type='charge') "
                "FROM subscriptions s WHERE s.user_id=:u"),
                {"u": str(libre)})).one()
        if total == 2 and activas == 1 and cobros == 2:
            ok += 1; print("  OK   volver a comprar abre otra suscripcion y otro cobro")
        else:
            print(f"  FALLA total={total} activas={activas} cobros={cobros}")
    else:
        print(f"  FALLA {r.status_code}")

    async with _eng.begin() as c:
        await c.execute(_t(
            "DELETE FROM billing_events WHERE subscription_id IN "
            "(SELECT id FROM subscriptions WHERE user_id=:u)"), {"u": str(libre)})
        await c.execute(_t("DELETE FROM subscriptions WHERE user_id=:u"), {"u": str(libre)})

    check("mejorar sin autenticar", 401,
          await client.post("/api/v1/caregiver/plan/upgrade"))

    check("plan sin autenticar", 401, await client.get("/api/v1/caregiver/plan"))

    print("--- perfil ---")
    r = await client.get("/api/v1/caregiver/profile", headers=token(cuidadora))
    check("devuelve el perfil", 200, r, campo="headline")
    if r.status_code == 200:
        d = r.json()
        print(f"       titular     : {d['headline'][:50]}")
        print(f"       experiencia : {d['years_experience']} anios")
        print(f"       especialidad: {d['specialties']}")
        print(f"       idiomas     : {d['languages']}")
        print(f"       zonas       : {d['zones']}")
        print(f"       certificados: {d['certifications']}")
        n += 1
        if d["headline"]:
            ok += 1; print("  OK   trae el titular guardado")
        else:
            print("  FALLA titular vacio")
        n += 1
        if all(isinstance(x, list) for x in (d["specialties"], d["languages"],
                                             d["zones"], d["certifications"])):
            ok += 1; print("  OK   las cuatro listas vienen como listas")
        else:
            print("  FALLA alguna lista no es lista")
        n += 1
        if d["specialties"] and not any(len(x) <= 4 for x in d["specialties"]):
            ok += 1; print("  OK   las especialidades vienen con su etiqueta, no el codigo")
        else:
            print(f"  FALLA especialidades: {d['specialties']}")

    # El perfil profesional es de cuentas de cuidador(a): 'libre' se marca
    # como tal mientras duran estas pruebas y se restaura al final.
    async with _eng.begin() as c:
        tipo_libre = (await c.execute(_t(
            "SELECT account_type FROM users WHERE id=:u"), {"u": str(libre)})).scalar()
        await c.execute(_t("UPDATE users SET account_type='caregiver' WHERE id=:u"),
                        {"u": str(libre)})

    r = await client.get("/api/v1/caregiver/profile", headers=token(str(libre)))
    check("quien no tiene perfil recibe uno vacio, no 404", 200, r, campo="headline")
    if r.status_code == 200:
        d = r.json()
        n += 1
        if d["headline"] == "" and d["years_experience"] == 0 and d["specialties"] == []:
            ok += 1; print("  OK   el perfil vacio viene completo y en cero")
        else:
            print(f"  FALLA {d}")

    print("--- guardar perfil ---")
    async with _eng.begin() as c:
        antes = (await c.execute(_t(
            "SELECT headline, bio, years_experience FROM caregiver_profiles "
            "WHERE user_id=:u"), {"u": cuidadora})).mappings().first()
        esp_antes = [r[0] for r in (await c.execute(_t(
            "SELECT specialty_code FROM caregiver_specialties cs "
            "JOIN caregiver_profiles p ON p.id=cs.profile_id WHERE p.user_id=:u"),
            {"u": cuidadora})).all()]
        idi_antes = [(r[0], r[1]) for r in (await c.execute(_t(
            "SELECT language_code, proficiency FROM caregiver_languages cl "
            "JOIN caregiver_profiles p ON p.id=cl.profile_id WHERE p.user_id=:u"),
            {"u": cuidadora})).all()]
        zon_antes = [r[0] for r in (await c.execute(_t(
            "SELECT commune_code FROM caregiver_zones cz "
            "JOIN caregiver_profiles p ON p.id=cz.profile_id WHERE p.user_id=:u"),
            {"u": cuidadora})).all()]
        certs_antes = (await c.execute(_t(
            "SELECT count(*) FROM caregiver_certifications cp "
            "JOIN caregiver_profiles p ON p.id=cp.profile_id WHERE p.user_id=:u"),
            {"u": cuidadora})).scalar()

    r = await client.put("/api/v1/caregiver/profile",
                         json={"headline": "Cuidadora con experiencia en demencias",
                               "bio": "Trabajo con adultos mayores hace 8 anios.",
                               "years_experience": 9,
                               "specialties": ["Diabetes", "Alzheimer y demencias"],
                               "languages": ["es", "en", "pt"],
                               "zones": ["08101", "08102"]},
                         headers=token(cuidadora))
    check("guarda el perfil", 200, r, campo="headline")
    if r.status_code == 200:
        d = r.json()
        n += 1
        if d["years_experience"] == 9 and "demencias" in d["headline"]:
            ok += 1; print("  OK   guarda titular y experiencia")
        else:
            print(f"  FALLA {d['headline']} / {d['years_experience']}")
        n += 1
        if sorted(d["languages"]) == ["en", "es", "pt"]:
            ok += 1; print("  OK   reemplaza la lista de idiomas completa")
        else:
            print(f"  FALLA idiomas {d['languages']}")
        n += 1
        if sorted(d["zones"]) == ["08101", "08102"]:
            ok += 1; print("  OK   reemplaza las zonas, quita las que ya no vienen")
        else:
            print(f"  FALLA zonas {d['zones']}")
        n += 1
        if len(d["specialties"]) == 2:
            ok += 1; print("  OK   acepta las especialidades por su etiqueta")
        else:
            print(f"  FALLA especialidades {d['specialties']}")
        n += 1
        if len(d["certifications"]) == certs_antes:
            ok += 1; print(f"  OK   no toca las certificaciones ({certs_antes} siguen ahi)")
        else:
            print(f"  FALLA habia {certs_antes} y quedaron {len(d['certifications'])}")

    check("especialidad que no esta en el catalogo", 422,
          await client.put("/api/v1/caregiver/profile",
                           json={"headline": "x", "specialties": ["Telequinesis"]},
                           headers=token(cuidadora)))
    check("codigo de idioma mal escrito", 422,
          await client.put("/api/v1/caregiver/profile",
                           json={"headline": "x", "languages": ["espanol"]},
                           headers=token(cuidadora)))
    check("codigo de comuna mal escrito", 422,
          await client.put("/api/v1/caregiver/profile",
                           json={"headline": "x", "zones": ["Concepcion"]},
                           headers=token(cuidadora)))
    check("experiencia negativa", 422,
          await client.put("/api/v1/caregiver/profile",
                           json={"headline": "x", "years_experience": -3},
                           headers=token(cuidadora)))

    r = await client.put("/api/v1/caregiver/profile",
                         json={"headline": "   ", "years_experience": 4},
                         headers=token(cuidadora))
    n += 1
    if r.status_code == 200 and r.json()["headline"].strip():
        ok += 1; print(f"  OK   titular vacio se completa solo ('{r.json()['headline']}')")
    else:
        print(f"  FALLA {r.status_code} {r.text[:90]}")

    # crear uno desde cero
    r = await client.put("/api/v1/caregiver/profile",
                         json={"headline": "Recien empiezo", "years_experience": 1,
                               "languages": ["es"]},
                         headers=token(str(libre)))
    check("crea el perfil de quien no tenia", 200, r)
    if r.status_code == 200:
        n += 1
        if r.json()["headline"] == "Recien empiezo" and r.json()["languages"] == ["es"]:
            ok += 1; print("  OK   el perfil nuevo queda con lo que mando")
        else:
            print(f"  FALLA {r.json()}")

    async with _eng.begin() as c:
        pid_libre = (await c.execute(_t(
            "SELECT id FROM caregiver_profiles WHERE user_id=:u"), {"u": str(libre)})).scalar()
        if pid_libre:
            for t in ("caregiver_languages", "caregiver_zones", "caregiver_specialties"):
                await c.execute(_t(f"DELETE FROM {t} WHERE profile_id=:p"), {"p": str(pid_libre)})
            await c.execute(_t("DELETE FROM caregiver_profiles WHERE id=:p"), {"p": str(pid_libre)})
        await c.execute(_t("UPDATE users SET account_type=:t WHERE id=:u"),
                        {"t": tipo_libre, "u": str(libre)})
        await c.execute(_t(
            "UPDATE caregiver_profiles SET headline=:h, bio=:b, years_experience=:a "
            "WHERE user_id=:u"),
            {"h": antes["headline"], "b": antes["bio"], "a": antes["years_experience"],
             "u": cuidadora})
        pid_c = (await c.execute(_t(
            "SELECT id FROM caregiver_profiles WHERE user_id=:u"), {"u": cuidadora})).scalar()
        for t in ("caregiver_specialties", "caregiver_languages", "caregiver_zones"):
            await c.execute(_t(f"DELETE FROM {t} WHERE profile_id=:p"), {"p": str(pid_c)})
        for cod in esp_antes:
            await c.execute(_t("INSERT INTO caregiver_specialties (profile_id, specialty_code) "
                               "VALUES (:p,:c)"), {"p": str(pid_c), "c": cod})
        for cod, niv in idi_antes:
            await c.execute(_t("INSERT INTO caregiver_languages (profile_id, language_code, "
                               "proficiency) VALUES (:p,:c,:n)"),
                            {"p": str(pid_c), "c": cod, "n": niv})
        for cod in zon_antes:
            await c.execute(_t("INSERT INTO caregiver_zones (profile_id, commune_code) "
                               "VALUES (:p,:c)"), {"p": str(pid_c), "c": cod})

    check("guardar sin autenticar", 401,
          await client.put("/api/v1/caregiver/profile", json={"headline": "x"}))

    check("perfil sin autenticar", 401, await client.get("/api/v1/caregiver/profile"))

    print("--- informes ---")
    r = await client.get("/api/v1/caregiver/reports", headers=token(cuidadora))
    check("devuelve el informe", 200, r, campo="period")
    if r.status_code == 200:
        d = r.json()
        print(f"       periodo        : {d['period']}")
        print(f"       tareas hechas  : {d['tasks_completed']}")
        print(f"       puntualidad    : {d['punctuality_pct']}%")
        print(f"       turnos cerrados: {d['checkins_on_time']}")
        print(f"       observaciones  : {d['observations_logged']}")
        print(f"       serie          : {[(p['label'], p['value']) for p in d['weekly_tasks']]}")
        n += 1
        if len(d["weekly_tasks"]) == 7:
            ok += 1; print("  OK   la serie trae los 7 dias, con ceros incluidos")
        else:
            print(f"  FALLA la serie trae {len(d['weekly_tasks'])} dias")
        n += 1
        if all(isinstance(p["value"], (int, float)) for p in d["weekly_tasks"]):
            ok += 1; print("  OK   todos los puntos son numeros")
        else:
            print("  FALLA hay puntos que no son numeros")
        n += 1
        if 0 <= d["punctuality_pct"] <= 100:
            ok += 1; print("  OK   la puntualidad esta entre 0 y 100")
        else:
            print(f"  FALLA puntualidad {d['punctuality_pct']}")

    # con una tarea recien completada el contador sube
    async with _eng.begin() as c:
        await c.execute(_t(
            "INSERT INTO care_tasks (patient_id, assigned_to_user_id, created_by_user_id, "
            "title, due_date, status, completed_at) "
            "VALUES (:p,:u,:u,'PRUEBA informe',current_date,'completed',now())"),
            {"p": PACIENTE, "u": cuidadora})
    r2 = await client.get("/api/v1/caregiver/reports", headers=token(cuidadora))
    n += 1
    if r2.json()["tasks_completed"] == r.json()["tasks_completed"] + 1:
        ok += 1; print("  OK   una tarea completada suma al contador")
    else:
        print(f"  FALLA {r.json()['tasks_completed']} -> {r2.json()['tasks_completed']}")
    n += 1
    if r2.json()["weekly_tasks"][-1]["value"] >= 1:
        ok += 1; print("  OK   y aparece en el dia de hoy de la serie")
    else:
        print("  FALLA no aparece en la serie")
    async with _eng.begin() as c:
        await c.execute(_t("DELETE FROM care_tasks WHERE title='PRUEBA informe'"))

    # alguien sin nada hecho recibe ceros, no un error
    r = await client.get("/api/v1/caregiver/reports", headers=token(str(libre)))
    check("quien no ha hecho nada recibe el informe en cero", 200, r)
    if r.status_code == 200:
        n += 1
        d = r.json()
        if d["tasks_completed"] == 0 and d["punctuality_pct"] == 0 and len(d["weekly_tasks"]) == 7:
            ok += 1; print("  OK   ceros y la serie completa, sin dividir por cero")
        else:
            print(f"  FALLA {d}")

    check("informe sin autenticar", 401, await client.get("/api/v1/caregiver/reports"))

    check("usuario sin pacientes", 404,
          await client.get("/api/v1/caregiver/today", headers=token(AJENO)))
    check("sin autenticar", 401, await client.get("/api/v1/caregiver/today"))


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
