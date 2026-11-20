"""Fechas y horas en la zona de la operación.

POR QUÉ EXISTE ESTE MÓDULO
    La base guarda instantes (timestamptz) y también horas de pared
    (due_date, due_time, shift_date, time_of_day). Son dos cosas
    distintas y pasar de una a la otra necesita saber en qué país está
    la señora, porque "hoy" y "las 8 de la mañana" no significan nada
    sin eso.

    Estaba resuelto con datetime.now(timezone.utc).date() repartido por
    los routers, que responde el día UTC. Desde las nueve de la noche en
    Chile eso ya es mañana, así que la pantalla de la cuidadora filtraba
    las tareas de mañana y la gráfica de su semana etiquetaba los días
    corridos.

    Acá está una sola vez. La zona sale de la configuración, la misma que
    db.py le pone a la conexión.

QUÉ NO VA ACÁ
    Un instante que se compara con otro instante no necesita nada de
    esto: now() - 7 días es el mismo momento en cualquier zona. Estas
    funciones son solo para cruzar la frontera entre un instante y un
    día.
"""
from __future__ import annotations

from datetime import date, datetime, time
from functools import lru_cache
from zoneinfo import ZoneInfo

from app.config import get_settings


@lru_cache
def zona() -> ZoneInfo:
    """La zona de la operación, cargada una sola vez."""
    return ZoneInfo(get_settings().timezone)


def ahora() -> datetime:
    """El instante actual, expresado en la zona de la operación."""
    return datetime.now(zona())


def hoy() -> date:
    """Qué día es hoy para la señora, que es el único hoy que importa."""
    return ahora().date()


def instante(dia: date, hora: time | None = None) -> datetime:
    """Convierte un día y una hora de pared en el instante que fueron.

    Sin hora se entiende el comienzo del día. Es lo que hace falta para
    comparar una fecha guardada como date contra una columna timestamptz,
    y para devolverle a la aplicación la hora de una tarea: due_date y
    due_time se guardaron como la hora del reloj de la pared, así que
    marcarlas como UTC las corre tres o cuatro horas en el teléfono.
    """
    return datetime.combine(dia, hora or time.min, tzinfo=zona())
