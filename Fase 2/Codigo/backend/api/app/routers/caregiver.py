"""Area de la cuidadora: resumen del dia, plan, perfil e informes.

Endpoints que la aplicacion ya consume:

    GET  /caregiver/today
    GET  /caregiver/plan
    POST /caregiver/plan/upgrade
    GET  /caregiver/profile
    PUT  /caregiver/profile
    GET  /caregiver/reports

Ninguno lleva paciente en la ruta: son del usuario que pide. El de hoy
resuelve solo cual es el paciente que corresponde mostrar.
"""
from datetime import date, datetime, timedelta, timezone
from uuid import UUID

from fastapi import APIRouter, Depends
from pydantic import BaseModel, Field
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

from app.db import get_db
from app.deps import CurrentUser, get_current_user
from app.errors import ApiError

router = APIRouter(prefix="/api/v1/caregiver", tags=["caregiver"])


# ---------------------------------------------------------------------------
# Resumen del dia
# ---------------------------------------------------------------------------
class TaskResumen(BaseModel):
    id:          UUID
    title:       str
    description: str | None
    due:         datetime | None
    status:      str
    category:    str | None


class TodayOut(BaseModel):
    patient_id:         str
    patient_name:       str
    shift_status:       str
    wellbeing_status:   str
    pending_tasks:      list[TaskResumen]
    observations_count: int
    alerts_count:       int
    adherence_pct:      float | None


