"""Almacenamiento de binarios: adaptador con dos implementaciones.

El front sube en dos pasos (ver core/network/upload_service.dart):

    1. POST /uploads          -> { upload_id, upload_url, file_url }
    2. PUT  <upload_url>      con los bytes del archivo
    3. se usa file_url en el recurso destino (documento, foto, mensaje...)

El binario NUNCA pasa por FastAPI en produccion: el cliente sube directo al
almacenamiento con una URL firmada de vida corta. Un PDF de 20 MB atravesando
la API seria un desperdicio de memoria y de conexiones.

Hay dos implementaciones detras de la misma interfaz:

    LocalStorage  desarrollo. Guarda en disco dentro del contenedor y la URL
                  de subida apunta a la propia API (PUT /uploads/{token}).
    AzureStorage  produccion. Devuelve una SAS real de Azure Blob, que es lo
                  que el front ya espera (manda la cabecera x-ms-blob-type).

El front no distingue una de otra: en los dos casos recibe un upload_url y le
hace PUT. Cambiar de una a otra es una variable de entorno, no un cambio de
codigo ni del contrato.
"""
from __future__ import annotations

import os
import shutil
from abc import ABC, abstractmethod
from datetime import datetime, timedelta, timezone
from functools import lru_cache
from pathlib import Path

from jose import JWTError, jwt
from pydantic_settings import BaseSettings, SettingsConfigDict

from app.config import get_settings

# RNF-13: los enlaces de archivos expiran en 15 minutos o menos.
UPLOAD_TTL_MINUTES = 15
DOWNLOAD_TTL_MINUTES = 5

# Tipos aceptados. Debe coincidir con el CHECK ck_files_mime_type de la tabla
# files: si la API acepta uno que la BD rechaza, el INSERT falla despues de
# que el usuario ya subio el archivo.
ALLOWED_CONTENT_TYPES = {
    "image/jpeg",
    "image/png",
    "image/webp",
    "image/heic",
    "application/pdf",
    "audio/mpeg",
    "audio/mp4",
    "audio/aac",
    "audio/wav",
    "audio/ogg",
}

# Techo duro, el mismo de ck_files_size_bytes.
MAX_SIZE_BYTES = 25 * 1024 * 1024

# Extension por tipo, para armar la ruta de almacenamiento.
_EXTENSION = {
    "image/jpeg": "jpg",
    "image/png": "png",
    "image/webp": "webp",
    "image/heic": "heic",
    "application/pdf": "pdf",
    "audio/mpeg": "mp3",
    "audio/mp4": "m4a",
    "audio/aac": "aac",
    "audio/wav": "wav",
    "audio/ogg": "ogg",
}


class StorageSettings(BaseSettings):
    """Configuracion propia del modulo, para no tocar config.py del equipo."""

    # local | azure
    storage_backend: str = "local"
    # Carpeta de LocalStorage dentro del contenedor.
    storage_local_dir: str = "/var/agecare/files"
    # URL publica de la API, para armar los enlaces que devuelve LocalStorage.
    storage_public_base_url: str = "http://localhost:8000"
    # Azure, se completan cuando Alloxentric entregue las credenciales.
    azure_storage_account: str = ""
    azure_storage_key: str = ""
    azure_storage_container: str = "agecare"

    model_config = SettingsConfigDict(
        env_file=".env", env_file_encoding="utf-8", extra="ignore"
    )


@lru_cache
def get_storage_settings() -> StorageSettings:
    return StorageSettings()


# ---------------------------------------------------------------------------
# Token de subida y de descarga
# ---------------------------------------------------------------------------
# Se firma un JWT corto en vez de guardar un token en la tabla. Dos motivos:
# no agrega una columna que solo vive 15 minutos, y el propio token lleva lo
# que hay que verificar al recibir el binario (tipo y tamano declarados), asi
# que el receptor no puede ser enganado cambiandolos a ultima hora.
def issue_token(*, purpose: str, file_id: str, storage_key: str,
                content_type: str, size: int, ttl_minutes: int) -> str:
    cfg = get_settings()
    now = datetime.now(timezone.utc)
    payload = {
        "pur": purpose,            # upload | download
        "fid": file_id,
        "key": storage_key,
        "ct": content_type,
        "sz": size,
        "iat": int(now.timestamp()),
        "exp": int((now + timedelta(minutes=ttl_minutes)).timestamp()),
    }
    return jwt.encode(payload, cfg.jwt_secret, algorithm=cfg.jwt_algorithm)


