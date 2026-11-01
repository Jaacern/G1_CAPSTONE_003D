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
from app.storage import get_storage

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


class DocumentIn(BaseModel):
    file_url: str = Field(min_length=1)
    title:    str = Field(min_length=1, max_length=160)
    category: str | None = None

    _limpiar = field_validator("title")(_texto_con_contenido)


@router.post("/patients/{patient_id}/documents", response_model=DocumentOut,
             status_code=201)
async def add_document(
    payload: DocumentIn,
    ctx: PatientContext = Depends(get_patient_member(["family", "caregiver", "doctor"])),
    db: AsyncSession = Depends(get_db),
):
    """Agrega un documento ya subido al expediente del paciente."""
    categoria = _categoria_a_base(payload.category)
    file_id = await _archivo_del_paciente(db, payload.file_url, ctx.patient_id)
    if file_id is None:
        raise ApiError(
            status_code=422, code="VALIDATION_ERROR",
            message="Falta el archivo del documento.",
            details=[{"field": "file_url", "message": "No puede ir vacio."}],
        )

    # uq_medical_documents_file deja un documento por archivo. Si el mismo
    # archivo ya esta en el expediente, es un reintento de la pantalla
    # despues de un error de red, no un documento nuevo: se devuelve el que
    # ya existe en vez de reventar con un 500 del motor.
    repetido = (
        await db.execute(
            text(
                """
                SELECT d.id, d.title, d.category, d.file_id, d.created_at,
                       u.full_name
                FROM medical_documents d
                JOIN users u ON u.id = d.added_by
                WHERE d.file_id = :fid AND d.deleted_at IS NULL
                """
            ),
            {"fid": file_id},
        )
    ).mappings().first()
    if repetido is not None:
        return _salida(repetido)

    fila = (
        await db.execute(
            text(
                """
                INSERT INTO medical_documents (
                    patient_id, file_id, category, title, added_by
                ) VALUES (:pid, :fid, :cat, :titulo, :uid)
                RETURNING id, title, category, file_id, created_at
                """
            ),
            {"pid": ctx.patient_id, "fid": file_id, "cat": categoria,
             "titulo": payload.title, "uid": ctx.user.user_id},
        )
    ).mappings().first()
    await db.commit()

    return _salida({**dict(fila), "full_name": ctx.user.full_name})


# ---------------------------------------------------------------------------
# Un documento suelto: la ruta no lleva el paciente
# ---------------------------------------------------------------------------
_NO_EXISTE = ApiError(
    status_code=404, code="NOT_FOUND",
    message="El recurso solicitado no existe o no esta disponible.",
)


async def _documento_del_usuario(db: AsyncSession, document_id: UUID,
                                 user_id: str):
    """Carga el documento comprobando que quien pide sea del circulo.

    Estas dos rutas no llevan el paciente, asi que no sirve la dependencia
    de membresia: hay que llegar al paciente desde el documento. La
    respuesta es 404 tanto si el documento no existe como si es de un
    paciente ajeno, para que no se puedan averiguar ids probando.
    """
    fila = (
        await db.execute(
            text(
                """
                SELECT d.id, d.patient_id, d.title, d.category, d.file_id,
                       d.created_at, f.storage_key, f.mime_type, f.size_bytes,
                       f.status AS file_status
                FROM medical_documents d
                JOIN patients p ON p.id = d.patient_id
                JOIN files f    ON f.id = d.file_id
                WHERE d.id = :did
                  AND d.deleted_at IS NULL
                  AND p.deleted_at IS NULL
                """
            ),
            {"did": str(document_id)},
        )
    ).mappings().first()
    if fila is None:
        raise _NO_EXISTE

    miembro = (
        await db.execute(
            text(
                """
                SELECT pm.role
                FROM patient_members pm
                WHERE pm.patient_id = :pid
                  AND pm.user_id = :uid
                  AND pm.removed_at IS NULL
                """
            ),
            {"pid": str(fila["patient_id"]), "uid": user_id},
        )
    ).mappings().first()
    if miembro is None:
        raise _NO_EXISTE

    return fila, miembro["role"]


@router.delete("/documents/{document_id}", status_code=204)
async def delete_document(
    document_id: UUID,
    user: CurrentUser = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Quita un documento del expediente.

    Es borrado logico. El archivo binario no se toca y la fila queda con
    deleted_at y deleted_by, que el CHECK exige juntos. Es la misma regla
    del resto del esquema: del expediente de un paciente no se borra nada
    de verdad, se marca quien lo quito y cuando.
    """
    fila, rol = await _documento_del_usuario(db, document_id, user.user_id)

    # El medico lee el expediente pero no lo edita.
    if rol not in ("family", "caregiver"):
        raise ApiError(
            status_code=403, code="FORBIDDEN",
            message="No tienes permisos para quitar documentos de este expediente.",
        )

    await db.execute(
        text(
            """
            UPDATE medical_documents
               SET deleted_at = now(), deleted_by = :uid, updated_at = now()
             WHERE id = :did AND deleted_at IS NULL
            """
        ),
        {"did": str(document_id), "uid": user.user_id},
    )
    await db.commit()
