"""Módulo 4: Pacientes, roles y onboarding (endpoints 4.1–4.10).

Cambios 2FN aplicados al esquema:
- patients.full_name es ahora GENERATED (first_name || last_name): lectura directa OK,
  escritura usa first_name + last_name por separado.
- patients.conditions eliminado → tabla patient_conditions.
- sex API (female|male|other) ↔ BD (F|M|O): mapeo conservado.
- scheduled_doses ya no tiene patient_id: las consultas por paciente hacen JOIN.
"""
import json
from datetime import date, datetime, timedelta, timezone

from fastapi import APIRouter, Depends, Response, status
from pydantic import BaseModel, EmailStr, Field
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

from app.db import get_db
from app.deps import CurrentUser, PatientContext, get_current_user, get_patient_member
from app.errors import ApiError
from app.security import generate_refresh_token, hash_token

router = APIRouter(prefix="/api/v1", tags=["patients"])

INVITATION_TTL_DAYS = 7
WEARABLE_STALE_AFTER = timedelta(hours=2)

_SEX_API_TO_DB = {"female": "F", "male": "M", "other": "O"}
_SEX_DB_TO_API = {v: k for k, v in _SEX_API_TO_DB.items()}


# --------------------------------------------------------------------------
# Schemas
# --------------------------------------------------------------------------
class PatientCreateIn(BaseModel):
    first_name: str = Field(min_length=1, max_length=60)
    last_name:  str = Field(min_length=1, max_length=60)
    birth_date: date
    sex: str                        # female | male | other
    photo_url: str | None = None
    conditions: list[str] | None = None


class PatientCreateOut(BaseModel):
    patient_id: str
    full_name:  str
    created_at: datetime


class PatientPatchIn(BaseModel):
    first_name: str | None = Field(default=None, min_length=1, max_length=60)
    last_name:  str | None = Field(default=None, min_length=1, max_length=60)
    birth_date: date | None = None
    sex:        str | None = None
    photo_url:  str | None = None
    conditions: list[str] | None = None


class PatientListItem(BaseModel):
    patient_id:       str
    full_name:        str
    photo_url:        str | None = None
    role:             str
    wellbeing_status: str


class PatientListOut(BaseModel):
    items: list[PatientListItem]


class WearableSummary(BaseModel):
    wearable_id:  str
    model:        str | None = None
    last_sync_at: datetime | None = None
    battery_pct:  int | None = None


class PatientDetailOut(BaseModel):
    patient_id: str
    full_name:  str
    first_name: str
    last_name:  str
    birth_date: date
    sex:        str
    photo_url:  str | None = None
    conditions: list[str]
    wearable:   WearableSummary | None = None


class InvitationCreateIn(BaseModel):
    role:  str
    email: EmailStr | None = None


class InvitationCreateOut(BaseModel):
    invitation_id: str
    token:         str
    invite_url:    str
    expires_at:    datetime


class InvitationAcceptIn(BaseModel):
    token: str


class InvitationAcceptOut(BaseModel):
    patient_id: str
    role:       str


class MemberOut(BaseModel):
    user_id:   str
    full_name: str
    email:     str
    role:      str
    joined_at: datetime


class PendingInvitationOut(BaseModel):
    invitation_id: str
    email:         str
    role:          str
    expires_at:    datetime


class MembersListOut(BaseModel):
    members:             list[MemberOut]
    pending_invitations: list[PendingInvitationOut]


class WearableLinkIn(BaseModel):
    serial_number: str
    model:         str


class WearableLinkOut(BaseModel):
    wearable_id: str
    linked_at:   datetime


class WearableStatusOut(BaseModel):
    wearable_id:  str | None = None
    last_sync_at: datetime | None = None
    battery_pct:  int | None = None
    is_stale:     bool


_VALID_INVITE_ROLES = ("family", "caregiver", "doctor", "elder")


# --------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------
async def _load_conditions(db: AsyncSession, patient_id: str) -> list[str]:
    rows = (
        await db.execute(
            text("SELECT condition FROM patient_conditions WHERE patient_id = :pid ORDER BY condition"),
            {"pid": patient_id},
        )
    ).scalars().all()
    return list(rows)


