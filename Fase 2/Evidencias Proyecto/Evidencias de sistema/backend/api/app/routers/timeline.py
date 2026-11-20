"""Historial del paciente: una sola línea de tiempo con scroll (DEF-010/011).

QUÉ RESUELVE
    El requisito era "un histórico con scroll de los datos del paciente para
    tomar decisiones" (docs/QA_ESCENARIOS_REALES_POR_ROL.md, E-MED-02). Los
    datos existían repartidos en seis lugares: bitácora, incidentes, relevos,
    dosis, alertas y tratamientos, cada uno con su endpoint y sin paginar. Para
    saber qué pasó antes de una alerta había que abrir cinco pantallas.

    Este endpoint los une en una lista, del más reciente al más antiguo, que
    se pide por páginas a medida que se baja.

QUÉ ENTRA DE LOS SIGNOS VITALES
    No todas las lecturas: el reloj manda una por hora y el historial se
    llenaría de pulsos normales que tapan lo importante. Entran las mediciones
    hechas a mano (las tomó una persona, por algo) y las del reloj que salieron
    del rango del paciente. La serie completa sigue en el detalle de cada vital.

PAGINACIÓN POR CURSOR
    Y no por número de página: mientras alguien baja por la lista se siguen
    registrando eventos, y con OFFSET la página siguiente repetiría o saltaría
    filas. El cursor es el último (momento, id) visto; la página siguiente
    trae lo estrictamente anterior. El id desempata dos eventos del mismo
    instante.
"""
from __future__ import annotations

import base64
from datetime import datetime
from typing import Literal

from fastapi import APIRouter, Depends, Query, Request
from pydantic import BaseModel
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

from app.db import get_db
from app.deps import PatientContext, get_patient_member
from app.errors import ApiError
from app.fechas import zona
from app.routers.logbook import _registrar_lectura

router = APIRouter(prefix="/api/v1", tags=["timeline"])

Kind = Literal["observation", "incident", "handover", "dose", "prn",
               "alert", "treatment", "vital"]
_KINDS: tuple[str, ...] = ("observation", "incident", "handover", "dose", "prn",
                           "alert", "treatment", "vital")

_LIMITE_MAX = 50


class TimelineEvent(BaseModel):
    id:        str
    kind:      str            # observation|incident|handover|dose|prn|alert|treatment|vital
    ts:        datetime
    subtype:   str | None = None   # categoría, tipo de incidente, estado de la dosis, tipo de vital...
    severity:  str | None = None   # info|warning|critical o la del incidente
    title:     str
    detail:    str | None = None
    author:    str | None = None
    # Solo signos vitales: el valor tal cual, para que la app lo formatee.
    value:            float | None = None
    value_secondary:  float | None = None
    unit:             str | None = None


class TimelineOut(BaseModel):
    items:       list[TimelineEvent]
    next_cursor: str | None = None


def _codificar(ts: datetime, eid: str) -> str:
    return base64.urlsafe_b64encode(f"{ts.isoformat()}|{eid}".encode()).decode()


def _decodificar(cursor: str) -> tuple[datetime, str]:
    try:
        ts_txt, eid = base64.urlsafe_b64decode(cursor.encode()).decode().split("|", 1)
        return datetime.fromisoformat(ts_txt), eid
    except Exception:  # noqa: BLE001
        raise ApiError(status_code=422, code="VALIDATION_ERROR",
                       message="El cursor de paginación no es válido.",
                       details=[{"field": "cursor", "message": "Cursor inválido."}])


