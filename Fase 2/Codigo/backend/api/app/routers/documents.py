"""Expediente de documentos del paciente.

Endpoints que la aplicacion ya consume:

    GET    /patients/{id}/documents
    POST   /patients/{id}/documents
    DELETE /documents/{id}
    GET    /documents/{id}/download

Aca la traduccion de categorias va en los DOS sentidos, a diferencia de la
bitacora. La pantalla no solo manda su clave al subir: tambien agrupa la
lista por categoria y elige el icono y el titulo de cada grupo con un
switch sobre sus propias claves. Si la API devolviera los codigos de la
base, todos los documentos caerian en el grupo 'Otros' y la pantalla
perderia lo unico que hace.
"""
from datetime import datetime
from uuid import UUID

from fastapi import APIRouter, Depends, Request
from pydantic import BaseModel, Field, field_validator
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

from app.db import get_db
from app.deps import CurrentUser, PatientContext, get_current_user, get_patient_member
from app.errors import ApiError
from app.routers.logbook import (
    _archivo_del_paciente,
    _registrar_lectura,
    _sin_tildes,
    _texto_con_contenido,
)
from app.storage import DOWNLOAD_TTL_MINUTES, get_storage

router = APIRouter(prefix="/api/v1", tags=["documents"])

# De la clave de la pantalla al codigo de la base.
_A_BASE = {
    "receta":         "prescription",
    "estudio":        "lab_result",
    "identificacion": "identification",
    "general":        "other",
    "otro":           "other",
}
_CODIGOS = {"prescription", "lab_result", "imaging", "report", "discharge",
            "consent", "insurance", "identification", "other"}

# Del codigo de la base a la clave de la pantalla. Los codigos que la
# pantalla no sabe dibujar caen en 'general', que es su grupo por defecto y
# ya tiene icono y titulo propios.
_A_PANTALLA = {
    "prescription":   "receta",
    "lab_result":     "estudio",
    "identification": "identificacion",
}


def _categoria_a_base(valor: str | None) -> str:
    if valor is None or not valor.strip():
        return "other"
    plano = _sin_tildes(valor)
    if plano in _CODIGOS:
        return plano
    resuelta = _A_BASE.get(plano)
    if resuelta is None:
        raise ApiError(
            status_code=422, code="VALIDATION_ERROR",
            message="Esa categoria de documento no existe.",
            details=[{"field": "category", "message": f"Valor recibido: {valor}."}],
        )
    return resuelta


def _categoria_a_pantalla(codigo: str) -> str:
    return _A_PANTALLA.get(codigo, "general")


class DocumentOut(BaseModel):
    id:            UUID
    title:         str
    category:      str
    file_url:      str
    created_at:    datetime
    uploader_name: str | None


class DocumentsOut(BaseModel):
    items: list[DocumentOut]


def _salida(f) -> DocumentOut:
    return DocumentOut(
        id=f["id"],
        title=f["title"],
        category=_categoria_a_pantalla(f["category"]),
        file_url=get_storage().file_url(
            file_id=str(f["file_id"]), storage_key=""),
        created_at=f["created_at"],
        uploader_name=f["full_name"],
    )


@router.get("/patients/{patient_id}/documents", response_model=DocumentsOut)
async def list_documents(
    request: Request,
    ctx: PatientContext = Depends(get_patient_member()),
    db: AsyncSession = Depends(get_db),
):
    """Documentos del paciente, lo mas reciente primero."""
    filas = (
        await db.execute(
            text(
                """
                SELECT d.id, d.title, d.category, d.file_id, d.created_at,
                       u.full_name
                FROM medical_documents d
                JOIN users u ON u.id = d.added_by
                WHERE d.patient_id = :pid
                  AND d.deleted_at IS NULL
                ORDER BY d.created_at DESC
                LIMIT 200
                """
            ),
            {"pid": ctx.patient_id},
        )
    ).mappings().all()

    await _registrar_lectura(db, ctx, request, seccion="documents")
    await db.commit()

    return DocumentsOut(items=[_salida(f) for f in filas])