def read_token(token: str, *, purpose: str) -> dict | None:
    """Devuelve el contenido del token, o None si no sirve."""
    cfg = get_settings()
    try:
        payload = jwt.decode(token, cfg.jwt_secret, algorithms=[cfg.jwt_algorithm])
    except JWTError:
        return None
    if payload.get("pur") != purpose:
        return None
    return payload


def build_storage_key(*, file_id: str, patient_id: str | None,
                      scope: str, content_type: str) -> str:
    """Ruta opaca dentro del almacenamiento.

    Lleva el ambito y el paciente para que el contenido quede agrupado y sea
    facil de auditar o purgar, pero el nombre final es el id del archivo: no
    se usa el nombre original, que puede traer acentos, espacios o barras.
    """
    ext = _EXTENSION.get(content_type, "bin")
    if scope == "patient" and patient_id:
        return f"patient/{patient_id}/{file_id}.{ext}"
    return f"{scope}/{file_id}.{ext}"


# ---------------------------------------------------------------------------
# Interfaz
# ---------------------------------------------------------------------------
class StorageBackend(ABC):
    """Lo minimo que la API necesita de un almacenamiento."""

    @abstractmethod
    def upload_url(self, *, file_id: str, storage_key: str,
                   content_type: str, size: int) -> str:
        """URL a la que el cliente hara PUT con los bytes."""

    @abstractmethod
    def file_url(self, *, file_id: str, storage_key: str) -> str:
        """URL con la que se referencia el archivo ya guardado."""

    @abstractmethod
    async def save(self, *, storage_key: str, data: bytes) -> None: ...

    @abstractmethod
    async def load(self, *, storage_key: str) -> bytes: ...

    @abstractmethod
    async def delete(self, *, storage_key: str) -> None: ...

    @abstractmethod
    def exists(self, *, storage_key: str) -> bool: ...


# ---------------------------------------------------------------------------
# Desarrollo: disco local servido por la propia API
# ---------------------------------------------------------------------------
class LocalStorage(StorageBackend):
    def __init__(self, root: str, public_base_url: str):
        self.root = Path(root)
        self.base = public_base_url.rstrip("/")
        self.root.mkdir(parents=True, exist_ok=True)

    def _path(self, storage_key: str) -> Path:
        # El storage_key lo arma la API, nunca el cliente, pero se normaliza
        # igual: una ruta con .. que escape de la carpeta seria grave.
        p = (self.root / storage_key).resolve()
        if not str(p).startswith(str(self.root.resolve())):
            raise ValueError("ruta de almacenamiento fuera de la carpeta raiz")
        return p

    def upload_url(self, *, file_id: str, storage_key: str,
                   content_type: str, size: int) -> str:
        token = issue_token(
            purpose="upload", file_id=file_id, storage_key=storage_key,
            content_type=content_type, size=size, ttl_minutes=UPLOAD_TTL_MINUTES,
        )
        return f"{self.base}/api/v1/uploads/{token}"

    def file_url(self, *, file_id: str, storage_key: str) -> str:
        return f"{self.base}/api/v1/files/{file_id}"

    async def save(self, *, storage_key: str, data: bytes) -> None:
        p = self._path(storage_key)
        p.parent.mkdir(parents=True, exist_ok=True)
        tmp = p.with_suffix(p.suffix + ".parcial")
        tmp.write_bytes(data)
        # Renombrar es atomico: nunca queda un archivo a medio escribir
        # visible para quien lo lea.
        tmp.replace(p)

    async def load(self, *, storage_key: str) -> bytes:
        return self._path(storage_key).read_bytes()

    async def delete(self, *, storage_key: str) -> None:
        p = self._path(storage_key)
        if p.exists():
            p.unlink()

    def exists(self, *, storage_key: str) -> bool:
        return self._path(storage_key).exists()

    def disk_usage(self) -> int:
        return shutil.disk_usage(self.root).free