# Cada bloque devuelve las mismas columnas. Los textos ya van en español: la
# app no tiene que conocer códigos internos para mostrar el historial.
_EVENTOS = """
WITH ev AS (
    SELECT o.observed_at AS ts, 'observation' AS kind, o.id::text AS id,
           o.category AS subtype, NULL::text AS severity,
           o.note::text AS title, NULL::text AS detail,
           u.full_name::text AS author,
           NULL::numeric AS value, NULL::numeric AS value_secondary,
           NULL::text AS unit
      FROM care_observations o
      JOIN users u ON u.id = o.author_id
     WHERE o.patient_id = :pid AND o.deleted_at IS NULL

    UNION ALL
    SELECT i.occurred_at, 'incident', i.id::text, i.type, i.severity,
           i.description::text, i.action_taken::text,
           u.full_name::text, NULL, NULL, NULL
      FROM incidents i
      JOIN users u ON u.id = i.reported_by
     WHERE i.patient_id = :pid

    UNION ALL
    SELECT s.created_at, 'handover', s.id::text, s.shift, NULL,
           s.note::text, NULL, u.full_name::text, NULL, NULL, NULL
      FROM shift_notes s
      JOIN users u ON u.id = s.author_id
     WHERE s.patient_id = :pid AND s.deleted_at IS NULL

    UNION ALL
    -- Dosis ya resueltas. Una pendiente todavía no es historia.
    SELECT COALESCE(sd.administered_at, sd.logged_at, sd.scheduled_at),
           'dose', sd.id::text, sd.status,
           CASE sd.status WHEN 'missed'  THEN 'warning'
                          WHEN 'adverse' THEN 'warning' END,
           COALESCE(m.name, ti.name)::text,
           concat_ws(' · ', COALESCE(m.dose_text, ti.dose_text),
                     'programada ' || to_char(sd.scheduled_at AT TIME ZONE :zona, 'HH24:MI'),
                     sd.reason),
           lu.full_name::text, NULL, NULL, NULL
      FROM scheduled_doses sd
      LEFT JOIN medications m      ON m.id = sd.medication_id
      LEFT JOIN treatment_items ti ON ti.id = sd.treatment_item_id
      LEFT JOIN treatments tr      ON tr.id = ti.treatment_id
      LEFT JOIN users lu           ON lu.id = sd.logged_by
     WHERE COALESCE(m.patient_id, tr.patient_id) = :pid
       AND sd.status <> 'pending'
       AND COALESCE(sd.administered_at, sd.logged_at, sd.scheduled_at) <= now()

    UNION ALL
    SELECT pu.administered_at, 'prn', pu.id::text, NULL,
           CASE WHEN pu.overrode_interval THEN 'warning' END,
           ti.name::text,
           concat_ws(' · ', ti.dose_text, pu.reason),
           u.full_name::text, NULL, NULL, NULL
      FROM treatment_item_prn_uses pu
      JOIN treatment_items ti ON ti.id = pu.treatment_item_id
      JOIN treatments tr      ON tr.id = ti.treatment_id
      JOIN users u            ON u.id = pu.logged_by
     WHERE tr.patient_id = :pid

    UNION ALL
    SELECT a.created_at, 'alert', a.id::text, a.type, a.severity,
           a.title::text, a.detail::text, NULL, NULL, NULL, NULL
      FROM alerts a
     WHERE a.patient_id = :pid

    UNION ALL
    -- Cada versión de un tratamiento: qué se indicó y quién.
    SELECT tr.effective_from, 'treatment', tr.id::text, tr.specialty, NULL,
           CASE WHEN tr.supersedes_id IS NULL THEN 'Tratamiento indicado'
                ELSE 'Tratamiento modificado' END,
           (SELECT string_agg(ti.name || ' ' || COALESCE(ti.dose_text, ''),
                              ', ' ORDER BY ti.name)
              FROM treatment_items ti
             WHERE ti.treatment_id = tr.id AND ti.action <> 'removed'),
           u.full_name::text, NULL, NULL, NULL
      FROM treatments tr
      LEFT JOIN users u ON u.id = tr.prescribed_by
     WHERE tr.patient_id = :pid

    UNION ALL
    -- Signos vitales: los medidos a mano y los del reloj fuera de rango.
    SELECT vr.measured_at, 'vital', vr.id::text, vr.type,
           CASE WHEN (th.min_value IS NOT NULL AND vr.value < th.min_value)
                  OR (th.max_value IS NOT NULL AND vr.value > th.max_value)
                THEN 'warning' END,
           vt.label::text,
           CASE WHEN vr.source = 'manual' THEN 'Medición manual'
                ELSE 'Reloj · fuera del rango del paciente' END
             || COALESCE(' · ' || (vr.meta->>'note'), ''),
           (SELECT u.full_name::text FROM users u
             WHERE u.id::text = vr.meta->>'recorded_by'),
           vr.value, vr.value_secondary, vt.unit::text
      FROM vital_readings vr
      JOIN vital_types vt ON vt.code = vr.type
      LEFT JOIN vital_thresholds th
             ON th.patient_id = vr.patient_id AND th.type = vr.type
            AND th.deleted_at IS NULL
     WHERE vr.patient_id = :pid
       AND (vr.source = 'manual'
            OR (th.min_value IS NOT NULL AND vr.value < th.min_value)
            OR (th.max_value IS NOT NULL AND vr.value > th.max_value))
)
SELECT * FROM ev
 WHERE kind = ANY(:kinds)
   AND (CAST(:bts AS timestamptz) IS NULL
        OR (ts, id) < (CAST(:bts AS timestamptz), CAST(:bid AS text)))
 ORDER BY ts DESC, id DESC
 LIMIT :lim
"""


@router.get("/patients/{patient_id}/timeline", response_model=TimelineOut)
async def get_timeline(
    request: Request,
    cursor: str | None = Query(default=None),
    limit: int = Query(default=20, ge=1, le=_LIMITE_MAX),
    kinds: list[Kind] | None = Query(default=None),
    ctx: PatientContext = Depends(get_patient_member()),
    db: AsyncSession = Depends(get_db),
):
    """Historial del paciente, lo más reciente primero, por páginas.

    Lo lee cualquier miembro del círculo: el médico para decidir, la familia
    para saber qué pasó. `kinds` acota los tipos (por ejemplo solo dosis y
    signos vitales); sin él vienen todos.
    """
    bts, bid = _decodificar(cursor) if cursor else (None, None)

    filas = (
        await db.execute(
            text(_EVENTOS),
            {
                "pid": ctx.patient_id,
                "kinds": list(kinds) if kinds else list(_KINDS),
                "bts": bts, "bid": bid,
                # Uno de más para saber si hay página siguiente sin contar todo.
                "lim": limit + 1,
                "zona": str(zona()),
            },
        )
    ).mappings().all()

    hay_mas = len(filas) > limit
    filas = filas[:limit]

    await _registrar_lectura(db, ctx, request, seccion="logbook")
    await db.commit()

    items = [
        TimelineEvent(
            id=f["id"], kind=f["kind"], ts=f["ts"], subtype=f["subtype"],
            severity=f["severity"], title=f["title"], detail=f["detail"],
            author=f["author"],
            value=float(f["value"]) if f["value"] is not None else None,
            value_secondary=float(f["value_secondary"])
            if f["value_secondary"] is not None else None,
            unit=f["unit"],
        )
        for f in filas
    ]
    siguiente = _codificar(filas[-1]["ts"], filas[-1]["id"]) if hay_mas and filas else None
    return TimelineOut(items=items, next_cursor=siguiente)
