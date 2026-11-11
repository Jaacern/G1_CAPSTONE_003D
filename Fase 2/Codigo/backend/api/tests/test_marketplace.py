"""Pruebas del marketplace."""
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
from app.routers import marketplace  # noqa: E402

app = FastAPI()
register_error_handlers(app)
app.include_router(marketplace.router)
app.include_router(marketplace.jobs_router)

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


async def ctx():
    async with _eng.begin() as c:
        rr = {m["role"]: str(m["user_id"]) for m in (await c.execute(_t(
            "SELECT user_id, role FROM patient_members WHERE patient_id=:p "
            "AND removed_at IS NULL"), {"p": PACIENTE})).mappings().all()}
        perfil = (await c.execute(_t(
            "SELECT cp.id, cp.status, cp.user_id FROM caregiver_profiles cp LIMIT 1"))).mappings().first()
    return rr, perfil


async def main(client, rr, perfil):
    global n, ok
    familiar = rr["family"]
    pid = str(perfil["id"])

    print("--- buscar cuidadoras ---")
    r = await client.get("/api/v1/marketplace/caregivers", headers=token(familiar))
    check("lista las cuidadoras publicadas", 200, r, campo="items")
    if r.status_code == 200:
        items = r.json()["items"]
        print(f"       encontradas: {len(items)}")
        if items:
            d = items[0]
            print(f"       {d['name']} | {d['rating']} ({d['reviews_count']}) | "
                  f"${d['price_per_hour']} | {d['zones']} | {d['specialties']}")
            n += 1
            if d["zones"] and d["specialties"]:
                ok += 1; print("  OK   trae zonas y especialidades en la misma consulta")
            else:
                print(f"  FALLA listas vacias: {d['zones']} {d['specialties']}")
            n += 1
            if isinstance(d["rating"], float) and d["reviews_count"] >= 0:
                ok += 1; print("  OK   trae la nota y cuantas resenas tiene")
            else:
                print("  FALLA rating mal formado")

    # filtro por zona
    async with _eng.begin() as c:
        zona = (await c.execute(_t(
            "SELECT commune_code FROM caregiver_zones WHERE profile_id=:p LIMIT 1"),
            {"p": pid})).scalar()
    r = await client.get(f"/api/v1/marketplace/caregivers?zone={zona}", headers=token(familiar))
    n += 1
    if r.status_code == 200 and len(r.json()["items"]) >= 1:
        ok += 1; print(f"  OK   filtra por comuna ({zona})")
    else:
        print(f"  FALLA filtro por zona: {r.status_code} {len(r.json().get('items', []))}")

    r = await client.get("/api/v1/marketplace/caregivers?zone=99999", headers=token(familiar))
    n += 1
    if r.status_code == 200 and r.json()["items"] == []:
        ok += 1; print("  OK   una comuna sin cuidadoras devuelve lista vacia, no error")
    else:
        print(f"  FALLA {r.status_code}")

    # filtro por especialidad, por etiqueta y por codigo
    async with _eng.begin() as c:
        esp = (await c.execute(_t(
            "SELECT s.code, s.label FROM caregiver_specialties cs "
            "JOIN specialties s ON s.code=cs.specialty_code WHERE cs.profile_id=:p LIMIT 1"),
            {"p": pid})).mappings().first()
    for valor, como in [(esp["code"], "codigo"), (esp["label"], "etiqueta")]:
        r = await client.get(f"/api/v1/marketplace/caregivers?specialty={valor}",
                             headers=token(familiar))
        n += 1
        if r.status_code == 200 and len(r.json()["items"]) >= 1:
            ok += 1; print(f"  OK   filtra por especialidad usando el {como} ({valor})")
        else:
            print(f"  FALLA filtro por {como}: {r.status_code}")

    # un perfil no publicado no aparece
    async with _eng.begin() as c:
        # El CHECK de fechas exige que draft no tenga published_at.
        await c.execute(_t("UPDATE caregiver_profiles SET status='draft', "
                           "published_at=NULL, suspended_at=NULL WHERE id=:p"), {"p": pid})
    r = await client.get("/api/v1/marketplace/caregivers", headers=token(familiar))
    n += 1
    if all(i["profile_id"] != pid for i in r.json()["items"]):
        ok += 1; print("  OK   un perfil en borrador no aparece en el buscador")
    else:
        print("  FALLA el borrador aparece")

    async with _eng.begin() as c:
        await c.execute(_t("UPDATE caregiver_profiles SET status='suspended', "
                           "published_at=coalesce(published_at, now()), "
                           "suspended_at=now() WHERE id=:p"), {"p": pid})
    r = await client.get("/api/v1/marketplace/caregivers", headers=token(familiar))
    n += 1
    if all(i["profile_id"] != pid for i in r.json()["items"]):
        ok += 1; print("  OK   un perfil suspendido tampoco aparece")
    else:
        print("  FALLA el suspendido aparece")

    async with _eng.begin() as c:
        await c.execute(_t("UPDATE caregiver_profiles SET status=:s, suspended_at=NULL, "
                           "published_at=coalesce(published_at, now()) WHERE id=:p"),
                        {"s": perfil["status"], "p": pid})

    print("--- ficha de la cuidadora ---")
    r = await client.get(f"/api/v1/marketplace/caregivers/{pid}", headers=token(familiar))
    check("devuelve la ficha", 200, r, campo="bio")
    if r.status_code == 200:
        d = r.json()
        print(f"       {d['name']} | {d['years_experience']} anios | idiomas {d['languages']}")
        print(f"       certificados verificados: {d['certifications']}")
        print(f"       resenas: {len(d['reviews'])}")
        n += 1
        if d["profile_id"] == pid and d["bio"]:
            ok += 1; print("  OK   trae biografia y experiencia")
        else:
            print(f"  FALLA {d['profile_id']} / bio vacia")
        n += 1
        if d["reviews"] and all(x["rating"] >= 1 for x in d["reviews"]):
            ok += 1; print("  OK   trae las resenas con su autor y nota")
        else:
            print(f"  FALLA resenas {d['reviews']}")
        n += 1
        if d["languages"] and d["zones"] and d["specialties"]:
            ok += 1; print("  OK   trae las tres listas del perfil")
        else:
            print("  FALLA alguna lista vacia")

    # solo certificaciones verificadas
    async with _eng.begin() as c:
        total = (await c.execute(_t(
            "SELECT count(*) FROM caregiver_certifications WHERE profile_id=:p "
            "AND deleted_at IS NULL"), {"p": pid})).scalar()
        verif = (await c.execute(_t(
            "SELECT count(*) FROM caregiver_certifications WHERE profile_id=:p "
            "AND deleted_at IS NULL AND verified_at IS NOT NULL"), {"p": pid})).scalar()
    n += 1
    if len(r.json()["certifications"]) == verif:
        ok += 1; print(f"  OK   muestra solo las verificadas ({verif} de {total})")
    else:
        print(f"  FALLA muestra {len(r.json()['certifications'])}, verificadas {verif}")

    check("ficha inexistente", 404,
          await client.get("/api/v1/marketplace/caregivers/"
                           "99999999-9999-4999-8999-999999999991", headers=token(familiar)))

    async with _eng.begin() as c:
        await c.execute(_t("UPDATE caregiver_profiles SET status='draft', "
                           "published_at=NULL, suspended_at=NULL WHERE id=:p"), {"p": pid})
    check("ficha de un perfil en borrador", 404,
          await client.get(f"/api/v1/marketplace/caregivers/{pid}", headers=token(familiar)))
    async with _eng.begin() as c:
        await c.execute(_t("UPDATE caregiver_profiles SET status='published', "
                           "published_at=now() WHERE id=:p"), {"p": pid})

    check("ficha sin autenticar", 401,
          await client.get(f"/api/v1/marketplace/caregivers/{pid}"))

    print("--- contactar ---")
    async with _eng.begin() as c:
        await c.execute(_t("DELETE FROM contact_requests WHERE message LIKE 'PRUEBA%'"))

    r = await client.post(f"/api/v1/marketplace/caregivers/{pid}/contact",
                          json={"message": "PRUEBA necesito ayuda los martes y jueves",
                                "patient_id": PACIENTE},
                          headers=token(familiar))
    check("envia la solicitud de contacto", 201, r, campo="id")
    if r.status_code == 201:
        n += 1
        if r.json()["status"] == "pending":
            ok += 1; print("  OK   nace pendiente")
        else:
            print(f"  FALLA estado {r.json()['status']}")
        primera = r.json()["id"]

        r2 = await client.post(f"/api/v1/marketplace/caregivers/{pid}/contact",
                               json={"message": "PRUEBA insisto, sigo buscando"},
                               headers=token(familiar))
        n += 1
        if r2.status_code == 201 and r2.json()["id"] == primera:
            ok += 1; print("  OK   reenviar actualiza la solicitud pendiente, no crea otra")
        else:
            print(f"  FALLA {r2.status_code} {r2.text[:90]}")
        async with _eng.begin() as c:
            msg = (await c.execute(_t(
                "SELECT message FROM contact_requests WHERE id=:i"),
                {"i": primera})).scalar()
        n += 1
        if "insisto" in msg:
            ok += 1; print("  OK   quedo el mensaje nuevo")
        else:
            print(f"  FALLA mensaje: {msg}")

    check("mensaje de solo espacios", 422,
          await client.post(f"/api/v1/marketplace/caregivers/{pid}/contact",
                            json={"message": "    "}, headers=token(familiar)))
    check("contactar con un paciente que no es suyo", 404,
          await client.post(f"/api/v1/marketplace/caregivers/{pid}/contact",
                            json={"message": "PRUEBA x",
                                  "patient_id": "99999999-9999-4999-8999-999999999991"},
                            headers=token(familiar)))
    check("contactar a una cuidadora inexistente", 404,
          await client.post("/api/v1/marketplace/caregivers/"
                            "99999999-9999-4999-8999-999999999991/contact",
                            json={"message": "PRUEBA x"}, headers=token(familiar)))
    check("la cuidadora no se contacta a si misma", 422,
          await client.post(f"/api/v1/marketplace/caregivers/{pid}/contact",
                            json={"message": "PRUEBA yo misma"},
                            headers=token(str(perfil["user_id"]))))
    check("contactar sin autenticar", 401,
          await client.post(f"/api/v1/marketplace/caregivers/{pid}/contact",
                            json={"message": "x"}))

    async with _eng.begin() as c:
        await c.execute(_t("DELETE FROM contact_requests WHERE message LIKE 'PRUEBA%'"))

    print("--- resenar ---")
    # el familiar comparte el circulo con la cuidadora, puede resenar
    async with _eng.begin() as c:
        previa = (await c.execute(_t(
            "SELECT id, rating, comment, patient_id FROM caregiver_reviews "
            "WHERE profile_id=:p AND author_id=:a"),
            {"p": pid, "a": familiar})).mappings().first()
        avg_antes = (await c.execute(_t(
            "SELECT rating_avg, rating_count FROM caregiver_profiles WHERE id=:p"),
            {"p": pid})).mappings().first()

    r = await client.post(f"/api/v1/marketplace/caregivers/{pid}/reviews",
                          json={"rating": 4, "comment": "PRUEBA muy dedicada con mi madre"},
                          headers=token(familiar))
    check("deja la resena", 201, r, campo="rating")
    if r.status_code == 201:
        n += 1
        if r.json()["rating"] == 4:
            ok += 1; print("  OK   guarda la nota")
        else:
            print(f"  FALLA nota {r.json()['rating']}")
        async with _eng.begin() as c:
            ahora = (await c.execute(_t(
                "SELECT rating_avg, rating_count FROM caregiver_profiles WHERE id=:p"),
                {"p": pid})).mappings().first()
        n += 1
        if float(ahora["rating_avg"]) == 4.0:
            ok += 1; print(f"  OK   el trigger recalculo el promedio ({avg_antes['rating_avg']} -> {ahora['rating_avg']})")
        else:
            print(f"  FALLA promedio {ahora['rating_avg']}")

        # cambiar de opinion
        r2 = await client.post(f"/api/v1/marketplace/caregivers/{pid}/reviews",
                               json={"rating": 5, "comment": "PRUEBA lo pense mejor, excelente"},
                               headers=token(familiar))
        async with _eng.begin() as c:
            cuantas = (await c.execute(_t(
                "SELECT count(*) FROM caregiver_reviews WHERE profile_id=:p AND author_id=:a"),
                {"p": pid, "a": familiar})).scalar()
            avg2 = (await c.execute(_t(
                "SELECT rating_avg FROM caregiver_profiles WHERE id=:p"), {"p": pid})).scalar()
        n += 1
        if r2.status_code == 201 and cuantas == 1 and float(avg2) == 5.0:
            ok += 1; print("  OK   la segunda resena reemplaza a la primera y recalcula")
        else:
            print(f"  FALLA {r2.status_code}, {cuantas} resenas, promedio {avg2}")

    check("nota fuera de rango", 422,
          await client.post(f"/api/v1/marketplace/caregivers/{pid}/reviews",
                            json={"rating": 9}, headers=token(familiar)))
    check("nota cero", 422,
          await client.post(f"/api/v1/marketplace/caregivers/{pid}/reviews",
                            json={"rating": 0}, headers=token(familiar)))
    check("la cuidadora no se resena a si misma", 422,
          await client.post(f"/api/v1/marketplace/caregivers/{pid}/reviews",
                            json={"rating": 5}, headers=token(str(perfil["user_id"]))))
    check("alguien que nunca compartio circulo", 403,
          await client.post(f"/api/v1/marketplace/caregivers/{pid}/reviews",
                            json={"rating": 5}, headers=token(AJENO)))
    check("resenar con un paciente que no comparten", 403,
          await client.post(f"/api/v1/marketplace/caregivers/{pid}/reviews",
                            json={"rating": 5,
                                  "patient_id": "99999999-9999-4999-8999-999999999991"},
                            headers=token(familiar)))
    check("resenar sin autenticar", 401,
          await client.post(f"/api/v1/marketplace/caregivers/{pid}/reviews",
                            json={"rating": 5}))

    # dejar la resena como estaba
    async with _eng.begin() as c:
        if previa:
            await c.execute(_t(
                "UPDATE caregiver_reviews SET rating=:r, comment=:c, patient_id=:p "
                "WHERE profile_id=:pr AND author_id=:a"),
                {"r": previa["rating"], "c": previa["comment"],
                 "p": str(previa["patient_id"]), "pr": pid, "a": familiar})
        else:
            await c.execute(_t(
                "DELETE FROM caregiver_reviews WHERE profile_id=:p AND author_id=:a"),
                {"p": pid, "a": familiar})

    print("--- catalogo de productos ---")
    r = await client.get("/api/v1/marketplace/products", headers=token(familiar))
    check("lista el catalogo", 200, r, campo="items")
    if r.status_code == 200:
        items = r.json()["items"]
        print(f"       productos: {len(items)}")
        for i in items[:3]:
            print(f"       {i['category']:11} {i['name'][:38]:40} ${i['price']:,.0f}")
        n += 1
        if len(items) >= 10:
            ok += 1; print(f"  OK   trae el catalogo completo ({len(items)})")
        else:
            print(f"  FALLA solo {len(items)}")
        n += 1
        cats = [i["category"] for i in items]
        if cats == sorted(cats):
            ok += 1; print("  OK   viene agrupado por categoria")
        else:
            print("  FALLA no viene ordenado")
        n += 1
        if all(isinstance(i["price"], float) for i in items):
            ok += 1; print("  OK   el precio siempre es un numero, nunca nulo")
        else:
            print("  FALLA hay precios nulos")

    r = await client.get("/api/v1/marketplace/products?category=bathroom",
                         headers=token(familiar))
    n += 1
    if r.status_code == 200 and r.json()["items"] and \
       all(i["category"] == "bathroom" for i in r.json()["items"]):
        ok += 1; print(f"  OK   filtra por categoria ({len(r.json()['items'])} de bano)")
    else:
        print(f"  FALLA filtro: {r.status_code}")

    check("categoria inventada", 422,
          await client.get("/api/v1/marketplace/products?category=teletransporte",
                           headers=token(familiar)))

    # un producto en borrador no aparece
    async with _eng.begin() as c:
        prod = (await c.execute(_t(
            "SELECT id FROM market_products WHERE status='published' LIMIT 1"))).scalar()
        await c.execute(_t("UPDATE market_products SET status='draft', published_at=NULL "
                           "WHERE id=:i"), {"i": str(prod)})
    r = await client.get("/api/v1/marketplace/products", headers=token(familiar))
    n += 1
    if all(i["id"] != str(prod) for i in r.json()["items"]):
        ok += 1; print("  OK   un producto en borrador no aparece")
    else:
        print("  FALLA el borrador aparece")
    check("detalle de un producto en borrador", 404,
          await client.get(f"/api/v1/marketplace/products/{prod}", headers=token(familiar)))
    async with _eng.begin() as c:
        await c.execute(_t("UPDATE market_products SET status='published', "
                           "published_at=now() WHERE id=:i"), {"i": str(prod)})

    r = await client.get(f"/api/v1/marketplace/products/{prod}", headers=token(familiar))
    check("detalle de un producto", 200, r, campo="description")
    if r.status_code == 200:
        d = r.json()
        n += 1
        if d["id"] == str(prod) and len(d["description"]) > 20:
            ok += 1; print(f"  OK   trae la descripcion completa ({d['name'][:40]})")
        else:
            print("  FALLA descripcion corta o id distinto")

    check("producto inexistente", 404,
          await client.get("/api/v1/marketplace/products/"
                           "99999999-9999-4999-8999-999999999991", headers=token(familiar)))
    check("catalogo sin autenticar", 401,
          await client.get("/api/v1/marketplace/products"))

    print("--- ofertas de trabajo ---")
    r = await client.get("/api/v1/jobs", headers=token(familiar))
    check("lista las ofertas", 200, r, campo="items")
    if r.status_code == 200:
        items = r.json()["items"]
        print(f"       ofertas: {len(items)}")
        for i in items[:4]:
            print(f"       {i['zone']}  {i['pay']:34} {i['title'][:38]}")
        n += 1
        if len(items) >= 5:
            ok += 1; print(f"  OK   trae las publicadas ({len(items)})")
        else:
            print(f"  FALLA solo {len(items)}")
        n += 1
        if all(i["pay"] and not i["pay"].startswith("$0") for i in items):
            ok += 1; print("  OK   todas traen el pago escrito, ninguna en cero")
        else:
            print(f"  FALLA pagos {[i['pay'] for i in items]}")
        n += 1
        rango = [i for i in items if " a $" in i["pay"]]
        desde = [i for i in items if i["pay"].startswith("Desde")]
        if rango and desde:
            ok += 1; print(f"  OK   distingue rango ('{rango[0]['pay']}') de minimo ('{desde[0]['pay']}')")
        else:
            print(f"  FALLA no distingue los dos casos")
        n += 1
        if any("." in i["pay"] for i in items):
            ok += 1; print("  OK   usa separador de miles con punto")
        else:
            print("  FALLA sin formato de miles")

    r = await client.get("/api/v1/jobs?zone=08101", headers=token(familiar))
    n += 1
    if r.status_code == 200 and r.json()["items"] and \
       all(i["zone"] == "08101" for i in r.json()["items"]):
        ok += 1; print(f"  OK   filtra por comuna ({len(r.json()['items'])} en 08101)")
    else:
        print(f"  FALLA filtro: {r.status_code}")

    # una cerrada no sale
    async with _eng.begin() as c:
        uno = (await c.execute(_t(
            "SELECT id FROM job_offers WHERE status='published' LIMIT 1"))).scalar()
        await c.execute(_t("UPDATE job_offers SET status='closed', closed_at=now() "
                           "WHERE id=:i"), {"i": str(uno)})
    r = await client.get("/api/v1/jobs", headers=token(familiar))
    n += 1
    if all(i["id"] != str(uno) for i in r.json()["items"]):
        ok += 1; print("  OK   una oferta cerrada no aparece")
    else:
        print("  FALLA la cerrada aparece")
    async with _eng.begin() as c:
        await c.execute(_t("UPDATE job_offers SET status='published', closed_at=NULL "
                           "WHERE id=:i"), {"i": str(uno)})

    check("ofertas sin autenticar", 401,
          await client.get("/api/v1/jobs"))

    check("buscar sin autenticar", 401,
          await client.get("/api/v1/marketplace/caregivers"))


async def run():
    rr, perfil = await ctx()
    transport = httpx.ASGITransport(app=app)
    async with httpx.AsyncClient(transport=transport, base_url="http://testserver") as cl:
        await main(cl, rr, perfil)
    await _eng.dispose()
    print()
    print(f"resultado: {ok} de {n}")
    # Codigo de salida para que el CI lo vea.
    return 0 if ok == n else 1


import sys  # noqa: E402

sys.exit(asyncio.run(run()))
