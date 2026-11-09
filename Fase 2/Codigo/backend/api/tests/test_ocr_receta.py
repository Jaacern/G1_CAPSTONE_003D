"""Pruebas del OCR y del escaneo de recetas, contra la base real.

Recorre el camino completo que hace la aplicacion: subir la foto, pedir el
texto, pedir los borradores. Se prueba de punta a punta y no solo el lector
porque lo que puede fallar aqui no es la gramatica de las indicaciones (eso
lo cubre test_receta_lector.py) sino los permisos: que el texto de un
documento medico no salga por una puerta que la descarga tiene cerrada.
"""
import os
os.environ.setdefault("POSTGRES_HOST", "127.0.0.1")
os.environ.setdefault("POSTGRES_PORT", "5432")
os.environ.setdefault("STORAGE_LOCAL_DIR", "/tmp/agecare-files-test")
os.environ.setdefault("STORAGE_PUBLIC_BASE_URL", "http://testserver")
# Sin esto el proveedor queda en 'none' y todo responde 503. La prueba
# necesita el motor de verdad: es el unico modo de saber si el binario de
# tesseract esta donde la imagen dice que esta.
os.environ.setdefault("OCR_PROVIDER", "tesseract")

import pathlib as _pl
import sys as _sys
_sys.path.insert(0, str(_pl.Path(__file__).resolve().parents[1]))

import asyncio  # noqa: E402
from datetime import datetime, timedelta, timezone  # noqa: E402

import httpx  # noqa: E402
from fastapi import FastAPI  # noqa: E402
from jose import jwt  # noqa: E402

from app.config import get_settings  # noqa: E402
from app.errors import register_error_handlers  # noqa: E402
from app.routers import files, medications  # noqa: E402

app = FastAPI()
register_error_handlers(app)
app.include_router(files.router)
app.include_router(medications.router)

FAMILIAR = "11111111-1111-4111-8111-111111111111"
MEDICO   = "22222222-2222-4222-8222-222222222222"
AJENO    = "eeeeeee1-0000-4000-8000-000000000001"
PACIENTE = "33333333-3333-4333-8333-333333333333"

RECETA = [
    "CENTRO DE SALUD FAMILIAR CORONEL",
    "",
    "Paciente: Elena Ramirez Soto",
    "RUT: 5.432.109-8   Edad: 78 anos",
    "",
    "INDICACIONES:",
    "",
    "1. Losartan 50 mg - 1 comprimido cada 24 horas",
    "2. Metformina 850 mg - 1 comprimido cada 12 horas",
    "3. Atorvastatina 20 mg - 1 comprimido en la noche",
    "",
    "Dr. Luis Fuentes - Medico Internista",
]

n = ok = 0


def check(nombre, cond, detalle=""):
    global ok, n
    n += 1
    if cond:
        ok += 1
        print(f"  OK   {nombre}")
    else:
        print(f"  FALLA {nombre}   {detalle}")


def estado(nombre, esperado, resp):
    cuerpo = ""
    if resp.status_code != esperado:
        cuerpo = resp.text[:130].replace("\n", " ")
    check(f"{esperado}  {nombre}", resp.status_code == esperado, cuerpo)


def token(uid: str) -> dict:
    cfg = get_settings()
    t = jwt.encode(
        {"sub": uid, "type": "access",
         "exp": int((datetime.now(timezone.utc) + timedelta(minutes=10)).timestamp())},
        cfg.jwt_secret, algorithm=cfg.jwt_algorithm)
    return {"Authorization": f"Bearer {t}"}


def imagen_receta() -> bytes:
    """Dibuja la receta como PNG, del tamano de una foto de telefono.

    Se genera y no se guarda un archivo de prueba en el repositorio porque
    una foto de receta, aunque sea inventada, se lee como un dato clinico
    cuando alguien la encuentra suelta en el proyecto.
    """
    import io

    from PIL import Image, ImageDraw

    img = Image.new("L", (900, 620), 255)
    d = ImageDraw.Draw(img)
    y = 30
    for linea in RECETA:
        # Sin fuente propia queda la de PIL, chica pero nitida; el escalado
        # de abajo es lo que le da a tesseract algo que leer.
        d.text((30, y), linea, fill=0)
        y += 44
    img = img.resize((1800, 1240), Image.LANCZOS)
    buf = io.BytesIO()
    img.save(buf, format="PNG")
    return buf.getvalue()


async def subir(client, binario: bytes) -> str:
    """Sube la foto como lo hace la aplicacion y devuelve su file_url."""
    r = await client.post(
        "/api/v1/uploads",
        json={"filename": "receta.png", "content_type": "image/png",
              "kind": "prescription", "size": len(binario),
              "patient_id": PACIENTE},
        headers=token(FAMILIAR),
    )
    r.raise_for_status()
    d = r.json()
    ruta = d["upload_url"].replace("http://testserver", "")
    r2 = await client.put(ruta, content=binario,
                          headers={"Content-Type": "image/png"})
    r2.raise_for_status()
    return d["file_url"]


async def cuantos(client) -> int | None:
    """Cuantos medicamentos tiene el paciente ahora mismo."""
    r = await client.get(f"/api/v1/patients/{PACIENTE}/medications",
                         headers=token(MEDICO))
    if r.status_code != 200:
        return None
    cuerpo = r.json()
    lista = cuerpo if isinstance(cuerpo, list) else cuerpo.get("items", [])
    return len(lista)