async def _replace_conditions(db: AsyncSession, patient_id: str, conditions: list[str]) -> None:
    """Reemplaza todas las condiciones de un paciente (DELETE + INSERT)."""
    await db.execute(
        text("DELETE FROM patient_conditions WHERE patient_id = :pid"),
        {"pid": patient_id},
    )
    for cond in conditions:
        await db.execute(
            text(
                "INSERT INTO patient_conditions (patient_id, condition) VALUES (:pid, :cond) "
                "ON CONFLICT (patient_id, condition) DO NOTHING"
            ),
            {"pid": patient_id, "cond": cond.strip()},
        )


async def _load_patient_detail(db: AsyncSession, patient_id: str) -> PatientDetailOut:
    patient = (
        await db.execute(
            text(
                """
                SELECT id, first_name, last_name, full_name,
                       birth_date, sex, photo_url
                FROM patients
                WHERE id = :pid AND deleted_at IS NULL
                """
            ),
            {"pid": patient_id},
        )
    ).mappings().first()

    if patient is None:
        raise ApiError(status_code=404, code="NOT_FOUND",
                       message="El recurso solicitado no existe o no está disponible.")

    wearable_row = (
        await db.execute(
            text(
                "SELECT id, model, last_sync_at, battery_pct "
                "FROM wearables WHERE patient_id = :pid AND unlinked_at IS NULL"
            ),
            {"pid": patient_id},
        )
    ).mappings().first()

    wearable = None
    if wearable_row:
        wearable = WearableSummary(
            wearable_id=str(wearable_row["id"]),
            model=wearable_row["model"],
            last_sync_at=wearable_row["last_sync_at"],
            battery_pct=wearable_row["battery_pct"],
        )

    conditions = await _load_conditions(db, patient_id)

    return PatientDetailOut(
        patient_id=str(patient["id"]),
        first_name=patient["first_name"],
        last_name=patient["last_name"],
        full_name=patient["full_name"],
        birth_date=patient["birth_date"],
        sex=_SEX_DB_TO_API.get(patient["sex"], patient["sex"]),
        photo_url=patient["photo_url"],
        conditions=conditions,
        wearable=wearable,
    )


