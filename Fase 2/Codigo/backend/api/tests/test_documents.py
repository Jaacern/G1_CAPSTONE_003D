"""Pruebas del expediente de documentos."""
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
from app.routers import documents, files  # noqa: E402

app = FastAPI()
register_error_handlers(app)
app.include_router(files.router)
app.include_router(documents.router)

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


async def archivo(client, uid, nombre="informe.pdf"):
    """Sube un archivo y devuelve su file_url."""
    up = await client.post("/api/v1/uploads",
                           json={"filename": nombre, "content_type": "application/pdf",
                                 "kind": "document", "size": 30, "patient_id": PACIENTE},
                           headers=token(uid))
    d = up.json()
    await client.put(d["upload_url"].replace("http://testserver", ""),
                     content=b"%PDF-1.4\n" + b"x" * 15 + b"\n%%EOF\n",
                     headers={"Content-Type": "application/pdf"})
    return d["file_url"]


async def main(client, rr):
    global n, ok
    familiar = rr.get("family") or rr.get("caregiver")

    async with _eng.begin() as c:
        await c.execute(_t("DELETE FROM medical_documents WHERE title LIKE 'PRUEBA%'"))

    # documentos de prueba, insertados directo para controlar la categoria
    claves = [("prescription", "receta"), ("lab_result", "estudio"),
              ("identification", "identificacion"), ("imaging", "general"),
              ("other", "general")]
    for codigo, _ in claves:
        url = await archivo(client, familiar, f"{codigo}.pdf")
        fid = url.rstrip("/").split("/")[-1]
        async with _eng.begin() as c:
            await c.execute(_t(
                "INSERT INTO medical_documents (patient_id, file_id, category, title, added_by) "
                "VALUES (:p,:f,:c,:t,:u)"),
                {"p": PACIENTE, "f": fid, "c": codigo,
                 "t": f"PRUEBA {codigo}", "u": familiar})

    print("--- listar documentos ---")
    r = await client.get(f"/api/v1/patients/{PACIENTE}/documents", headers=token(familiar))
    check("lista el expediente", 200, r, campo="items")
    if r.status_code == 200:
        items = {i["title"]: i for i in r.json()["items"] if i["title"].startswith("PRUEBA")}
        n += 1
        if len(items) == 5:
            ok += 1; print("  OK   trae los 5 documentos")
        else:
            print(f"  FALLA trae {len(items)}")
        for codigo, clave in claves:
            n += 1
            got = items.get(f"PRUEBA {codigo}", {}).get("category")
            if got == clave:
                ok += 1; print(f"  OK   '{codigo}' se devuelve como '{clave}'")
            else:
                print(f"  FALLA '{codigo}' dio '{got}', se esperaba '{clave}'")
        uno = items.get("PRUEBA other", {})
        n += 1
        if uno.get("file_url", "").startswith("http") and "/files/" in uno.get("file_url", ""):
            ok += 1; print("  OK   devuelve file_url usable")
        else:
            print(f"  FALLA file_url: {uno.get('file_url')}")
        n += 1
        if uno.get("uploader_name"):
            ok += 1; print(f"  OK   devuelve quien lo subio ({uno['uploader_name']})")
        else:
            print("  FALLA no devuelve uploader_name")

    # un borrado no aparece
    async with _eng.begin() as c:
        await c.execute(_t(
            "UPDATE medical_documents SET deleted_at=now(), deleted_by=:u "
            "WHERE title='PRUEBA other'"), {"u": familiar})
    r = await client.get(f"/api/v1/patients/{PACIENTE}/documents", headers=token(familiar))
    n += 1
    titulos = [i["title"] for i in r.json()["items"]]
    if "PRUEBA other" not in titulos:
        ok += 1; print("  OK   un documento borrado no aparece")
    else:
        print("  FALLA el borrado sigue apareciendo")

    check("listar desde fuera del circulo", 404,
          await client.get(f"/api/v1/patients/{PACIENTE}/documents", headers=token(AJENO)))
    check("sin autenticar", 401,
          await client.get(f"/api/v1/patients/{PACIENTE}/documents"))

    print("--- agregar documentos ---")
    url = await archivo(client, familiar, "receta nueva.pdf")
    r = await client.post(f"/api/v1/patients/{PACIENTE}/documents",
                          json={"file_url": url, "title": "PRUEBA receta del cardiologo",
                                "category": "receta"},
                          headers=token(familiar))
    check("agrega un documento", 201, r, campo="id")
    if r.status_code == 201:
        d = r.json()
        n += 1
        if d["category"] == "receta":
            ok += 1; print("  OK   devuelve la categoria en la clave de la pantalla")
        else:
            print(f"  FALLA categoria {d['category']}")
        async with _eng.begin() as c:
            guardada = (await c.execute(_t(
                "SELECT category FROM medical_documents WHERE id=:i"), {"i": d["id"]})).scalar()
        n += 1
        if guardada == "prescription":
            ok += 1; print("  OK   en la base queda como 'prescription'")
        else:
            print(f"  FALLA en la base quedo '{guardada}'")
        n += 1
        if d["uploader_name"]:
            ok += 1; print("  OK   devuelve quien lo subio")
        else:
            print("  FALLA sin uploader_name")

        # reintento con el mismo archivo
        r2 = await client.post(f"/api/v1/patients/{PACIENTE}/documents",
                               json={"file_url": url, "title": "PRUEBA reintento",
                                     "category": "receta"}, headers=token(familiar))
        n += 1
        if r2.status_code == 201 and r2.json()["id"] == d["id"]:
            ok += 1; print("  OK   reenviar el mismo archivo devuelve el documento existente")
        else:
            print(f"  FALLA reintento: {r2.status_code} {r2.text[:100]}")

    for clave, codigo in [("estudio", "lab_result"), ("identificacion", "identification"),
                          ("general", "other")]:
        u = await archivo(client, familiar, f"{clave}-nuevo.pdf")
        rr2 = await client.post(f"/api/v1/patients/{PACIENTE}/documents",
                                json={"file_url": u, "title": f"PRUEBA {clave}",
                                      "category": clave}, headers=token(familiar))
        n += 1
        if rr2.status_code == 201 and rr2.json()["category"] == clave:
            ok += 1; print(f"  OK   '{clave}' va y vuelve bien (base: {codigo})")
        else:
            print(f"  FALLA '{clave}': {rr2.status_code} {rr2.text[:90]}")

    u = await archivo(client, familiar, "sin-categoria.pdf")
    check("sin categoria queda en general", 201,
          await client.post(f"/api/v1/patients/{PACIENTE}/documents",
                            json={"file_url": u, "title": "PRUEBA sin categoria"},
                            headers=token(familiar)))

    u2 = await archivo(client, familiar, "mala.pdf")
    check("categoria inventada", 422,
          await client.post(f"/api/v1/patients/{PACIENTE}/documents",
                            json={"file_url": u2, "title": "x", "category": "radiografia"},
                            headers=token(familiar)))
    check("titulo de solo espacios", 422,
          await client.post(f"/api/v1/patients/{PACIENTE}/documents",
                            json={"file_url": u2, "title": "   "}, headers=token(familiar)))
    check("archivo que no existe", 422,
          await client.post(f"/api/v1/patients/{PACIENTE}/documents",
                            json={"file_url": "http://testserver/api/v1/files/"
                                               "99999999-9999-4999-8999-999999999991",
                                  "title": "x"}, headers=token(familiar)))
    check("file_url que no es una referencia", 422,
          await client.post(f"/api/v1/patients/{PACIENTE}/documents",
                            json={"file_url": "https://ejemplo.com/doc.pdf", "title": "x"},
                            headers=token(familiar)))
    check("agregar desde fuera del circulo", 404,
          await client.post(f"/api/v1/patients/{PACIENTE}/documents",
                            json={"file_url": u2, "title": "x"}, headers=token(AJENO)))

    print("--- borrar y descargar ---")
    u = await archivo(client, familiar, "para-borrar.pdf")
    doc = (await client.post(f"/api/v1/patients/{PACIENTE}/documents",
                             json={"file_url": u, "title": "PRUEBA para borrar",
                                   "category": "estudio"},
                             headers=token(familiar))).json()
    did = doc["id"]

    rd = await client.get(f"/api/v1/documents/{did}/download", headers=token(familiar))
    check("pide el enlace de descarga", 200, rd, campo="url")
    if rd.status_code == 200:
        d = rd.json()
        mins = (datetime.fromisoformat(d["expires_at"]) - datetime.now(timezone.utc)).total_seconds() / 60
        n += 1
        if 4 <= mins <= 5.1:
            ok += 1; print(f"  OK   RNF-13: vence en {mins:.1f} minutos")
        else:
            print(f"  FALLA vence en {mins:.1f} minutos")
        corto = d["url"].replace("http://testserver", "")
        rb = await client.get(corto)
        n += 1
        if rb.status_code == 200 and rb.content.startswith(b"%PDF"):
            ok += 1; print("  OK   el enlace entrega el PDF sin cabecera")
        else:
            print(f"  FALLA el enlace dio {rb.status_code}")

    check("descargar desde fuera del circulo", 404,
          await client.get(f"/api/v1/documents/{did}/download", headers=token(AJENO)))
    check("documento inexistente", 404,
          await client.get("/api/v1/documents/99999999-9999-4999-8999-999999999991/download",
                           headers=token(familiar)))

    # Si el circulo de demo no tiene medico, se agrega uno para probar la
    # rama de permisos y se saca al final.
    doctor = rr.get("doctor")
    doctor_agregado = False
    if doctor is None:
        async with _eng.begin() as c:
            cand = (await c.execute(_t(
                "SELECT id FROM users WHERE id NOT IN "
                "(SELECT user_id FROM patient_members WHERE patient_id=:p) "
                "AND is_active AND deleted_at IS NULL LIMIT 1"),
                {"p": PACIENTE})).scalar()
            if cand:
                await c.execute(_t(
                    "INSERT INTO patient_members (patient_id, user_id, role, is_owner) "
                    "VALUES (:p,:u,'doctor',false)"), {"p": PACIENTE, "u": str(cand)})
                doctor = str(cand)
                doctor_agregado = True
    if doctor:
        check("el medico puede descargar", 200,
              await client.get(f"/api/v1/documents/{did}/download", headers=token(doctor)))
        check("el medico no puede borrar", 403,
              await client.delete(f"/api/v1/documents/{did}", headers=token(doctor)))

    if doctor_agregado:
        async with _eng.begin() as c:
            await c.execute(_t(
                "DELETE FROM patient_members WHERE patient_id=:p AND user_id=:u"),
                {"p": PACIENTE, "u": doctor})

    check("borrar desde fuera del circulo", 404,
          await client.delete(f"/api/v1/documents/{did}", headers=token(AJENO)))
    check("borra el documento", 204,
          await client.delete(f"/api/v1/documents/{did}", headers=token(familiar)))

    async with _eng.begin() as c:
        fila = (await c.execute(_t(
            "SELECT deleted_at, deleted_by FROM medical_documents WHERE id=:i"),
            {"i": did})).mappings().first()
    n += 1
    if fila["deleted_at"] is not None and str(fila["deleted_by"]) == familiar:
        ok += 1; print("  OK   es borrado logico, con quien lo quito y cuando")
    else:
        print(f"  FALLA {dict(fila)}")

    async with _eng.begin() as c:
        bin_vivo = (await c.execute(_t(
            "SELECT status FROM files WHERE id=:f"),
            {"f": u.rstrip("/").split("/")[-1]})).scalar()
    n += 1
    if bin_vivo == "stored":
        ok += 1; print("  OK   el archivo binario no se toca")
    else:
        print(f"  FALLA el archivo quedo en '{bin_vivo}'")

    check("borrar dos veces", 404,
          await client.delete(f"/api/v1/documents/{did}", headers=token(familiar)))
    check("descargar uno borrado", 404,
          await client.get(f"/api/v1/documents/{did}/download", headers=token(familiar)))

    r = await client.get(f"/api/v1/patients/{PACIENTE}/documents", headers=token(familiar))
    n += 1
    if "PRUEBA para borrar" not in [i["title"] for i in r.json()["items"]]:
        ok += 1; print("  OK   ya no aparece en el expediente")
    else:
        print("  FALLA sigue en la lista")

    async with _eng.begin() as c:
        cuenta = (await c.execute(_t(
            "SELECT count(*) FROM record_access_log WHERE patient_id=:p AND section='documents'"),
            {"p": PACIENTE})).scalar()
    n += 1
    if cuenta >= 1:
        ok += 1; print(f"  OK   la lectura queda registrada (RNF-14, {cuenta})")
    else:
        print("  FALLA no quedo registro")


async def run():
    rr = await roles()
    async with _eng.begin() as c:
        await c.execute(_t("DELETE FROM record_access_log WHERE section='documents'"))
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
