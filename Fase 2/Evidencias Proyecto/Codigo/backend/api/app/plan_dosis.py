"""Lo que le pasa a la agenda de tomas cuando el plan cambia (RF-26, RF-27).

EL PROBLEMA
    Las tomas se generan con dias de anticipacion, asi que cuando el medico
    descontinua un medicamento o le cambia los horarios, las que ya estaban
    generadas no desaparecen solas. Al adulto mayor le seguian apareciendo
    las tomas de un remedio que ya no toma, el barrido horario las pasaba a
    'missed' por no confirmarlas, y la adherencia le bajaba a una persona que
    hizo todo bien.

    RF-26 lo dice: modificar un medicamento regenera SOLO las tomas futuras.
    Lo de "solo futuras" es la parte importante.

QUE SE TOCA Y QUE NO
    Solo lo que todavia no paso y nadie registro: 'pending' y 'postponed' con
    hora futura. Lo ya administrado, omitido o saltado es historia clinica y
    no se reescribe, aunque el medicamento se descontinue despues.

    El corte es "de ahora en adelante" y no "de hoy en adelante". La toma de
    las 08:00 de hoy, cuando ya son las 14:00, pertenece al dia que paso: si
    el medico cambia el plan a mitad de tarde, esa toma de la manana sigue
    contando. Lo contrario borraria media jornada de registro cada vez que se
    ajusta una dosis.

POR QUE CANCELAR Y NO BORRAR
    La fila queda con estado 'cancelled' (968). Asi el expediente conserva
    que esa toma existia y dejo de corresponder, y el generador la reconoce:
    si esa misma hora vuelve al plan, la revive en vez de duplicarla.
"""
from __future__ import annotations

from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

# Lo que aun esta por registrarse. Lo demas ya es historia.
_ABIERTAS = "('pending', 'postponed')"


async def cancelar_futuras_de_medicamento(
    db: AsyncSession, medication_id: str, *, motivo: str
) -> int:
    """Cancela las tomas futuras de un medicamento del modelo antiguo."""
    r = await db.execute(
        text(
            f"""
            UPDATE scheduled_doses
               SET status = 'cancelled', reason = :motivo
             WHERE medication_id = CAST(:mid AS uuid)
               AND status IN {_ABIERTAS}
               AND scheduled_at > now()
            """
        ),
        {"mid": str(medication_id), "motivo": motivo[:300]},
    )
    return r.rowcount or 0


async def cancelar_futuras_de_tratamiento(
    db: AsyncSession, treatment_id: str, *, motivo: str
) -> int:
    """Cancela las tomas futuras de todas las indicaciones de un tratamiento.

    Se usa al reemplazar un tratamiento por uno nuevo: el anterior deja de
    regir, y con el dejan de corresponder sus tomas. Las del tratamiento
    nuevo las crea el generador a partir de sus propias indicaciones, asi que
    una indicacion que se mantuvo igual recupera su hora cuando el generador
    pasa (el ON CONFLICT revive la fila cancelada).
    """
    r = await db.execute(
        text(
            f"""
            UPDATE scheduled_doses sd
               SET status = 'cancelled', reason = :motivo
              FROM treatment_items ti
             WHERE ti.id = sd.treatment_item_id
               AND ti.treatment_id = CAST(:tid AS uuid)
               AND sd.status IN {_ABIERTAS}
               AND sd.scheduled_at > now()
            """
        ),
        {"tid": str(treatment_id), "motivo": motivo[:300]},
    )
    return r.rowcount or 0
