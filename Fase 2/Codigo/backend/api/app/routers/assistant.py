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


# ---------------------------------------------------------------------------
# Limite del plan
# ---------------------------------------------------------------------------
async def _cobrar_consulta(db: AsyncSession, user_id: str) -> None:
    """Descuenta una consulta del cupo mensual del plan (ai_queries_month).

    El plan gratis trae el limite en cero, asi que el asistente es de pago
    y eso se decide aca, no en la pantalla. Sin suscripcion activa tampoco
    hay cupo.

    El contador se incrementa en la misma sentencia que lo lee, con ON
    CONFLICT, para que dos preguntas enviadas a la vez no gasten el mismo
    cupo dos veces.
    """
    suscripcion = (
        await db.execute(
            text(
                """
                SELECT s.id, s.plan_id
                FROM subscriptions s
                WHERE s.user_id = :uid
                  AND s.status = 'active'
                  AND (s.current_period_end IS NULL
                       OR s.current_period_end > now())
                ORDER BY s.started_at DESC
                LIMIT 1
                """
            ),
            {"uid": user_id},
        )
    ).mappings().first()

    sin_cupo = ApiError(
        status_code=402, code="PLAN_LIMIT_REACHED",
        message="Tu plan no incluye mas consultas al asistente este mes.",
    )

    if suscripcion is None:
        raise sin_cupo

    tope = (
        await db.execute(
            text("SELECT limit_value FROM plan_limits "
                 "WHERE plan_id = :pid AND limit_key = 'ai_queries_month'"),
            {"pid": str(suscripcion["plan_id"])},
        )
    ).scalar()

    # NULL es sin tope. Cero es no incluido, que no es lo mismo.
    if tope == 0:
        raise sin_cupo

    usado = (
        await db.execute(
            text(
                """
                INSERT INTO usage_counters (
                    subscription_id, limit_key, period_start, used_value,
                    last_used_at
                ) VALUES (
                    :sid, 'ai_queries_month',
                    -- El mes sale de la zona de la conexion (db.py). Antes
                    -- se forzaba UTC aqui, y las tres primeras horas del dia
                    -- 1 en Chile todavia son del mes anterior alla: las
                    -- consultas de esa madrugada se cobraban al cupo de un
                    -- mes que ya habia cerrado.
                    CAST(date_trunc('month', now()) AS date),
                    1, now()
                )
                ON CONFLICT (subscription_id, limit_key, period_start)
                DO UPDATE SET used_value = usage_counters.used_value + 1,
                              last_used_at = now(),
                              updated_at = now()
                RETURNING used_value
                """
            ),
            {"sid": str(suscripcion["id"])},
        )
    ).scalar()

    if tope is not None and usado > tope:
        # Se pasa del cupo. Se deshace el incremento para que el contador
        # no siga subiendo con cada intento rechazado y el mes siguiente
        # arranque con una cifra que nadie consumio.
        await db.execute(
            text(
                """
                UPDATE usage_counters
                   SET used_value = used_value - 1
                 WHERE subscription_id = :sid
                   AND limit_key = 'ai_queries_month'
                   AND period_start = CAST(date_trunc('month', now()) AS date)
                """
            ),
            {"sid": str(suscripcion["id"])},
        )
        await db.commit()
        raise sin_cupo


# ---------------------------------------------------------------------------
# Preguntar
# ---------------------------------------------------------------------------
class AskIn(BaseModel):
    text:            str = Field(min_length=1, max_length=2000)
    conversation_id: UUID | None = None

    _limpiar = field_validator("text")(_texto_con_contenido)


class CitationOut(BaseModel):
    label:     str
    reference: str | None = None
    url:       str | None = None


class AssistantMessageOut(BaseModel):
    id:         UUID
    role:       str
    text:       str
    created_at: datetime
    citations:  list[CitationOut]


class ReplyOut(BaseModel):
    conversation_id: UUID
    message:         AssistantMessageOut


def _titulo(pregunta: str) -> str:
    limpio = " ".join(pregunta.split())
    return limpio[:117] + "..." if len(limpio) > 120 else limpio


def _dosis(m) -> str:
    """Como se escribe la dosis de un medicamento.

    dose_text es el texto libre que escribio quien lo cargo ('media
    tableta', 'segun necesidad'), y cuando existe manda sobre la cantidad
    numerica, porque es lo que dice la receta.
    """
    if m["dose_text"]:
        return f"{m['name']} {m['dose_text']}"
    if m["dose_amount"] is not None:
        return f"{m['name']} {m['dose_amount']} {m['dose_unit'] or ''}".strip()
    return m["name"]


