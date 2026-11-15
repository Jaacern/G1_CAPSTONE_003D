"""Pruebas del endpoint POST /uploads contra la base real."""
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


from datetime import datetime, timedelta, timezone  # noqa: E402

import asyncio  # noqa: E402

import httpx  # noqa: E402
from fastapi import FastAPI  # noqa: E402
from jose import jwt  # noqa: E402

from app.config import get_settings  # noqa: E402
from app.errors import register_error_handlers  # noqa: E402
from app.routers import files  # noqa: E402

app = FastAPI()
register_error_handlers(app)
app.include_router(files.router)

FAMILIAR = "11111111-1111-4111-8111-111111111111"   # miembro del paciente
from _ajeno import AJENO  # noqa: E402  (cuenta sin circulo, creada y borrada por la prueba)
PACIENTE = "33333333-3333-4333-8333-333333333333"


def token(uid: str) -> dict:
    cfg = get_settings()
    t = jwt.encode(
        {"sub": uid, "type": "access",
         "exp": int((datetime.now(timezone.utc) + timedelta(minutes=10)).timestamp())},
        cfg.jwt_secret, algorithm=cfg.jwt_algorithm)
    return {"Authorization": f"Bearer {t}"}


async def post(client, body, uid=FAMILIAR, auth=True):
    return await client.post("/api/v1/uploads", json=body,
                             headers=token(uid) if auth else {})


BASE = {"filename": "examen.pdf", "content_type": "application/pdf",
        "kind": "document", "size": 184320, "patient_id": PACIENTE}


