"""Dependencias de autenticación y autorización (spec 2.2 y 16.2).

- get_current_user: valida el JWT Bearer y devuelve el usuario autenticado.
- get_patient_member(roles): factory que exige que el usuario tenga una
  membresía viva en el paciente (patient_members) con uno de los roles dados.
  Es el control de acceso por recurso que pide la sección 16.2.
"""
from collections.abc import Awaitable, Callable
from uuid import UUID

from fastapi import Depends, Path
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from jose import JWTError, jwt
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import get_settings
from app.db import get_db
from app.errors import ApiError

settings = get_settings()
bearer_scheme = HTTPBearer(auto_error=False)


class CurrentUser:
    def __init__(self, user_id: str, email: str, full_name: str, locale: str):
        self.user_id = user_id
        self.email = email
        self.full_name = full_name
        self.locale = locale


class PatientContext:
    """Usuario autenticado + su rol sobre el paciente en cuestión."""

    def __init__(self, user: CurrentUser, patient_id: str, role: str, is_owner: bool):
        self.user = user
        self.patient_id = patient_id
        self.role = role
        self.is_owner = is_owner


async def get_current_user(
    creds: HTTPAuthorizationCredentials | None = Depends(bearer_scheme),
    db: AsyncSession = Depends(get_db),
) -> CurrentUser:
    unauthorized = ApiError(
        status_code=401,
        code="UNAUTHORIZED",
        message="Tu sesión expiró. Vuelve a iniciar sesión.",
    )
    if creds is None or not creds.credentials:
        raise unauthorized

    try:
        payload = jwt.decode(
            creds.credentials,
            settings.jwt_secret,
            algorithms=[settings.jwt_algorithm],
        )
    except JWTError:
        raise unauthorized

    if payload.get("type") != "access":
        raise unauthorized

    user_id = payload.get("sub")
    if not user_id:
        raise unauthorized

    row = (
        await db.execute(
            text(
                """
                SELECT id, email, full_name, locale
                FROM users
                WHERE id = :uid AND is_active = true AND deleted_at IS NULL
                """
            ),
            {"uid": user_id},
        )
    ).mappings().first()

    if row is None:
        raise unauthorized

    return CurrentUser(
        user_id=str(row["id"]),
        email=row["email"],
        full_name=row["full_name"],
        locale=row["locale"],
    )


def get_patient_member(
    roles: list[str] | None = None,
    require_owner: bool = False,
) -> Callable[..., Awaitable[PatientContext]]:
    """Factory de dependencia: exige membresía viva en el paciente.

    roles: lista de roles permitidos (family|caregiver|doctor|elder).
           None = cualquier rol con membresía.
    require_owner: además exige que sea el familiar administrador (is_owner).
    """

    async def _dependency(
        patient_id: UUID = Path(...),
        user: CurrentUser = Depends(get_current_user),
        db: AsyncSession = Depends(get_db),
    ) -> PatientContext:
        membership = (
            await db.execute(
                text(
                    """
                    SELECT pm.role, pm.is_owner
                    FROM patient_members pm
                    JOIN patients p ON p.id = pm.patient_id
                    WHERE pm.patient_id = :pid
                      AND pm.user_id = :uid
                      AND pm.removed_at IS NULL
                      AND p.deleted_at IS NULL
                    """
                ),
                {"pid": str(patient_id), "uid": user.user_id},
            )
        ).mappings().first()

        # 404 si no existe o no tiene acceso: no revelamos existencia (spec 2.5).
        if membership is None:
            raise ApiError(
                status_code=404,
                code="NOT_FOUND",
                message="El recurso solicitado no existe o no está disponible.",
            )

        if roles is not None and membership["role"] not in roles:
            raise ApiError(
                status_code=403,
                code="FORBIDDEN",
                message="No tienes permisos para realizar esta acción sobre este paciente.",
            )

        if require_owner and not membership["is_owner"]:
            raise ApiError(
                status_code=403,
                code="FORBIDDEN",
                message="No tienes permisos para realizar esta acción sobre este paciente.",
            )

        return PatientContext(
            user=user,
            patient_id=str(patient_id),
            role=membership["role"],
            is_owner=membership["is_owner"],
        )

    return _dependency
