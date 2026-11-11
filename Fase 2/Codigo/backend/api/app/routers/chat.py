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
from datetime import datetime, timezone
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


class MessageIn(BaseModel):
    type:      str = Field(default="text")
    text:      str | None = Field(default=None, max_length=4000)
    media_url: str | None = None


_TIPOS = {"text", "voice", "photo"}


@router.post("/patients/{patient_id}/chat/messages", response_model=MessageOut,
             status_code=201)
async def send_message(
    payload: MessageIn,
    ctx: PatientContext = Depends(get_patient_member()),
    db: AsyncSession = Depends(get_db),
):
    """Envia un mensaje al chat del circulo.

    chk_messages_content exige que un mensaje de texto traiga texto y que
    uno de voz o foto traiga archivo. Se valida aca para que el usuario
    reciba un 422 que explica que falto, en vez del error del motor.
    """
    tipo = payload.type.strip().lower()
    if tipo not in _TIPOS:
        raise ApiError(
            status_code=422, code="VALIDATION_ERROR",
            message="Ese tipo de mensaje no existe.",
            details=[{"field": "type",
                      "message": f"Valores aceptados: {', '.join(sorted(_TIPOS))}."}],
        )

    cuerpo = (payload.text or "").strip() or None
    file_id = await _archivo_del_paciente(db, payload.media_url, ctx.patient_id)

    if tipo == "text" and cuerpo is None:
        raise ApiError(
            status_code=422, code="VALIDATION_ERROR",
            message="El mensaje no puede ir vacio.",
            details=[{"field": "text", "message": "Escribe algo antes de enviar."}],
        )
    if tipo in ("voice", "photo") and file_id is None:
        raise ApiError(
            status_code=422, code="VALIDATION_ERROR",
            message=f"Un mensaje de tipo '{tipo}' necesita el archivo.",
            details=[{"field": "media_url", "message": "Falta el archivo."}],
        )

    conv = await _conversacion(db, ctx.patient_id, crear=True)

    fila = (
        await db.execute(
            text(
                """
                INSERT INTO messages (conversation_id, sender_id, kind, body, file_id)
                VALUES (:conv, :uid, :tipo, :cuerpo, :fid)
                RETURNING id, sender_id, kind, body, file_id, created_at
                """
            ),
            {"conv": conv, "uid": ctx.user.user_id, "tipo": tipo,
             "cuerpo": cuerpo, "fid": file_id},
        )
    ).mappings().first()

    # Un acuse por cada miembro vivo del circulo menos quien escribe, para
    # que el no leido tenga a quien contarse. Se crean al enviar y no al
    # abrir la pantalla: si se crearan al leer, un mensaje que nadie abrio
    # no tendria ninguna fila y no habria forma de distinguir "nadie lo
    # leyo" de "no se le mostro a nadie".
    await db.execute(
        text(
            """
            INSERT INTO message_receipts (message_id, recipient_id)
            SELECT :mid, pm.user_id
            FROM patient_members pm
            WHERE pm.patient_id = :pid
              AND pm.user_id <> :uid
              AND pm.removed_at IS NULL
            ON CONFLICT (message_id, recipient_id) DO NOTHING
            """
        ),
        {"mid": str(fila["id"]), "pid": ctx.patient_id, "uid": ctx.user.user_id},
    )

    await db.execute(
        text("UPDATE conversations SET last_message_at = now(), updated_at = now() "
             "WHERE id = :conv"),
        {"conv": conv},
    )
    await db.commit()

    return _salida(
        {**dict(fila), "full_name": ctx.user.full_name, "role": ctx.role,
         "leido_por": []},
        ctx.patient_id,
    )


class ReadOut(BaseModel):
    marked:  int
    read_at: datetime


