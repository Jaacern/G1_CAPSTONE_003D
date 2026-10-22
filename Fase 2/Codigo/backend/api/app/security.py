"""Utilidades de seguridad: verificación de contraseñas (bcrypt) y JWT.

El seed usa hashes bcrypt ($2b$12$...). La password de los usuarios de
demostración es 'demo1234'.
"""
import hashlib
import secrets
from datetime import datetime, timedelta, timezone

from jose import jwt
from passlib.context import CryptContext

from app.config import get_settings

settings = get_settings()

pwd_context = CryptContext(schemes=["bcrypt"], deprecated="auto")


def verify_password(plain: str, password_hash: str) -> bool:
    """Compara una contraseña en claro contra el hash almacenado."""
    return pwd_context.verify(plain, password_hash)


def hash_password(plain: str) -> str:
    """Genera el hash bcrypt de una contraseña (para altas de usuario)."""
    return pwd_context.hash(plain)


def create_access_token(subject: str, extra_claims: dict | None = None) -> str:
    """Crea un JWT de acceso firmado. `subject` normalmente es el user_id.

    Vigencia de 30 minutos (spec 2.2).
    """
    now = datetime.now(timezone.utc)
    payload: dict = {
        "sub": subject,
        "type": "access",
        "iat": now,
        "exp": now + timedelta(minutes=settings.access_token_expire_minutes),
    }
    if extra_claims:
        payload.update(extra_claims)
    return jwt.encode(payload, settings.jwt_secret, algorithm=settings.jwt_algorithm)


def generate_refresh_token() -> str:
    """Genera un refresh token opaco (256 bits aleatorios en hex).

    No es un JWT: es un secreto aleatorio cuyo hash SHA-256 se persiste en
    la tabla refresh_tokens (columna token_hash de 64 chars). Así el servidor
    puede revocarlo, cosa que un JWT sin estado no permite.
    """
    return secrets.token_hex(32)  # 32 bytes -> 64 chars hex


def hash_token(token: str) -> str:
    """SHA-256 en hex del token. Coincide con token_hash del esquema."""
    return hashlib.sha256(token.encode()).hexdigest()


def refresh_token_expiry() -> datetime:
    """Vencimiento del refresh token: 30 días desde ahora (spec 2.2)."""
    return datetime.now(timezone.utc) + timedelta(
        days=settings.refresh_token_expire_days
    )
