"""Módulo 3: Autenticación y cuenta de usuario (endpoints 3.1–3.9).

Alineado con la Especificación de Endpoints v1. Usa las tablas existentes:
users, refresh_tokens (rotación con family_id), push_devices,
password_reset_tokens (RF-05).
"""
import hashlib
import os
import re
import uuid
from datetime import datetime, timedelta, timezone
from typing import Literal

from fastapi import APIRouter, Depends, Request, Response, status
from pydantic import BaseModel, EmailStr, Field, field_validator
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

from app.db import get_db
from app.deps import CurrentUser, get_current_user, is_verified_doctor
from app.email_provider import get_email
from app.errors import ApiError
from app.ratelimit import LIMIT_INVITE_CODE, LIMIT_LOGIN, LIMIT_REFRESH, limiter
from app.validators import clean_person_name, normalize_phone, parse_rut
from app.security import (
    create_access_token,
    generate_refresh_token,
    hash_password,
    hash_token,
    refresh_token_expiry,
    verify_password,
)

router = APIRouter(prefix="/api/v1", tags=["auth"])

_PASSWORD_RE = re.compile(r"^(?=.*[A-Za-z])(?=.*\d).{8,}$")


# --------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------
async def _issue_tokens(
    db: AsyncSession, user_id: str, family_id: str | None = None
) -> tuple[str, str]:
    """Emite (access_token, refresh_token) y persiste el hash del refresh.

    Si family_id es None, inicia una nueva familia de sesión (nuevo login).
    """
    if family_id is None:
        family_id = str(uuid.uuid4())

    refresh = generate_refresh_token()
    await db.execute(
        text(
            """
            INSERT INTO refresh_tokens (user_id, family_id, token_hash, expires_at)
            VALUES (:uid, :fid, :thash, :exp)
            """
        ),
        {
            "uid": user_id,
            "fid": family_id,
            "thash": hash_token(refresh),
            "exp": refresh_token_expiry(),
        },
    )
    access = create_access_token(subject=user_id)
    return access, refresh


async def _load_memberships(db: AsyncSession, user_id: str) -> list[dict]:
    rows = (
        await db.execute(
            text(
                """
                SELECT pm.patient_id, p.full_name AS patient_name, pm.role
                FROM patient_members pm
                JOIN patients p ON p.id = pm.patient_id
                WHERE pm.user_id = :uid
                  AND pm.removed_at IS NULL
                  AND p.deleted_at IS NULL
                  -- Una membresía 'doctor' solo cuenta con habilitación vigente.
                  AND (pm.role <> 'doctor' OR EXISTS (
                        SELECT 1 FROM doctor_profiles d
                        WHERE d.user_id = pm.user_id AND d.revoked_at IS NULL))
                ORDER BY p.full_name
                """
            ),
            {"uid": user_id},
        )
    ).mappings().all()
    return [
        {
            "patient_id": str(r["patient_id"]),
            "patient_name": r["patient_name"],
            "role": r["role"],
        }
        for r in rows
    ]


# --------------------------------------------------------------------------
# Schemas
# --------------------------------------------------------------------------
class UserOut(BaseModel):
    user_id: str
    full_name: str
    first_name: str
    second_name: str | None = None
    last_name: str
    second_last_name: str | None = None
    # "12.345.678-5"; nulo si la cuenta no lo registró.
    rut: str | None = None
    email: str
    phone: str | None = None
    avatar_url: str | None = None
    locale: str
    # Tipo de persona para la plataforma (family|caregiver|doctor|elder).
    account_type: str = "family"
    # Solo tiene sentido para account_type == 'doctor'.
    doctor_verified: bool = False
    # Personal de AgeCare (panel de administración). No es familia de nadie:
    # la app móvil no le ofrece crear ni cuidar adultos mayores.
    is_staff: bool = False
    memberships: list["MembershipOut"] = []


class MembershipOut(BaseModel):
    patient_id: str
    patient_name: str
    role: str


