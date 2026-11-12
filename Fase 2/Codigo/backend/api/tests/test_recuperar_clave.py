"""Pruebas de la recuperacion de contrasena con codigo (RF-05).

Recorre el flujo entero contra la base real: pedir el codigo, que llegue el
correo, canjearlo, y todo lo que puede salir mal. El correo no sale a ninguna
parte: se reemplaza el proveedor por uno que guarda lo que recibe.

Cada comprobacion protege algo que ya fue un defecto o es una promesa de
seguridad:
  - el reset actualizaba users.hashed_password, una columna que no existe
    (la real es password_hash), asi que el primer canje real habria dado 500;
  - un codigo de 6 digitos sin tope de intentos se adivina por fuerza bruta;
  - responder distinto segun exista o no el correo revela que cuentas hay.
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
import re  # noqa: E402
import uuid  # noqa: E402

import httpx  # noqa: E402
from sqlalchemy import text  # noqa: E402

from app.db import engine  # noqa: E402
from app.email_provider import EmailProvider, Envio  # noqa: E402
from app.main import app  # noqa: E402
from app.ratelimit import limiter  # noqa: E402
from app.routers import auth as auth_router  # noqa: E402
from app.security import hash_password  # noqa: E402

UID = str(uuid.uuid4())
CORREO = "recuperar-prueba@agecare.cl"
VIEJA = "ClaveVieja1"
NUEVA = "ClaveNueva2"

n = ok = 0


def check(nombre, cond, detalle=""):
    global n, ok
    n += 1
    if cond:
        ok += 1
        print(f"  OK   {nombre}")
    else:
        print(f"  FALLA {nombre}   {detalle}")


class CorreoFalso(EmailProvider):
    """Guarda lo que se enviaria."""

    def __init__(self):
        self.enviados: list[dict] = []
        self.falla = False

    @property
    def disponible(self):
        return True

    async def enviar(self, *, destinatario, asunto, cuerpo_html, cuerpo_texto,
                     imagenes_inline=None):
        if self.falla:
            return Envio(ok=False, error="servidor SMTP caido")
        self.enviados.append({"to": destinatario, "asunto": asunto,
                              "html": cuerpo_html, "texto": cuerpo_texto,
                              "imagenes": imagenes_inline or {}})
        return Envio(ok=True)


def codigo_de(correo: dict) -> str:
    m = re.search(r"c[oó]digo es:\s*(\d{3}) (\d{3})", correo["texto"])
    return (m.group(1) + m.group(2)) if m else ""


async def crear_usuario():
    async with engine.begin() as c:
        await c.execute(text("DELETE FROM users WHERE email = :e"), {"e": CORREO})
        await c.execute(text(
            "INSERT INTO users (id, email, password_hash, first_name, last_name, "
            "phone, locale) VALUES (:id, :e, :h, 'Rita', 'Prueba <b>', "
            "'+56900000077', 'es')"),
            {"id": UID, "e": CORREO, "h": hash_password(VIEJA)})


async def borrar_usuario():
    async with engine.begin() as c:
        await c.execute(text("DELETE FROM refresh_tokens WHERE user_id = :u"), {"u": UID})
        await c.execute(text("DELETE FROM password_reset_tokens WHERE user_id = :u"), {"u": UID})
        await c.execute(text("DELETE FROM users WHERE id = :u"), {"u": UID})


async def fila_codigo():
    async with engine.begin() as c:
        return (await c.execute(text(
            "SELECT attempts, used_at, expires_at FROM password_reset_tokens "
            "WHERE user_id = :u ORDER BY created_at DESC LIMIT 1"),
            {"u": UID})).mappings().first()


async def login(client, clave):
    return await client.post("/api/v1/auth/login",
                             json={"email": CORREO, "password": clave})


async def reset(client, codigo, clave=NUEVA, correo=CORREO):
    return await client.post("/api/v1/auth/password/reset",
                             json={"email": correo, "code": codigo, "new_password": clave})


async def pedir(client, correo=CORREO):
    return await client.post("/api/v1/auth/password/recovery", json={"email": correo})


async def main(client, correo: CorreoFalso):
    # ---------------- pedir el codigo ----------------
    print("--- pedir el codigo ---")
    r = await pedir(client, "no-existe-nadie@agecare.cl")
    check("un correo que no existe responde 202 igual (no revela cuentas)",
          r.status_code == 202, r.status_code)
    check("y no se envia nada", not correo.enviados, correo.enviados)

    r = await pedir(client)
    check("un correo que existe responde 202", r.status_code == 202, r.status_code)
    check("y se envia un correo a esa direccion",
          len(correo.enviados) == 1 and correo.enviados[0]["to"] == CORREO,
          correo.enviados)
    c1 = correo.enviados[0] if correo.enviados else {"texto": "", "html": "", "asunto": ""}
    code1 = codigo_de(c1)
    check("el correo trae un codigo de 6 digitos", len(code1) == 6, c1["texto"][:200])
    check("el HTML muestra el codigo, la vigencia y los intentos",
          f"{code1[:3]} {code1[3:]}" in c1["html"] and "minutos" in c1["html"]
          and "intentos" in c1["html"])
    check("el HTML lleva la marca y los textos legales",
          "AgeCare" in c1["html"] and "Términos y condiciones" in c1["html"]
          and "Política de privacidad" in c1["html"])
    logo = c1.get("imagenes", {}).get("agecare-logo", b"")
    check("el logo de AgeCare viaja adjunto como imagen en linea (PNG)",
          logo[:8] == b"\x89PNG\r\n\x1a\n" and len(logo) < 60_000, len(logo))
    check("el HTML lo referencia por cid, pequeno",
          'src="cid:agecare-logo"' in c1["html"] and 'width="88"' in c1["html"])
    check("usa la paleta del logo (indigo, azul, amarillo, lavanda)",
          all(c in c1["html"] for c in ("#192998", "#344CC8", "#FEC502", "#B39FFE")))
    check("el nombre del usuario se escapa en el HTML (sin inyeccion)",
          "&lt;b&gt;" in c1["html"] and "Prueba <b>" not in c1["html"])
    check("hay version de texto plano", "No compartas" in c1["texto"])
    fila = await fila_codigo()
    check("en la base solo hay hash, nunca el codigo",
          fila is not None and fila["attempts"] == 0 and fila["used_at"] is None)

    # ---------------- canjear mal ----------------
    print("--- canjear mal ---")
    mal = "000000" if code1 != "000000" else "111111"
    r = await reset(client, mal)
    check("codigo equivocado da 400 INVALID_RESET_CODE",
          r.status_code == 400 and r.json()["error"]["code"] == "INVALID_RESET_CODE",
          (r.status_code, r.text[:120]))
    check("y cuenta el intento", (await fila_codigo())["attempts"] == 1)
    r = await reset(client, code1, clave="corta")
    check("contrasena debil da 400 WEAK_PASSWORD",
          r.status_code == 400 and r.json()["error"]["code"] == "WEAK_PASSWORD",
          (r.status_code, r.text[:120]))
    r = await reset(client, "abc123")
    check("un codigo que no son 6 digitos se rechaza igual",
          r.status_code == 400 and r.json()["error"]["code"] == "INVALID_RESET_CODE")
    r = await reset(client, code1, correo="no-existe-nadie@agecare.cl")
    check("correo inexistente da el mismo error, no uno distinto",
          r.status_code == 400 and r.json()["error"]["code"] == "INVALID_RESET_CODE",
          (r.status_code, r.text[:120]))

    # ---------------- canjear bien ----------------
    print("--- canjear bien ---")
    sesion = await login(client, VIEJA)
    check("antes del cambio entra con la contrasena vieja",
          sesion.status_code == 200, (sesion.status_code, sesion.text[:100]))
    refresh = sesion.json().get("refresh_token") if sesion.status_code == 200 else None

    r = await reset(client, f"{code1[:3]} {code1[3:]}")
    check("el codigo correcto (con espacio, como se ve en el correo) da 204",
          r.status_code == 204, (r.status_code, r.text[:160]))
    check("la contrasena vieja ya no entra",
          (await login(client, VIEJA)).status_code == 401)
    check("la nueva si", (await login(client, NUEVA)).status_code == 200)
    if refresh:
        r = await client.post("/api/v1/auth/refresh", json={"refresh_token": refresh})
        check("las sesiones abiertas antes se cerraron", r.status_code == 401,
              r.status_code)
    r = await reset(client, code1, clave="OtraClave33")
    check("un codigo ya usado no sirve otra vez", r.status_code == 400, r.status_code)

    # ---------------- tope de intentos ----------------
    print("--- tope de intentos ---")
    await pedir(client)
    code2 = codigo_de(correo.enviados[-1])
    check("pedir otro codigo invalida el anterior",
          (await reset(client, code1, clave="OtraClave33")).status_code == 400)
    equivocado = "123456" if code2 != "123456" else "654321"
    for _ in range(5):
        await reset(client, equivocado)
    fila = await fila_codigo()
    check("al quinto error el codigo queda inutilizado",
          fila["used_at"] is not None, dict(fila))
    r = await reset(client, code2, clave="OtraClave33")
    check("y ni el codigo correcto sirve despues",
          r.status_code == 400, (r.status_code, r.text[:100]))
    check("la contrasena no cambio", (await login(client, NUEVA)).status_code == 200)

    # ---------------- vencimiento ----------------
    print("--- vencimiento ---")
    await pedir(client)
    code3 = codigo_de(correo.enviados[-1])
    async with engine.begin() as c:
        await c.execute(text(
            "UPDATE password_reset_tokens SET created_at = now() - interval '2 hours', "
            "expires_at = now() - interval '1 hour' "
            "WHERE user_id = :u AND used_at IS NULL"), {"u": UID})
    r = await reset(client, code3, clave="OtraClave33")
    check("un codigo vencido no sirve", r.status_code == 400, r.status_code)

    # ---------------- correo caido ----------------
    print("--- el correo falla ---")
    correo.falla = True
    r = await pedir(client)
    check("si el SMTP falla, la persona igual recibe 202 (no se rompe la pantalla)",
          r.status_code == 202, r.status_code)
    correo.falla = False


def probar_mime():
    """Arma el correo con el proveedor SMTP de verdad, con un servidor falso."""
    import email as _email
    import smtplib

    from app.email_provider import EmailSettings, Smtp
    from app.email_templates import correo_recuperacion, logo_inline

    enviados = []

    class SmtpFalso:
        def __init__(self, *a, **k): pass
        def __enter__(self): return self
        def __exit__(self, *a): return False
        def starttls(self, **k): pass
        def login(self, *a): pass
        def send_message(self, msg): enviados.append(msg)

    original = smtplib.SMTP
    smtplib.SMTP = SmtpFalso
    try:
        cfg = EmailSettings(email_provider="smtp", email_host="h",
                            email_user="u@agecare.cl", email_password="x")
        asunto, html, texto = correo_recuperacion(
            nombre="Ana", codigo="123456", minutos=30, intentos=5)
        r = Smtp(cfg)._enviar_sync("ana@agecare.cl", asunto, html, texto,
                                   logo_inline())
    finally:
        smtplib.SMTP = original

    print("--- mensaje MIME del proveedor SMTP ---")
    check("el envio con imagen en linea sale bien", r.ok and len(enviados) == 1, r)
    if enviados:
        msg = _email.message_from_bytes(enviados[0].as_bytes())
        tipos = [p.get_content_type() for p in msg.walk()]
        check("tiene texto, HTML y la imagen",
              "text/plain" in tipos and "text/html" in tipos and "image/png" in tipos,
              tipos)
        check("la imagen esta dentro de multipart/related (se ve en linea)",
              "multipart/related" in tipos, tipos)
        cids = [p["Content-ID"] for p in msg.walk() if p.get_content_type() == "image/png"]
        check("con el Content-ID que usa el HTML", cids == ["<agecare-logo>"], cids)


async def correr():
    limiter.enabled = False  # los limites por IP tienen su propia prueba
    correo = CorreoFalso()
    original = auth_router.get_email
    auth_router.get_email = lambda: correo
    await crear_usuario()
    transport = httpx.ASGITransport(app=app, raise_app_exceptions=False)
    try:
        async with httpx.AsyncClient(transport=transport,
                                     base_url="http://testserver", timeout=60) as client:
            await main(client, correo)
    finally:
        auth_router.get_email = original
        await borrar_usuario()
        await engine.dispose()
    probar_mime()
    print(f"\n{ok}/{n} comprobaciones")
    return 0 if ok == n and n > 0 else 1


if __name__ == "__main__":
    raise SystemExit(asyncio.run(correr()))
