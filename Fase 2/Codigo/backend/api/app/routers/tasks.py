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
