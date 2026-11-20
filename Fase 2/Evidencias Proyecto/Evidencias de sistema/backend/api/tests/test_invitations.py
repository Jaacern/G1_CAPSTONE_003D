"""Pruebas de las invitaciones al círculo de cuidado (código de 6 dígitos).

El flujo: el familiar administrador genera un código para un rol, lo comparte
por fuera de la app, y la cuidadora o el médico lo canjea para quedar en
patient_members. Se prueba contra el esquema real, con usuarios propios que se
crean al empezar y se borran al terminar, para no tocar los de la semilla.

Ojo con el número de canjes: /invitations/accept tiene límite por IP
(LIMIT_INVITE_CODE, 12 por minuto) y todas estas llamadas salen de la misma.
Este archivo hace menos de doce a propósito.
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
import hashlib  # noqa: E402
import re  # noqa: E402
from datetime import datetime, timedelta, timezone  # noqa: E402

import httpx  # noqa: E402
from fastapi import FastAPI  # noqa: E402
from jose import jwt  # noqa: E402
from sqlalchemy import text as _t  # noqa: E402

from app.config import get_settings  # noqa: E402
from app.db import engine as _eng  # noqa: E402
from app.errors import register_error_handlers  # noqa: E402
from app.routers import patients  # noqa: E402

app = FastAPI()
register_error_handlers(app)
app.include_router(patients.router)

PACIENTE = "33333333-3333-4333-8333-333333333333"
FAMILIAR = "11111111-1111-4111-8111-111111111111"   # administrador de la semilla
CUIDADORA_SEMILLA = "22222222-2222-4222-8222-222222222222"
# Dominio real (.cl) a proposito: la API valida el correo y rechaza los
# dominios reservados como .test, asi que con uno de esos no se podria
# probar reinvitar al mismo correo.
DOMINIO = "@pruebas-invitaciones.agecare.cl"
CORREO_REINVITADO = "reinvitada" + DOMINIO
HASH_SEMBRADO = "e" * 64
# Hash de cada invitación que crea esta prueba: la limpieza borra solo esas y
# deja intactas las que alguien haya generado a mano en su base de desarrollo.
HASHES = [HASH_SEMBRADO]
n = ok = 0


def token(uid):
    cfg = get_settings()
    t = jwt.encode({"sub": uid, "type": "access",
                    "exp": int((datetime.now(timezone.utc) + timedelta(minutes=10)).timestamp())},
                   cfg.jwt_secret, algorithm=cfg.jwt_algorithm)
    return {"Authorization": f"Bearer {t}"}


def check(nombre, condicion, detalle=""):
    global n, ok
    n += 1
    if condicion:
        ok += 1
        print(f"  OK   {nombre}")
    else:
        print(f"  FALLA {nombre}")
        if detalle:
            print(f"       {str(detalle)[:200]}")


def codigo_error(r):
    """Las respuestas de error vienen como {"error": {"code": ...}}."""
    try:
        return r.json().get("error", {}).get("code")
    except ValueError:
        return None


def sha(code):
    return hashlib.sha256(code.encode()).hexdigest()


async def limpiar():
    async with _eng.begin() as c:
        await c.execute(_t(
            "DELETE FROM invitations WHERE accepted_by IN "
            "(SELECT id FROM users WHERE email LIKE :d) "
            "OR email LIKE :d OR token_hash = ANY(:hs)"),
            {"d": "%" + DOMINIO, "hs": HASHES})
        await c.execute(_t(
            "DELETE FROM patient_members WHERE user_id IN "
            "(SELECT id FROM users WHERE email LIKE :d)"), {"d": "%" + DOMINIO})
        await c.execute(_t(
            "DELETE FROM doctor_profiles WHERE user_id IN "
            "(SELECT id FROM users WHERE email LIKE :d)"), {"d": "%" + DOMINIO})
        await c.execute(_t("DELETE FROM users WHERE email LIKE :d"), {"d": "%" + DOMINIO})


async def crear_usuario(nombre, tipo):
    async with _eng.begin() as c:
        uid = (await c.execute(_t(
            "INSERT INTO users (email, password_hash, first_name, last_name, locale, account_type) "
            "VALUES (:e, 'x', :n, 'Prueba', 'es', :t) RETURNING id"),
            {"e": nombre + DOMINIO, "n": nombre.capitalize(), "t": tipo})).scalar_one()
        if tipo == "doctor":
            await c.execute(_t(
                "INSERT INTO doctor_profiles (user_id, license_number, specialty) "
                "VALUES (:u, :l, 'Medicina general')"),
                {"u": uid, "l": "RNPI-PRUEBA-" + nombre.upper()})
    return str(uid)


async def invitar(cl, rol, correo=None, como=FAMILIAR):
    cuerpo = {"role": rol}
    if correo:
        cuerpo["email"] = correo
    r = await cl.post(f"/api/v1/patients/{PACIENTE}/invitations",
                      json=cuerpo, headers=token(como))
    if r.status_code == 201:
        HASHES.append(sha(r.json()["token"]))
    return r


async def aceptar(cl, codigo, como):
    return await cl.post("/api/v1/invitations/accept", json={"token": codigo},
                         headers=token(como))


async def miembro(uid):
    async with _eng.begin() as c:
        r = await c.execute(_t(
            "SELECT role, is_owner FROM patient_members "
            "WHERE patient_id = :p AND user_id = :u AND removed_at IS NULL"),
            {"p": PACIENTE, "u": uid})
        return r.mappings().first()


async def main(cl):
    cuidadora = await crear_usuario("cuidadora", "caregiver")
    medico = await crear_usuario("medico", "doctor")
    sin_habilitar = await crear_usuario("falsomedico", "caregiver")

    print("--- generar códigos ---")
    r1 = await invitar(cl, "caregiver")
    check("el familiar genera un código para cuidadora (201)", r1.status_code == 201, r1.text)
    cod_cuidadora = r1.json().get("token", "") if r1.status_code == 201 else ""
    check("el código tiene 6 dígitos", re.fullmatch(r"\d{6}", cod_cuidadora) is not None, cod_cuidadora)

    # Antes de la migración 961 esto respondía 500: los dos sin correo
    # chocaban en el índice ux_invitations_pending.
    r2 = await invitar(cl, "doctor")
    check("un segundo código sin correo al mismo paciente no choca (201)",
          r2.status_code == 201, r2.text)
    cod_medico = r2.json().get("token", "") if r2.status_code == 201 else ""
    check("los dos códigos son distintos", cod_cuidadora != cod_medico)

    async with _eng.begin() as c:
        fila = (await c.execute(_t(
            "SELECT email, token_hash FROM invitations WHERE token_hash = :h"),
            {"h": sha(cod_cuidadora)})).mappings().first()
    check("se guarda el hash del código y no el código", fila is not None
          and fila["token_hash"] != cod_cuidadora, fila)
    check("sin correo queda NULL, no ''", fila is not None and fila["email"] is None, fila)

    r = await invitar(cl, "caregiver", como=CUIDADORA_SEMILLA)
    check("quien no es administrador no puede invitar", r.status_code in (403, 404), r.status_code)

    r = await cl.get(f"/api/v1/patients/{PACIENTE}/members", headers=token(FAMILIAR))
    pendientes = r.json().get("pending_invitations", []) if r.status_code == 200 else []
    check("la lista de miembros muestra las pendientes sin correo",
          r.status_code == 200 and any(p["email"] is None for p in pendientes), r.text)

    print("--- reinvitar al mismo correo ---")
    ra = await invitar(cl, "caregiver", correo=CORREO_REINVITADO)
    rb = await invitar(cl, "caregiver", correo=CORREO_REINVITADO)
    check("reinvitar al mismo correo no choca (201 y 201)",
          ra.status_code == 201 and rb.status_code == 201, (ra.text, rb.text))
    async with _eng.begin() as c:
        vivas = (await c.execute(_t(
            "SELECT count(*) FROM invitations WHERE patient_id = :p AND email = :e "
            "AND accepted_at IS NULL AND revoked_at IS NULL"),
            {"p": PACIENTE, "e": CORREO_REINVITADO})).scalar_one()
    check("queda una sola invitación viva para ese correo", vivas == 1, vivas)

    print("--- canjear ---")
    # canje 1
    r = await aceptar(cl, "12ab", cuidadora)
    check("un código que no son 6 dígitos se rechaza en el borde (422)", r.status_code == 422, r.text)

    # canje 2: un código con buen formato que no corresponde a ninguna pendiente
    ajeno = next(f"{i:06d}" for i in range(1000000)
                 if f"{i:06d}" not in (cod_cuidadora, cod_medico))
    async with _eng.begin() as c:
        ocupado = (await c.execute(_t(
            "SELECT 1 FROM invitations WHERE token_hash = :h "
            "AND accepted_at IS NULL AND revoked_at IS NULL"), {"h": sha(ajeno)})).first()
    if ocupado is None:
        r = await aceptar(cl, ajeno, cuidadora)
        check("un código inexistente responde 400 INVALID_INVITATION",
              r.status_code == 400 and codigo_error(r) == "INVALID_INVITATION", r.text)

    # canje 3: el administrador no puede canjear un código para su propio paciente
    r = await aceptar(cl, cod_cuidadora, FAMILIAR)
    check("quien ya está en el círculo recibe 409 y el código no se gasta",
          r.status_code == 409, r.text)
    m = await miembro(FAMILIAR)
    check("el administrador sigue siendo familiar y dueño",
          m is not None and m["role"] == "family" and m["is_owner"], m)

    # canje 4
    r = await aceptar(cl, cod_cuidadora, cuidadora)
    check("la cuidadora canjea su código (200, rol caregiver)",
          r.status_code == 200 and r.json().get("role") == "caregiver"
          and r.json().get("patient_id") == PACIENTE, r.text)
    m = await miembro(cuidadora)
    check("la cuidadora queda en patient_members", m is not None and m["role"] == "caregiver", m)

    # canje 5
    r = await aceptar(cl, cod_cuidadora, medico)
    check("el mismo código no sirve dos veces (400)", r.status_code == 400, r.text)

    # canje 6
    r = await aceptar(cl, cod_medico, sin_habilitar)
    check("sin habilitación de médico no se acepta un código de médico (403)",
          r.status_code == 403 and codigo_error(r) == "DOCTOR_NOT_VERIFIED", r.text)

    # canje 7: el rechazo anterior no gastó el código
    r = await aceptar(cl, cod_medico, medico)
    check("el médico habilitado canjea su código (200, rol doctor)",
          r.status_code == 200 and r.json().get("role") == "doctor", r.text)
    m = await miembro(medico)
    check("el médico queda en patient_members", m is not None and m["role"] == "doctor", m)

    # canje 8: una invitación vencida no se acepta
    vencido = next(f"{i:06d}" for i in range(999999, 0, -1)
                   if f"{i:06d}" not in (cod_cuidadora, cod_medico, ajeno))
    HASHES.append(sha(vencido))
    async with _eng.begin() as c:
        await c.execute(_t(
            "INSERT INTO invitations (patient_id, email, role, token_hash, invited_by, "
            "expires_at, created_at) VALUES (:p, NULL, 'caregiver', :h, :f, "
            "now() - interval '1 day', now() - interval '8 days')"),
            {"p": PACIENTE, "h": sha(vencido), "f": FAMILIAR})
    otra = await crear_usuario("tardia", "caregiver")
    r = await aceptar(cl, vencido, otra)
    check("un código vencido responde 400", r.status_code == 400, r.text)

    # Un código ya canjeado puede volver a salir para una invitación nueva:
    # solo las pendientes tienen que ser distintas (índice parcial de 961).
    async with _eng.begin() as c:
        try:
            await c.execute(_t(
                "INSERT INTO invitations (patient_id, email, role, token_hash, invited_by, expires_at) "
                "VALUES (:p, NULL, 'caregiver', :h, :f, now() + interval '7 days')"),
                {"p": PACIENTE, "h": sha(cod_cuidadora), "f": FAMILIAR})
            reusable = True
        except Exception as e:  # noqa: BLE001
            reusable = False
            print(f"       {str(e).splitlines()[0]}")
    check("un código ya usado puede reutilizarse en una invitación nueva", reusable)

    # Dos pendientes con el mismo código, en cambio, no pueden convivir.
    async with _eng.begin() as c:
        await c.execute(_t(
            "INSERT INTO invitations (patient_id, email, role, token_hash, invited_by, expires_at) "
            "VALUES (:p, NULL, 'caregiver', :h, :f, now() + interval '7 days')"),
            {"p": PACIENTE, "h": HASH_SEMBRADO, "f": FAMILIAR})
    try:
        async with _eng.begin() as c:
            await c.execute(_t(
                "INSERT INTO invitations (patient_id, email, role, token_hash, invited_by, expires_at) "
                "VALUES (:p, NULL, 'doctor', :h, :f, now() + interval '7 days')"),
                {"p": PACIENTE, "h": HASH_SEMBRADO, "f": FAMILIAR})
        duplicado_bloqueado = False
    except Exception:  # noqa: BLE001
        duplicado_bloqueado = True
    check("dos invitaciones pendientes no pueden tener el mismo código", duplicado_bloqueado)


async def run():
    await limpiar()
    transport = httpx.ASGITransport(app=app)
    try:
        async with httpx.AsyncClient(transport=transport, base_url="http://testserver") as cl:
            await main(cl)
    finally:
        await limpiar()
        await _eng.dispose()
    print(f"\n{ok} ok, {n - ok} fallas")
    return 0 if ok == n else 1


_sys.exit(asyncio.run(run()))