@router.post("/patients/{patient_id}/chat/read", response_model=ReadOut)
async def mark_read(
    ctx: PatientContext = Depends(get_patient_member()),
    db: AsyncSession = Depends(get_db),
):
    """Marca como leido todo el chat del paciente.

    Es lo que la pantalla llama al abrir la conversacion, sin indicar
    mensajes: se marca lo que esta pendiente para quien pide.

    Solo se tocan los acuses que todavia no tienen fecha. Si se escribiera
    siempre, abrir la pantalla dos veces movería la hora de lectura de
    mensajes vistos ayer, y esa hora es justamente lo que le dice a la
    familia cuando la cuidadora se entero de algo.
    """
    conv = await _conversacion(db, ctx.patient_id)
    if conv is None:
        return ReadOut(marked=0, read_at=datetime.now(timezone.utc))

    filas = (
        await db.execute(
            text(
                """
                UPDATE message_receipts mr
                   SET read_at = now(),
                       delivered_at = coalesce(mr.delivered_at, now())
                  FROM messages m
                 WHERE m.id = mr.message_id
                   AND m.conversation_id = :conv
                   AND mr.recipient_id = :uid
                   AND mr.read_at IS NULL
                RETURNING mr.read_at
                """
            ),
            {"conv": conv, "uid": ctx.user.user_id},
        )
    ).scalars().all()
    await db.commit()

    return ReadOut(
        marked=len(filas),
        read_at=filas[0] if filas else datetime.now(timezone.utc),
    )

# ---------------------------------------------------------------------------
# RF-54: WebSocket de chat en tiempo real
# ---------------------------------------------------------------------------
# CÓMO FUNCIONA
#   1. El cliente abre ws://host/api/v1/patients/{id}/chat/ws?token=<jwt>
#   2. El backend valida el JWT y comprueba que el usuario pertenece al
#      círculo del paciente.
#   3. Se registra la sesión en chat_ws_sessions.
#   4. El backend abre una conexión asyncpg dedicada y hace LISTEN
#      "chat_new_message". Cuando llega un NOTIFY (disparado por el trigger
#      de la tabla messages), se consulta el mensaje completo y se envía al
#      cliente por el WebSocket.
#   5. Al cerrar la conexión (normal o por error) se borra la sesión.
#
# POR QUÉ LISTEN/NOTIFY Y NO POLLING
#   El cliente ya usaba polling (GET /chat/messages cada N segundos).
#   LISTEN/NOTIFY entrega el aviso en milisegundos y sin tráfico innecesario.
#   No necesita Redis ni un broker externo: Postgres ya está.
#
# PING/PONG
#   El cliente manda texto "ping" y el servidor responde "pong".
#   Sirve para detectar conexiones muertas sin esperar el timeout del SO.

import asyncio
import json
import os

import asyncpg
from fastapi import WebSocket, WebSocketDisconnect
from app.security import decode_access_token


