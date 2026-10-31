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
import hashlib
from datetime import datetime, timedelta, timezone
from urllib.parse import quote
from uuid import UUID, uuid4

from fastapi import APIRouter, Depends, Request, Response
from fastapi.security import HTTPAuthorizationCredentials
from pydantic import BaseModel, Field
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

from app.db import get_db
from app.deps import CurrentUser, bearer_scheme, get_current_user
from app.errors import ApiError
from app.storage import (
    ALLOWED_CONTENT_TYPES,
    DOWNLOAD_TTL_MINUTES,
    MAX_SIZE_BYTES,
    UPLOAD_TTL_MINUTES,
    build_storage_key,
    get_storage,
    read_token,
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


class UploadDoneOut(BaseModel):
    file_id:  UUID
    file_url: str
    size:     int
    checksum: str
    status:   str


@router.put("/uploads/{token}", response_model=UploadDoneOut)
async def complete_upload(
    token: str,
    request: Request,
    db: AsyncSession = Depends(get_db),
):
    """Recibe los bytes y deja el archivo en estado stored (RF-39).

    No pide cabecera Authorization, a proposito. El token ES la credencial,
    igual que una SAS de Azure: va firmado, dura 15 minutos, sirve para un
    solo archivo y no se puede alterar sin invalidar la firma. Asi el front
    usa el mismo codigo contra las dos implementaciones de almacenamiento,
    que es justamente lo que upload_service.dart ya hace.
    """
    claims = read_token(token, purpose="upload")
    if claims is None:
        raise ApiError(
            status_code=401,
            code="UPLOAD_TOKEN_INVALID",
            message="El enlace de subida no es valido o ya vencio.",
        )

    file_id = claims["fid"]
    row = (
        await db.execute(
            text(
                """
                SELECT storage_key, mime_type, size_bytes, status,
                       upload_expires_at
                FROM files
                WHERE id = :id
                """
            ),
            {"id": file_id},
        )
    ).first()

    if row is None:
        raise ApiError(
            status_code=404, code="NOT_FOUND",
            message="El recurso solicitado no existe o no esta disponible.",
        )

    # Reintento sobre un archivo ya subido. No es un error del cliente ni
    # motivo para sobrescribir el binario: se responde que ya esta.
    if row.status == "stored":
        raise ApiError(
            status_code=409, code="ALREADY_UPLOADED",
            message="Ese archivo ya fue subido.",
        )
    if row.status != "pending":
        raise ApiError(
            status_code=409, code="INVALID_STATE",
            message=f"El archivo esta en estado '{row.status}' y no admite subida.",
        )

    # Doble vencimiento a proposito: el del token y el de la fila. El token
    # puede estar vivo y la fila vencida si alguien cambio el TTL, y al
    # reves si se reemplazo la llave de firma. Vale el mas estricto.
    if row.upload_expires_at <= datetime.now(timezone.utc):
        raise ApiError(
            status_code=410, code="UPLOAD_EXPIRED",
            message="El enlace de subida vencio. Pide uno nuevo.",
        )

    # El tipo lo manda el cliente en la cabecera; tiene que ser el mismo que
    # se declaro al pedir el enlace, porque es el que la fila ya tiene
    # guardado y el que el CHECK del motor acepto.
    declarado = claims["ct"]
    enviado = (request.headers.get("content-type") or "").split(";")[0].strip()
    if enviado and enviado != declarado:
        raise ApiError(
            status_code=415, code="CONTENT_TYPE_MISMATCH",
            message="El tipo de contenido no coincide con el declarado al pedir el enlace.",
            details=[{"field": "content-type",
                      "message": f"Declarado: {declarado}. Enviado: {enviado}."}],
        )

    # Se corta antes de leer el cuerpo si el propio cliente avisa que trae
    # mas de lo permitido: no tiene sentido juntar 100 MB en memoria para
    # despues rechazarlos.
    largo = request.headers.get("content-length")
    if largo and largo.isdigit() and int(largo) > MAX_SIZE_BYTES:
        raise ApiError(
            status_code=413, code="FILE_TOO_LARGE",
            message=f"El archivo supera el maximo de {MAX_SIZE_BYTES // (1024*1024)} MB.",
        )

    data = await request.body()
    if not data:
        raise ApiError(
            status_code=422, code="VALIDATION_ERROR",
            message="No llegaron bytes del archivo.",
        )
    if len(data) > MAX_SIZE_BYTES:
        raise ApiError(
            status_code=413, code="FILE_TOO_LARGE",
            message=f"El archivo supera el maximo de {MAX_SIZE_BYTES // (1024*1024)} MB.",
        )

    # El tamano real manda sobre el declarado. El declarado sirvio para
    # rechazar temprano; una vez que los bytes estan aca, lo que la fila
    # tiene que decir es cuanto pesa el archivo de verdad.
    checksum = hashlib.sha256(data).hexdigest()

    storage = get_storage()
    await storage.save(storage_key=row.storage_key, data=data)

    # El binario se guarda ANTES de marcar la fila. Si falla el guardado la
    # fila sigue pending y se puede reintentar; al reves quedaria una fila
    # que dice stored apuntando a un archivo que no existe.
    await db.execute(
        text(
            """
            UPDATE files
               SET status = 'stored',
                   stored_at = now(),
                   size_bytes = :size,
                   checksum_sha256 = :sum,
                   updated_at = now()
             WHERE id = :id
               AND status = 'pending'
            """
        ),
        {"id": file_id, "size": len(data), "sum": checksum},
    )
    await db.commit()

    return UploadDoneOut(
        file_id=UUID(file_id),
        file_url=storage.file_url(file_id=file_id, storage_key=row.storage_key),
        size=len(data),
        checksum=checksum,
        status="stored",
    )


# ---------------------------------------------------------------------------
# Lectura
# ---------------------------------------------------------------------------
_NO_EXISTE = ApiError(
    status_code=404, code="NOT_FOUND",
    message="El recurso solicitado no existe o no esta disponible.",
)


async def _cargar_archivo(db: AsyncSession, file_id: UUID):
    row = (
        await db.execute(
            text(
                """
                SELECT id, patient_id, scope, storage_key, original_name,
                       mime_type, size_bytes, status
                FROM files
                WHERE id = :id
                """
            ),
            {"id": str(file_id)},
        )
    ).mappings().first()
    # Un archivo pending todavia no tiene bytes y uno purged ya no los tiene.
    # En los dos casos la respuesta honesta es que no esta disponible.
    if row is None or row["status"] != "stored":
        raise _NO_EXISTE
    return row


async def _exigir_acceso(db: AsyncSession, row, user_id: str) -> None:
    """Control de acceso por ambito del archivo (spec 16.2).

    patient    solo los miembros vivos del circulo de ese paciente
    catalog    cualquier usuario autenticado, es contenido comun
    caregiver  cualquier usuario autenticado, son los certificados que la
               cuidadora publica en el marketplace para que los vean
    """
    if row["scope"] != "patient":
        return
    miembro = (
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
            {"pid": str(row["patient_id"]), "uid": user_id},
        )
    ).first()
    if miembro is None:
        raise _NO_EXISTE