# ---------------------------------------------------------------------------
# Produccion: Azure Blob Storage
# ---------------------------------------------------------------------------
class AzureStorage(StorageBackend):
    """Devuelve SAS reales de Azure Blob.

    El paquete azure-storage-blob se importa de forma perezosa para que la API
    arranque igual en desarrollo, donde no esta instalado ni hace falta.
    """

    def __init__(self, account: str, key: str, container: str):
        if not account or not key:
            raise RuntimeError(
                "STORAGE_BACKEND=azure pero faltan AZURE_STORAGE_ACCOUNT o "
                "AZURE_STORAGE_KEY. Mientras Alloxentric no entregue las "
                "credenciales, usa STORAGE_BACKEND=local."
            )
        self.account, self.key, self.container = account, key, container

    def _sas(self, storage_key: str, *, write: bool, ttl: int) -> str:
        from azure.storage.blob import BlobSasPermissions, generate_blob_sas

        token = generate_blob_sas(
            account_name=self.account,
            container_name=self.container,
            blob_name=storage_key,
            account_key=self.key,
            permission=BlobSasPermissions(write=True, create=True) if write
            else BlobSasPermissions(read=True),
            expiry=datetime.now(timezone.utc) + timedelta(minutes=ttl),
        )
        return (f"https://{self.account}.blob.core.windows.net/"
                f"{self.container}/{storage_key}?{token}")

    def upload_url(self, *, file_id: str, storage_key: str,
                   content_type: str, size: int) -> str:
        return self._sas(storage_key, write=True, ttl=UPLOAD_TTL_MINUTES)

    def file_url(self, *, file_id: str, storage_key: str) -> str:
        # Se devuelve la URL de la API y no la SAS de lectura: la SAS vence y
        # el file_url queda guardado en la fila del documento o del mensaje.
        return (f"{get_storage_settings().storage_public_base_url.rstrip('/')}"
                f"/api/v1/files/{file_id}")

    def download_url(self, *, storage_key: str) -> str:
        return self._sas(storage_key, write=False, ttl=DOWNLOAD_TTL_MINUTES)

    async def save(self, *, storage_key: str, data: bytes) -> None:
        from azure.storage.blob.aio import BlobServiceClient

        svc = BlobServiceClient(
            f"https://{self.account}.blob.core.windows.net", credential=self.key)
        async with svc:
            await svc.get_blob_client(self.container, storage_key).upload_blob(
                data, overwrite=True)

    async def load(self, *, storage_key: str) -> bytes:
        from azure.storage.blob.aio import BlobServiceClient

        svc = BlobServiceClient(
            f"https://{self.account}.blob.core.windows.net", credential=self.key)
        async with svc:
            stream = await svc.get_blob_client(
                self.container, storage_key).download_blob()
            return await stream.readall()

    async def delete(self, *, storage_key: str) -> None:
        from azure.storage.blob.aio import BlobServiceClient

        svc = BlobServiceClient(
            f"https://{self.account}.blob.core.windows.net", credential=self.key)
        async with svc:
            await svc.get_blob_client(self.container, storage_key).delete_blob()

    def exists(self, *, storage_key: str) -> bool:
        # No se consulta Azure de forma sincrona desde el request; el estado
        # del archivo lo lleva files.status en la base.
        return True


@lru_cache
def get_storage() -> StorageBackend:
    cfg = get_storage_settings()
    if cfg.storage_backend == "azure":
        return AzureStorage(
            cfg.azure_storage_account, cfg.azure_storage_key,
            cfg.azure_storage_container)
    return LocalStorage(cfg.storage_local_dir, cfg.storage_public_base_url)