@router.websocket("/patients/{patient_id}/chat/ws")
async def chat_websocket(
    patient_id: str,
    websocket: WebSocket,
    token: str = "",
):
    """WebSocket del chat en tiempo real (RF-54).

    El token JWT va como query param: ws://...?token=<access_token>
    Los WebSockets no permiten cabeceras Authorization en el handshake
    del navegador, así que es la forma estándar.
    """
    # --- Autenticación ---
    try:
        payload = decode_access_token(token)
        user_id = payload.get("sub")
        if not user_id:
            await websocket.close(code=4001)
            return
    except Exception:
        await websocket.close(code=4001)
        return

    # --- Autorización: miembro del círculo ---
    from app.db import engine as _engine
    async with _engine.connect() as conn:
        miembro = (await conn.execute(
            text(
                """
                SELECT role FROM patient_members
                WHERE patient_id = CAST(:pid AS uuid)
                  AND user_id    = CAST(:uid AS uuid)
                  AND removed_at IS NULL
                """
            ),
            {"pid": patient_id, "uid": user_id},
        )).scalar()

    if miembro is None:
        await websocket.close(code=4003)
        return

    await websocket.accept()

    # --- Registrar sesión ---
    async with _engine.begin() as conn:
        await conn.execute(
            text(
                """
                INSERT INTO chat_ws_sessions
                    (user_id, patient_id, worker_pid)
                VALUES (CAST(:uid AS uuid), CAST(:pid AS uuid), :wpid)
                ON CONFLICT (user_id, patient_id)
                DO UPDATE SET worker_pid = EXCLUDED.worker_pid,
                              connected_at = now(),
                              last_ping_at = now()
                """
            ),
            {"uid": user_id, "pid": patient_id, "wpid": os.getpid()},
        )

    # --- Conexión asyncpg dedicada para LISTEN ---
    from app.config import get_settings
    s = get_settings()
    dsn = (
        f"postgresql://{s.postgres_user}:{s.postgres_password}"
        f"@{s.postgres_host}:{s.postgres_port}/{s.postgres_db}"
    )

    pg_conn = await asyncpg.connect(dsn)

    # Cola local para pasar los eventos del callback (hilo asyncpg) al loop.
    queue: asyncio.Queue = asyncio.Queue()

    def _on_notify(conn_ref, pid, channel, payload_str):
        try:
            data = json.loads(payload_str)
            if str(data.get("conversation_id")) or True:
                queue.put_nowait(data)
        except Exception:
            pass

    await pg_conn.add_listener("chat_new_message", _on_notify)

    async def _leer_ws():
        """Recibe ping del cliente; devuelve pong. Cierra al desconectar."""
        while True:
            try:
                msg = await websocket.receive_text()
                if msg == "ping":
                    await websocket.send_text("pong")
                    # Actualizar last_ping_at.
                    async with _engine.begin() as conn:
                        await conn.execute(
                            text(
                                "UPDATE chat_ws_sessions SET last_ping_at = now() "
                                "WHERE user_id = CAST(:uid AS uuid) "
                                "  AND patient_id = CAST(:pid AS uuid)"
                            ),
                            {"uid": user_id, "pid": patient_id},
                        )
            except WebSocketDisconnect:
                queue.put_nowait(None)  # señal de cierre
                return
            except Exception:
                queue.put_nowait(None)
                return

    async def _enviar_eventos():
        """Lee la cola y manda los mensajes nuevos al cliente."""
        while True:
            evento = await queue.get()
            if evento is None:
                return  # cierre
            # Filtrar: solo la conversación del paciente correcto.
            # El NOTIFY lleva conversation_id; verificamos que pertenezca
            # al paciente de esta conexión para no cruzar conversaciones.
            async with _engine.connect() as conn:
                conv_pid = (await conn.execute(
                    text(
                        "SELECT patient_id FROM conversations "
                        "WHERE id = CAST(:cid AS uuid)"
                    ),
                    {"cid": str(evento.get("conversation_id", ""))},
                )).scalar()

            if str(conv_pid) != patient_id:
                continue  # no es esta conversación

            # Leer el mensaje completo para enviarlo.
            async with _engine.connect() as conn:
                fila = (await conn.execute(
                    text(
                        """
                        SELECT m.id, m.sender_id, m.kind, m.body, m.file_id,
                               m.created_at, u.full_name,
                               pm.role
                        FROM messages m
                        JOIN users u ON u.id = m.sender_id
                        LEFT JOIN patient_members pm
                               ON pm.patient_id = CAST(:pid AS uuid)
                              AND pm.user_id = m.sender_id
                        WHERE m.id = CAST(:mid AS uuid)
                        """
                    ),
                    {"mid": str(evento.get("message_id", "")),
                     "pid": patient_id},
                )).mappings().first()

            if fila is None:
                continue

            out = _salida(
                {**dict(fila), "leido_por": []},
                patient_id,
            )
            try:
                await websocket.send_text(out.model_dump_json())
            except Exception:
                return

    try:
        await asyncio.gather(_leer_ws(), _enviar_eventos())
    finally:
        # Limpiar al desconectar.
        try:
            await pg_conn.remove_listener("chat_new_message", _on_notify)
            await pg_conn.close()
        except Exception:
            pass
        try:
            async with _engine.begin() as conn:
                await conn.execute(
                    text(
                        "DELETE FROM chat_ws_sessions "
                        "WHERE user_id = CAST(:uid AS uuid) "
                        "  AND patient_id = CAST(:pid AS uuid)"
                    ),
                    {"uid": user_id, "pid": patient_id},
                )
        except Exception:
            pass