async def _contexto(db: AsyncSession, patient_id: str) -> tuple[str, list]:
    """Arma el resumen del expediente que ve el modelo, y sus fuentes.

    El modelo NO consulta la base. Recibe un texto armado aca, con lo que
    esta persona ya tiene derecho a ver, y nada mas. Asi el control de
    acceso sigue siendo del motor y de la API, y no depende de que el
    modelo se porte bien.

    Cada bloque deja registrada su fuente para poder citarla despues: una
    respuesta sobre salud sin de donde salio no sirve para decidir nada.
    """
    from app.assistant_provider import Fuente

    partes: list[str] = []
    fuentes: list = []

    paciente = (
        await db.execute(
            text(
                """
                SELECT id, first_name, last_name, birth_date, sex
                FROM patients WHERE id = :pid
                """
            ),
            {"pid": patient_id},
        )
    ).mappings().first()
    if paciente:
        edad = (
            await db.execute(
                text("SELECT CAST(extract(year FROM age(CAST(:fecha AS date))) AS int)"),
                {"fecha": paciente["birth_date"]},
            )
        ).scalar()
        partes.append(
            f"Paciente: {paciente['first_name']} {paciente['last_name']}, "
            f"{edad} anios, sexo {paciente['sex']}."
        )
        fuentes.append(Fuente(tabla="patients", id=str(paciente["id"]),
                              label="Datos del paciente"))

    condiciones = (
        await db.execute(
            text("SELECT condition FROM patient_conditions "
                 "WHERE patient_id = :pid AND deleted_at IS NULL "
                 "ORDER BY diagnosed_at DESC NULLS LAST LIMIT 20"),
            {"pid": patient_id},
        )
    ).scalars().all()
    if condiciones:
        partes.append("Condiciones registradas: " + ", ".join(condiciones) + ".")

    medicamentos = (
        await db.execute(
            text(
                """
                SELECT id, name, dose_amount, dose_unit, dose_text
                FROM medications
                WHERE patient_id = :pid
                  AND discontinued_at IS NULL
                  AND (end_date IS NULL OR end_date >= current_date)
                ORDER BY name LIMIT 30
                """
            ),
            {"pid": patient_id},
        )
    ).mappings().all()
    if medicamentos:
        partes.append(
            "Medicamentos vigentes: "
            + "; ".join(_dosis(m) for m in medicamentos) + "."
        )
        for m in medicamentos[:5]:
            fuentes.append(Fuente(tabla="medications", id=str(m["id"]),
                                  label="Medicamentos"))

    adherencia = (
        await db.execute(
            text(
                """
                SELECT count(*) FILTER (WHERE d.status = 'taken') AS tomadas,
                       count(*) AS total
                FROM scheduled_doses d
                JOIN medications m ON m.id = d.medication_id
                WHERE m.patient_id = :pid
                  AND d.scheduled_at >= now() - interval '7 days'
                  AND d.scheduled_at <= now()
                """
            ),
            {"pid": patient_id},
        )
    ).mappings().first()
    if adherencia and adherencia["total"]:
        partes.append(
            f"Dosis de los ultimos 7 dias: {adherencia['tomadas']} tomadas "
            f"de {adherencia['total']} programadas."
        )

    vitales = (
        await db.execute(
            text(
                """
                SELECT DISTINCT ON (v.type)
                       v.id, v.type, v.value, v.value_secondary,
                       v.measured_at, t.label, t.unit
                FROM vital_readings v
                JOIN vital_types t ON t.code = v.type
                WHERE v.patient_id = :pid
                  AND v.measured_at >= now() - interval '14 days'
                ORDER BY v.type, v.measured_at DESC
                """
            ),
            {"pid": patient_id},
        )
    ).mappings().all()
    if vitales:
        partes.append(
            "Ultimas mediciones: "
            + "; ".join(
                f"{v['label']} {v['value']}"
                + (f"/{v['value_secondary']}" if v["value_secondary"] is not None else "")
                + f" {v['unit']} ({v['measured_at']:%d-%m %H:%M})"
                for v in vitales
            ) + "."
        )
        for v in vitales[:5]:
            fuentes.append(Fuente(tabla="vital_readings", id=str(v["id"]),
                                  label="Mediciones"))

    observaciones = (
        await db.execute(
            text(
                """
                SELECT id, category, note, observed_at
                FROM care_observations
                WHERE patient_id = :pid AND deleted_at IS NULL
                ORDER BY observed_at DESC LIMIT 10
                """
            ),
            {"pid": patient_id},
        )
    ).mappings().all()
    if observaciones:
        partes.append(
            "Bitacora reciente: "
            + " | ".join(f"{o['observed_at']:%d-%m} [{o['category']}] {o['note']}"
                         for o in observaciones) + "."
        )
        for o in observaciones[:5]:
            fuentes.append(Fuente(tabla="care_observations", id=str(o["id"]),
                                  label="Bitacora"))

    alertas = (
        await db.execute(
            text(
                """
                SELECT id, title, severity, created_at
                FROM alerts
                WHERE patient_id = :pid AND status = 'active'
                ORDER BY created_at DESC LIMIT 10
                """
            ),
            {"pid": patient_id},
        )
    ).mappings().all()
    if alertas:
        partes.append(
            "Alertas activas: "
            + "; ".join(f"{a['title']} ({a['severity']})" for a in alertas) + "."
        )
        for a in alertas:
            fuentes.append(Fuente(tabla="alerts", id=str(a["id"]),
                                  label="Alertas"))

    return "\n".join(partes), fuentes


