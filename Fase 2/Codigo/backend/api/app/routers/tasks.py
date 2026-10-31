"""Tareas de cuidado.

Endpoints que la aplicacion ya consume:

    GET  /patients/{id}/tasks
    POST /patients/{id}/tasks
    POST /tasks/{id}/status

Tres cosas no calzan entre la pantalla y la tabla, y se resuelven aca:

    estado     la pantalla usa 'done' y la columna guarda 'completed'
    fecha      la pantalla manda un instante completo y la tabla guarda
               due_date y due_time por separado
    categoria  la pantalla manda la etiqueta en espanol
"""
from datetime import date, datetime, time, timezone
from uuid import UUID

from fastapi import APIRouter, Depends
from pydantic import BaseModel, Field, field_validator
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

from app.db import get_db
from app.deps import CurrentUser, PatientContext, get_current_user, get_patient_member
from app.errors import ApiError
from app.routers.logbook import _sin_tildes, _texto_con_contenido

router = APIRouter(prefix="/api/v1", tags=["tasks"])

# La pantalla llama 'done' a lo que la columna guarda como 'completed'. Son
# el mismo estado; traducir en los dos sentidos es mas barato que cambiar
# una lista cerrada que ya tiene datos.
_ESTADO_A_BASE = {"pending": "pending", "in_progress": "in_progress",
                  "done": "completed", "completed": "completed",
                  "cancelled": "cancelled"}
_ESTADO_A_APP = {"pending": "pending", "in_progress": "in_progress",
                 "completed": "done", "cancelled": "cancelled"}

_CATEGORIA = {
    "higiene":          "hygiene",
    "medicacion":       "medication",
    "alimentacion":     "food",
    "actividad fisica": "activity",
    "actividad":        "activity",
    "compania":         "company",
    "otros":            "other",
    "otro":             "other",
}
_CATEGORIAS_BASE = {"hygiene", "medication", "food", "activity",
                    "company", "other"}


def _resolver_categoria(valor: str | None) -> str | None:
    if valor is None or not valor.strip():
        return None
    plano = _sin_tildes(valor)
    if plano in _CATEGORIAS_BASE:
        return plano
    resuelta = _CATEGORIA.get(plano)
    if resuelta is None:
        raise ApiError(
            status_code=422, code="VALIDATION_ERROR",
            message="Esa categoria de tarea no existe.",
            details=[{"field": "category", "message": f"Valor recibido: {valor}."}],
        )
    return resuelta


def _due(fecha: date, hora: time | None) -> datetime | None:
    """Arma el instante que la pantalla espera en 'due'.

    La tabla guarda la fecha y la hora en columnas separadas, y la hora es
    opcional porque hay tareas del dia sin hora fija. Si no hay hora, no se
    inventa una: se devuelve el inicio del dia y la pantalla ya sabe
    mostrar 'Sin hora' cuando corresponde.
    """
    if hora is None:
        return datetime.combine(fecha, time(0, 0), tzinfo=timezone.utc)
    return datetime.combine(fecha, hora, tzinfo=timezone.utc)


class TaskOut(BaseModel):
    id:          UUID
    title:       str
    description: str | None
    due:         datetime | None
    status:      str
    category:    str | None


class TasksOut(BaseModel):
    items: list[TaskOut]


def _salida(f) -> TaskOut:
    return TaskOut(
        id=f["id"],
        title=f["title"],
        description=f["description"],
        due=_due(f["due_date"], f["due_time"]),
        status=_ESTADO_A_APP.get(f["status"], f["status"]),
        category=f["category"],
    )


@router.get("/patients/{patient_id}/tasks", response_model=TasksOut)
async def list_tasks(
    ctx: PatientContext = Depends(get_patient_member()),
    db: AsyncSession = Depends(get_db),
):
    """Tareas del paciente, las mas proximas primero.

    El orden va de lo mas cercano a lo mas lejano, porque una tarea es algo
    que hay que hacer y la pantalla la muestra para eso. Una tarea sin hora
    va al principio de su dia: es del dia completo, no de la medianoche.
    """
    filas = (
        await db.execute(
            text(
                """
                SELECT id, title, description, due_date, due_time,
                       status, category
                FROM care_tasks
                WHERE patient_id = :pid
                  AND deleted_at IS NULL
                ORDER BY due_date, due_time NULLS FIRST, created_at
                LIMIT 200
                """
            ),
            {"pid": ctx.patient_id},
        )
    ).mappings().all()

    return TasksOut(items=[_salida(f) for f in filas])


class TaskIn(BaseModel):
    title:       str = Field(min_length=1, max_length=150)
    description: str | None = None
    due:         datetime | None = None
    category:    str | None = None

    _limpiar = field_validator("title")(_texto_con_contenido)


@router.post("/patients/{patient_id}/tasks", response_model=TaskOut,
             status_code=201)
async def create_task(
    payload: TaskIn,
    ctx: PatientContext = Depends(get_patient_member(["caregiver", "family"])),
    db: AsyncSession = Depends(get_db),
):
    """Crea una tarea de cuidado.

    due_date es obligatoria en la tabla y la pantalla permite no poner
    fecha. Cuando no viene, la tarea es para hoy: es lo que significa una
    tarea sin fecha en una pantalla que muestra el dia.
    """
    categoria = _resolver_categoria(payload.category)

    if payload.due is None:
        fecha, hora = datetime.now(timezone.utc).date(), None
    else:
        momento = payload.due
        if momento.tzinfo is None:
            momento = momento.replace(tzinfo=timezone.utc)
        momento = momento.astimezone(timezone.utc)
        fecha = momento.date()
        # Medianoche exacta se guarda sin hora. Es lo que manda la pantalla
        # cuando el usuario elige fecha y no elige hora, y guardarla como
        # 00:00 haria aparecer una tarea "de la medianoche" que nadie puso.
        hora = None if (momento.hour == 0 and momento.minute == 0) else momento.time()

    descripcion = payload.description.strip() if payload.description else None

    # assigned_to_user_id es obligatorio y la pantalla no pide a quien se le
    # asigna. Si la crea la cuidadora, es para ella. Si la crea un familiar,
    # lo que esta haciendo es pedirle algo a la cuidadora, asi que se le
    # asigna a ella cuando hay una sola en el circulo. Con ninguna o con
    # varias no hay forma de saber a cual, y queda a nombre de quien la creo.
    asignado = ctx.user.user_id
    if ctx.role != "caregiver":
        cuidadoras = (
            await db.execute(
                text(
                    """
                    SELECT user_id
                    FROM patient_members
                    WHERE patient_id = :pid
                      AND role = 'caregiver'
                      AND removed_at IS NULL
                    """
                ),
                {"pid": ctx.patient_id},
            )
        ).scalars().all()
        if len(cuidadoras) == 1:
            asignado = str(cuidadoras[0])

    fila = (
        await db.execute(
            text(
                """
                INSERT INTO care_tasks (
                    patient_id, assigned_to_user_id, created_by_user_id,
                    title, description, due_date, due_time, status, category
                ) VALUES (
                    :pid, :asignado, :uid, :titulo, :desc, :fecha, :hora,
                    'pending', :cat
                )
                RETURNING id, title, description, due_date, due_time,
                          status, category
                """
            ),
            {
                "pid": ctx.patient_id, "uid": ctx.user.user_id,
                "asignado": asignado,
                "titulo": payload.title, "desc": descripcion or None,
                "fecha": fecha, "hora": hora, "cat": categoria,
            },
        )
    ).mappings().first()
    await db.commit()

    return _salida(fila)