class RegisterIn(BaseModel):
    first_name: str = Field(min_length=1, max_length=60)
    second_name: str | None = Field(default=None, max_length=60)
    last_name:  str = Field(min_length=1, max_length=60)
    second_last_name: str | None = Field(default=None, max_length=60)
    # Obligatorio para la cuidadora: entra a casas ajenas y se publica en el
    # marketplace. El familiar no lo necesita.
    rut: str | None = None
    email: EmailStr
    password: str
    phone: str | None = None
    # Qué persona se registra. Obligatorio salvo que venga una invitación, que
    # ya define el rol. 'elder' no se ofrece: la cuenta del adulto mayor la
    # crea su familia. 'doctor' exige el código de habilitación.
    account_type: Literal["family", "caregiver", "doctor"] | None = None
    doctor_enrollment_token: str | None = None
    invitation_token: str | None = None
    locale: str = "es"

    @field_validator("first_name", "last_name")
    @classmethod
    def _nombre_valido(cls, v: str) -> str:
        return clean_person_name(v)

    @field_validator("second_name", "second_last_name")
    @classmethod
    def _nombre_opcional(cls, v: str | None) -> str | None:
        return clean_person_name(v) if v and v.strip() else None

    @field_validator("rut")
    @classmethod
    def _rut_valido(cls, v: str | None) -> str | None:
        if not v or not v.strip():
            return None
        numero, dv = parse_rut(v)
        return f"{numero}-{dv}"

    @field_validator("phone")
    @classmethod
    def _telefono_valido(cls, v: str | None) -> str | None:
        return normalize_phone(v) if v else None


def rut_legible(numero: int | None, dv: str | None) -> str | None:
    """12345678, '5' -> '12.345.678-5'."""
    if numero is None or dv is None:
        return None
    return f"{numero:,}".replace(",", ".") + f"-{dv}"


class RegisterOut(BaseModel):
    user_id: str
    email: str
    role: str | None
    account_type: str
    access_token: str
    refresh_token: str


class LoginIn(BaseModel):
    email: EmailStr
    password: str


class LoginOut(BaseModel):
    access_token: str
    refresh_token: str
    token_type: str = "bearer"
    user: UserOut
    memberships: list[MembershipOut]


class RefreshIn(BaseModel):
    refresh_token: str


class TokenPairOut(BaseModel):
    access_token: str
    refresh_token: str
    token_type: str = "bearer"


class LogoutIn(BaseModel):
    refresh_token: str
    device_id: uuid.UUID | None = None


class RecoveryIn(BaseModel):
    email: EmailStr


class ResetIn(BaseModel):
    reset_token: str
    new_password: str


class ProfilePatchIn(BaseModel):
    first_name: str | None = Field(default=None, min_length=1, max_length=60)
    # Para segundo nombre y segundo apellido, "" significa quitarlo; ausente
    # (None) significa no tocarlo.
    second_name: str | None = Field(default=None, max_length=60)
    last_name:  str | None = Field(default=None, min_length=1, max_length=60)
    second_last_name: str | None = Field(default=None, max_length=60)
    phone: str | None = None
    avatar_url: str | None = None
    locale: str | None = None

    @field_validator("first_name", "last_name")
    @classmethod
    def _nombre_valido(cls, v: str | None) -> str | None:
        return clean_person_name(v) if v is not None else None

    @field_validator("second_name", "second_last_name")
    @classmethod
    def _nombre_opcional(cls, v: str | None) -> str | None:
        if v is None:
            return None
        return clean_person_name(v) if v.strip() else ""

    @field_validator("phone")
    @classmethod
    def _telefono_valido(cls, v: str | None) -> str | None:
        return normalize_phone(v) if v else None


class DeviceIn(BaseModel):
    push_token: str
    platform: str  # ios | android
    app_version: str | None = None


class DeviceOut(BaseModel):
    device_id: str