@router.post("/patients/{patient_id}/assistant/messages",
             response_model=ReplyOut, status_code=201)
async def ask(
    payload: AskIn,
    ctx: PatientContext = Depends(get_patient_member()),
    db: AsyncSession = Depends(get_db),
):
    """Pregunta al asistente sobre el expediente del paciente.

    El orden importa. Primero se comprueba que haya proveedor, despues se
    cobra el cupo del plan y recien al final se guarda: nadie paga una
    consulta que el sistema no pudo responder.
    """
    import time

    from app.assistant_provider import AssistantNotConfigured, get_assistant

    proveedor = get_assistant()
    if not proveedor.disponible:
        raise ApiError(
            status_code=503, code="ASSISTANT_UNAVAILABLE",
            message="El asistente no esta disponible en este momento.",
            details=[{"field": "assistant",
                      "message": "No hay un proveedor de modelo configurado."}],
        )

    conv = (
        await db.execute(
            text(
                """
                SELECT id, title FROM conversations
                WHERE patient_id = :pid AND type = 'assistant' AND user_id = :uid
                """
            ),
            {"pid": ctx.patient_id, "uid": ctx.user.user_id},
        )
    ).mappings().first()

    # La pantalla puede mandar un conversation_id. Si manda uno que no es
    # suyo, no se le responde sobre esa conversacion.
    if payload.conversation_id is not None and (
        conv is None or conv["id"] != payload.conversation_id
    ):
        raise _NO_EXISTE

    await _cobrar_consulta(db, ctx.user.user_id)

    contexto, fuentes = await _contexto(db, ctx.patient_id)

    historial = []
    if conv is not None:
        previas = (
            await db.execute(
                text(
                    """
                    SELECT query_text, response_text
                    FROM assistant_queries
                    WHERE conversation_id = :conv
                    ORDER BY created_at DESC
                    LIMIT 6
                    """
                ),
                {"conv": str(conv["id"])},
            )
        ).mappings().all()
        for p in reversed(previas):
            historial.append({"role": "user", "content": p["query_text"]})
            historial.append({"role": "assistant", "content": p["response_text"]})

    inicio = time.monotonic()
    try:
        respuesta = await proveedor.responder(
            pregunta=payload.text, contexto=contexto,
            rol=ctx.role, historial=historial,
        )
    except AssistantNotConfigured:
        raise ApiError(
            status_code=503, code="ASSISTANT_UNAVAILABLE",
            message="El asistente no esta disponible en este momento.",
        )
    except Exception:
        # Cualquier falla del proveedor es un 503 y no un 500: el problema
        # no esta en la peticion del usuario.
        raise ApiError(
            status_code=503, code="ASSISTANT_ERROR",
            message="El asistente no pudo responder. Intenta de nuevo en un momento.",
        )
    latencia = int((time.monotonic() - inicio) * 1000)

    if conv is None:
        conv_id = (
            await db.execute(
                text(
                    """
                    INSERT INTO conversations (
                        patient_id, type, user_id, title, last_message_at
                    ) VALUES (:pid, 'assistant', :uid, :titulo, now())
                    RETURNING id
                    """
                ),
                {"pid": ctx.patient_id, "uid": ctx.user.user_id,
                 "titulo": _titulo(payload.text)},
            )
        ).scalar()
    else:
        conv_id = conv["id"]
        await db.execute(
            text(
                """
                UPDATE conversations
                   SET last_message_at = now(),
                       updated_at = now(),
                       title = coalesce(title, :titulo)
                 WHERE id = :cid
                """
            ),
            {"cid": str(conv_id), "titulo": _titulo(payload.text)},
        )

    # frozen_role_name guarda el rol que la persona tenia al preguntar. Si
    # manana deja de ser cuidadora, la consulta sigue diciendo con que rol
    # accedio al expediente, que es lo que una auditoria necesita saber.
    consulta = (
        await db.execute(
            text(
                """
                INSERT INTO assistant_queries (
                    conversation_id, conversation_type, user_id,
                    frozen_role_name, query_text, response_text, latency_ms
                ) VALUES (
                    :conv, 'assistant', :uid, :rol, :pregunta, :respuesta, :ms
                )
                RETURNING id, created_at
                """
            ),
            {"conv": str(conv_id), "uid": ctx.user.user_id, "rol": ctx.role,
             "pregunta": payload.text, "respuesta": respuesta.texto,
             "ms": latencia},
        )
    ).mappings().first()

    # Las fuentes son las del expediente que se le mostro al modelo. No se
    # le pregunta al modelo cuales uso: diria las que quiera.
    for f in fuentes:
        await db.execute(
            text(
                """
                INSERT INTO assistant_citations (
                    query_id, source_table_name, source_record_id
                ) VALUES (:qid, :tabla, :rid)
                """
            ),
            {"qid": str(consulta["id"]), "tabla": f.tabla, "rid": f.id},
        )

    await db.commit()

    return ReplyOut(
        conversation_id=conv_id,
        message=AssistantMessageOut(
            id=consulta["id"],
            role="assistant",
            text=respuesta.texto,
            created_at=consulta["created_at"],
            citations=[CitationOut(label=f.label, reference=f.tabla)
                       for f in _unicas(fuentes)],
        ),
    )


