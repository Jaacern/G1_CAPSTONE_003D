"""Pruebas de voz."""
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
from app.routers import files, speech  # noqa: E402
from app import speech_provider as sp  # noqa: E402

app = FastAPI()
register_error_handlers(app)
app.include_router(files.router)
app.include_router(speech.router)

PACIENTE = "33333333-3333-4333-8333-333333333333"
AJENO = "eeeeeee1-0000-4000-8000-000000000001"
n = ok = 0


class ProveedorFalso(sp.SpeechProvider):
    def __init__(self):
        self.falla = False
        self.recibido = None

    @property
    def disponible(self):
        return True

    async def transcribir(self, *, audio, mime_type):
        self.recibido = {"bytes": len(audio), "mime": mime_type}
        if self.falla:
            raise RuntimeError("se cayo")
        return "hola, la senora almorzo completo"

    async def sintetizar(self, *, texto, voz):
        if self.falla:
            raise RuntimeError("se cayo")
        return b"ID3" + texto.encode("utf-8")[:40]


FALSO = ProveedorFalso()


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


async def subir_audio(client, uid):
    up = await client.post("/api/v1/uploads",
                           json={"filename": "nota.m4a", "content_type": "audio/aac",
                                 "kind": "audio", "size": 40, "patient_id": PACIENTE},
                           headers=token(uid))
    d = up.json()
    await client.put(d["upload_url"].replace("http://testserver", ""),
                     content=b"\x00\x00\x00\x20ftypM4A " + b"x" * 24,
                     headers={"Content-Type": "audio/aac"})
    return d["file_url"]