# --------------------------------------------------------------------------
# 3.1 Registrar cuenta
# --------------------------------------------------------------------------
@router.post("/auth/register", response_model=RegisterOut, status_code=201)
# El registro acepta un codigo de invitacion de 6 digitos: sin limite seria
# la forma de probar codigos al azar sin pasar por /invitations/accept.
@limiter.limit(LIMIT_INVITE_CODE)
async def register(request: Request, payload: RegisterIn,
                   db: AsyncSession = Depends(get_db)):
    if not _PASSWORD_RE.match(payload.password):
        raise ApiError(
            status_code=400,
            code="WEAK_PASSWORD",
            message="La contraseña no cumple los requisitos mínimos de seguridad.",
        )

    # Correo único (índice ux_users_email_lower).
    exists = (
        await db.execute(
            text("SELECT 1 FROM users WHERE lower(email) = lower(:e)"),
            {"e": payload.email},
        )
    ).first()
    if exists:
        raise ApiError(
            status_code=409,
            code="EMAIL_ALREADY_EXISTS",
            message="Ya existe una cuenta con este correo electrónico.",
        )

    # Invitación (opcional): valida token vivo y no vencido.
    invitation = None
    if payload.invitation_token:
        invitation = (
            await db.execute(
                text(
                    """
                    SELECT id, patient_id, role, email
                    FROM invitations
                    WHERE token_hash = :th
                      AND accepted_at IS NULL
                      AND revoked_at IS NULL
                      AND expires_at > now()
                    """
                ),
                {"th": hash_token(payload.invitation_token)},
            )
        ).mappings().first()
        if invitation is None:
            raise ApiError(
                status_code=400,
                code="INVALID_INVITATION",
                message="La invitación no existe, ya fue usada o está vencida.",
            )

    # ── Tipo de cuenta ────────────────────────────────────────────────────
    # Con invitación, el rol lo define quien invita. Sin invitación hay que
    # elegirlo: ya no se asume "familiar" en silencio.
    if invitation is not None:
        account_type = invitation["role"]
        if payload.account_type is not None and payload.account_type != account_type:
            raise ApiError(
                status_code=422,
                code="ROLE_MISMATCH",
                message="El tipo de cuenta no coincide con el de la invitación.",
            )
    else:
        if payload.account_type is None:
            raise ApiError(
                status_code=422,
                code="VALIDATION_ERROR",
                message="Hay datos inválidos en la solicitud. Revisa los campos marcados.",
                details=[{"field": "account_type",
                          "message": "Indica si te registras como familiar, cuidador(a) o médico."}],
            )
        account_type = payload.account_type

    # Médico: nadie se declara médico. Hace falta el código que emite el
    # personal de AgeCare tras verificar el registro profesional, y ese código
    # está ligado al correo con el que se registra.
    enrollment = None
    if account_type == "doctor":
        if invitation is not None or not payload.doctor_enrollment_token:
            raise ApiError(
                status_code=403,
                code="DOCTOR_ENROLLMENT_REQUIRED",
                message=(
                    "Las cuentas de médico las habilita el equipo de AgeCare. "
                    "Crea tu cuenta con el código de habilitación y luego ingresa la invitación."
                ),
            )
        enrollment = (
            await db.execute(
                text(
                    """
                    SELECT id, license_number, specialty, created_by
                    FROM doctor_enrollments
                    WHERE token_hash = :th
                      AND lower(email) = lower(:email)
                      AND accepted_at IS NULL
                      AND revoked_at IS NULL
                      AND expires_at > now()
                    FOR UPDATE
                    """
                ),
                {"th": hash_token(payload.doctor_enrollment_token),
                 "email": payload.email},
            )
        ).mappings().first()
        if enrollment is None:
            raise ApiError(
                status_code=403,
                code="INVALID_DOCTOR_ENROLLMENT",
                message="El código de habilitación no existe, ya fue usado, venció o no corresponde a este correo.",
            )
    elif payload.doctor_enrollment_token:
        raise ApiError(
            status_code=422,
            code="VALIDATION_ERROR",
            message="Hay datos inválidos en la solicitud. Revisa los campos marcados.",
            details=[{"field": "doctor_enrollment_token",
                      "message": "El código de habilitación solo aplica a cuentas de médico."}],
        )

    # Cuidador(a): entra a la casa de un adulto mayor y la familia tiene que
    # poder identificarla y llamarla. Sin RUT ni teléfono no hay cuenta.
    if account_type == "caregiver":
        faltan = []
        if payload.rut is None:
            faltan.append({"field": "rut",
                           "message": "El RUT es obligatorio para cuidadores(as)."})
        if payload.phone is None:
            faltan.append({"field": "phone",
                           "message": "El teléfono es obligatorio para cuidadores(as)."})
        if faltan:
            raise ApiError(
                status_code=422, code="VALIDATION_ERROR",
                message="Hay datos inválidos en la solicitud. Revisa los campos marcados.",
                details=faltan,
            )

    rut_numero = rut_dv = None
    if payload.rut is not None:
        n, rut_dv = payload.rut.split("-")
        rut_numero = int(n)
        if (await db.execute(
            text("SELECT 1 FROM users WHERE rut_number = :n"), {"n": rut_numero},
        )).first():
            raise ApiError(
                status_code=409, code="RUT_ALREADY_EXISTS",
                message="Ya existe una cuenta con ese RUT.",
            )

    user_id = str(uuid.uuid4())
    await db.execute(
        text(
            """
            INSERT INTO users (id, email, password_hash, first_name, second_name,
                               last_name, second_last_name, rut_number, rut_dv,
                               phone, locale, account_type)
            VALUES (:id, :email, :ph, :fn, :sn, :ln, :sln, :rn, :rdv,
                    :phone, :locale, :atype)
            """
        ),
        {
            "id": user_id,
            "email": payload.email,
            "ph": hash_password(payload.password),
            "fn": payload.first_name,
            "sn": payload.second_name,
            "ln": payload.last_name,
            "sln": payload.second_last_name,
            "rn": rut_numero,
            "rdv": rut_dv,
            "phone": payload.phone,
            "locale": payload.locale,
            "atype": account_type,
        },
    )

    if enrollment is not None:
        await db.execute(
            text(
                """
                INSERT INTO doctor_profiles (user_id, license_number, specialty, verified_by)
                VALUES (:uid, :lic, :spec, :by)
                """
            ),
            {"uid": user_id, "lic": enrollment["license_number"],
             "spec": enrollment["specialty"], "by": enrollment["created_by"]},
        )
        await db.execute(
            text("UPDATE doctor_enrollments SET accepted_at = now(), accepted_by = :uid "
                 "WHERE id = :eid"),
            {"uid": user_id, "eid": enrollment["id"]},
        )

    role = None
    if invitation is not None:
        role = invitation["role"]
        await db.execute(
            text(
                """
                INSERT INTO patient_members (patient_id, user_id, role, is_owner)
                VALUES (:pid, :uid, :role, false)
                ON CONFLICT (patient_id, user_id) DO NOTHING
                """
            ),
            {"pid": invitation["patient_id"], "uid": user_id, "role": role},
        )
        await db.execute(
            text(
                """
                UPDATE invitations
                SET accepted_at = now(), accepted_by = :uid
                WHERE id = :iid
                """
            ),
            {"uid": user_id, "iid": invitation["id"]},
        )

    access, refresh = await _issue_tokens(db, user_id)
    await db.commit()

    return RegisterOut(
        user_id=user_id,
        email=payload.email,
        role=role,
        account_type=account_type,
        access_token=access,
        refresh_token=refresh,
    )