def _content_disposition(nombre: str) -> str:
    # El nombre original puede traer acentos, comillas o saltos de linea.
    # Va en el formato de RFC 5987 y ademas una version ascii de respaldo.
    seguro = "".join(c for c in nombre if c.isalnum() or c in "._- ") or "archivo"
    return f"inline; filename=\"{seguro}\"; filename*=UTF-8''{quote(nombre)}"


@router.get("/files/{file_id}")
async def read_file(
    file_id: UUID,
    t: str | None = None,
    creds: HTTPAuthorizationCredentials | None = Depends(bearer_scheme),
    db: AsyncSession = Depends(get_db),
):
    """Entrega el binario (RF-42).

    Acepta dos formas de credencial, y hacen falta las dos:

        cabecera Bearer  las llamadas que hace Dio desde el repositorio
        ?t=<token>       Image.network, que no manda cabeceras

    El token de descarga vale 5 minutos y para un solo archivo, asi que no
    sirve para pasearse por el expediente de nadie.
    """
    # Primero la credencial y despues la fila, en ese orden: si se mirara la
    # fila antes, quien no esta autenticado distinguiria un archivo que
    # existe (401) de uno que no (404).
    user: CurrentUser | None = None
    if t:
        claims = read_token(t, purpose="download")
        if claims is None or claims.get("fid") != str(file_id):
            raise ApiError(
                status_code=401, code="DOWNLOAD_TOKEN_INVALID",
                message="El enlace del archivo no es valido o ya vencio.",
            )
    else:
        user = await get_current_user(creds, db)

    row = await _cargar_archivo(db, file_id)
    if user is not None:
        await _exigir_acceso(db, row, user.user_id)

    storage = get_storage()
    try:
        data = await storage.load(storage_key=row["storage_key"])
    except FileNotFoundError:
        # La fila dice stored y el binario no esta. Es una inconsistencia que
        # hay que ver en los registros, no un 404 silencioso.
        raise ApiError(
            status_code=500, code="STORAGE_ERROR",
            message="El archivo no se pudo leer del almacenamiento.",
        )

    return Response(
        content=data,
        media_type=row["mime_type"],
        headers={
            "Content-Disposition": _content_disposition(row["original_name"]),
            # Privado y corto: es contenido de salud, no se guarda en caches
            # intermedias ni en el disco del dispositivo mas de lo necesario.
            "Cache-Control": "private, max-age=300",
            "X-Content-Type-Options": "nosniff",
        },
    )


class DownloadLinkOut(BaseModel):
    file_id:    UUID
    name:       str
    mime_type:  str
    size:       int
    url:        str
    expires_at: datetime


@router.get("/files/{file_id}/download", response_model=DownloadLinkOut)
async def download_link(
    file_id: UUID,
    user: CurrentUser = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Entrega un enlace de lectura de vida corta (RF-42, RNF-13).

    Es el paso que le falta al front para mostrar imagenes: pide el enlace
    con su sesion y recien despues se lo pasa a Image.network, que no sabe
    mandar cabeceras.
    """
    row = await _cargar_archivo(db, file_id)
    await _exigir_acceso(db, row, user.user_id)

    storage = get_storage()
    return DownloadLinkOut(
        file_id=row["id"],
        name=row["original_name"],
        mime_type=row["mime_type"],
        size=row["size_bytes"],
        url=storage.download_url(
            file_id=str(row["id"]), storage_key=row["storage_key"],
            content_type=row["mime_type"], size=row["size_bytes"],
        ),
        expires_at=datetime.now(timezone.utc) + timedelta(minutes=DOWNLOAD_TTL_MINUTES),
    )
