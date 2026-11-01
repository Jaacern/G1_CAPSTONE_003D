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


class TtsIn(BaseModel):
    text:  str = Field(min_length=1, max_length=3000)
    voice: str | None = Field(default=None, max_length=60)

    @field_validator("text")
    @classmethod
    def _limpiar(cls, v: str) -> str:
        limpio = v.strip()
        if not limpio:
            raise ValueError("No hay texto que leer.")
        return limpio


class TtsOut(BaseModel):
    audio_url: str
    cached:    bool


# Lista cerrada de voces. Si se aceptara cualquier texto, un nombre
# inventado llegaria a Azure y volveria un error que no dice nada, y
# ademas seria un valor del cliente metido tal cual en el SSML.
_VOCES = {
    "es-CL-CatalinaNeural", "es-CL-LorenzoNeural",
    "es-MX-DaliaNeural", "es-MX-JorgeNeural",
    "es-ES-ElviraNeural", "es-ES-AlvaroNeural",
}


@router.post("/tts", response_model=TtsOut)
async def speak(
    payload: TtsIn,
    user: CurrentUser = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Convierte un texto en audio y devuelve un enlace para reproducirlo.

    El audio se guarda y se reutiliza. La pantalla del adulto mayor lee la
    misma tarjeta varias veces y volver a sintetizarla seria pagarle a
    Azure dos veces por el mismo archivo, ademas de hacerlo esperar.

    La copia es por persona, no comun. Asi un texto que incluya algo del
    expediente de un paciente queda como archivo de quien lo pidio y no
    como contenido de catalogo que cualquiera podria leer.
    """
    import hashlib

    from app.speech_provider import (SpeechNotConfigured, get_speech,
                                     get_speech_settings)

    proveedor = get_speech()
    if not proveedor.disponible:
        raise _NO_DISPONIBLE

    voz = payload.voice or get_speech_settings().speech_default_voice
    if voz not in _VOCES:
        raise ApiError(
            status_code=422, code="VALIDATION_ERROR",
            message="Esa voz no esta disponible.",
            details=[{"field": "voice",
                      "message": f"Voces disponibles: {', '.join(sorted(_VOCES))}."}],
        )

    firma = hashlib.sha256(
        f"{user.user_id}|{voz}|{payload.text}".encode("utf-8")
    ).hexdigest()
    storage_key = f"user/tts/{firma}.mp3"

    storage = get_storage()

    guardado = (
        await db.execute(
            text(
                """
                SELECT id, storage_key, mime_type, size_bytes
                FROM files
                WHERE storage_key = :key AND status = 'stored'
                """
            ),
            {"key": storage_key},
        )
    ).mappings().first()

    if guardado is not None:
        return TtsOut(
            audio_url=storage.download_url(
                file_id=str(guardado["id"]), storage_key=guardado["storage_key"],
                content_type=guardado["mime_type"], size=guardado["size_bytes"],
            ),
            cached=True,
        )

    try:
        audio = await proveedor.sintetizar(texto=payload.text, voz=voz)
    except SpeechNotConfigured:
        raise _NO_DISPONIBLE
    except Exception:
        raise ApiError(
            status_code=503, code="SPEECH_ERROR",
            message="No se pudo generar el audio. Intenta de nuevo.",
        )

    await storage.save(storage_key=storage_key, data=audio)

    # Se guarda el binario antes de la fila, igual que en la subida: si
    # falla el guardado no queda una fila que dice stored apuntando a un
    # archivo que no existe.
    file_id = str(uuid4())
    nombre = (payload.text[:40] + "...") if len(payload.text) > 40 else payload.text
    await db.execute(
        text(
            """
            INSERT INTO files (
                id, patient_id, uploaded_by, storage_key, original_name,
                mime_type, size_bytes, status, upload_expires_at, stored_at,
                scope
            ) VALUES (
                :id, NULL, :uid, :key, :nombre,
                'audio/mpeg', :tam, 'stored', now(), now(),
                'user'
            )
            ON CONFLICT (storage_key) DO NOTHING
            """
        ),
        {"id": file_id, "uid": user.user_id, "key": storage_key,
         "nombre": nombre, "tam": len(audio)},
    )
    await db.commit()

    # Dos peticiones iguales a la vez pueden chocar en el UNIQUE. La que
    # perdio se queda con la fila que gano, que apunta al mismo audio.
    fila = (
        await db.execute(
            text("SELECT id, mime_type, size_bytes FROM files "
                 "WHERE storage_key = :key"),
            {"key": storage_key},
        )
    ).mappings().first()

    return TtsOut(
        audio_url=storage.download_url(
            file_id=str(fila["id"]), storage_key=storage_key,
            content_type=fila["mime_type"], size=fila["size_bytes"],
        ),
        cached=False,
    )