# --------------------------------------------------------------------------
# 3.2 Iniciar sesión
# --------------------------------------------------------------------------
@router.post("/auth/login", response_model=LoginOut)
@limiter.limit(LIMIT_LOGIN)
async def login(request: Request, payload: LoginIn, db: AsyncSession = Depends(get_db)):
    user = (
        await db.execute(
            text(
                """
                SELECT id, email, password_hash, first_name, second_name,
                       last_name, second_last_name, full_name, rut_number, rut_dv,
                       phone, avatar_url, locale, account_type, is_staff
                FROM users
                WHERE lower(email) = lower(:email)
                  AND is_active = true
                  AND deleted_at IS NULL
                """
            ),
            {"email": payload.email},
        )
    ).mappings().first()

    if user is None or not verify_password(payload.password, user["password_hash"]):
        raise ApiError(
            status_code=401,
            code="INVALID_CREDENTIALS",
            message="Correo o contraseña incorrectos.",
        )

    memberships = await _load_memberships(db, str(user["id"]))
    access, refresh = await _issue_tokens(db, str(user["id"]))
    await db.commit()

    return LoginOut(
        access_token=access,
        refresh_token=refresh,
        user=UserOut(
            user_id=str(user["id"]),
            first_name=user["first_name"],
            second_name=user["second_name"],
            last_name=user["last_name"],
            second_last_name=user["second_last_name"],
            rut=rut_legible(user["rut_number"], user["rut_dv"]),
            full_name=user["full_name"],
            email=user["email"],
            phone=user["phone"],
            avatar_url=user["avatar_url"],
            locale=user["locale"],
            account_type=user["account_type"],
            is_staff=user["is_staff"],
            doctor_verified=(user["account_type"] == "doctor"
                             and await is_verified_doctor(db, str(user["id"]))),
            memberships=[MembershipOut(**m) for m in memberships],
        ),
        memberships=[MembershipOut(**m) for m in memberships],
    )