async def main(client):
    n = ok = 0

    def check(nombre, esperado, resp, campo=None):
        nonlocal n, ok
        n += 1
        got = resp.status_code
        bien = got == esperado
        if bien and campo:
            bien = campo in resp.json()
        if bien:
            ok += 1
            print(f"  OK   {esperado}  {nombre}")
        else:
            cuerpo = resp.text[:110].replace("\n", " ")
            print(f"  FALLA esperaba {esperado} y dio {got}  {nombre}\n       {cuerpo}")

    print("--- debe aceptar ---")
    r = await post(client, BASE)
    check("documento PDF de un paciente del circulo", 201, r)
    if r.status_code == 201:
        d = r.json()
        print(f"       upload_id : {d['upload_id']}")
        print(f"       upload_url: {d['upload_url'][:62]}...")
        print(f"       file_url  : {d['file_url']}")
        print(f"       expires_at: {d['expires_at']}")
        exp = datetime.fromisoformat(d["expires_at"])
        mins = (exp - datetime.now(timezone.utc)).total_seconds() / 60
        n += 1
        if 14 <= mins <= 15.1:
            ok += 1; print(f"  OK   RNF-13: el enlace vence en {mins:.1f} minutos")
        else:
            print(f"  FALLA RNF-13: vence en {mins:.1f} minutos, deberia ser 15")

    check("nota de voz en audio/aac (el formato que genera el front)", 201,
          await post(client, {**BASE, "filename": "nota.m4a", "content_type": "audio/aac",
                "kind": "audio", "size": 48000}))
    check("foto JPEG", 201,
          await post(client, {**BASE, "filename": "f.jpg", "content_type": "image/jpeg",
                "kind": "photo", "size": 96000}))
    check("archivo de catalogo, sin paciente", 201,
          await post(client, {"filename": "cuento.mp3", "content_type": "audio/mpeg",
                "kind": "catalog", "size": 4200000}))

    print("--- debe rechazar ---")
    check("sin autenticar", 401, await post(client, BASE, auth=False))
    check("tipo no permitido (.exe)", 422,
          await post(client, {**BASE, "filename": "v.exe", "content_type": "application/x-msdownload"}))
    check("kind inventado", 422, await post(client, {**BASE, "kind": "telepatia"}))
    check("mas de 25 MB", 413, await post(client, {**BASE, "size": 31457280}))
    check("tamano cero", 422, await post(client, {**BASE, "size": 0}))
    check("documento sin patient_id", 422,
          await post(client, {"filename": "x.pdf", "content_type": "application/pdf",
                "kind": "document", "size": 1000}))
    check("usuario que NO es del circulo del paciente", 404, await post(client, BASE, uid=AJENO))
    check("paciente inexistente", 404,
          await post(client, {**BASE, "patient_id": "99999999-9999-4999-8999-999999999998"}))

    # --- PUT /uploads/{token} -------------------------------------------
    print("--- subida del binario (PUT) ---")
    import hashlib
    from app.storage import issue_token

    PDF = b"%PDF-1.4\n" + b"contenido de prueba AgeCare\n" * 40 + b"%%EOF\n"

    r = await post(client, {**BASE, "size": len(PDF)})
    if r.status_code != 201:
        print(f"  FALLA no se pudo reservar el archivo: {r.text[:120]}")
    else:
        d = r.json()
        url = d["upload_url"].replace("http://testserver", "")

        # El PUT no lleva Authorization a proposito: el token es la credencial.
        rp = await client.put(url, content=PDF,
                              headers={"Content-Type": "application/pdf"})
        check("sube el binario y queda stored", 200, rp, campo="checksum")
        if rp.status_code == 200:
            cuerpo = rp.json()
            n += 1
            if cuerpo["checksum"] == hashlib.sha256(PDF).hexdigest():
                ok += 1; print("  OK   el sha256 guardado coincide con los bytes")
            else:
                print("  FALLA el sha256 no coincide")
            n += 1
            if cuerpo["size"] == len(PDF) and cuerpo["status"] == "stored":
                ok += 1; print(f"  OK   size real {cuerpo['size']} y status stored")
            else:
                print(f"  FALLA size/status: {cuerpo}")

        check("segundo PUT sobre el mismo archivo", 409,
              await client.put(url, content=PDF,
                               headers={"Content-Type": "application/pdf"}))

    # tipo distinto del declarado
    r = await post(client, {**BASE, "size": len(PDF)})
    url2 = r.json()["upload_url"].replace("http://testserver", "")
    check("tipo de contenido distinto del declarado", 415,
          await client.put(url2, content=PDF,
                           headers={"Content-Type": "image/png"}))

    # cuerpo vacio
    r = await post(client, {**BASE, "size": len(PDF)})
    url3 = r.json()["upload_url"].replace("http://testserver", "")
    check("cuerpo vacio", 422,
          await client.put(url3, content=b"",
                           headers={"Content-Type": "application/pdf"}))

    # token basura y token firmado con otra llave
    check("token inventado", 401,
          await client.put("/api/v1/uploads/esto.no.es.un.token", content=PDF,
                           headers={"Content-Type": "application/pdf"}))
    ajeno = jwt.encode(
        {"pur": "upload", "fid": "00000000-0000-4000-8000-000000000000",
         "key": "x", "ct": "application/pdf", "sz": 10,
         "exp": int((datetime.now(timezone.utc) + timedelta(minutes=5)).timestamp())},
        "otra-llave-distinta", algorithm="HS256")
    check("token firmado con otra llave", 401,
          await client.put(f"/api/v1/uploads/{ajeno}", content=PDF,
                           headers={"Content-Type": "application/pdf"}))

    # token con proposito de descarga usado para subir
    r = await post(client, {**BASE, "size": len(PDF)})
    d4 = r.json()
    mal = issue_token(purpose="download", file_id=d4["upload_id"],
                      storage_key="x", content_type="application/pdf",
                      size=len(PDF), ttl_minutes=5)
    check("token de descarga usado para subir", 401,
          await client.put(f"/api/v1/uploads/{mal}", content=PDF,
                           headers={"Content-Type": "application/pdf"}))

    # token vivo sobre una fila ya vencida
    r = await post(client, {**BASE, "size": len(PDF)})
    d5 = r.json()
    from app.db import engine as _eng
    from sqlalchemy import text as _t
    async with _eng.begin() as conn:
        await conn.execute(_t("UPDATE files SET upload_expires_at = now() - interval '1 hour' WHERE id = :i"),
                           {"i": d5["upload_id"]})
    check("enlace vencido (fila vencida)", 410,
          await client.put(d5["upload_url"].replace("http://testserver", ""),
                           content=PDF, headers={"Content-Type": "application/pdf"}))

    # mas de 25 MB avisados en content-length
    r = await post(client, {**BASE, "size": 1000})
    url6 = r.json()["upload_url"].replace("http://testserver", "")
    check("binario de 26 MB", 413,
          await client.put(url6, content=b"\0" * (26 * 1024 * 1024),
                           headers={"Content-Type": "application/pdf"}))

    # --- GET /files/{id} y /files/{id}/download --------------------------
    print("--- lectura del archivo (GET) ---")
    r = await post(client, {**BASE, "filename": "receta medica.pdf", "size": len(PDF)})
    guardado = r.json()
    await client.put(guardado["upload_url"].replace("http://testserver", ""),
                     content=PDF, headers={"Content-Type": "application/pdf"})
    fid = guardado["upload_id"]

    rg = await client.get(f"/api/v1/files/{fid}", headers=token(FAMILIAR))
    check("miembro del circulo lee el archivo", 200, rg)
    if rg.status_code == 200:
        n += 1
        if rg.content == PDF and rg.headers["content-type"].startswith("application/pdf"):
            ok += 1; print("  OK   devuelve los mismos bytes y el tipo correcto")
        else:
            print(f"  FALLA bytes o tipo: {len(rg.content)} / {rg.headers.get('content-type')}")
        n += 1
        if "receta medica.pdf" in rg.headers.get("content-disposition", ""):
            ok += 1; print("  OK   conserva el nombre original en Content-Disposition")
        else:
            print(f"  FALLA disposition: {rg.headers.get('content-disposition')}")

    check("usuario fuera del circulo", 404,
          await client.get(f"/api/v1/files/{fid}", headers=token(AJENO)))
    check("sin credencial de ningun tipo", 401,
          await client.get(f"/api/v1/files/{fid}"))
    check("archivo inexistente", 404,
          await client.get("/api/v1/files/99999999-9999-4999-8999-999999999997",
                           headers=token(FAMILIAR)))

    # archivo reservado pero nunca subido: no esta disponible
    pend = (await post(client, {**BASE, "size": len(PDF)})).json()["upload_id"]
    check("archivo pending (reservado, sin subir)", 404,
          await client.get(f"/api/v1/files/{pend}", headers=token(FAMILIAR)))

    # enlace corto
    rl = await client.get(f"/api/v1/files/{fid}/download", headers=token(FAMILIAR))
    check("pide el enlace corto", 200, rl, campo="url")
    if rl.status_code == 200:
        link = rl.json()
        exp = datetime.fromisoformat(link["expires_at"])
        mins = (exp - datetime.now(timezone.utc)).total_seconds() / 60
        n += 1
        if 4 <= mins <= 5.1:
            ok += 1; print(f"  OK   RNF-13: el enlace de lectura vence en {mins:.1f} minutos")
        else:
            print(f"  FALLA RNF-13: vence en {mins:.1f} minutos, deberia ser 5")
        corto = link["url"].replace("http://testserver", "")
        check("el enlace corto sirve sin cabecera (Image.network)", 200,
              await client.get(corto))
        suelto = corto.split("t=")[1]
        check("token de subida usado como enlace de lectura", 401,
              await client.get(f"/api/v1/files/{fid}?t="
                               + guardado["upload_url"].split("/uploads/")[1]))

    check("enlace corto pedido por alguien fuera del circulo", 404,
          await client.get(f"/api/v1/files/{fid}/download", headers=token(AJENO)))

    # el catalogo es comun: cualquiera autenticado lo ve
    cat = (await post(client, {"filename": "cuento.mp3", "content_type": "audio/mpeg",
                               "kind": "catalog", "size": len(PDF)})).json()
    await client.put(cat["upload_url"].replace("http://testserver", ""),
                     content=PDF, headers={"Content-Type": "audio/mpeg"})
    check("archivo de catalogo visible para cualquier autenticado", 200,
          await client.get(f"/api/v1/files/{cat['upload_id']}", headers=token(AJENO)))
    check("el enlace de un archivo no sirve para otro archivo", 401,
          await client.get(f"/api/v1/files/{cat['upload_id']}?t={suelto}"))

    # --- RNF-14: registro de accesos -------------------------------------
    print("--- registro de accesos (RNF-14) ---")

    async def accesos(eid):
        async with _eng.begin() as conn:
            r = await conn.execute(_t(
                "SELECT user_id, role, section, entity_id, user_agent "
                "FROM record_access_log WHERE entity_id = :e ORDER BY accessed_at"),
                {"e": eid})
            return r.mappings().all()

    reg = (await post(client, {**BASE, "size": len(PDF)})).json()
    await client.put(reg["upload_url"].replace("http://testserver", ""),
                     content=PDF, headers={"Content-Type": "application/pdf"})
    rid = reg["upload_id"]

    antes = len(await accesos(rid))
    await client.get(f"/api/v1/files/{rid}", headers={**token(FAMILIAR),
                                                     "User-Agent": "AgeCare/1.0 (test)"})
    filas = await accesos(rid)
    n += 1
    if len(filas) == antes + 1:
        ok += 1; print("  OK   leer el archivo deja una fila de acceso")
    else:
        print(f"  FALLA se esperaba una fila nueva, hay {len(filas)}")
    if filas:
        f = filas[-1]
        n += 1
        if (str(f["user_id"]) == FAMILIAR and f["section"] == "documents"
                and str(f["entity_id"]) == rid and f["role"] == "family"):
            ok += 1; print(f"  OK   queda con rol '{f['role']}', seccion documents y el id del archivo")
        else:
            print(f"  FALLA contenido de la fila: {dict(f)}")
        n += 1
        if f["user_agent"] == "AgeCare/1.0 (test)":
            ok += 1; print("  OK   guarda el agente que hizo la consulta")
        else:
            print(f"  FALLA user_agent: {f['user_agent']}")

    # pedir el enlace corto tambien cuenta como acceso
    await client.get(f"/api/v1/files/{rid}/download", headers=token(FAMILIAR))
    n += 1
    if len(await accesos(rid)) == antes + 2:
        ok += 1; print("  OK   pedir el enlace corto tambien queda registrado")
    else:
        print("  FALLA pedir el enlace corto no quedo registrado")

    # bajar con ?t= no duplica: ya quedo anotado al pedir el enlace
    link2 = (await client.get(f"/api/v1/files/{rid}/download",
                              headers=token(FAMILIAR))).json()["url"]
    hasta = len(await accesos(rid))
    await client.get(link2.replace("http://testserver", ""))
    n += 1
    if len(await accesos(rid)) == hasta:
        ok += 1; print("  OK   bajar con el enlace no duplica el registro")
    else:
        print("  FALLA el enlace duplico el registro")

    # el catalogo no se registra
    antes_cat = len(await accesos(cat["upload_id"]))
    await client.get(f"/api/v1/files/{cat['upload_id']}", headers=token(AJENO))
    n += 1
    if len(await accesos(cat["upload_id"])) == antes_cat == 0:
        ok += 1; print("  OK   el catalogo no genera registro de acceso")
    else:
        print("  FALLA el catalogo genero registro")

    # --- ambito user: la foto de perfil ----------------------------------
    print("--- foto de perfil (ambito user) ---")
    JPG = b"\xff\xd8\xff\xe0" + b"foto de perfil" * 20 + b"\xff\xd9"

    ra = await post(client, {"filename": "yo.jpg", "content_type": "image/jpeg",
                             "kind": "avatar", "size": len(JPG)})
    check("subir foto de perfil sin indicar paciente", 201, ra)
    if ra.status_code == 201:
        av = ra.json()
        rpa = await client.put(av["upload_url"].replace("http://testserver", ""),
                               content=JPG, headers={"Content-Type": "image/jpeg"})
        check("sube el binario de la foto de perfil", 200, rpa)
        aid = av["upload_id"]
        async with _eng.begin() as conn:
            got = (await conn.execute(_t(
                "SELECT scope, patient_id, uploaded_by FROM files WHERE id=:i"),
                {"i": aid})).mappings().first()
        n += 1
        if got["scope"] == "user" and got["patient_id"] is None \
                and str(got["uploaded_by"]) == FAMILIAR:
            ok += 1; print("  OK   queda con ambito user, sin paciente y con dueno")
        else:
            print(f"  FALLA la fila quedo como {dict(got)}")

        check("su dueno la ve", 200,
              await client.get(f"/api/v1/files/{aid}", headers=token(FAMILIAR)))
        check("alguien que no comparte circulo no la ve", 404,
              await client.get(f"/api/v1/files/{aid}", headers=token(AJENO)))
        n += 1
        if len(await accesos(aid)) == 0:
            ok += 1; print("  OK   la foto de perfil no genera registro de expediente")
        else:
            print("  FALLA la foto de perfil genero registro de expediente")

        # un segundo miembro del mismo circulo si la ve
        async with _eng.begin() as conn:
            otro = (await conn.execute(_t(
                "SELECT user_id FROM patient_members WHERE patient_id = :p "
                "AND user_id <> :u AND removed_at IS NULL LIMIT 1"),
                {"p": PACIENTE, "u": FAMILIAR})).scalar()
        if otro:
            check("otro miembro del mismo circulo la ve", 200,
                  await client.get(f"/api/v1/files/{aid}", headers=token(str(otro))))
        else:
            print("  (no hay otro miembro en el circulo para probarlo)")

    check("avatar con patient_id se ignora el paciente", 201,
          await post(client, {"filename": "yo2.jpg", "content_type": "image/jpeg",
                              "kind": "avatar", "size": len(JPG),
                              "patient_id": PACIENTE}))

    print()
    print(f"resultado: {ok} de {n}")
    # Codigo de salida para que el CI lo vea.
    return 0 if ok == n else 1



async def run():
    from app.db import engine
    transport = httpx.ASGITransport(app=app)
    async with httpx.AsyncClient(transport=transport,
                                 base_url="http://testserver") as c:
        await main(c)
    await engine.dispose()


import sys  # noqa: E402

sys.exit(asyncio.run(run()))
