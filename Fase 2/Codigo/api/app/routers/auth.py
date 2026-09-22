"""Módulo 3: Autenticación y cuenta de usuario (endpoints 3.1–3.9).

Alineado con la Especificación de Endpoints v1. Usa las tablas existentes:
users, refresh_tokens (rotación con family_id), push_devices.

Notas de alcance para este hito:
- password/recovery y password/reset no envían correo real: recovery siempre
  responde 202 (evita enumeración) y reset queda como stub documentado, porque
  no hay tabla de tokens de recuperación en el SQL actual. Se implementará
  cuando se agregue esa tabla.
"""
import re
import uuid
from datetime import datetime

from fastapi import APIRouter, Depends, Response, status
from pydantic import BaseModel, EmailStr, Field
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

from app.db import get_db
from app.deps import CurrentUser, get_current_user
from app.errors import ApiError
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
    email: str
    phone: str | None = None
    avatar_url: str | None = None
    locale: str
    memberships: list["MembershipOut"] = []


class MembershipOut(BaseModel):
    patient_id: str
    patient_name: str
    role: str


class RegisterIn(BaseModel):
    full_name: str = Field(min_length=2, max_length=120)
    email: EmailStr
    password: str
    phone: str | None = None
    invitation_token: str | None = None
    locale: str = "es"


class RegisterOut(BaseModel):
    user_id: str
    email: str
    role: str | None
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
    full_name: str | None = Field(default=None, min_length=2, max_length=120)
    phone: str | None = None
    avatar_url: str | None = None
    locale: str | None = None


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
async def register(payload: RegisterIn, db: AsyncSession = Depends(get_db)):
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

    user_id = str(uuid.uuid4())
    await db.execute(
        text(
            """
            INSERT INTO users (id, email, password_hash, full_name, phone, locale)
            VALUES (:id, :email, :ph, :fn, :phone, :locale)
            """
        ),
        {
            "id": user_id,
            "email": payload.email,
            "ph": hash_password(payload.password),
            "fn": payload.full_name,
            "phone": payload.phone,
            "locale": payload.locale,
        },
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
        access_token=access,
        refresh_token=refresh,
    )


# --------------------------------------------------------------------------
# 3.2 Iniciar sesión
# --------------------------------------------------------------------------
@router.post("/auth/login", response_model=LoginOut)
async def login(payload: LoginIn, db: AsyncSession = Depends(get_db)):
    user = (
        await db.execute(
            text(
                """
                SELECT id, email, password_hash, full_name, phone, avatar_url, locale
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
            full_name=user["full_name"],
            email=user["email"],
            phone=user["phone"],
            avatar_url=user["avatar_url"],
            locale=user["locale"],
            memberships=[MembershipOut(**m) for m in memberships],
        ),
        memberships=[MembershipOut(**m) for m in memberships],
    )


# --------------------------------------------------------------------------
# 3.3 Refrescar token (rotación + detección de reuso)
# --------------------------------------------------------------------------
@router.post("/auth/refresh", response_model=TokenPairOut)
async def refresh_token(payload: RefreshIn, db: AsyncSession = Depends(get_db)):
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
# 3.5 Solicitar recuperación de contraseña
# --------------------------------------------------------------------------
@router.post("/auth/password/recovery", status_code=202)
async def password_recovery(payload: RecoveryIn, db: AsyncSession = Depends(get_db)):
    # Siempre 202, exista o no el correo (evita enumeración de cuentas).
    # El envío real de correo y la tabla de tokens de reset se añadirán luego.
    return Response(status_code=status.HTTP_202_ACCEPTED)


# --------------------------------------------------------------------------
# 3.6 Restablecer contraseña (stub: requiere tabla de tokens de reset)
# --------------------------------------------------------------------------
@router.post("/auth/password/reset", status_code=204)
async def password_reset(payload: ResetIn, db: AsyncSession = Depends(get_db)):
    if not _PASSWORD_RE.match(payload.new_password):
        raise ApiError(
            status_code=400,
            code="WEAK_PASSWORD",
            message="La contraseña no cumple los requisitos mínimos de seguridad.",
        )
    # Sin tabla de tokens de recuperación en el SQL actual: el token no se
    # puede validar todavía. Se responde con el error de la spec hasta que
    # exista la tabla correspondiente.
    raise ApiError(
        status_code=400,
        code="INVALID_RESET_TOKEN",
        message="El enlace de recuperación es inválido o expiró. Solicita uno nuevo.",
    )


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
                SELECT id, email, full_name, phone, avatar_url, locale
                FROM users WHERE id = :uid
                """
            ),
            {"uid": user.user_id},
        )
    ).mappings().first()
    memberships = await _load_memberships(db, user.user_id)
    return UserOut(
        user_id=str(row["id"]),
        full_name=row["full_name"],
        email=row["email"],
        phone=row["phone"],
        avatar_url=row["avatar_url"],
        locale=row["locale"],
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