# --------------------------------------------------------------------------
# 4.1 Crear paciente
# --------------------------------------------------------------------------
@router.post("/patients", response_model=PatientCreateOut, status_code=201)
async def create_patient(
    payload: PatientCreateIn,
    user: CurrentUser = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    sex_db = _SEX_API_TO_DB.get(payload.sex)
    if sex_db is None:
        raise ApiError(status_code=422, code="VALIDATION_ERROR",
                       message="Hay datos inválidos en la solicitud. Revisa los campos marcados.")

    patient = (
        await db.execute(
            text(
                """
                INSERT INTO patients (first_name, last_name, birth_date, sex, photo_url)
                VALUES (:fn, :ln, :bd, :sex, :photo)
                RETURNING id, full_name, created_at
                """
            ),
            {
                "fn":    payload.first_name,
                "ln":    payload.last_name,
                "bd":    payload.birth_date,
                "sex":   sex_db,
                "photo": payload.photo_url,
            },
        )
    ).mappings().first()

    pid = str(patient["id"])

    # Condiciones en tabla normalizada
    if payload.conditions:
        await _replace_conditions(db, pid, payload.conditions)

    # Creador = familiar administrador
    await db.execute(
        text(
            "INSERT INTO patient_members (patient_id, user_id, role, is_owner) "
            "VALUES (:pid, :uid, 'family', true)"
        ),
        {"pid": pid, "uid": user.user_id},
    )
    await db.commit()

    return PatientCreateOut(
        patient_id=pid,
        full_name=patient["full_name"],
        created_at=patient["created_at"],
    )


# --------------------------------------------------------------------------
# 4.2 Listar mis pacientes
# --------------------------------------------------------------------------
@router.get("/patients", response_model=PatientListOut)
async def list_patients(
    user: CurrentUser = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    rows = (
        await db.execute(
            text(
                """
                SELECT p.id, p.full_name, p.photo_url, pm.role
                FROM patient_members pm
                JOIN patients p ON p.id = pm.patient_id
                WHERE pm.user_id = :uid
                  AND pm.removed_at IS NULL
                  AND p.deleted_at IS NULL
                ORDER BY p.full_name
                """
            ),
            {"uid": user.user_id},
        )
    ).mappings().all()

    return PatientListOut(items=[
        PatientListItem(
            patient_id=str(r["id"]),
            full_name=r["full_name"],
            photo_url=r["photo_url"],
            role=r["role"],
            wellbeing_status="ok",
        )
        for r in rows
    ])


# --------------------------------------------------------------------------
# 4.3 Detalle del paciente
# --------------------------------------------------------------------------
@router.get("/patients/{patient_id}", response_model=PatientDetailOut)
async def get_patient(
    ctx: PatientContext = Depends(get_patient_member()),
    db: AsyncSession = Depends(get_db),
):
    return await _load_patient_detail(db, ctx.patient_id)


# --------------------------------------------------------------------------
# 4.4 Actualizar paciente
# --------------------------------------------------------------------------
@router.patch("/patients/{patient_id}", response_model=PatientDetailOut)
async def update_patient(
    payload: PatientPatchIn,
    ctx: PatientContext = Depends(get_patient_member(roles=["family"], require_owner=True)),
    db: AsyncSession = Depends(get_db),
):
    fields = payload.model_dump(exclude_unset=True)
    conditions = fields.pop("conditions", None)

    sets: list[str] = []
    params: dict = {"pid": ctx.patient_id}

    if "first_name" in fields:
        sets.append("first_name = :first_name"); params["first_name"] = fields["first_name"]
    if "last_name" in fields:
        sets.append("last_name = :last_name");   params["last_name"]  = fields["last_name"]
    if "birth_date" in fields:
        sets.append("birth_date = :birth_date"); params["birth_date"] = fields["birth_date"]
    if "sex" in fields:
        sex_db = _SEX_API_TO_DB.get(fields["sex"])
        if sex_db is None:
            raise ApiError(status_code=422, code="VALIDATION_ERROR",
                           message="Hay datos inválidos en la solicitud. Revisa los campos marcados.")
        sets.append("sex = :sex"); params["sex"] = sex_db
    if "photo_url" in fields:
        sets.append("photo_url = :photo_url"); params["photo_url"] = fields["photo_url"]

    if sets:
        await db.execute(
            text(f"UPDATE patients SET {', '.join(sets)} WHERE id = :pid AND deleted_at IS NULL"),
            params,
        )

    if conditions is not None:
        await _replace_conditions(db, ctx.patient_id, conditions)

    await db.commit()
    return await _load_patient_detail(db, ctx.patient_id)


# --------------------------------------------------------------------------
# 4.5 Invitar miembro
# --------------------------------------------------------------------------
@router.post("/patients/{patient_id}/invitations",
             response_model=InvitationCreateOut, status_code=201)
async def create_invitation(
    payload: InvitationCreateIn,
    ctx: PatientContext = Depends(get_patient_member(roles=["family"], require_owner=True)),
    db: AsyncSession = Depends(get_db),
):
    if payload.role not in _VALID_INVITE_ROLES:
        raise ApiError(status_code=422, code="VALIDATION_ERROR",
                       message="Hay datos inválidos en la solicitud. Revisa los campos marcados.")

    if payload.email is not None:
        already = (
            await db.execute(
                text(
                    "SELECT 1 FROM patient_members pm JOIN users u ON u.id = pm.user_id "
                    "WHERE pm.patient_id = :pid AND pm.removed_at IS NULL "
                    "AND lower(u.email) = lower(:email)"
                ),
                {"pid": ctx.patient_id, "email": payload.email},
            )
        ).first()
        if already:
            raise ApiError(status_code=409, code="MEMBER_ALREADY_EXISTS",
                           message="Esta persona ya forma parte del círculo de cuidado del paciente.")

    if payload.role == "elder":
        elder_exists = (
            await db.execute(
                text("SELECT 1 FROM patient_members WHERE patient_id = :pid "
                     "AND role = 'elder' AND removed_at IS NULL"),
                {"pid": ctx.patient_id},
            )
        ).first()
        if elder_exists:
            raise ApiError(status_code=409, code="ELDER_ALREADY_LINKED",
                           message="El paciente ya tiene una cuenta de adulto mayor vinculada.")

    token = generate_refresh_token()
    expires_at = datetime.now(timezone.utc) + timedelta(days=INVITATION_TTL_DAYS)

    invitation = (
        await db.execute(
            text(
                "INSERT INTO invitations (patient_id, email, role, token_hash, invited_by, expires_at) "
                "VALUES (:pid, :email, :role, :th, :inviter, :exp) RETURNING id, expires_at"
            ),
            {
                "pid": ctx.patient_id, "email": payload.email or "",
                "role": payload.role, "th": hash_token(token),
                "inviter": ctx.user.user_id, "exp": expires_at,
            },
        )
    ).mappings().first()
    await db.commit()

    return InvitationCreateOut(
        invitation_id=str(invitation["id"]),
        token=token,
        invite_url=f"https://app.agecare.app/invite/{token}",
        expires_at=invitation["expires_at"],
    )


# --------------------------------------------------------------------------
# 4.6 Aceptar invitación
# --------------------------------------------------------------------------
@router.post("/invitations/accept", response_model=InvitationAcceptOut)
async def accept_invitation(
    payload: InvitationAcceptIn,
    user: CurrentUser = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    invalid = ApiError(status_code=400, code="INVALID_INVITATION",
                       message="La invitación no existe, ya fue usada o está vencida.")

    invitation = (
        await db.execute(
            text(
                "SELECT id, patient_id, role FROM invitations "
                "WHERE token_hash = :th AND accepted_at IS NULL "
                "AND revoked_at IS NULL AND expires_at > now()"
            ),
            {"th": hash_token(payload.token)},
        )
    ).mappings().first()

    if invitation is None:
        raise invalid

    await db.execute(
        text(
            "INSERT INTO patient_members (patient_id, user_id, role, is_owner) "
            "VALUES (:pid, :uid, :role, false) ON CONFLICT (patient_id, user_id) DO NOTHING"
        ),
        {"pid": str(invitation["patient_id"]), "uid": user.user_id, "role": invitation["role"]},
    )
    await db.execute(
        text("UPDATE invitations SET accepted_at = now(), accepted_by = :uid WHERE id = :iid"),
        {"uid": user.user_id, "iid": invitation["id"]},
    )
    await db.commit()

    return InvitationAcceptOut(patient_id=str(invitation["patient_id"]), role=invitation["role"])


# --------------------------------------------------------------------------
# 4.7 Listar miembros e invitaciones pendientes
# --------------------------------------------------------------------------
@router.get("/patients/{patient_id}/members", response_model=MembersListOut)
async def list_members(
    ctx: PatientContext = Depends(get_patient_member(roles=["family", "doctor"])),
    db: AsyncSession = Depends(get_db),
):
    member_rows = (
        await db.execute(
            text(
                "SELECT u.id AS user_id, u.full_name, u.email, pm.role, pm.created_at AS joined_at "
                "FROM patient_members pm JOIN users u ON u.id = pm.user_id "
                "WHERE pm.patient_id = :pid AND pm.removed_at IS NULL ORDER BY pm.created_at"
            ),
            {"pid": ctx.patient_id},
        )
    ).mappings().all()

    pending_rows = (
        await db.execute(
            text(
                "SELECT id AS invitation_id, email, role, expires_at FROM invitations "
                "WHERE patient_id = :pid AND accepted_at IS NULL "
                "AND revoked_at IS NULL AND expires_at > now() ORDER BY created_at"
            ),
            {"pid": ctx.patient_id},
        )
    ).mappings().all()

    return MembersListOut(
        members=[MemberOut(user_id=str(r["user_id"]), full_name=r["full_name"],
                           email=r["email"], role=r["role"], joined_at=r["joined_at"])
                 for r in member_rows],
        pending_invitations=[PendingInvitationOut(invitation_id=str(r["invitation_id"]),
                                                  email=r["email"], role=r["role"],
                                                  expires_at=r["expires_at"])
                             for r in pending_rows],
    )


# --------------------------------------------------------------------------
# 4.8 Quitar miembro
# --------------------------------------------------------------------------
@router.delete("/patients/{patient_id}/members/{user_id}", status_code=204)
async def remove_member(
    user_id: str,
    ctx: PatientContext = Depends(get_patient_member(roles=["family"], require_owner=True)),
    db: AsyncSession = Depends(get_db),
):
    target = (
        await db.execute(
            text("SELECT is_owner FROM patient_members "
                 "WHERE patient_id = :pid AND user_id = :uid AND removed_at IS NULL"),
            {"pid": ctx.patient_id, "uid": user_id},
        )
    ).mappings().first()

    if target is None:
        raise ApiError(status_code=404, code="NOT_FOUND",
                       message="El recurso solicitado no existe o no está disponible.")
    if target["is_owner"]:
        raise ApiError(status_code=400, code="CANNOT_REMOVE_OWNER",
                       message="No puedes quitar al administrador del paciente.")

    await db.execute(
        text("UPDATE patient_members SET removed_at = now() "
             "WHERE patient_id = :pid AND user_id = :uid AND removed_at IS NULL"),
        {"pid": ctx.patient_id, "uid": user_id},
    )
    await db.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)


# --------------------------------------------------------------------------
# 4.9 Vincular wearable
# --------------------------------------------------------------------------
@router.post("/patients/{patient_id}/wearable",
             response_model=WearableLinkOut, status_code=201)
async def link_wearable(
    payload: WearableLinkIn,
    ctx: PatientContext = Depends(get_patient_member(roles=["family", "caregiver"])),
    db: AsyncSession = Depends(get_db),
):
    in_use = (
        await db.execute(
            text("SELECT 1 FROM wearables WHERE provider = 'simulator' "
                 "AND serial_number = :serial AND unlinked_at IS NULL AND patient_id <> :pid"),
            {"serial": payload.serial_number, "pid": ctx.patient_id},
        )
    ).first()
    if in_use:
        raise ApiError(status_code=409, code="WEARABLE_IN_USE",
                       message="Este dispositivo ya está vinculado a otro paciente.")

    await db.execute(
        text("UPDATE wearables SET unlinked_at = now() "
             "WHERE patient_id = :pid AND unlinked_at IS NULL"),
        {"pid": ctx.patient_id},
    )
    wearable = (
        await db.execute(
            text(
                "INSERT INTO wearables (patient_id, provider, serial_number, model) "
                "VALUES (:pid, 'simulator', :serial, :model) RETURNING id, created_at"
            ),
            {"pid": ctx.patient_id, "serial": payload.serial_number, "model": payload.model},
        )
    ).mappings().first()
    await db.commit()

    return WearableLinkOut(wearable_id=str(wearable["id"]), linked_at=wearable["created_at"])


# --------------------------------------------------------------------------
# 4.10 Estado del wearable
# --------------------------------------------------------------------------
@router.get("/patients/{patient_id}/wearable/status", response_model=WearableStatusOut)
async def wearable_status(
    ctx: PatientContext = Depends(get_patient_member()),
    db: AsyncSession = Depends(get_db),
):
    wearable = (
        await db.execute(
            text("SELECT id, last_sync_at, battery_pct FROM wearables "
                 "WHERE patient_id = :pid AND unlinked_at IS NULL"),
            {"pid": ctx.patient_id},
        )
    ).mappings().first()

    if wearable is None:
        return WearableStatusOut(wearable_id=None, last_sync_at=None,
                                 battery_pct=None, is_stale=True)

    last_sync_at = wearable["last_sync_at"]
    is_stale = (last_sync_at is None or
                last_sync_at < datetime.now(last_sync_at.tzinfo) - WEARABLE_STALE_AFTER)

    return WearableStatusOut(wearable_id=str(wearable["id"]), last_sync_at=last_sync_at,
                             battery_pct=wearable["battery_pct"], is_stale=is_stale)