def _unicas(fuentes: list) -> list:
    """Una cita por tipo de fuente, no una por fila.

    La pantalla muestra las fuentes como etiquetas bajo la respuesta.
    Cinco veces 'Medicamentos' no le dice nada a nadie.
    """
    vistas = {}
    for f in fuentes:
        vistas.setdefault(f.label, f)
    return list(vistas.values())


class MessagesOut(BaseModel):
    items: list[AssistantMessageOut]


# Nombre legible de cada tabla del expediente, para mostrar la fuente.
_ETIQUETA = {
    "patients":           "Datos del paciente",
    "patient_conditions": "Condiciones",
    "medications":        "Medicamentos",
    "scheduled_doses":    "Dosis",
    "vital_readings":     "Mediciones",
    "care_observations":  "Bitacora",
    "alerts":             "Alertas",
    "medical_documents":  "Documentos",
}


@router.get("/assistant/conversations/{conversation_id}/messages",
            response_model=MessagesOut)
async def conversation_messages(
    conversation_id: UUID,
    user: CurrentUser = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Historial de una conversacion con el asistente.

    Cada fila de assistant_queries es una pregunta y su respuesta, porque
    asi quedo la tabla: una consulta es un hecho con las dos partes. La
    pantalla en cambio dibuja mensajes sueltos, asi que cada fila se abre
    en dos, el de la persona y el del asistente.

    La ruta no lleva el paciente. Se comprueba que la conversacion sea de
    quien pide, que en el asistente es mas estricto que la membresia: no
    basta con ser del circulo, tiene que ser su propia conversacion.
    """
    conv = (
        await db.execute(
            text(
                """
                SELECT id, user_id FROM conversations
                WHERE id = :cid AND type = 'assistant'
                """
            ),
            {"cid": str(conversation_id)},
        )
    ).mappings().first()

    if conv is None or str(conv["user_id"]) != user.user_id:
        raise _NO_EXISTE

    filas = (
        await db.execute(
            text(
                """
                SELECT q.id, q.query_text, q.response_text, q.created_at,
                       coalesce(c.tablas, ARRAY[]::text[]) AS tablas
                FROM assistant_queries q
                LEFT JOIN LATERAL (
                    SELECT array_agg(DISTINCT ac.source_table_name) AS tablas
                    FROM assistant_citations ac
                    WHERE ac.query_id = q.id
                ) c ON true
                WHERE q.conversation_id = :cid
                ORDER BY q.created_at
                LIMIT 200
                """
            ),
            {"cid": str(conversation_id)},
        )
    ).mappings().all()

    mensajes: list[AssistantMessageOut] = []
    for f in filas:
        mensajes.append(AssistantMessageOut(
            id=f["id"], role="user", text=f["query_text"],
            created_at=f["created_at"], citations=[],
        ))
        mensajes.append(AssistantMessageOut(
            id=f["id"], role="assistant", text=f["response_text"],
            created_at=f["created_at"],
            citations=[CitationOut(label=_ETIQUETA.get(t, t), reference=t)
                       for t in sorted(f["tablas"])],
        ))

    return MessagesOut(items=mensajes)
