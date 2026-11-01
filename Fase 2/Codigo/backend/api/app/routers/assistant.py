"""Asistente de IA sobre el expediente del paciente.

Endpoints que la aplicacion ya consume:

    GET  /patients/{id}/assistant/conversations
    POST /patients/{id}/assistant/messages
    GET  /assistant/conversations/{id}/messages

La conversacion con el asistente es privada de cada persona:
ux_conversations_assistant deja una por paciente y usuario, asi que lo que
le pregunta la cuidadora no lo ve la familia ni al reves.
"""
from datetime import datetime, timezone
from uuid import UUID

from fastapi import APIRouter, Depends
from pydantic import BaseModel, Field, field_validator
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

from app.db import get_db
from app.deps import CurrentUser, PatientContext, get_current_user, get_patient_member
from app.errors import ApiError
from app.routers.logbook import _texto_con_contenido

router = APIRouter(prefix="/api/v1", tags=["assistant"])

_NO_EXISTE = ApiError(
    status_code=404, code="NOT_FOUND",
    message="El recurso solicitado no existe o no esta disponible.",
)


class ConversationOut(BaseModel):
    id:         UUID
    title:      str
    updated_at: datetime


class ConversationsOut(BaseModel):
    items: list[ConversationOut]


@router.get("/patients/{patient_id}/assistant/conversations",
            response_model=ConversationsOut)
async def list_conversations(
    ctx: PatientContext = Depends(get_patient_member()),
    db: AsyncSession = Depends(get_db),
):
    """Conversaciones que esta persona tiene con el asistente sobre este
    paciente.

    Devuelve solo las propias. La conversacion con el asistente suele
    traer dudas que uno no le hace al resto del circulo, asi que no se
    comparte aunque todos cuiden al mismo paciente.
    """
    filas = (
        await db.execute(
            text(
                """
                SELECT id, title, last_message_at, updated_at
                FROM conversations
                WHERE patient_id = :pid
                  AND type = 'assistant'
                  AND user_id = :uid
                ORDER BY coalesce(last_message_at, updated_at) DESC
                """
            ),
            {"pid": ctx.patient_id, "uid": ctx.user.user_id},
        )
    ).mappings().all()

    return ConversationsOut(items=[
        ConversationOut(
            id=f["id"],
            # La pantalla ya pone 'Conversacion' cuando falta, pero mandarlo
            # resuelto evita que una conversacion sin titulo se vea distinta
            # segun quien la dibuje.
            title=f["title"] or "Conversacion",
            updated_at=f["last_message_at"] or f["updated_at"],
        )
        for f in filas
    ])