# --------------------------------------------------------------------------
# 3.3 Refrescar token (rotación + detección de reuso)
# --------------------------------------------------------------------------
@router.post("/auth/refresh", response_model=TokenPairOut)
@limiter.limit(LIMIT_REFRESH)
async def refresh_token(request: Request, payload: RefreshIn, db: AsyncSession = Depends(get_db)):
    invalid = ApiError(
        status_code=401,
        code="INVALID_REFRESH_TOKEN",
        message="El token de refresco es inválido, expiró o ya fue utilizado.",
    )

    token_hash = hash_token(payload.refresh_token)
    row = (
        await db.execute(
            text(
                """
                SELECT id, user_id, family_id, revoked_at, expires_at
                FROM refresh_tokens
                WHERE token_hash = :th
                """
            ),
            {"th": token_hash},
        )
    ).mappings().first()

    if row is None or row["expires_at"] <= datetime.now(row["expires_at"].tzinfo):
        raise invalid

    # Reuso detectado: el token ya fue revocado -> anular toda la familia.
    if row["revoked_at"] is not None:
        await db.execute(
            text(
                """
                UPDATE refresh_tokens
                SET revoked_at = now(), revoked_reason = 'reuse_detected'
                WHERE family_id = :fid AND revoked_at IS NULL
                """
            ),
            {"fid": row["family_id"]},
        )
        await db.commit()
        raise invalid

    # Rotación: revoca el actual y emite uno nuevo en la misma familia.
    await db.execute(
        text(
            """
            UPDATE refresh_tokens
            SET revoked_at = now(), revoked_reason = 'rotated'
            WHERE id = :id
            """
        ),
        {"id": row["id"]},
    )
    access, new_refresh = await _issue_tokens(
        db, str(row["user_id"]), family_id=str(row["family_id"])
    )
    await db.commit()
    return TokenPairOut(access_token=access, refresh_token=new_refresh)


# --------------------------------------------------------------------------
# 3.4 Cerrar sesión
# --------------------------------------------------------------------------
@router.post("/auth/logout", status_code=204)
async def logout(
    payload: LogoutIn,
    user: CurrentUser = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    await db.execute(
        text(
            """
            UPDATE refresh_tokens
            SET revoked_at = now(), revoked_reason = 'logout'
            WHERE token_hash = :th AND user_id = :uid AND revoked_at IS NULL
            """
        ),
        {"th": hash_token(payload.refresh_token), "uid": user.user_id},
    )
    if payload.device_id is not None:
        await db.execute(
            text(
                """
                UPDATE push_devices SET is_active = false
                WHERE id = :did AND user_id = :uid
                """
            ),
            {"did": str(payload.device_id), "uid": user.user_id},
        )
    await db.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)


