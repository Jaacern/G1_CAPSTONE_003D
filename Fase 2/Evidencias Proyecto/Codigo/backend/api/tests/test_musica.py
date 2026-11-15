"""Pruebas del Director Musical (RF-65 a RF-67, RF-69) y de su registro de acceso.

Lo que estas pruebas protegen, porque ya fallo en silencio una vez:

  - Que consultar las creaciones deje fila en record_access_log con la seccion
    'music'. El CHECK de la tabla no la admitia, registrar_acceso() se traga
    sus errores para no romper la consulta, y la auditoria quedaba sin ninguna
    fila de musica y sin avisar.
  - Que crear una creacion registre UNA sesion de actividad (RF-69), y que el
    reintento idempotente (RF-66) no la cuente dos veces.
  - Que se pueda crear sin client_uuid: la columna es NOT NULL y un NULL
    explicito no activa el DEFAULT.
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
import uuid  # noqa: E402
from datetime import datetime, timedelta, timezone  # noqa: E402

import httpx  # noqa: E402
from jose import jwt  # noqa: E402
from sqlalchemy import text  # noqa: E402

from app import acceso  # noqa: E402
from app.config import get_settings  # noqa: E402
from app.db import engine  # noqa: E402
from app.main import app  # noqa: E402
from _ajeno import AJENO  # noqa: E402

FAMILIAR = "11111111-1111-4111-8111-111111111111"
ELENA = "33333333-3333-4333-8333-333333333333"
BASE = f"/api/v1/patients/{ELENA}"
TITULO = "PRUEBA-MUSICA"

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
    return {"Authorization": f"Bearer {t}", "User-Agent": "prueba-musica"}


async def subir_audio(client) -> str:
    """Sube un audio de verdad por el flujo de /uploads y devuelve su id."""
    contenido = b"ID3" + b"x" * 40
    r = await client.post(
        "/api/v1/uploads", headers=token(FAMILIAR),
        json={"filename": "melodia.mp3", "content_type": "audio/mpeg",
              "kind": "audio", "size": len(contenido), "patient_id": ELENA})
    d = r.json()
    await client.put(d["upload_url"].replace("http://testserver", ""),
                     content=contenido, headers={"Content-Type": "audio/mpeg"})
    return d["upload_id"]


async def sesiones_de(creation_id: str) -> list:
    async with engine.begin() as c:
        return (await c.execute(text(
            "SELECT activity, duration_seconds, completed, interactions_count "
            "FROM activity_sessions WHERE meta->>'creation_id' = :c"),
            {"c": creation_id})).mappings().all()


async def accesos_music() -> int:
    async with engine.begin() as c:
        return (await c.execute(text(
            "SELECT count(*) FROM record_access_log WHERE user_id = :u "
            "AND patient_id = :p AND section = 'music' "
            "AND accessed_at > now() - interval '1 hour'"),
            {"u": FAMILIAR, "p": ELENA})).scalar()


async def borrar_accesos():
    acceso.olvidar_recientes()
    async with engine.begin() as c:
        await c.execute(text(
            "DELETE FROM record_access_log WHERE user_id = :u "
            "AND accessed_at > now() - interval '1 hour'"), {"u": FAMILIAR})


async def limpiar():
    async with engine.begin() as c:
        ids = [str(x[0]) for x in (await c.execute(text(
            "SELECT id FROM music_creations WHERE title LIKE :t"),
            {"t": TITULO + "%"})).all()]
        files = [str(x[0]) for x in (await c.execute(text(
            "SELECT file_id FROM music_creations WHERE title LIKE :t"),
            {"t": TITULO + "%"})).all()]
        if ids:
            await c.execute(text(
                "DELETE FROM activity_sessions WHERE meta->>'creation_id' = ANY(:i)"),
                {"i": ids})
            await c.execute(text(
                "DELETE FROM creation_shares WHERE music_creation_id = ANY(CAST(:i AS uuid[]))"),
                {"i": ids})
            await c.execute(text("DELETE FROM music_creations WHERE id = ANY(CAST(:i AS uuid[]))"),
                            {"i": ids})
        if files:
            await c.execute(text("DELETE FROM files WHERE id = ANY(CAST(:f AS uuid[]))"),
                            {"f": files})
    await borrar_accesos()


async def main(client):
    h = token(FAMILIAR)
    await limpiar()
    fid = await subir_audio(client)
    cuid = str(uuid.uuid4())
    params = {"file_id": fid, "title": TITULO + " uno",
              "duration_seconds": 42, "client_uuid": cuid}

    # ---------------- RF-65 / RF-66 / RF-69: crear ----------------
    print("--- crear una creacion ---")
    r = await client.post(BASE + "/music", params=params, headers=h)
    check("crear devuelve 201", r.status_code == 201, (r.status_code, r.text[:120]))
    c1 = r.json() if r.status_code == 201 else {}
    check("conserva el client_uuid del dispositivo", c1.get("client_uuid") == cuid, c1)
    check("no es un reintento", c1.get("already_existed") is False, c1)

    ses = await sesiones_de(c1.get("id", ""))
    check("RF-69: queda UNA sesion de actividad 'music'",
          len(ses) == 1 and ses[0]["activity"] == "music", [dict(s) for s in ses])
    check("con la duracion de la melodia (42 s) y marcada completa",
          len(ses) == 1 and ses[0]["duration_seconds"] == 42 and ses[0]["completed"],
          [dict(s) for s in ses])

    print("--- RF-66: el reintento no duplica ---")
    r = await client.post(BASE + "/music", params=params, headers=h)
    c2 = r.json() if r.status_code == 201 else {}
    check("reintentar con el mismo client_uuid devuelve la misma creacion",
          r.status_code == 201 and c2.get("id") == c1.get("id")
          and c2.get("already_existed") is True, (r.status_code, c2))
    check("y no cuenta una segunda sesion",
          len(await sesiones_de(c1.get("id", ""))) == 1)

    print("--- sin client_uuid ---")
    fid2 = await subir_audio(client)
    r = await client.post(BASE + "/music", headers=h, params={
        "file_id": fid2, "title": TITULO + " dos", "duration_seconds": 5})
    c3 = r.json() if r.status_code == 201 else {}
    check("crear sin client_uuid funciona (se genera uno)",
          r.status_code == 201 and bool(c3.get("client_uuid")),
          (r.status_code, r.text[:160]))

    # ---------------- RNF-14: acceso registrado ----------------
    print("--- el acceso a musica queda registrado (RNF-14) ---")
    async with engine.begin() as c:
        validas = (await c.execute(text(
            "SELECT pg_get_constraintdef(oid) FROM pg_constraint "
            "WHERE conname = 'ck_record_access_log_section' LIMIT 1"))).scalar()
    check("el CHECK de record_access_log admite 'music'", "'music'" in validas, validas)

    await borrar_accesos()
    r = await client.get(BASE + "/music", headers=h)
    check("listar creaciones responde 200", r.status_code == 200, r.status_code)
    check("y deja una fila con la seccion 'music'", await accesos_music() == 1,
          await accesos_music())

    await borrar_accesos()
    r = await client.get(f"{BASE}/music/{c1.get('id')}", headers=h)
    check("el detalle de una creacion tambien",
          r.status_code == 200 and await accesos_music() == 1,
          (r.status_code, await accesos_music()))

    r = await client.get(BASE + "/music", headers=token(AJENO))
    check("un extrano no ve la musica del paciente", r.status_code == 404, r.status_code)

    # ---------------- RF-67: enlace de escucha ----------------
    print("--- enlace de escucha ---")
    r = await client.post(f"{BASE}/music/{c1.get('id')}/share", headers=h)
    check("compartir devuelve 201 con token", r.status_code == 201
          and bool(r.json().get("token")), (r.status_code, r.text[:100]))
    sh = r.json() if r.status_code == 201 else {}

    r = await client.get(f"/api/v1/music/shared/{sh.get('token')}")
    check("el enlace se escucha sin sesion (redirige al audio)",
          r.status_code == 302 and "location" in r.headers, (r.status_code, r.text[:80]))
    r = await client.get(f"{BASE}/music/{c1.get('id')}", headers=h)
    reproducciones = [s["play_count"] for s in r.json().get("shares", [])]
    check("y cuenta la reproduccion", reproducciones == [1], reproducciones)

    r = await client.get("/api/v1/music/shared/token-que-no-existe")
    check("un enlace inventado da 404", r.status_code == 404, r.status_code)

    r = await client.delete(f"/api/v1/music/shares/{sh.get('share_id')}", headers=h)
    check("revocar el enlace da 204", r.status_code == 204, r.status_code)
    r = await client.get(f"/api/v1/music/shared/{sh.get('token')}")
    check("revocado, ya no se escucha", r.status_code == 404, r.status_code)

    await limpiar()


async def correr():
    transport = httpx.ASGITransport(app=app, raise_app_exceptions=False)
    async with httpx.AsyncClient(transport=transport, base_url="http://testserver",
                                 timeout=60) as client:
        try:
            await main(client)
        finally:
            await limpiar()
    await engine.dispose()
    print(f"\n{ok}/{n} comprobaciones")
    return 0 if ok == n and n > 0 else 1


if __name__ == "__main__":
    raise SystemExit(asyncio.run(correr()))
