"""Pruebas de la galeria familiar."""
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
from app.routers import files, gallery  # noqa: E402

app = FastAPI()
register_error_handlers(app)
app.include_router(files.router)
app.include_router(gallery.router)

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
        return {m["role"]: str(m["user_id"]) for m in (await c.execute(_t(
            "SELECT user_id, role FROM patient_members WHERE patient_id=:p "
            "AND removed_at IS NULL"), {"p": PACIENTE})).mappings().all()}


async def subir(client, uid, nombre="foto.jpg"):
    up = await client.post("/api/v1/uploads",
                           json={"filename": nombre, "content_type": "image/jpeg",
                                 "kind": "photo", "size": 24, "patient_id": PACIENTE},
                           headers=token(uid))
    d = up.json()
    await client.put(d["upload_url"].replace("http://testserver", ""),
                     content=b"\xff\xd8\xff\xe0" + b"x" * 18 + b"\xff\xd9",
                     headers={"Content-Type": "image/jpeg"})
    return d["file_url"]


async def main(client, rr):
    global n, ok
    familiar = rr["family"]
    elder = rr.get("elder")
    cuidadora = rr.get("caregiver")

    async with _eng.begin() as c:
        await c.execute(_t("DELETE FROM photo_reactions WHERE photo_id IN "
                           "(SELECT id FROM gallery_photos WHERE caption LIKE 'PRUEBA%')"))
        await c.execute(_t("DELETE FROM gallery_photos WHERE caption LIKE 'PRUEBA%'"))
        # dos fotos de prueba
        for i, cap in enumerate(["PRUEBA los nietos en la playa", "PRUEBA el cumpleanos"]):
            url = await subir(client, familiar, f"f{i}.jpg")
            fid = url.rstrip("/").split("/")[-1]
            pid_foto = (await c.execute(_t(
                "INSERT INTO gallery_photos (patient_id, published_by_user_id, file_id, "
                "caption, display_order) VALUES (:p,:u,:f,:c,:o) RETURNING id"),
                {"p": PACIENTE, "u": familiar, "f": fid, "c": cap, "o": i})).scalar()
            if i == 0 and elder:
                await c.execute(_t(
                    "INSERT INTO photo_reactions (photo_id, user_id, reaction_type) "
                    "VALUES (:f,:u,'love')"), {"f": str(pid_foto), "u": elder})
                if cuidadora:
                    await c.execute(_t(
                        "INSERT INTO photo_reactions (photo_id, user_id, reaction_type) "
                        "VALUES (:f,:u,'smile')"), {"f": str(pid_foto), "u": cuidadora})

    print("--- listar la galeria ---")
    r = await client.get(f"/api/v1/patients/{PACIENTE}/photos", headers=token(familiar))
    check("lista las fotos", 200, r, campo="items")
    if r.status_code == 200:
        items = [i for i in r.json()["items"] if (i["caption"] or "").startswith("PRUEBA")]
        print(f"       fotos de prueba: {len(items)}")
        for i in items:
            print(f"       {i['caption'][:34]:36} de {i['from_name']:14} {i['reactions']}")
        n += 1
        if len(items) == 2:
            ok += 1; print("  OK   trae las dos fotos")
        else:
            print(f"  FALLA trae {len(items)}")
        con_react = [i for i in items if i["reactions"]]
        n += 1
        if con_react and con_react[0]["reactions"].get("love") == 1:
            ok += 1; print("  OK   cuenta las reacciones por tipo")
        else:
            print(f"  FALLA reacciones {[i['reactions'] for i in items]}")
        n += 1
        if any(i["reactions"] == {} for i in items):
            ok += 1; print("  OK   una foto sin reacciones trae el diccionario vacio, no nulo")
        else:
            print("  FALLA la foto sin reacciones no trae {}")
        n += 1
        if all(i["url"].startswith("http") and "/files/" in i["url"] for i in items):
            ok += 1; print("  OK   la url apunta al archivo")
        else:
            print("  FALLA url mal armada")
        n += 1
        if all(i["from_name"] for i in items):
            ok += 1; print("  OK   dice quien la compartio")
        else:
            print("  FALLA sin from_name")

    # una foto borrada no aparece
    async with _eng.begin() as c:
        await c.execute(_t("UPDATE gallery_photos SET deleted_at=now() "
                           "WHERE caption='PRUEBA el cumpleanos'"))
    r = await client.get(f"/api/v1/patients/{PACIENTE}/photos", headers=token(familiar))
    n += 1
    if "PRUEBA el cumpleanos" not in [i["caption"] for i in r.json()["items"]]:
        ok += 1; print("  OK   una foto borrada no aparece")
    else:
        print("  FALLA la borrada aparece")
    async with _eng.begin() as c:
        await c.execute(_t("UPDATE gallery_photos SET deleted_at=NULL "
                           "WHERE caption='PRUEBA el cumpleanos'"))

    print("--- compartir una foto ---")
    url = await subir(client, familiar, "nueva.jpg")
    r = await client.post(f"/api/v1/patients/{PACIENTE}/photos",
                          json={"file_url": url, "caption": "PRUEBA almuerzo del domingo"},
                          headers=token(familiar))
    check("comparte la foto", 201, r, campo="id")
    if r.status_code == 201:
        d = r.json()
        n += 1
        if d["caption"] == "PRUEBA almuerzo del domingo" and d["reactions"] == {}:
            ok += 1; print("  OK   nace con su texto y sin reacciones")
        else:
            print(f"  FALLA {d}")
        n += 1
        if d["from_name"]:
            ok += 1; print(f"  OK   queda a nombre de quien la compartio ({d['from_name']})")
        else:
            print("  FALLA sin from_name")

        # queda primera en la lista
        lista = (await client.get(f"/api/v1/patients/{PACIENTE}/photos",
                                  headers=token(familiar))).json()["items"]
        n += 1
        if lista and lista[0]["id"] == d["id"]:
            ok += 1; print("  OK   la foto nueva queda primera en la galeria")
        else:
            print(f"  FALLA quedo en la posicion {[i['id'] for i in lista].index(d['id'])}")

        # reintento con el mismo archivo
        r2 = await client.post(f"/api/v1/patients/{PACIENTE}/photos",
                               json={"file_url": url, "caption": "PRUEBA reintento"},
                               headers=token(familiar))
        n += 1
        if r2.status_code == 201 and r2.json()["id"] == d["id"]:
            ok += 1; print("  OK   reenviar la misma foto no la duplica")
        else:
            print(f"  FALLA {r2.status_code}")

    u2 = await subir(client, familiar, "sin-texto.jpg")
    r = await client.post(f"/api/v1/patients/{PACIENTE}/photos",
                          json={"file_url": u2}, headers=token(familiar))
    check("una foto sin texto se acepta", 201, r)
    if r.status_code == 201:
        async with _eng.begin() as c:
            await c.execute(_t("UPDATE gallery_photos SET caption='PRUEBA sin texto' "
                               "WHERE id=:i"), {"i": r.json()["id"]})

    u3 = await subir(client, familiar, "mala.jpg")
    check("archivo que no existe", 422,
          await client.post(f"/api/v1/patients/{PACIENTE}/photos",
                            json={"file_url": "http://testserver/api/v1/files/"
                                               "99999999-9999-4999-8999-999999999991"},
                            headers=token(familiar)))
    check("url que no es una referencia", 422,
          await client.post(f"/api/v1/patients/{PACIENTE}/photos",
                            json={"file_url": "https://ejemplo.com/foto.jpg"},
                            headers=token(familiar)))
    if elder:
        check("el adulto mayor no publica en su propia galeria", 403,
              await client.post(f"/api/v1/patients/{PACIENTE}/photos",
                                json={"file_url": u3}, headers=token(elder)))
    check("compartir desde fuera del circulo", 404,
          await client.post(f"/api/v1/patients/{PACIENTE}/photos",
                            json={"file_url": u3}, headers=token(AJENO)))

    print("--- reaccionar ---")
    async with _eng.begin() as c:
        foto = (await c.execute(_t(
            "SELECT id FROM gallery_photos WHERE caption='PRUEBA el cumpleanos'"))).scalar()
        await c.execute(_t("DELETE FROM photo_reactions WHERE photo_id=:f"), {"f": str(foto)})

    quien = elder or familiar
    r = await client.post(f"/api/v1/photos/{foto}/reactions",
                          json={"reaction": "love"}, headers=token(quien))
    check("deja una reaccion", 200, r, campo="reactions")
    if r.status_code == 200:
        n += 1
        if r.json()["reactions"].get("love") == 1 and r.json()["mine"] == "love":
            ok += 1; print("  OK   queda registrada y dice cual es la mia")
        else:
            print(f"  FALLA {r.json()}")

        r2 = await client.post(f"/api/v1/photos/{foto}/reactions",
                               json={"reaction": "smile"}, headers=token(quien))
        n += 1
        if r2.json()["reactions"] == {"smile": 1} and r2.json()["mine"] == "smile":
            ok += 1; print("  OK   tocar otra cambia la reaccion, no suma otra")
        else:
            print(f"  FALLA {r2.json()}")

        r3 = await client.post(f"/api/v1/photos/{foto}/reactions",
                               json={"reaction": "smile"}, headers=token(quien))
        n += 1
        if r3.json()["reactions"] == {} and r3.json()["mine"] is None:
            ok += 1; print("  OK   tocar la misma otra vez la quita")
        else:
            print(f"  FALLA {r3.json()}")

        # dos personas distintas suman
        await client.post(f"/api/v1/photos/{foto}/reactions",
                          json={"reaction": "love"}, headers=token(quien))
        r4 = await client.post(f"/api/v1/photos/{foto}/reactions",
                               json={"reaction": "love"}, headers=token(cuidadora))
        n += 1
        if r4.json()["reactions"].get("love") == 2:
            ok += 1; print("  OK   dos personas suman la misma reaccion")
        else:
            print(f"  FALLA {r4.json()}")

    check("reaccion inventada", 422,
          await client.post(f"/api/v1/photos/{foto}/reactions",
                            json={"reaction": "aplauso"}, headers=token(quien)))
    check("reaccionar a una foto de otro circulo", 404,
          await client.post(f"/api/v1/photos/{foto}/reactions",
                            json={"reaction": "love"}, headers=token(AJENO)))
    check("foto inexistente", 404,
          await client.post("/api/v1/photos/99999999-9999-4999-8999-999999999991/reactions",
                            json={"reaction": "love"}, headers=token(quien)))

    print("--- quitar una foto ---")
    u = await subir(client, familiar, "para-borrar.jpg")
    borrable = (await client.post(f"/api/v1/patients/{PACIENTE}/photos",
                                  json={"file_url": u, "caption": "PRUEBA para borrar"},
                                  headers=token(familiar))).json()["id"]

    if cuidadora:
        check("otra persona del circulo no puede quitarla", 403,
              await client.delete(f"/api/v1/photos/{borrable}", headers=token(cuidadora)))
    check("quitar desde fuera del circulo", 404,
          await client.delete(f"/api/v1/photos/{borrable}", headers=token(AJENO)))
    check("quien la compartio la quita", 204,
          await client.delete(f"/api/v1/photos/{borrable}", headers=token(familiar)))

    async with _eng.begin() as c:
        fila = (await c.execute(_t(
            "SELECT deleted_at FROM gallery_photos WHERE id=:i"), {"i": borrable})).scalar()
    n += 1
    if fila is not None:
        ok += 1; print("  OK   es borrado logico")
    else:
        print("  FALLA no quedo marcada")

    lista = (await client.get(f"/api/v1/patients/{PACIENTE}/photos",
                              headers=token(familiar))).json()["items"]
    n += 1
    if all(i["id"] != borrable for i in lista):
        ok += 1; print("  OK   ya no aparece en la galeria")
    else:
        print("  FALLA sigue apareciendo")

    check("quitarla dos veces", 404,
          await client.delete(f"/api/v1/photos/{borrable}", headers=token(familiar)))

    if elder:
        check("el adulto mayor ve su galeria", 200,
              await client.get(f"/api/v1/patients/{PACIENTE}/photos", headers=token(elder)))
    check("alguien fuera del circulo", 404,
          await client.get(f"/api/v1/patients/{PACIENTE}/photos", headers=token(AJENO)))
    check("sin autenticar", 401,
          await client.get(f"/api/v1/patients/{PACIENTE}/photos"))


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
