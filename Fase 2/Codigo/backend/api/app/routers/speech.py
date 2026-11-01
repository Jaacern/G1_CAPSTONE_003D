"""Voz: transcribir una nota y leer un texto en voz alta.

Endpoints que la aplicacion ya consume:

    POST /stt  { audio_url }    -> { text }
    POST /tts  { text, voice }  -> { audio_url }

Ninguno lleva paciente en la ruta, pero el audio que se transcribe si
pertenece a uno, asi que el permiso se resuelve desde el archivo.
"""
import re
from uuid import UUID, uuid4

from fastapi import APIRouter, Depends
from pydantic import BaseModel, Field, field_validator
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

from app.db import get_db
from app.deps import CurrentUser, get_current_user
from app.errors import ApiError
from app.storage import get_storage

router = APIRouter(prefix="/api/v1", tags=["speech"])

_UUID = re.compile(
    r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-"
    r"[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
)

_NO_DISPONIBLE = ApiError(
    status_code=503, code="SPEECH_UNAVAILABLE",
    message="El servicio de voz no esta disponible en este momento.",
)


class SttIn(BaseModel):
    audio_url: str = Field(min_length=1)


class SttOut(BaseModel):
    text: str


@router.post("/stt", response_model=SttOut)
async def transcribe(
    payload: SttIn,
    user: CurrentUser = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Transcribe una nota de voz ya subida.

    Recibe la URL del archivo, no el audio: la nota ya se subio por el
    camino normal, asi que mandarla de nuevo seria subir dos veces lo
    mismo.

    El permiso sale del archivo. Un audio del expediente de un paciente
    solo lo transcribe quien es de ese circulo, igual que para oirlo: si
    no, bastaria con tener el id de un archivo ajeno para leer lo que
    alguien dijo sobre otra persona.
    """
    from app.speech_provider import SpeechNotConfigured, get_speech

    proveedor = get_speech()
    if not proveedor.disponible:
        raise _NO_DISPONIBLE

    encontrado = _UUID.search(payload.audio_url)
    if encontrado is None:
        raise ApiError(
            status_code=422, code="VALIDATION_ERROR",
            message="La referencia del audio no es valida.",
            details=[{"field": "audio_url",
                      "message": f"Valor recibido: {payload.audio_url}."}],
        )
    file_id = encontrado.group(0)

    archivo = (
        await db.execute(
            text(
                """
                SELECT f.storage_key, f.mime_type, f.patient_id, f.scope,
                       f.uploaded_by
                FROM files f
                WHERE f.id = :fid AND f.status = 'stored'
                """
            ),
            {"fid": file_id},
        )
    ).mappings().first()

    no_existe = ApiError(
        status_code=404, code="NOT_FOUND",
        message="El recurso solicitado no existe o no esta disponible.",
    )
    if archivo is None:
        raise no_existe

    if archivo["scope"] == "patient":
        miembro = (
            await db.execute(
                text(
                    """
                    SELECT 1 FROM patient_members
                    WHERE patient_id = :pid AND user_id = :uid
                      AND removed_at IS NULL
                    """
                ),
                {"pid": str(archivo["patient_id"]), "uid": user.user_id},
            )
        ).first()
        if miembro is None:
            raise no_existe
    elif str(archivo["uploaded_by"]) != user.user_id:
        raise no_existe

    if not archivo["mime_type"].startswith("audio/"):
        raise ApiError(
            status_code=422, code="VALIDATION_ERROR",
            message="Ese archivo no es un audio.",
            details=[{"field": "audio_url",
                      "message": f"Tipo del archivo: {archivo['mime_type']}."}],
        )

    storage = get_storage()
    try:
        audio = await storage.load(storage_key=archivo["storage_key"])
    except FileNotFoundError:
        raise no_existe

    try:
        texto = await proveedor.transcribir(
            audio=audio, mime_type=archivo["mime_type"])
    except SpeechNotConfigured:
        raise _NO_DISPONIBLE
    except Exception:
        raise ApiError(
            status_code=503, code="SPEECH_ERROR",
            message="No se pudo transcribir el audio. Intenta de nuevo.",
        )

    return SttOut(text=texto)