async def main(client):
    antes = await cuantos(client)
    binario = imagen_receta()
    print(f"--- foto de receta generada: {len(binario)} bytes ---")
    file_url = await subir(client, binario)
    file_id = file_url.rstrip("/").split("/")[-1]
    print(f"    file_id: {file_id}")

    # ---------------- texto del archivo ----------------
    print("--- POST /files/{id}/ocr ---")
    r = await client.post(f"/api/v1/files/{file_id}/ocr", headers=token(FAMILIAR))
    estado("un miembro del circulo puede extraer el texto", 200, r)
    texto = ""
    if r.status_code == 200:
        d = r.json()
        texto = d["texto"]
        print(f"       motor={d['motor']} confianza={d['confianza']} "
              f"caracteres={d['caracteres']}")
        check("devuelve texto", len(texto) > 40, f"{len(texto)} caracteres")
        check("leyo los nombres de los farmacos",
              all(x.lower() in texto.lower()
                  for x in ("Losartan", "Metformina", "Atorvastatina")),
              texto[:160].replace("\n", " | "))

    print("--- GET /files/{id}/ocr ---")
    r = await client.get(f"/api/v1/files/{file_id}/ocr", headers=token(FAMILIAR))
    estado("el texto queda guardado y se relee sin volver a procesar", 200, r)
    if r.status_code == 200:
        check("el texto releido es el mismo", r.json()["texto"] == texto)

    print("--- permisos ---")
    r = await client.post(f"/api/v1/files/{file_id}/ocr", headers=token(AJENO))
    estado("un usuario ajeno al circulo no saca el texto", 404, r)
    r = await client.get(f"/api/v1/files/{file_id}/ocr", headers=token(AJENO))
    estado("ni lo relee", 404, r)
    r = await client.post(f"/api/v1/files/{file_id}/ocr")
    estado("sin sesion tampoco", 401, r)

    # ---------------- borradores de la receta ----------------
    print("--- POST /patients/{id}/medications/scan ---")
    r = await client.post(f"/api/v1/patients/{PACIENTE}/medications/scan",
                          json={"media_url": file_url}, headers=token(MEDICO))
    estado("el medico escanea la receta", 200, r)
    if r.status_code == 200:
        d = r.json()
        meds = d["medications"]
        for m in meds:
            print(f"       {m['name']:<22} {m['dose']:>4} {m['unit']:<10} "
                  f"{m['schedule']}")
        check("saca las tres indicaciones", len(meds) == 3,
              [m["name"] for m in meds])
        nombres = " ".join(m["name"] for m in meds).lower()
        check("no mete el encabezado ni al doctor como medicamento",
              "centro" not in nombres and "fuentes" not in nombres
              and "paciente" not in nombres, nombres)
        check("sin_indicaciones en False cuando si las hay",
              d["sin_indicaciones"] is False)
        check("devuelve el texto completo junto a los borradores",
              len(d["texto"]) > 40)
        por_nombre = {m["name"].lower(): m for m in meds}
        met = next((v for k, v in por_nombre.items() if "metformina" in k), None)
        if met:
            check("Metformina cada 12 horas queda con dos horarios",
                  len(met["schedule"]) == 2, met["schedule"])
            check("Metformina conserva la unidad mg", met["unit"] == "mg",
                  met["unit"])
        ator = next((v for k, v in por_nombre.items() if "atorvastatina" in k), None)
        if ator:
            check("la de la noche queda en un horario nocturno",
                  ator["schedule"] in (["22:00"], ["21:00"], ["20:00"]),
                  ator["schedule"])
        check("cada borrador trae la linea original para comparar",
              all(m["origen"].strip() for m in meds))

    print("--- el familiar tambien puede escanear ---")
    r = await client.post(f"/api/v1/patients/{PACIENTE}/medications/scan",
                          json={"media_url": file_url}, headers=token(FAMILIAR))
    estado("quien llega con el papel es quien le saca la foto", 200, r)

    print("--- escaneo: lo que debe rechazar ---")
    r = await client.post(f"/api/v1/patients/{PACIENTE}/medications/scan",
                          json={"media_url": file_url}, headers=token(AJENO))
    estado("un ajeno al circulo no escanea", 404, r)
    r = await client.post(f"/api/v1/patients/{PACIENTE}/medications/scan",
                          json={"media_url": ""}, headers=token(MEDICO))
    estado("sin foto no hay escaneo", 422, r)
    r = await client.post(f"/api/v1/patients/{PACIENTE}/medications/scan",
                          json={"media_url": "http://x/files/no-es-un-uuid"},
                          headers=token(MEDICO))
    estado("una referencia que no es un id valido", 422, r)
    otro = "99999999-9999-4999-8999-999999999999"
    r = await client.post(f"/api/v1/patients/{PACIENTE}/medications/scan",
                          json={"media_url": f"http://x/files/{otro}"},
                          headers=token(MEDICO))
    estado("una foto que no existe", 422, r)
    r = await client.post(f"/api/v1/files/{otro}/ocr", headers=token(MEDICO))
    estado("OCR de un archivo que no existe", 404, r)

    print("--- escanear no guarda nada ---")
    # Lo decidido con Alloxentric: el OCR propone, el medico confirma. Si el
    # escaneo creara medicamentos, una lectura de 500 mg donde el papel dice
    # 50 entraria sola al plan de dosis.
    #
    # Se cuenta antes y despues en vez de buscar los nombres de la receta: el
    # paciente de prueba ya tiene Metformina en su plan, que es justamente lo
    # que pasa de verdad cuando se escanea la receta de un control.
    check("el escaneo no creo ningun medicamento",
          antes is not None and await cuantos(client) == antes,
          f"antes {antes}, despues {await cuantos(client)}")


async def correr():
    transport = httpx.ASGITransport(app=app)
    async with httpx.AsyncClient(transport=transport,
                                 base_url="http://testserver",
                                 timeout=120) as client:
        await main(client)
    print(f"\n{ok}/{n} comprobaciones")
    return 0 if ok == n else 1


if __name__ == "__main__":
    raise SystemExit(asyncio.run(correr()))
