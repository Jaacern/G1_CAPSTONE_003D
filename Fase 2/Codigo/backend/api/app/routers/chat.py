"""Chat del circulo de cuidado.

Endpoints que la aplicacion ya consume:

    GET  /patients/{id}/chat/messages
    POST /patients/{id}/chat/messages
    POST /patients/{id}/chat/read

Es el chat humano del equipo: una sola conversacion por paciente, donde
estan la familia, la cuidadora y el medico. El asistente de IA usa la
misma tabla con type='assistant' y una conversacion por persona, y va por
su propio router.
"""
from datetime import datetime
from uuid import UUID

from fastapi import APIRouter, Depends, Query
from pydantic import BaseModel, Field
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

from app.db import get_db
from app.deps import PatientContext, get_patient_member
from app.errors import ApiError
from app.routers.logbook import _archivo_del_paciente
from app.storage import get_storage

router = APIRouter(prefix="/api/v1", tags=["chat"])


class MessageOut(BaseModel):
    id:          UUID
    patient_id:  UUID
    sender_id:   UUID
    sender_name: str
    sender_role: str
    type:        str
    text:        str | None
    media_url:   str | None
    created_at:  datetime
    read_by:     list[str]


class MessagesOut(BaseModel):
    items: list[MessageOut]


def _salida(f, patient_id: str) -> MessageOut:
    return MessageOut(
        id=f["id"],
        patient_id=UUID(patient_id),
        sender_id=f["sender_id"],
        sender_name=f["full_name"],
        sender_role=f["role"] or "",
        type=f["kind"],
        text=f["body"],
        media_url=(get_storage().file_url(file_id=str(f["file_id"]),
                                          storage_key="")
                   if f["file_id"] else None),
        created_at=f["created_at"],
        read_by=[str(x) for x in (f["leido_por"] or [])],
    )


async def _conversacion(db: AsyncSession, patient_id: str,
                        crear: bool = False) -> str | None:
    """Devuelve la conversacion humana del paciente.

    Hay una sola por paciente y nace con el primer mensaje, no al crear el
    paciente: una conversacion vacia que nadie abrio no le sirve a nadie.
    """
    actual = (
        await db.execute(
            text("SELECT id FROM conversations "
                 "WHERE patient_id = :pid AND type = 'human'"),
            {"pid": patient_id},
        )
    ).scalar()
    if actual is not None or not crear:
        return str(actual) if actual else None

    # Dos personas pueden escribir el primer mensaje a la vez. El ON
    # CONFLICT no sirve porque no hay restriccion unica sobre
    # (patient_id, type), asi que se vuelve a consultar si el INSERT no
    # devolvio fila por una carrera.
    nueva = (
        await db.execute(
            text(
                """
                INSERT INTO conversations (patient_id, type, user_id)
                SELECT :pid, 'human', NULL
                WHERE NOT EXISTS (
                    SELECT 1 FROM conversations
                    WHERE patient_id = :pid AND type = 'human'
                )
                RETURNING id
                """
            ),
            {"pid": patient_id},
        )
    ).scalar()
    if nueva is not None:
        return str(nueva)

    return str(
        (
            await db.execute(
                text("SELECT id FROM conversations "
                     "WHERE patient_id = :pid AND type = 'human'"),
                {"pid": patient_id},
            )
        ).scalar()
    )


@router.get("/patients/{patient_id}/chat/messages", response_model=MessagesOut)
async def list_messages(
    before: datetime | None = Query(default=None),
    limit: int = Query(default=50, ge=1, le=200),
    ctx: PatientContext = Depends(get_patient_member()),
    db: AsyncSession = Depends(get_db),
):
    """Mensajes del chat, del mas nuevo al mas viejo.

    La pantalla pagina hacia atras con 'before', que es la fecha del
    mensaje mas antiguo que ya tiene. Se devuelve en orden descendente
    porque es como se arma una conversacion al desplazarse hacia arriba.
    """
    conv = await _conversacion(db, ctx.patient_id)
    if conv is None:
        # Todavia nadie escribio. Es una conversacion vacia, no un error.
        return MessagesOut(items=[])

    filas = (
        await db.execute(
            text(
                """
                SELECT m.id, m.sender_id, m.kind, m.body, m.file_id,
                       m.created_at, u.full_name, pm.role,
                       coalesce(r.leido_por, ARRAY[]::uuid[]) AS leido_por
                FROM messages m
                JOIN users u ON u.id = m.sender_id
                LEFT JOIN patient_members pm
                       ON pm.patient_id = :pid AND pm.user_id = m.sender_id
                LEFT JOIN LATERAL (
                    SELECT array_agg(mr.recipient_id) AS leido_por
                    FROM message_receipts mr
                    WHERE mr.message_id = m.id AND mr.read_at IS NOT NULL
                ) r ON true
                WHERE m.conversation_id = :conv
                  AND (CAST(:antes AS timestamptz) IS NULL
                       OR m.created_at < CAST(:antes AS timestamptz))
                ORDER BY m.created_at DESC
                LIMIT :tope
                """
            ),
            {"pid": ctx.patient_id, "conv": conv, "antes": before,
             "tope": limit},
        )
    ).mappings().all()

    return MessagesOut(items=[_salida(f, ctx.patient_id) for f in filas])