# --------------------------------------------------------------------------
# 3.5 Solicitar recuperación de contraseña (RF-05)
# --------------------------------------------------------------------------
@router.post("/auth/password/recovery", status_code=202)
async def password_recovery(
    payload: RecoveryIn, db: AsyncSession = Depends(get_db)
):
    """Solicita el enlace de recuperación de contraseña.

    Siempre responde 202 exista o no el correo, para no revelar qué cuentas
    hay en el sistema (evitar enumeración de usuarios).

    Si el correo existe:
    1. Invalida tokens anteriores del usuario.
    2. Genera un token aleatorio seguro y guarda su hash SHA-256.
    3. Envía el enlace al correo del usuario por el proveedor configurado.
    4. Si el correo no está configurado (EMAIL_PROVIDER=none) el token se
       crea igual; sin enlace el flujo queda incompleto pero no explota.
    """
    fila = (
        await db.execute(
            text(
                """
                SELECT id, full_name FROM users
                WHERE lower(email) = lower(:email)
                  AND is_active = true
                  AND deleted_at IS NULL
                """
            ),
            {"email": payload.email},
        )
    ).mappings().first()

    if fila is None:
        # No existe la cuenta: responde 202 igualmente (anti-enumeración).
        return Response(status_code=status.HTTP_202_ACCEPTED)

    # Leer la ventana de validez desde system_parameters.
    minutos = (
        await db.execute(
            text(
                "SELECT value FROM system_parameters "
                "WHERE key = 'password_reset_expire_minutes'"
            )
        )
    ).scalar()
    try:
        minutos = int(minutos)
    except (TypeError, ValueError):
        minutos = 30

    # Invalidar tokens anteriores del mismo usuario.
    await db.execute(
        text(
            "UPDATE password_reset_tokens SET used_at = now() "
            "WHERE user_id = :uid AND used_at IS NULL"
        ),
        {"uid": str(fila["id"])},
    )

    # Generar token seguro y guardar solo el hash.
    token_claro = os.urandom(32).hex()  # 64 hex chars, 256 bits de entropía
    token_hash = hashlib.sha256(token_claro.encode()).hexdigest()
    vence = datetime.now(timezone.utc) + timedelta(minutes=minutos)

    await db.execute(
        text(
            """
            INSERT INTO password_reset_tokens (user_id, token_hash, expires_at)
            VALUES (:uid, :hash, :exp)
            """
        ),
        {"uid": str(fila["id"]), "hash": token_hash, "exp": vence},
    )
    await db.commit()

    # Enviar correo con el enlace. Si el proveedor no está configurado
    # el Envio queda como fallido pero no lanzamos: el 202 ya salió.
    nombre = fila["full_name"] or payload.email
    enlace = f"agecare://reset-password?token={token_claro}"

    cuerpo_html = f"""
    <html><body style="font-family:sans-serif;color:#222;">
    <h2>Recupera tu contraseña — AgeCare</h2>
    <p>Hola, <strong>{nombre}</strong>.</p>
    <p>Recibimos una solicitud para restablecer la contraseña de tu cuenta.</p>
    <p>
      <a href="{enlace}"
         style="display:inline-block;padding:12px 24px;background:#1976d2;
                color:#fff;border-radius:6px;text-decoration:none;
                font-weight:bold;">
        Restablecer contraseña
      </a>
    </p>
    <p>Este enlace vence en <strong>{minutos} minutos</strong>.<br>
    Si no solicitaste esto, ignora este mensaje.</p>
    <hr><p style="font-size:0.85rem;color:#888;">AgeCare · Cuidando a quienes cuidaron de nosotros.</p>
    </body></html>
    """
    cuerpo_texto = (
        f"Hola {nombre},\n\n"
        f"Para restablecer tu contraseña abre este enlace "
        f"(válido {minutos} min):\n{enlace}\n\n"
        "Si no lo pediste, ignora este mensaje.\n\n— AgeCare"
    )

    await get_email().enviar(
        destinatario=payload.email,
        asunto="Recupera tu contraseña en AgeCare",
        cuerpo_html=cuerpo_html,
        cuerpo_texto=cuerpo_texto,
    )

    return Response(status_code=status.HTTP_202_ACCEPTED)


# --------------------------------------------------------------------------
# 3.6 Restablecer contraseña (RF-05)
# --------------------------------------------------------------------------
@router.post("/auth/password/reset", status_code=204)
async def password_reset(
    payload: ResetIn, db: AsyncSession = Depends(get_db)
):
    """Establece la nueva contraseña usando el token del correo.

    Valida:
    - El token existe y no fue usado.
    - No venció.
    - La contraseña cumple los requisitos de seguridad.

    Tras el reset invalida todos los refresh tokens del usuario (cierra
    todas las sesiones activas) como medida de seguridad.
    """
    if not _PASSWORD_RE.match(payload.new_password):
        raise ApiError(
            status_code=400,
            code="WEAK_PASSWORD",
            message="La contraseña no cumple los requisitos mínimos de seguridad.",
        )

    token_hash = hashlib.sha256(payload.reset_token.encode()).hexdigest()

    fila = (
        await db.execute(
            text(
                """
                SELECT prt.id, prt.user_id, prt.expires_at
                FROM password_reset_tokens prt
                WHERE prt.token_hash = :hash
                  AND prt.used_at IS NULL
                """
            ),
            {"hash": token_hash},
        )
    ).mappings().first()

    if fila is None:
        raise ApiError(
            status_code=400,
            code="INVALID_RESET_TOKEN",
            message="El enlace de recuperación es inválido o expiró. Solicita uno nuevo.",
        )

    if fila["expires_at"] < datetime.now(timezone.utc):
        raise ApiError(
            status_code=400,
            code="INVALID_RESET_TOKEN",
            message="El enlace de recuperación es inválido o expiró. Solicita uno nuevo.",
        )

    nuevo_hash = hash_password(payload.new_password)

    # Actualizar contraseña, marcar token como usado y cerrar todas las sesiones.
    await db.execute(
        text("UPDATE users SET hashed_password = :pw WHERE id = :uid"),
        {"pw": nuevo_hash, "uid": str(fila["user_id"])},
    )
    await db.execute(
        text(
            "UPDATE password_reset_tokens SET used_at = now() WHERE id = :id"
        ),
        {"id": str(fila["id"])},
    )
    # Cerrar todas las sesiones activas del usuario como medida de seguridad.
    await db.execute(
        text(
            "UPDATE refresh_tokens SET revoked_at = now() "
            "WHERE user_id = :uid AND revoked_at IS NULL"
        ),
        {"uid": str(fila["user_id"])},
    )
    await db.commit()

    return Response(status_code=status.HTTP_204_NO_CONTENT)


