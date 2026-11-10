"""Dependencias de autenticación y autorización (spec 2.2 y 16.2).

- get_current_user: valida el JWT Bearer y devuelve el usuario autenticado.
- get_patient_member(roles): factory que exige que el usuario tenga una
  membresía viva en el paciente (patient_members) con uno de los roles dados.
  Es el control de acceso por recurso que pide la sección 16.2.
- get_staff_user: exige que el usuario sea personal de Alloxentric. Es un
  permiso sobre el catálogo comercial, no sobre expedientes.
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


async def is_verified_doctor(db: AsyncSession, user_id: str) -> bool:
    """True si la cuenta es de tipo médico y su habilitación sigue vigente.

    La habilitación (doctor_profiles) la crea el personal de la empresa tras
    verificar el registro profesional. Sin ella, la membresía con rol
    'doctor' no vale nada: nadie se vuelve médico por declararlo ni por
    aceptar una invitación.
    """
    return bool(
        (
            await db.execute(
                text(
                    """
                    SELECT 1
                    FROM users u
                    JOIN doctor_profiles d ON d.user_id = u.id
                    WHERE u.id = :uid
                      AND u.account_type = 'doctor'
                      AND u.is_active = true
                      AND u.deleted_at IS NULL
                      AND d.revoked_at IS NULL
                    """
                ),
                {"uid": user_id},
            )
        ).first()
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

        # Un médico solo opera si su habilitación está vigente. Va antes del
        # chequeo de roles a propósito: aplica a TODO endpoint, incluso a los
        # de solo lectura, porque la ficha clínica es información sensible.
        if membership["role"] == "doctor" and not await is_verified_doctor(
            db, user.user_id
        ):
            raise ApiError(
                status_code=403,
                code="DOCTOR_NOT_VERIFIED",
                message=(
                    "Tu cuenta de médico aún no está habilitada. "
                    "Contacta al equipo de AgeCare para verificar tu registro profesional."
                ),
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


class StaffUser(CurrentUser):
    """Usuario autenticado que además es personal de Alloxentric."""


async def get_staff_user(
    user: CurrentUser = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> StaffUser:
    """Exige que quien llama sea personal de la empresa.

    Es un permiso de otra naturaleza que get_patient_member. Ese pregunta
    por una relación con UN paciente; este pregunta por una condición de la
    persona, porque administrar los planes no es algo que se haga sobre un
    paciente sino sobre el catálogo que se le vende a todos.

    Responde 403 y no 404. Es a propósito, y la diferencia con el resto de
    la API vale explicarla: en los expedientes se responde 404 para no
    confirmarle a un extraño que cierto paciente existe. Acá no hay nada
    que ocultar, la existencia de una administración de planes no es un
    secreto, y un 404 solo confundiría a quien de verdad es del equipo y
    entró con la cuenta equivocada.
    """
    es_staff = (
        await db.execute(
            text(
                """
                SELECT is_staff FROM users
                WHERE id = :uid AND is_active = true AND deleted_at IS NULL
                """
            ),
            {"uid": user.user_id},
        )
    ).scalar()

    if not es_staff:
        raise ApiError(
            status_code=403,
            code="STAFF_ONLY",
            message="Esta sección es solo para el personal de Alloxentric.",
        )

    return StaffUser(
        user_id=user.user_id,
        email=user.email,
        full_name=user.full_name,
        locale=user.locale,
    )
