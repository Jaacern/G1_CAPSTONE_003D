"""Director Musical — RF-65 a RF-67, RF-69.

Endpoints:

    GET    /patients/{id}/music               listar creaciones del paciente
    POST   /patients/{id}/music               registrar nueva creación (sube audio)
    GET    /patients/{id}/music/{cid}         detalle de una creación
    DELETE /patients/{id}/music/{cid}         eliminar (lógico)
    POST   /patients/{id}/music/{cid}/share   compartir por enlace de escucha (RF-67)
    GET    /music/shared/{token}              reproducir por enlace (sin auth, RF-67)
    DELETE /music/shares/{share_id}           revocar enlace

DECISIONES DE DISEÑO
    · client_uuid (RF-66): el dispositivo lo genera antes de subir. Si la
      conexión se corta y el adulto mayor reintenta, el INSERT choca con el
      UNIQUE y no crea un duplicado.
    · Enlace seguro (RF-67): el token en claro solo vive en la URL que se
      comparte. En la base se guarda el hash SHA-256, igual que refresh_tokens
      y password_reset_tokens. El enlace vence (por defecto 72 horas).
    · play_count y last_played_at se actualizan en cada reproducción, que es
      lo que necesita RF-69 ("saber cuántas veces se escuchó").
    · El audio se sirve por URL temporal firmada (igual que el resto de files),
      nunca directo desde la API.
"""
from __future__ import annotations

import hashlib
import os
from datetime import datetime, timedelta, timezone
from uuid import UUID

from fastapi import APIRouter, Depends, Query
from fastapi.responses import RedirectResponse
from pydantic import BaseModel, Field
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

from app.db import get_db
from app.deps import CurrentUser, PatientContext, get_current_user, get_patient_member
from app.errors import ApiError
from app.storage import get_storage

router = APIRouter(prefix="/api/v1", tags=["music"])

_NO_EXISTE = ApiError(
    status_code=404, code="NOT_FOUND",
    message="La creación no existe o no está disponible.",
)

# Duración por defecto del enlace de escucha en horas.
_LINK_EXPIRE_HOURS = 72


# ---------------------------------------------------------------------------
# Modelos de salida
# ---------------------------------------------------------------------------

class MusicCreationOut(BaseModel):
    id: UUID
    patient_id: UUID
    title: str
    duration_seconds: int
    audio_url: str
    created_by: UUID
    client_uuid: UUID | None
    play_count: int
    created_at: datetime
    shares: list[dict] = []


class ShareOut(BaseModel):
    share_id: UUID
    token: str          # solo en la respuesta de POST, nunca más
    url: str
    expires_at: datetime
    play_count: int


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _audio_url(file_id: str) -> str:
    return get_storage().file_url(file_id=file_id, storage_key="")


async def _get_creation(
    db: AsyncSession, creation_id: str, patient_id: str
) -> dict:
    fila = (
        await db.execute(
            text(
                """
                SELECT mc.id, mc.patient_id, mc.title, mc.duration_seconds,
                       mc.file_id, mc.created_by_user_id, mc.client_uuid,
                       mc.created_at
                FROM music_creations mc
                WHERE mc.id = CAST(:cid AS uuid)
                  AND mc.patient_id = CAST(:pid AS uuid)
                  AND mc.deleted_at IS NULL
                """
            ),
            {"cid": creation_id, "pid": patient_id},
        )
    ).mappings().first()
    if fila is None:
        raise _NO_EXISTE
    return dict(fila)


async def _shares_activos(db: AsyncSession, creation_id: str) -> list[dict]:
    rows = (
        await db.execute(
            text(
                """
                SELECT id, expires_at, play_count, last_played_at,
                       revoked_at, shared_by
                FROM creation_shares
                WHERE music_creation_id = CAST(:cid AS uuid)
                  AND token_hash IS NOT NULL
                  AND revoked_at IS NULL
                  AND expires_at > now()
                ORDER BY expires_at DESC
                """
            ),
            {"cid": creation_id},
        )
    ).mappings().all()
    return [dict(r) for r in rows]


# ---------------------------------------------------------------------------
# Endpoints
# ---------------------------------------------------------------------------

@router.get("/patients/{patient_id}/music")
async def list_music(
    patient_id: str,
    limit: int = Query(default=50, ge=1, le=200),
    before: datetime | None = Query(default=None),
    ctx: PatientContext = Depends(get_patient_member()),
    db: AsyncSession = Depends(get_db),
):
    """RF-65: lista las creaciones musicales del paciente."""
    filas = (
        await db.execute(
            text(
                """
                SELECT mc.id, mc.patient_id, mc.title, mc.duration_seconds,
                       mc.file_id, mc.created_by_user_id, mc.client_uuid,
                       mc.created_at,
                       COALESCE(
                           (SELECT SUM(play_count)
                            FROM creation_shares cs
                            WHERE cs.music_creation_id = mc.id
                              AND cs.token_hash IS NOT NULL),
                           0
                       ) AS play_count
                FROM music_creations mc
                WHERE mc.patient_id = CAST(:pid AS uuid)
                  AND mc.deleted_at IS NULL
                  AND (:before::timestamptz IS NULL OR mc.created_at < :before)
                ORDER BY mc.created_at DESC
                LIMIT :lim
                """
            ),
            {"pid": ctx.patient_id, "before": before, "lim": limit},
        )
    ).mappings().all()

    return {
        "items": [
            {
                "id": str(f["id"]),
                "patient_id": str(f["patient_id"]),
                "title": f["title"],
                "duration_seconds": f["duration_seconds"],
                "audio_url": _audio_url(str(f["file_id"])),
                "created_by": str(f["created_by_user_id"]),
                "client_uuid": str(f["client_uuid"]) if f["client_uuid"] else None,
                "play_count": f["play_count"],
                "created_at": f["created_at"].isoformat(),
            }
            for f in filas
        ]
    }