# --------------------------------------------------------------------------
# 3.7 Obtener mi perfil
# --------------------------------------------------------------------------
@router.get("/users/me", response_model=UserOut)
async def get_me(
    user: CurrentUser = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    row = (
        await db.execute(
            text(
                """
                SELECT id, email, first_name, second_name, last_name,
                       second_last_name, full_name, rut_number, rut_dv,
                       phone, avatar_url, locale, account_type, is_staff
                FROM users WHERE id = :uid
                """
            ),
            {"uid": user.user_id},
        )
    ).mappings().first()
    memberships = await _load_memberships(db, user.user_id)
    return UserOut(
        user_id=str(row["id"]),
        first_name=row["first_name"],
        second_name=row["second_name"],
        last_name=row["last_name"],
        second_last_name=row["second_last_name"],
        rut=rut_legible(row["rut_number"], row["rut_dv"]),
        full_name=row["full_name"],
        email=row["email"],
        phone=row["phone"],
        avatar_url=row["avatar_url"],
        locale=row["locale"],
        account_type=row["account_type"],
        is_staff=row["is_staff"],
        doctor_verified=(row["account_type"] == "doctor"
                         and await is_verified_doctor(db, user.user_id)),
        memberships=[MembershipOut(**m) for m in memberships],
    )


# --------------------------------------------------------------------------
# 3.8 Actualizar mi perfil
# --------------------------------------------------------------------------
@router.patch("/users/me", response_model=UserOut)
async def patch_me(
    payload: ProfilePatchIn,
    user: CurrentUser = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    fields = payload.model_dump(exclude_unset=True)
    # "" en un campo opcional del nombre es quitarlo: se guarda NULL.
    for k in ("second_name", "second_last_name"):
        if fields.get(k) == "":
            fields[k] = None
    if fields:
        sets = ", ".join(f"{k} = :{k}" for k in fields)
        fields["uid"] = user.user_id
        await db.execute(
            text(f"UPDATE users SET {sets} WHERE id = :uid"), fields
        )
        await db.commit()
    return await get_me(user=user, db=db)


# --------------------------------------------------------------------------
# 3.9 Registrar dispositivo push
# --------------------------------------------------------------------------
@router.post("/users/me/devices", response_model=DeviceOut, status_code=201)
async def register_device(
    payload: DeviceIn,
    user: CurrentUser = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    if payload.platform not in ("ios", "android", "web"):
        raise ApiError(
            status_code=422,
            code="VALIDATION_ERROR",
            message="Hay datos inválidos en la solicitud. Revisa los campos marcados.",
        )
    # Upsert por push_token (índice único ux_push_devices_token).
    row = (
        await db.execute(
            text(
                """
                INSERT INTO push_devices (user_id, push_token, platform, last_seen_at)
                VALUES (:uid, :tok, :plat, now())
                ON CONFLICT (push_token) DO UPDATE
                    SET user_id = EXCLUDED.user_id,
                        platform = EXCLUDED.platform,
                        is_active = true,
                        last_seen_at = now()
                RETURNING id
                """
            ),
            {"uid": user.user_id, "tok": payload.push_token, "plat": payload.platform},
        )
    ).mappings().first()
    await db.commit()
    return DeviceOut(device_id=str(row["id"]))