async def main(client, rr):
    global n, ok
    familiar, cuidadora = rr["family"], rr["caregiver"]

    print("--- transcribir: sin proveedor ---")
    sp.get_speech.cache_clear()
    audio = await subir_audio(client, cuidadora)
    r = await client.post("/api/v1/stt", json={"audio_url": audio},
                          headers=token(cuidadora))
    check("sin proveedor responde 503, no un texto inventado", 503, r)
    if r.status_code == 503:
        n += 1
        if r.json()["error"]["code"] == "SPEECH_UNAVAILABLE":
            ok += 1; print("  OK   con un codigo que la pantalla distingue")
        else:
            print(f"  FALLA codigo {r.json()['error']['code']}")

    print("--- transcribir: con proveedor ---")
    sp.get_speech = lambda: FALSO
    r = await client.post("/api/v1/stt", json={"audio_url": audio},
                          headers=token(cuidadora))
    check("transcribe", 200, r, campo="text")
    if r.status_code == 200:
        print(f"       texto: {r.json()['text']}")
        n += 1
        if r.json()["text"]:
            ok += 1; print("  OK   devuelve el texto")
        else:
            print("  FALLA texto vacio")
        n += 1
        if FALSO.recibido and FALSO.recibido["mime"] == "audio/aac" and FALSO.recibido["bytes"] > 0:
            ok += 1; print(f"  OK   le pasa el audio y su tipo ({FALSO.recibido})")
        else:
            print(f"  FALLA {FALSO.recibido}")

    check("otro miembro del circulo tambien puede", 200,
          await client.post("/api/v1/stt", json={"audio_url": audio},
                            headers=token(familiar)))
    check("alguien de fuera del circulo no", 404,
          await client.post("/api/v1/stt", json={"audio_url": audio},
                            headers=token(AJENO)))
    check("referencia que no es un archivo", 422,
          await client.post("/api/v1/stt", json={"audio_url": "https://ejemplo.com/a.mp3"},
                            headers=token(cuidadora)))
    check("archivo que no existe", 404,
          await client.post("/api/v1/stt",
                            json={"audio_url": "http://testserver/api/v1/files/"
                                               "99999999-9999-4999-8999-999999999991"},
                            headers=token(cuidadora)))

    # un archivo que no es audio
    up = await client.post("/api/v1/uploads",
                           json={"filename": "x.pdf", "content_type": "application/pdf",
                                 "kind": "document", "size": 20, "patient_id": PACIENTE},
                           headers=token(cuidadora))
    du = up.json()
    await client.put(du["upload_url"].replace("http://testserver", ""),
                     content=b"%PDF-1.4\n" + b"x" * 10, headers={"Content-Type": "application/pdf"})
    check("un PDF no se transcribe", 422,
          await client.post("/api/v1/stt", json={"audio_url": du["file_url"]},
                            headers=token(cuidadora)))

    FALSO.falla = True
    check("si el proveedor se cae responde 503, no 500", 503,
          await client.post("/api/v1/stt", json={"audio_url": audio},
                            headers=token(cuidadora)))
    FALSO.falla = False

    check("sin autenticar", 401,
          await client.post("/api/v1/stt", json={"audio_url": audio}))

    print("--- leer en voz alta ---")
    async with _eng.begin() as c:
        await c.execute(_t("DELETE FROM files WHERE storage_key LIKE 'user/tts/%'"))

    TEXTO = "PRUEBA Tomar agua durante el dia es importante."
    r = await client.post("/api/v1/tts",
                          json={"text": TEXTO, "voice": "es-CL-CatalinaNeural"},
                          headers=token(cuidadora))
    check("genera el audio", 200, r, campo="audio_url")
    if r.status_code == 200:
        d = r.json()
        print(f"       url: {d['audio_url'][:66]}...")
        n += 1
        if d["cached"] is False:
            ok += 1; print("  OK   la primera vez lo sintetiza")
        else:
            print("  FALLA dice que venia en cache")

        corto = d["audio_url"].replace("http://testserver", "")
        rb = await client.get(corto)
        n += 1
        if rb.status_code == 200 and rb.content.startswith(b"ID3"):
            ok += 1; print("  OK   el enlace entrega el mp3 sin cabecera de sesion")
        else:
            print(f"  FALLA el enlace dio {rb.status_code}")

        r2 = await client.post("/api/v1/tts",
                               json={"text": TEXTO, "voice": "es-CL-CatalinaNeural"},
                               headers=token(cuidadora))
        n += 1
        if r2.status_code == 200 and r2.json()["cached"] is True:
            ok += 1; print("  OK   la segunda vez lo reutiliza, no vuelve a pagar")
        else:
            print(f"  FALLA cached={r2.json().get('cached')}")

        async with _eng.begin() as c:
            cuantos = (await c.execute(_t(
                "SELECT count(*) FROM files WHERE storage_key LIKE 'user/tts/%'"))).scalar()
        n += 1
        if cuantos == 1:
            ok += 1; print("  OK   hay un solo archivo para las dos peticiones")
        else:
            print(f"  FALLA hay {cuantos} archivos")

        # otra persona con el mismo texto tiene su propia copia
        r3 = await client.post("/api/v1/tts",
                               json={"text": TEXTO, "voice": "es-CL-CatalinaNeural"},
                               headers=token(familiar))
        async with _eng.begin() as c:
            cuantos = (await c.execute(_t(
                "SELECT count(*) FROM files WHERE storage_key LIKE 'user/tts/%'"))).scalar()
            ambito = (await c.execute(_t(
                "SELECT DISTINCT scope FROM files WHERE storage_key LIKE 'user/tts/%'"))).scalar()
        n += 1
        if r3.json()["cached"] is False and cuantos == 2:
            ok += 1; print("  OK   cada persona tiene su copia, no se comparte")
        else:
            print(f"  FALLA cached={r3.json().get('cached')}, archivos={cuantos}")
        n += 1
        if ambito == "user":
            ok += 1; print("  OK   el audio queda con ambito 'user', no de catalogo")
        else:
            print(f"  FALLA ambito {ambito}")

        # una voz distinta es otro audio
        r4 = await client.post("/api/v1/tts",
                               json={"text": TEXTO, "voice": "es-MX-DaliaNeural"},
                               headers=token(cuidadora))
        n += 1
        if r4.json()["cached"] is False:
            ok += 1; print("  OK   cambiar la voz genera otro audio")
        else:
            print("  FALLA reutilizo el de otra voz")

    r = await client.post("/api/v1/tts", json={"text": "PRUEBA sin voz"},
                          headers=token(cuidadora))
    check("sin voz usa la por defecto", 200, r)

    check("voz inventada", 422,
          await client.post("/api/v1/tts",
                            json={"text": "x", "voice": "es-XX-NadieNeural"},
                            headers=token(cuidadora)))
    check("texto de solo espacios", 422,
          await client.post("/api/v1/tts", json={"text": "    "},
                            headers=token(cuidadora)))

    FALSO.falla = True
    r = await client.post("/api/v1/tts", json={"text": "PRUEBA con proveedor caido"},
                          headers=token(cuidadora))
    check("si el proveedor se cae responde 503", 503, r)
    async with _eng.begin() as c:
        basura = (await c.execute(_t(
            "SELECT count(*) FROM files WHERE original_name LIKE 'PRUEBA con proveedor%'"))).scalar()
    n += 1
    if basura == 0:
        ok += 1; print("  OK   y no deja un archivo a medias")
    else:
        print(f"  FALLA quedaron {basura} archivos")
    FALSO.falla = False

    check("tts sin autenticar", 401,
          await client.post("/api/v1/tts", json={"text": "x"}))

    async with _eng.begin() as c:
        await c.execute(_t("DELETE FROM files WHERE storage_key LIKE 'user/tts/%'"))


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