@router.post("/patients/{patient_id}/music", status_code=201)
async def create_music(
    patient_id: str,
    file_id: UUID = Query(..., description="ID del archivo de audio ya subido"),
    title: str = Query(..., min_length=1, max_length=150),
    duration_seconds: int = Query(..., ge=1),
    client_uuid: UUID | None = Query(
        default=None,
        description="UUID generado por el dispositivo antes de subir. "
                    "Idempotente: si ya existe devuelve la creación existente.",
    ),
    ctx: PatientContext = Depends(get_patient_member()),
    user: CurrentUser = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """RF-65 / RF-66: registra una creación musical.

    Si se pasa client_uuid y ya existe una creación con ese identificador
    para este paciente, devuelve la existente en vez de crear un duplicado.
    """
    # RF-66: idempotencia por client_uuid.
    if client_uuid is not None:
        existente = (
            await db.execute(
                text(
                    """
                    SELECT id FROM music_creations
                    WHERE patient_id = CAST(:pid AS uuid)
                      AND client_uuid = CAST(:cuid AS uuid)
                      AND deleted_at IS NULL
                    """
                ),
                {"pid": ctx.patient_id, "cuid": str(client_uuid)},
            )
        ).scalar()
        if existente is not None:
            fila = await _get_creation(db, str(existente), ctx.patient_id)
            return {
                "id": str(fila["id"]),
                "patient_id": str(fila["patient_id"]),
                "title": fila["title"],
                "duration_seconds": fila["duration_seconds"],
                "audio_url": _audio_url(str(fila["file_id"])),
                "created_by": str(fila["created_by_user_id"]),
                "client_uuid": str(fila["client_uuid"]) if fila["client_uuid"] else None,
                "play_count": 0,
                "created_at": fila["created_at"].isoformat(),
                "already_existed": True,
            }

    nueva_id = (
        await db.execute(
            text(
                """
                INSERT INTO music_creations
                    (patient_id, created_by_user_id, title, file_id,
                     duration_seconds, client_uuid)
                VALUES (
                    CAST(:pid AS uuid), CAST(:uid AS uuid), :title,
                    CAST(:fid AS uuid), :dur,
                    CAST(:cuid AS uuid)
                )
                RETURNING id, created_at
                """
            ),
            {
                "pid": ctx.patient_id,
                "uid": user.user_id,
                "title": title,
                "fid": str(file_id),
                "dur": duration_seconds,
                "cuid": str(client_uuid) if client_uuid else None,
            },
        )
    ).mappings().first()
    await db.commit()

    return {
        "id": str(nueva_id["id"]),
        "patient_id": ctx.patient_id,
        "title": title,
        "duration_seconds": duration_seconds,
        "audio_url": _audio_url(str(file_id)),
        "created_by": user.user_id,
        "client_uuid": str(client_uuid) if client_uuid else None,
        "play_count": 0,
        "created_at": nueva_id["created_at"].isoformat(),
        "already_existed": False,
    }


@router.get("/patients/{patient_id}/music/{creation_id}")
async def get_music(
    patient_id: str,
    creation_id: str,
    ctx: PatientContext = Depends(get_patient_member()),
    db: AsyncSession = Depends(get_db),
):
    """RF-65: detalle de una creación, con sus enlaces activos."""
    fila = await _get_creation(db, creation_id, ctx.patient_id)
    shares = await _shares_activos(db, creation_id)
    return {
        "id": str(fila["id"]),
        "patient_id": str(fila["patient_id"]),
        "title": fila["title"],
        "duration_seconds": fila["duration_seconds"],
        "audio_url": _audio_url(str(fila["file_id"])),
        "created_by": str(fila["created_by_user_id"]),
        "client_uuid": str(fila["client_uuid"]) if fila["client_uuid"] else None,
        "play_count": sum(s["play_count"] for s in shares),
        "created_at": fila["created_at"].isoformat(),
        "shares": [
            {
                "share_id": str(s["id"]),
                "expires_at": s["expires_at"].isoformat(),
                "play_count": s["play_count"],
                "last_played_at": s["last_played_at"].isoformat()
                if s["last_played_at"] else None,
            }
            for s in shares
        ],
    }


@router.delete("/patients/{patient_id}/music/{creation_id}", status_code=204)
async def delete_music(
    patient_id: str,
    creation_id: str,
    ctx: PatientContext = Depends(get_patient_member()),
    db: AsyncSession = Depends(get_db),
):
    """RF-65: eliminación lógica de una creación."""
    await _get_creation(db, creation_id, ctx.patient_id)
    await db.execute(
        text(
            "UPDATE music_creations SET deleted_at = now() "
            "WHERE id = CAST(:id AS uuid)"
        ),
        {"id": creation_id},
    )
    await db.commit()


@router.post("/patients/{patient_id}/music/{creation_id}/share", status_code=201)
async def share_music(
    patient_id: str,
    creation_id: str,
    expire_hours: int = Query(
        default=_LINK_EXPIRE_HOURS, ge=1, le=720,
        description="Horas de validez del enlace (máx 30 días).",
    ),
    ctx: PatientContext = Depends(get_patient_member()),
    user: CurrentUser = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """RF-67: genera un enlace seguro de escucha con vencimiento.

    El token en claro solo aparece en esta respuesta. En la base se guarda
    el hash SHA-256. Compartir de nuevo genera un nuevo enlace independiente.
    """
    await _get_creation(db, creation_id, ctx.patient_id)

    token_claro = os.urandom(32).hex()
    token_hash = hashlib.sha256(token_claro.encode()).hexdigest()
    vence = datetime.now(timezone.utc) + timedelta(hours=expire_hours)

    share_id = (
        await db.execute(
            text(
                """
                INSERT INTO creation_shares
                    (music_creation_id, token_hash, expires_at, shared_by)
                VALUES (
                    CAST(:cid AS uuid), :hash, :exp,
                    CAST(:uid AS uuid)
                )
                RETURNING id
                """
            ),
            {
                "cid": creation_id,
                "hash": token_hash,
                "exp": vence,
                "uid": user.user_id,
            },
        )
    ).scalar()
    await db.commit()

    return {
        "share_id": str(share_id),
        "token": token_claro,
        "url": f"/api/v1/music/shared/{token_claro}",
        "expires_at": vence.isoformat(),
        "play_count": 0,
    }


@router.get("/music/shared/{token}")
async def play_shared_music(
    token: str,
    db: AsyncSession = Depends(get_db),
):
    """RF-67 / RF-69: reproducir por enlace sin autenticación.

    Redirige a la URL temporal del audio y registra la reproducción.
    No requiere sesión: es el endpoint que usa la nieta con el enlace.
    """
    token_hash = hashlib.sha256(token.encode()).hexdigest()

    fila = (
        await db.execute(
            text(
                """
                SELECT cs.id, cs.music_creation_id, mc.file_id
                FROM creation_shares cs
                JOIN music_creations mc ON mc.id = cs.music_creation_id
                WHERE cs.token_hash = :hash
                  AND cs.revoked_at IS NULL
                  AND cs.expires_at > now()
                  AND mc.deleted_at IS NULL
                """
            ),
            {"hash": token_hash},
        )
    ).mappings().first()

    if fila is None:
        raise ApiError(
            status_code=404,
            code="LINK_NOT_FOUND",
            message="El enlace de escucha no existe, venció o fue revocado.",
        )

    # RF-69: contabilizar reproducción.
    await db.execute(
        text(
            """
            UPDATE creation_shares
               SET play_count      = play_count + 1,
                   last_played_at  = now()
             WHERE id = :sid
            """
        ),
        {"sid": str(fila["id"])},
    )
    await db.commit()

    audio_url = _audio_url(str(fila["file_id"]))
    return RedirectResponse(url=audio_url, status_code=302)


@router.delete("/music/shares/{share_id}", status_code=204)
async def revoke_share(
    share_id: str,
    user: CurrentUser = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """RF-67: revocar un enlace de escucha antes de que venza."""
    fila = (
        await db.execute(
            text(
                """
                SELECT cs.id, mc.patient_id
                FROM creation_shares cs
                JOIN music_creations mc ON mc.id = cs.music_creation_id
                WHERE cs.id = CAST(:sid AS uuid)
                  AND cs.token_hash IS NOT NULL
                  AND cs.revoked_at IS NULL
                """
            ),
            {"sid": share_id},
        )
    ).mappings().first()

    if fila is None:
        raise _NO_EXISTE

    # Solo miembros del círculo del paciente pueden revocar.
    miembro = (
        await db.execute(
            text(
                """
                SELECT 1 FROM patient_members
                WHERE patient_id = :pid
                  AND user_id = CAST(:uid AS uuid)
                  AND removed_at IS NULL
                """
            ),
            {"pid": str(fila["patient_id"]), "uid": user.user_id},
        )
    ).scalar()

    if miembro is None:
        raise ApiError(
            status_code=403,
            code="FORBIDDEN",
            message="No tienes permiso para revocar este enlace.",
        )

    await db.execute(
        text(
            "UPDATE creation_shares SET revoked_at = now() "
            "WHERE id = CAST(:sid AS uuid)"
        ),
        {"sid": share_id},
    )
    await db.commit()