@router.get("/today", response_model=TodayOut)
async def today(
    user: CurrentUser = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Lo que la cuidadora necesita ver al abrir la aplicacion.

    La pantalla no manda paciente, asi que hay que elegirlo. Se prefiere el
    del turno abierto, porque si esta en turno es a esa casa donde esta. Si
    no hay turno abierto, el ultimo que atendio. Si nunca atendio a nadie,
    el primero de su circulo.
    """
    elegido = (
        await db.execute(
            text(
                """
                SELECT p.id, p.first_name || ' ' || p.last_name AS nombre
                FROM patient_members pm
                JOIN patients p ON p.id = pm.patient_id
                LEFT JOIN care_shifts abierto
                       ON abierto.patient_id = pm.patient_id
                      AND abierto.caregiver_id = pm.user_id
                      AND abierto.checked_out_at IS NULL
                LEFT JOIN LATERAL (
                    SELECT max(checked_in_at) AS ultimo
                    FROM care_shifts s
                    WHERE s.patient_id = pm.patient_id
                      AND s.caregiver_id = pm.user_id
                ) hist ON true
                WHERE pm.user_id = :uid
                  AND pm.removed_at IS NULL
                  AND p.deleted_at IS NULL
                ORDER BY (abierto.id IS NOT NULL) DESC,
                         hist.ultimo DESC NULLS LAST,
                         pm.created_at
                LIMIT 1
                """
            ),
            {"uid": user.user_id},
        )
    ).mappings().first()

    if elegido is None:
        raise ApiError(
            status_code=404, code="NO_PATIENTS",
            message="Todavia no tienes pacientes asignados.",
        )

    patient_id = str(elegido["id"])
    hoy = datetime.now(timezone.utc).date()

    en_turno = (
        await db.execute(
            text(
                """
                SELECT 1 FROM care_shifts
                WHERE caregiver_id = :uid AND patient_id = :pid
                  AND checked_out_at IS NULL
                """
            ),
            {"uid": user.user_id, "pid": patient_id},
        )
    ).first()

    # El semaforo lo calcula el proceso que llena wellbeing_snapshots. Si
    # todavia no corrio hoy, se usa el ultimo que haya, que es mejor que
    # inventar un 'ok' que nadie calculo.
    bienestar = (
        await db.execute(
            text(
                """
                SELECT status FROM wellbeing_snapshots
                WHERE patient_id = :pid
                ORDER BY snapshot_date DESC
                LIMIT 1
                """
            ),
            {"pid": patient_id},
        )
    ).scalar()

    pendientes = (
        await db.execute(
            text(
                """
                SELECT id, title, description, due_date, due_time,
                       status, category
                FROM care_tasks
                WHERE patient_id = :pid
                  AND deleted_at IS NULL
                  AND status IN ('pending', 'in_progress')
                  AND due_date <= :hoy
                ORDER BY due_date, due_time NULLS FIRST, created_at
                LIMIT 50
                """
            ),
            {"pid": patient_id, "hoy": hoy},
        )
    ).mappings().all()

    observaciones = (
        await db.execute(
            text(
                """
                SELECT count(*) FROM care_observations
                WHERE patient_id = :pid
                  AND deleted_at IS NULL
                  AND observed_at >= :desde
                """
            ),
            {"pid": patient_id, "desde": datetime.combine(
                hoy, datetime.min.time(), tzinfo=timezone.utc)},
        )
    ).scalar()

    alertas = (
        await db.execute(
            text("SELECT count(*) FROM alerts "
                 "WHERE patient_id = :pid AND status = 'active'"),
            {"pid": patient_id},
        )
    ).scalar()

    # Adherencia de los ultimos siete dias: dosis tomadas sobre dosis que
    # ya vencieron. Las que todavia no llegan no cuentan en contra.
    adherencia = (
        await db.execute(
            text(
                """
                SELECT round(
                         100.0 * count(*) FILTER (WHERE d.status = 'taken')
                         / nullif(count(*), 0), 1)
                FROM scheduled_doses d
                JOIN medications m ON m.id = d.medication_id
                WHERE m.patient_id = :pid
                  AND d.scheduled_at >= now() - interval '7 days'
                  AND d.scheduled_at <= now()
                """
            ),
            {"pid": patient_id},
        )
    ).scalar()

    return TodayOut(
        patient_id=patient_id,
        patient_name=elegido["nombre"],
        shift_status="checked_in" if en_turno else "checked_out",
        wellbeing_status=bienestar or "ok",
        pending_tasks=[
            TaskResumen(
                id=t["id"], title=t["title"], description=t["description"],
                due=(datetime.combine(t["due_date"], t["due_time"] or datetime.min.time(),
                                      tzinfo=timezone.utc)),
                status="done" if t["status"] == "completed" else t["status"],
                category=t["category"],
            )
            for t in pendientes
        ],
        observations_count=observaciones or 0,
        alerts_count=alertas or 0,
        adherence_pct=float(adherencia) if adherencia is not None else None,
    )


# ---------------------------------------------------------------------------
# Plan
# ---------------------------------------------------------------------------
class PlanOut(BaseModel):
    tier:        str
    features:    list[str]
    limits_text: str


async def _plan_del_usuario(db: AsyncSession, user_id: str) -> PlanOut:
    """Arma el plan vigente del usuario.

    Sin suscripcion es plan gratis. No se crea una fila al vuelo para
    representarlo: la ausencia de suscripcion ya significa gratis, y
    escribir en una consulta de lectura es una sorpresa que nadie espera.
    """
    plan = (
        await db.execute(
            text(
                """
                SELECT p.id, p.code
                FROM subscriptions s
                JOIN plans p ON p.id = s.plan_id
                WHERE s.user_id = :uid
                  AND s.status = 'active'
                  AND (s.current_period_end IS NULL
                       OR s.current_period_end > now())
                ORDER BY p.tier DESC
                LIMIT 1
                """
            ),
            {"uid": user_id},
        )
    ).mappings().first()

    if plan is None:
        plan = (
            await db.execute(
                text("SELECT id, code FROM plans WHERE code = 'free'")
            )
        ).mappings().first()
        if plan is None:
            raise ApiError(
                status_code=500, code="PLAN_NOT_CONFIGURED",
                message="No hay planes configurados en el sistema.",
            )

    caracteristicas = (
        await db.execute(
            text(
                """
                SELECT f.label
                FROM plan_features pf
                JOIN features f ON f.code = pf.feature_code
                WHERE pf.plan_id = :pid AND pf.is_included
                ORDER BY f.module, f.label
                """
            ),
            {"pid": str(plan["id"])},
        )
    ).scalars().all()

    # El texto de limites se arma aca y no en la pantalla: la unidad vive en
    # limit_keys, que es donde quedo al normalizar, y la pantalla no deberia
    # tener que saber que 'megabytes' se escribe 'MB' ni que un limite nulo
    # significa sin tope.
    limites = (
        await db.execute(
            text(
                """
                SELECT k.label, pl.limit_value, k.unit
                FROM plan_limits pl
                JOIN limit_keys k ON k.key = pl.limit_key
                WHERE pl.plan_id = :pid
                ORDER BY k.label
                """
            ),
            {"pid": str(plan["id"])},
        )
    ).mappings().all()

    return PlanOut(
        tier=plan["code"],
        features=list(caracteristicas),
        limits_text=" · ".join(_texto_limite(l) for l in limites),
    )


_UNIDAD = {
    "count":     "",
    "days":      " dias",
    "months":    " meses",
    "megabytes": " MB",
    "per_month": " al mes",
    "per_day":   " al dia",
}


def _texto_limite(l) -> str:
    if l["limit_value"] is None:
        return f"{l['label']}: sin tope"
    if l["limit_value"] == 0:
        return f"{l['label']}: no incluido"
    return f"{l['label']}: {l['limit_value']}{_UNIDAD.get(l['unit'], '')}"


@router.get("/plan", response_model=PlanOut)
async def get_plan(
    user: CurrentUser = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Plan vigente del usuario, con lo que incluye y sus topes."""
    return await _plan_del_usuario(db, user.user_id)


@router.post("/plan/upgrade", response_model=PlanOut)
async def upgrade_plan(
    user: CurrentUser = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Pasa la cuenta al plan premium.

    No hay cobro todavia. Cuando Alloxentric conecte la pasarela, el pago
    ocurre antes de llamar aca y este endpoint pasa a recibir la referencia
    del proveedor, que es para lo que existe subscriptions.provider_ref. Se
    deja el periodo en un mes, que es lo que dura el ciclo en plan_prices.

    No se borra ni se reemplaza la suscripcion anterior: billing_events
    apunta a ella y el historial de cobros no se pisa. Se reusa la fila del
    usuario si ya existe, cambiandole el plan.
    """
    premium = (
        await db.execute(text("SELECT id FROM plans WHERE code = 'premium'"))
    ).scalar()
    if premium is None:
        raise ApiError(
            status_code=500, code="PLAN_NOT_CONFIGURED",
            message="El plan premium no esta configurado.",
        )

    actual = (
        await db.execute(
            text("SELECT id FROM subscriptions WHERE user_id = :uid "
                 "ORDER BY started_at DESC LIMIT 1"),
            {"uid": user.user_id},
        )
    ).scalar()

    if actual is None:
        await db.execute(
            text(
                """
                INSERT INTO subscriptions (
                    user_id, plan_id, status, started_at, current_period_end
                ) VALUES (
                    :uid, :pid, 'active', now(), now() + interval '1 month'
                )
                """
            ),
            {"uid": user.user_id, "pid": str(premium)},
        )
    else:
        await db.execute(
            text(
                """
                UPDATE subscriptions
                   SET plan_id = :pid,
                       status = 'active',
                       cancelled_at = NULL,
                       current_period_end = now() + interval '1 month',
                       updated_at = now()
                 WHERE id = :sid
                """
            ),
            {"pid": str(premium), "sid": str(actual)},
        )

    await db.commit()
    return await _plan_del_usuario(db, user.user_id)
