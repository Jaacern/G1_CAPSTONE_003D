"""Pruebas del feed del adulto mayor."""
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
from app.routers import content  # noqa: E402

app = FastAPI()
register_error_handlers(app)
app.include_router(content.router)

USUARIO = "11111111-1111-4111-8111-111111111111"
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


async def main(client):
    global n, ok
    print("--- feed ---")
    r = await client.get("/api/v1/content/feed", headers=token(USUARIO))
    check("devuelve el feed", 200, r, campo="items")
    if r.status_code == 200:
        items = r.json()["items"]
        print(f"       tarjetas: {len(items)}")
        for i in items[:5]:
            print(f"       [{i['type']:8}] {i['title'][:42]}")
        n += 1
        if len(items) >= 10:
            ok += 1; print(f"  OK   trae las tarjetas publicadas ({len(items)})")
        else:
            print(f"  FALLA solo {len(items)}")
        n += 1
        if all(i["body"] and i["title"] for i in items):
            ok += 1; print("  OK   todas traen titulo y cuerpo para leer en voz alta")
        else:
            print("  FALLA hay tarjetas sin texto")
        n += 1
        tipos_primeros = [i["type"] for i in items[:5]]
        if len(set(tipos_primeros)) == 5:
            ok += 1; print(f"  OK   la primera pantalla trae los cinco tipos {tipos_primeros}")
        else:
            print(f"  FALLA la primera pantalla repite tipos: {tipos_primeros}")
        n += 1
        if all(i["type"] in ("news", "joke", "memory", "exercise", "tip") for i in items):
            ok += 1; print("  OK   todos los tipos son de los que la pantalla sabe dibujar")
        else:
            print("  FALLA hay un tipo desconocido")

    r = await client.get("/api/v1/content/feed?category=joke", headers=token(USUARIO))
    n += 1
    if r.status_code == 200 and r.json()["items"] and \
       all(i["type"] == "joke" for i in r.json()["items"]):
        ok += 1; print(f"  OK   filtra por tipo ({len(r.json()['items'])} chistes)")
    else:
        print(f"  FALLA filtro: {r.status_code}")

    check("tipo inventado", 422,
          await client.get("/api/v1/content/feed?category=poema", headers=token(USUARIO)))

    # un borrador no sale
    async with _eng.begin() as c:
        uno = (await c.execute(_t(
            "SELECT id FROM elder_feed_items WHERE status='published' LIMIT 1"))).scalar()
        await c.execute(_t("UPDATE elder_feed_items SET status='draft', published_at=NULL "
                           "WHERE id=:i"), {"i": str(uno)})
    r = await client.get("/api/v1/content/feed", headers=token(USUARIO))
    n += 1
    if all(i["id"] != str(uno) for i in r.json()["items"]):
        ok += 1; print("  OK   una tarjeta en borrador no sale")
    else:
        print("  FALLA el borrador sale")

    async with _eng.begin() as c:
        await c.execute(_t("UPDATE elder_feed_items SET status='archived', "
                           "published_at=now() WHERE id=:i"), {"i": str(uno)})
    r = await client.get("/api/v1/content/feed", headers=token(USUARIO))
    n += 1
    if all(i["id"] != str(uno) for i in r.json()["items"]):
        ok += 1; print("  OK   una archivada tampoco")
    else:
        print("  FALLA la archivada sale")
    async with _eng.begin() as c:
        await c.execute(_t("UPDATE elder_feed_items SET status='published', "
                           "published_at=now() WHERE id=:i"), {"i": str(uno)})

    check("sin autenticar", 401, await client.get("/api/v1/content/feed"))


async def run():
    transport = httpx.ASGITransport(app=app)
    async with httpx.AsyncClient(transport=transport, base_url="http://testserver") as cl:
        await main(cl)
    await _eng.dispose()
    print()
    print(f"resultado: {ok} de {n}")
    # Codigo de salida para que el CI lo vea.
    return 0 if ok == n else 1


import sys  # noqa: E402

sys.exit(asyncio.run(run()))
