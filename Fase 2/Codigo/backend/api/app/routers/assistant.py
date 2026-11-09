"""Asistente de IA sobre el expediente del paciente.

Endpoints que la aplicacion ya consume:

    GET  /patients/{id}/assistant/conversations
    POST /patients/{id}/assistant/messages
    GET  /assistant/conversations/{id}/messages

La conversacion con el asistente es privada de cada persona:
ux_conversations_assistant deja una por paciente y usuario, asi que lo que
le pregunta la cuidadora no lo ve la familia ni al reves.
"""
import re
from datetime import datetime, timezone
from uuid import UUID

from fastapi import APIRouter, Depends
from pydantic import BaseModel, Field, field_validator
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

from app.assistant_safety import (
    limpiar_texto_libre,
    pide_criterio_clinico,
    sanitizar_respuesta,
)
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


async def _ficha_base(db: AsyncSession, patient_id: str) -> tuple[str, list]:
    """Datos de cabecera del expediente: quien es, que tiene, que toma hoy.

    Van en toda consulta, sin importar la pregunta, porque son el marco para
    leer cualquier dato: la edad y las condiciones cambian como se entiende
    una medicion, y los medicamentos vigentes y las alertas activas es lo que
    cualquiera necesita tener presente. El historico que pide la pregunta se
    agrega aparte, en _contexto.
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
        # Se nombran como estan cargadas: es lo registrado en el expediente,
        # no un diagnostico que haga el asistente.
        partes.append("Condiciones registradas en el expediente: "
                      + ", ".join(c.replace("_", " ") for c in condiciones) + ".")

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

    # La adherencia no va en la ficha: el bloque de dosis del periodo
    # consultado la trae con sus totales. Con las dos cifras a la vista (7
    # dias fijos y el periodo de la pregunta) el modelo las mezclaba.

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
            "Alertas activas ahora (sin atender todavia): "
            + "; ".join(f"{a['title']} ({a['severity']})" for a in alertas) + "."
        )
    else:
        partes.append("Alertas activas ahora: ninguna.")
        for a in alertas:
            fuentes.append(Fuente(tabla="alerts", id=str(a["id"]),
                                  label="Alertas"))

    # Texto de los documentos del expediente, el que dejo el OCR. Sin esto
    # el asistente no puede responder sobre una receta o un examen aunque la
    # foto este subida: para el modelo una imagen no existe.
    #
    # Se recortan los documentos a 1200 caracteres cada uno y se toman los
    # cuatro mas recientes. El examen de laboratorio de dos paginas se come
    # el contexto entero, y lo que importa de el casi siempre esta arriba.
    documentos = (
        await db.execute(
            text(
                """
                SELECT f.id,
                       COALESCE(NULLIF(f.original_name, ''), 'documento')
                           AS nombre,
                       to_char(f.created_at, 'DD-MM-YYYY') AS cuando,
                       left(o.texto, 1200) AS texto,
                       length(o.texto)     AS largo
                FROM file_ocr o
                JOIN files f ON f.id = o.file_id
                WHERE f.patient_id = :pid
                  AND f.scope = 'patient'
                  AND f.status = 'stored'
                  AND f.purged_at IS NULL
                ORDER BY f.created_at DESC
                LIMIT 4
                """
            ),
            {"pid": patient_id},
        )
    ).mappings().all()
    for d in documentos:
        recorte = d["texto"].strip()
        if len(recorte) < 20:
            # Una foto sin texto legible. Meterla solo gastaria contexto.
            continue
        cola = " (recortado)" if d["largo"] > len(recorte) else ""
        partes.append(
            f"Documento del expediente \"{d['nombre']}\" ({d['cuando']}), "
            f"texto leido de la imagen{cola}: {recorte}"
        )
        fuentes.append(Fuente(tabla="files", id=str(d["id"]),
                              label=f"Documento: {d['nombre']}"))

    return "\n".join(partes), fuentes


async def _contexto(db: AsyncSession, patient_id: str, pregunta: str,
                    pregunta_anterior: str | None = None) -> tuple[str, list]:
    """Expediente que ve el modelo: la ficha base mas lo que pide la pregunta.

    El modelo NO consulta la base. Recibe un texto armado aca, con lo que
    esta persona ya tiene derecho a ver, y nada mas: el control de acceso lo
    hizo la API al validar la membresia (get_patient_member), no el modelo.

    La ficha base (quien es, condiciones, medicamentos, alertas activas) va
    siempre. Encima se agrega el bloque historico que corresponde al periodo
    y tema de la pregunta, para que "la presion de la semana pasada" o "se
    olvido una dosis en el mes" tengan datos detras y no solo el ultimo valor.

    Las fuentes de cada bloque se devuelven para citarlas: una respuesta
    sobre salud sin de donde salio no sirve para decidir nada.
    """
    from app.assistant_context import (
        contexto_historico,
        heredar_tema,
        interpretar_pregunta,
    )
    from app.fechas import hoy

    base, fuentes = await _ficha_base(db, patient_id)

    # Sin la fecha de hoy el modelo la deducia del ultimo dato que veia y
    # llamaba "hoy" a un dia de la semana pasada.
    dia = hoy()
    _DIAS = ["lunes", "martes", "miércoles", "jueves", "viernes", "sábado",
             "domingo"]
    fecha_hoy = f"Fecha de hoy: {_DIAS[dia.weekday()]} {dia.strftime('%d-%m-%Y')}."
    base = f"{fecha_hoy}\n{base}" if base else fecha_hoy

    consulta = interpretar_pregunta(pregunta, dia)
    consulta = heredar_tema(consulta, pregunta, pregunta_anterior, dia)
    # "Puedo subirle el losartan?" no nombra la presion, pero la respuesta
    # honesta necesita mostrarla ("la ultima presion registrada fue...").
    # Si la pregunta pide criterio clinico y no trae mediciones, se agregan
    # todas las del periodo.
    if pide_criterio_clinico(pregunta) and not consulta.vitales:
        from dataclasses import replace
        consulta = replace(consulta, general=True)
    historico, fuentes_hist = await contexto_historico(db, patient_id, consulta)
    fuentes.extend(fuentes_hist)

    partes = [p for p in (base, historico) if p]

    # La pregunta que ve el modelo lleva el periodo resuelto y, si es un
    # seguimiento ("y la semana pasada?"), la pregunta anterior: con la
    # frase suelta el modelo contestaba "no hay datos" teniendolos delante.
    # Se dice que el periodo YA esta resuelto: con "periodo consultado: X" el
    # modelo leia "la semana pasada" como la semana anterior a X.
    aclaracion = (f"Nota del sistema: el periodo de esta pregunta ya fue "
                  f"calculado y es {consulta.etiqueta}; los datos del bloque "
                  f"'Datos del periodo consultado' son exactamente los que "
                  f"pide. Respondela con ellos")
    if pregunta_anterior and len(pregunta.split()) <= 6:
        aclaracion += (f". Es continuacion de la pregunta anterior "
                       f"\"{limpiar_texto_libre(pregunta_anterior, 150)}\": "
                       f"responde lo mismo, pero para este periodo")
    pregunta_modelo = f"{pregunta}\n({aclaracion}.)"
    return "\n\n".join(partes), fuentes, pregunta_modelo


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

    previas = []
    if conv is not None:
        previas = (
            await db.execute(
                text(
                    """
                    SELECT query_text
                    FROM assistant_queries
                    WHERE conversation_id = :conv
                    ORDER BY created_at DESC
                    LIMIT 6
                    """
                ),
                {"conv": str(conv["id"])},
            )
        ).mappings().all()

    contexto, fuentes, pregunta_modelo = await _contexto(
        db, ctx.patient_id, payload.text,
        previas[0]["query_text"] if previas else None,
    )

    # Si la pregunta pide diagnosticar, interpretar un valor o indicar un
    # tratamiento, se le recuerda al modelo el limite antes de responder.
    # Es un aviso, no un bloqueo: igual presenta los datos registrados y
    # deriva al medico. El filtro de salida es la red que no depende de que
    # el modelo haga caso.
    if pide_criterio_clinico(payload.text):
        contexto += (
            "\n\n[Nota: la pregunta pide una interpretacion clinica, un "
            "diagnostico o una indicacion de tratamiento. No califiques los "
            "valores ni indiques dosis, pero SI entrega los datos registrados "
            "que correspondan (fecha, promedio, minimo y maximo). Despues "
            "recuerda que interpretarlos le corresponde al medico tratante.]"
        )

    # Solo las preguntas anteriores, no las respuestas. Con las respuestas el
    # modelo copiaba lo que habia contestado antes (con cifras y fechas de
    # ese dia) en vez de leer el expediente de ahora, y un error viejo se
    # repetia para siempre. Las preguntas bastan para entender un
    # seguimiento como "y ayer?".
    historial = []
    if previas:
        preguntas = [limpiar_texto_libre(p["query_text"], 200)
                     for p in reversed(previas)]
        historial.append({
            "role": "system",
            "content": (
                "Preguntas anteriores de esta conversacion (solo para "
                "entender a que se refiere la pregunta nueva; los datos "
                "salen unicamente del expediente de arriba): "
                + " | ".join(preguntas)
            ),
        })

    inicio = time.monotonic()
    try:
        respuesta = await proveedor.responder(
            pregunta=pregunta_modelo, contexto=contexto,
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

    # Ultima barrera: aunque el prompt lo prohibe, si el modelo deslizo un
    # diagnostico o una indicacion de dosis, aqui se quita y se deja la
    # derivacion al medico. No depende de que el modelo haya obedecido.
    # Con el expediente al lado se comprueba ademas que cada cifra y fecha
    # de la respuesta este en el, y se respetan las citas textuales.
    seguro = sanitizar_respuesta(respuesta.texto, contexto)
    texto_final = seguro.texto

    # Ante "es normal su oxigenacion?" el modelo a veces solo se niega y no
    # entrega los datos que tiene delante. La negativa es correcta, pero la
    # familia se queda sin nada: se anexan las mediciones del expediente tal
    # cual, sin pasar por el modelo.
    # Se mira si la respuesta trae algun valor medido (no basta una fecha:
    # "no hay datos para el 02-11 al 08-11" tiene cifras y ningun dato).
    if pide_criterio_clinico(payload.text):
        registradas = _lineas_mediciones(contexto)
        valores = {v for ln in registradas
                   for v in re.findall(r"\d+(?:\.\d+)?", ln.split(":", 1)[-1])
                   if len(v) >= 2}
        trae_valor = any(re.search(rf"(?<![\d.]){re.escape(v)}(?![\d])",
                                   texto_final.replace(",", "."))
                         for v in valores)
        if registradas and not trae_valor:
            # "No hay datos de X" junto a los datos de X se contradice: esa
            # frase era falsa y se quita.
            texto_final = re.sub(
                r"[^.\n]*\b(?:no hay|sin)\s+(?:datos|mediciones|registros|"
                r"informaci[oó]n)\b[^.\n]*\.?\s*", "", texto_final,
                flags=re.IGNORECASE).strip()
            texto_final = (
                (f"{texto_final}\n\n" if texto_final else
                 "No puedo decir si estos valores son normales; eso lo "
                 "evalúa el médico tratante.\n\n")
                + "Lo registrado en el expediente:\n" + "\n".join(registradas))

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
             "pregunta": payload.text, "respuesta": texto_final,
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
            text=texto_final,
            created_at=consulta["created_at"],
            citations=[CitationOut(label=f.label, reference=f.tabla)
                       for f in _unicas(fuentes)],
        ),
    )


def _lineas_mediciones(contexto: str) -> list[str]:
    """Las lineas de resumen del bloque 'Mediciones del período', sin la
    viñeta ni las series diarias, para mostrarlas tal cual."""
    lineas, dentro = [], False
    for ln in contexto.split("\n"):
        if ln.startswith("Mediciones del período"):
            dentro = True
            continue
        if dentro:
            if ln.startswith("- "):
                if "sin mediciones registradas" not in ln:
                    lineas.append(ln[2:].strip())
            elif not ln.startswith("  "):
                break
    return lineas[:8]


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
    "shift_notes":        "Relevos",
    "incidents":          "Incidentes",
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
