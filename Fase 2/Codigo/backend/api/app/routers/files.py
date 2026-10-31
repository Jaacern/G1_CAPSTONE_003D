"""Modulo de archivos: subida en dos pasos y acceso a binarios.

Requisitos que cubre:
    RF-39  subir archivos por enlace temporal, validando tipo y tamano
    RF-42  descargar o visualizar por enlace temporal corto
    RNF-13 los enlaces expiran en 15 minutos o menos

Contrato definido por el front (core/network/upload_service.dart):

    POST /uploads  { filename, content_type, kind, size }
      ->           { upload_id, upload_url, file_url }
    PUT  <upload_url>  con los bytes

La validacion de tipo y tamano ocurre ANTES de entregar la URL. Es la unica
forma de que sirva: si se validara al recibir el binario, el usuario ya habria
gastado su conexion subiendo 20 MB que se van a rechazar.
"""
from datetime import datetime, timedelta, timezone
from uuid import UUID, uuid4

from fastapi import APIRouter, Depends
from pydantic import BaseModel, Field
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

from app.db import get_db
from app.deps import CurrentUser, get_current_user
from app.errors import ApiError
from app.storage import (
    ALLOWED_CONTENT_TYPES,
    MAX_SIZE_BYTES,
    UPLOAD_TTL_MINUTES,
    build_storage_key,
    get_storage,
)

router = APIRouter(prefix="/api/v1", tags=["files"])

# El front manda kind; la base guarda scope. No son lo mismo: kind describe
# para que se usara el archivo, scope de quien es. Cuatro de los kind que
# manda la app son del expediente de un paciente.
_KIND_TO_SCOPE = {
    "photo":        "patient",
    "document":     "patient",
    "audio":        "patient",
    "prescription": "patient",
    "catalog":      "catalog",
    "certification": "caregiver",
}


class UploadRequestIn(BaseModel):
    filename:     str = Field(min_length=1, max_length=255)
    content_type: str = Field(min_length=3, max_length=100)
    kind:         str
    size:         int = Field(gt=0)
    # No viene en el contrato original del front porque cuando se escribio
    # files.patient_id todavia era obligatorio para todo. Es obligatorio para
    # los kind de expediente y se ignora en los demas.
    patient_id:   UUID | None = None


class UploadRequestOut(BaseModel):
    upload_id:  str
    upload_url: str
    file_url:   str
    expires_at: datetime


@router.post("/uploads", response_model=UploadRequestOut, status_code=201)
async def create_upload(
    payload: UploadRequestIn,
    user: CurrentUser = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Reserva un archivo y entrega la URL temporal para subirlo (RF-39)."""
    scope = _KIND_TO_SCOPE.get(payload.kind)
    if scope is None:
        raise ApiError(
            status_code=422,
            code="VALIDATION_ERROR",
            message="El tipo de archivo solicitado no es valido.",
            details=[{"field": "kind",
                      "message": f"Valores aceptados: {', '.join(sorted(_KIND_TO_SCOPE))}."}],
        )

    if payload.content_type not in ALLOWED_CONTENT_TYPES:
        raise ApiError(
            status_code=422,
            code="UNSUPPORTED_MEDIA_TYPE",
            message="Ese formato de archivo no esta permitido.",
            details=[{"field": "content_type",
                      "message": f"Formatos aceptados: {', '.join(sorted(ALLOWED_CONTENT_TYPES))}."}],
        )

    if payload.size > MAX_SIZE_BYTES:
        raise ApiError(
            status_code=413,
            code="FILE_TOO_LARGE",
            message=f"El archivo supera el maximo de {MAX_SIZE_BYTES // (1024*1024)} MB.",
            details=[{"field": "size", "message": f"Tamano recibido: {payload.size} bytes."}],
        )

    patient_id: str | None = None
    if scope == "patient":
        if payload.patient_id is None:
            raise ApiError(
                status_code=422,
                code="VALIDATION_ERROR",
                message="Falta indicar a que paciente pertenece el archivo.",
                details=[{"field": "patient_id",
                          "message": f"Obligatorio para kind='{payload.kind}'."}],
            )
        patient_id = str(payload.patient_id)

        # Control de acceso por recurso: hay que ser miembro vivo del paciente.
        # 404 y no 403, para no revelar que el paciente existe (spec 2.5).
        member = (
            await db.execute(
                text(
                    """
                    SELECT 1
                    FROM patient_members pm
                    JOIN patients p ON p.id = pm.patient_id
                    WHERE pm.patient_id = :pid
                      AND pm.user_id = :uid
                      AND pm.removed_at IS NULL
                      AND p.deleted_at IS NULL
                    """
                ),
                {"pid": patient_id, "uid": user.user_id},
            )
        ).first()
        if member is None:
            raise ApiError(
                status_code=404,
                code="NOT_FOUND",
                message="El recurso solicitado no existe o no esta disponible.",
            )

    file_id = str(uuid4())
    storage_key = build_storage_key(
        file_id=file_id, patient_id=patient_id,
        scope=scope, content_type=payload.content_type,
    )
    expires_at = datetime.now(timezone.utc) + timedelta(minutes=UPLOAD_TTL_MINUTES)

    # La fila nace en estado pending. Si el cliente nunca completa la subida,
    # queda ahi y la barre el proceso de limpieza: no se pierde el rastro de
    # que alguien pidio subir algo.
    await db.execute(
        text(
            """
            INSERT INTO files (
                id, patient_id, uploaded_by, storage_key, original_name,
                mime_type, size_bytes, status, upload_expires_at, scope
            ) VALUES (
                :id, :pid, :uid, :key, :name,
                :ct, :size, 'pending', :exp, :scope
            )
            """
        ),
        {
            "id": file_id, "pid": patient_id, "uid": user.user_id,
            "key": storage_key, "name": payload.filename,
            "ct": payload.content_type, "size": payload.size,
            "exp": expires_at, "scope": scope,
        },
    )
    await db.commit()

    storage = get_storage()
    return UploadRequestOut(
        upload_id=file_id,
        upload_url=storage.upload_url(
            file_id=file_id, storage_key=storage_key,
            content_type=payload.content_type, size=payload.size,
        ),
        file_url=storage.file_url(file_id=file_id, storage_key=storage_key),
        expires_at=expires_at,
    )
