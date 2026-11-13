"""Area de la cuidadora: resumen del dia, plan, perfil e informes.

Endpoints que la aplicacion ya consume:

    GET  /caregiver/today
    GET  /caregiver/plan
    POST /caregiver/plan/upgrade
    POST /caregiver/plan/cancel
    GET  /caregiver/reports

El perfil profesional (GET/PUT /caregiver/profile) vive en
caregiver_profile.py.

Ninguno lleva paciente en la ruta: son del usuario que pide. El de hoy
resuelve solo cual es el paciente que corresponde mostrar.
"""
from datetime import date, datetime, timedelta, timezone
from decimal import Decimal
from uuid import UUID, uuid4

from fastapi import APIRouter, Depends, Query
from pydantic import BaseModel
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

from app.db import get_db
from app.deps import CurrentUser, get_current_user
from app.errors import ApiError
# hoy() entra con nombre propio: en este modulo 'hoy' ya es una variable.
from app.fechas import hoy as hoy_local
from app.fechas import instante
from app.payment_provider import PaymentNotConfigured, get_payment_provider

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
    hoy = hoy_local()

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
            # Desde la medianoche chilena, no la UTC: si no, "las
            # observaciones de hoy" arrancan a las nueve de la noche de ayer.
            {"pid": patient_id, "desde": instante(hoy)},
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
    #
    # Una dosis cuelga de un medicamento suelto o de una indicacion de un
    # tratamiento (scheduled_doses.treatment_item_id). Antes solo se miraban
    # las de medications, y un paciente con su esquema en tratamientos
    # aparecia sin adherencia. Se une igual que en las dosis del dia.
    adherencia = (
        await db.execute(
            text(
                """
                SELECT round(
                         100.0 * count(*) FILTER (WHERE d.status = 'taken')
                         / nullif(count(*), 0), 1)
                FROM scheduled_doses d
                LEFT JOIN medications m ON m.id = d.medication_id
                LEFT JOIN treatment_items ti ON ti.id = d.treatment_item_id
                LEFT JOIN treatments tr ON tr.id = ti.treatment_id
                WHERE COALESCE(m.patient_id, tr.patient_id) = :pid
                  AND d.scheduled_at >= now() - interval '7 days'
                  AND d.scheduled_at <= now()
                  -- Una toma cancelada (cambio o se descontinuo la
                  -- indicacion) no es una toma omitida: no cuenta.
                  AND d.status <> 'cancelled'
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
                # due_date y due_time se guardaron como hora de pared;
                # marcarlas UTC las corre tres o cuatro horas en el telefono.
                due=instante(t["due_date"], t["due_time"]),
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
    # Hasta cuando tiene acceso a un plan de pago. Nulo en el gratuito y en
    # un premium sin fecha de termino.
    valid_until: datetime | None = None
    # El usuario pidio no renovar: conserva el acceso hasta valid_until.
    cancel_requested: bool = False
    # purchase | admin (cortesia del personal). Nulo en el plan gratuito.
    source:      str | None = None
    # Precio mensual vigente del premium, para que la pantalla de
    # suscripcion muestre el que de verdad se cobra y no uno escrito en la app.
    offer_amount:   Decimal | None = None
    offer_currency: str | None = None


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
                SELECT p.id, p.code, s.current_period_end, s.source,
                       (s.cancel_requested_at IS NOT NULL) AS cancel_requested
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

    de_pago = "current_period_end" in plan  # el gratuito no trae suscripcion
    oferta = (
        await db.execute(
            text(
                """
                SELECT pr.amount, pr.currency
                  FROM plan_prices pr JOIN plans p ON p.id = pr.plan_id
                 WHERE p.code = 'premium' AND p.status = 'active'
                   AND pr.period = 'monthly' AND pr.valid_to IS NULL
                 ORDER BY pr.valid_from DESC LIMIT 1
                """
            )
        )
    ).mappings().first()
    return PlanOut(
        offer_amount=oferta["amount"] if oferta else None,
        offer_currency=oferta["currency"] if oferta else None,
        tier=plan["code"],
        features=list(caracteristicas),
        limits_text=" · ".join(_texto_limite(l) for l in limites),
        valid_until=plan["current_period_end"] if de_pago else None,
        cancel_requested=bool(plan["cancel_requested"]) if de_pago else False,
        source=plan["source"] if de_pago else None,
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
    """Contrata el plan premium: cobra, abre la suscripcion y deja el cobro.

    El cobro lo procesa el proveedor de pagos configurado
    (app/payment_provider.py). Hoy es uno simulado porque Alloxentric aun no
    elige pasarela; cuando la elija, se escribe su adaptador y este
    endpoint no cambia.

    Deja lo mismo que dejaria un pago real:
      - una suscripcion nueva con source = 'purchase' y la referencia del
        proveedor en provider_ref;
      - un evento 'charge' en billing_events, con el precio con que se
        cobro y el periodo que cubre.

    La suscripcion activa anterior (por ejemplo una cortesia del personal)
    se cierra y no se edita: asi el historial muestra cada etapa. Si la
    cuenta ya tiene premium comprado y vigente, no se cobra de nuevo.
    """
    premium = (
        await db.execute(
            text("SELECT id FROM plans WHERE code = 'premium' AND status = 'active'")
        )
    ).scalar()
    precio = None
    if premium is not None:
        precio = (
            await db.execute(
                text(
                    """
                    SELECT id, amount, currency FROM plan_prices
                     WHERE plan_id = :pid AND period = 'monthly'
                       AND valid_to IS NULL
                     ORDER BY valid_from DESC LIMIT 1
                    """
                ),
                {"pid": str(premium)},
            )
        ).mappings().first()
    if premium is None or precio is None:
        raise ApiError(
            status_code=500, code="PLAN_NOT_CONFIGURED",
            message="El plan premium no esta disponible para contratar.",
        )

    activa = (
        await db.execute(
            text(
                """
                SELECT s.id, s.source, p.tier,
                       (s.cancel_requested_at IS NOT NULL) AS cancelada
                  FROM subscriptions s
                  JOIN plans p ON p.id = s.plan_id
                 WHERE s.user_id = :uid AND s.status = 'active'
                   AND (s.current_period_end IS NULL
                        OR s.current_period_end > now())
                 FOR UPDATE OF s
                """
            ),
            {"uid": user.user_id},
        )
    ).mappings().first()
    if activa is not None and activa["tier"] > 0 and activa["source"] == "purchase":
        # Ya esta pagado el periodo en curso. Si habia pedido cancelar, volver
        # a "suscribirse" solo retoma la renovacion: no se cobra otra vez.
        if activa["cancelada"]:
            await db.execute(
                text("UPDATE subscriptions SET cancel_requested_at = NULL, "
                     "updated_at = now() WHERE id = :sid"),
                {"sid": str(activa["id"])},
            )
            await db.commit()
        return await _plan_del_usuario(db, user.user_id)

    try:
        cobro = await get_payment_provider().cobrar(
            user_id=user.user_id, monto=precio["amount"],
            moneda=precio["currency"], descripcion="Suscripcion premium mensual",
        )
    except PaymentNotConfigured as e:
        raise ApiError(status_code=503, code="PAYMENT_NOT_CONFIGURED",
                       message=str(e))
    if not cobro.ok:
        raise ApiError(
            status_code=402, code="PAYMENT_FAILED",
            message=cobro.failure_reason or "No se pudo procesar el pago.",
        )

    # Se cierra la suscripcion activa antes de abrir la nueva: la base solo
    # admite una activa por usuario.
    await db.execute(
        text(
            """
            UPDATE subscriptions
               SET status = 'cancelled', cancelled_at = now(),
                   change_reason = 'Reemplazada por una compra',
                   updated_at = now()
             WHERE user_id = :uid AND status = 'active'
            """
        ),
        {"uid": user.user_id},
    )
    sub_id = (
        await db.execute(
            text(
                """
                INSERT INTO subscriptions
                    (user_id, plan_id, status, started_at,
                     current_period_end, provider_ref, source)
                VALUES (:uid, :pid, 'active', now(),
                        now() + interval '1 month', :ref, 'purchase')
                RETURNING id
                """
            ),
            {"uid": user.user_id, "pid": str(premium), "ref": cobro.provider_ref},
        )
    ).scalar()
    await db.execute(
        text(
            """
            INSERT INTO billing_events
                (subscription_id, plan_price_id, type, status, amount, currency,
                 period_start, period_end, provider_ref, provider_event_id,
                 occurred_at)
            VALUES (:sid, :prid, 'charge', 'succeeded', :amt, :cur,
                    now(), now() + interval '1 month', :ref, :evt, now())
            """
        ),
        {"sid": str(sub_id), "prid": str(precio["id"]), "amt": precio["amount"],
         "cur": precio["currency"], "ref": cobro.provider_ref,
         "evt": cobro.provider_event_id},
    )

    await db.commit()
    return await _plan_del_usuario(db, user.user_id)


@router.post("/plan/cancel", response_model=PlanOut)
async def cancel_plan(
    user: CurrentUser = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Cancela la renovacion del premium. El acceso sigue hasta fin de periodo.

    No corta el acceso en el acto ni reembolsa: el periodo en curso ya esta
    pagado. La suscripcion queda marcada para no renovarse, y cuando vence
    la cuenta vuelve sola al plan gratuito. Se puede retomar antes de que
    venza volviendo a suscribirse (no se cobra de nuevo).

    Solo aplica a un premium comprado. Una cortesia del personal termina en
    la fecha que le fijaron y no se cancela desde aqui.
    """
    activa = (
        await db.execute(
            text(
                """
                SELECT s.id, s.source, s.current_period_end,
                       (s.cancel_requested_at IS NOT NULL) AS cancelada
                  FROM subscriptions s
                  JOIN plans p ON p.id = s.plan_id
                 WHERE s.user_id = :uid AND s.status = 'active' AND p.tier > 0
                   AND (s.current_period_end IS NULL
                        OR s.current_period_end > now())
                 ORDER BY p.tier DESC
                 LIMIT 1
                 FOR UPDATE OF s
                """
            ),
            {"uid": user.user_id},
        )
    ).mappings().first()

    if activa is None:
        raise ApiError(status_code=409, code="NO_ACTIVE_SUBSCRIPTION",
                       message="No tienes una suscripcion premium activa.")
    if activa["source"] != "purchase":
        raise ApiError(
            status_code=409, code="COURTESY_NOT_CANCELLABLE",
            message="Tu premium es una cortesia de AgeCare y termina en su "
                    "fecha de vencimiento. No hay nada que cancelar.",
        )
    if activa["cancelada"]:
        return await _plan_del_usuario(db, user.user_id)

    await db.execute(
        text("UPDATE subscriptions SET cancel_requested_at = now(), "
             "updated_at = now() WHERE id = :sid"),
        {"sid": str(activa["id"])},
    )
    await db.execute(
        text(
            """
            INSERT INTO billing_events
                (subscription_id, type, status, provider_ref,
                 provider_event_id, occurred_at)
            VALUES (:sid, 'cancelled', 'succeeded', :ref, :evt, now())
            """
        ),
        {"sid": str(activa["id"]), "ref": f"user:{user.user_id}",
         "evt": f"cancel-{uuid4()}"},
    )
    await db.commit()
    return await _plan_del_usuario(db, user.user_id)


class ReportPoint(BaseModel):
    label: str
    value: float


class ReportOut(BaseModel):
    period:             str
    days:               int
    tasks_completed:    int
    punctuality_pct:    float
    checkins_on_time:   int
    observations_logged: int
    # Serie de la grafica: por dia hasta 30 dias, por semana en 90. El
    # nombre se mantiene por compatibilidad con la app.
    weekly_tasks:       list[ReportPoint]


_DIAS = ["lun", "mar", "mie", "jue", "vie", "sab", "dom"]

# RF-74: informes por rango de fechas. Los ultimos 7 dias son del plan
# gratuito; 30 y 90 dias son la funcion 'activity_reports' del premium
# (RF-73: se bloquea en el servidor, no solo en la pantalla).
_RANGOS = (7, 30, 90)


@router.get("/reports", response_model=ReportOut)
async def reports(
    days: int = Query(7, description="7, 30 o 90. Mas de 7 requiere Premium."),
    user: CurrentUser = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Desempeno de la cuidadora en los ultimos 7, 30 o 90 dias.

    Es sobre su propio trabajo, no sobre un paciente: cuenta lo que hizo
    ella en todos los circulos donde participa.
    """
    if days not in _RANGOS:
        raise ApiError(
            status_code=422, code="VALIDATION_ERROR",
            message="El rango debe ser de 7, 30 o 90 dias.",
            details=[{"field": "days", "message": f"Valor recibido: {days}."}],
        )
    if days > 7 and (await _plan_del_usuario(db, user.user_id)).tier == "free":
        raise ApiError(
            status_code=402, code="PREMIUM_REQUIRED",
            message="Los informes de 30 y 90 dias son parte de Premium.",
        )
    desde = datetime.now(timezone.utc) - timedelta(days=days)

    tareas = (
        await db.execute(
            text(
                """
                SELECT count(*) FROM care_tasks
                WHERE assigned_to_user_id = :uid
                  AND status = 'completed'
                  AND completed_at >= :desde
                  AND deleted_at IS NULL
                """
            ),
            {"uid": user.user_id, "desde": desde},
        )
    ).scalar()

    observaciones = (
        await db.execute(
            text(
                """
                SELECT count(*) FROM care_observations
                WHERE author_id = :uid
                  AND observed_at >= :desde
                  AND deleted_at IS NULL
                """
            ),
            {"uid": user.user_id, "desde": desde},
        )
    ).scalar()

    # Puntualidad: turnos que empezaron a la hora. Sin horario pactado en el
    # esquema, lo unico medible hoy es si el turno se marco o no, asi que se
    # cuentan los cerrados sobre el total. Un turno que quedo abierto para
    # siempre es una marca que la cuidadora olvido hacer.
    turnos = (
        await db.execute(
            text(
                """
                SELECT count(*) AS total,
                       count(*) FILTER (WHERE checked_out_at IS NOT NULL) AS cerrados
                FROM care_shifts
                WHERE caregiver_id = :uid AND checked_in_at >= :desde
                """
            ),
            {"uid": user.user_id, "desde": desde},
        )
    ).mappings().first()

    puntualidad = (
        round(100.0 * turnos["cerrados"] / turnos["total"], 1)
        if turnos and turnos["total"] else 0.0
    )

    # Serie por dia para la grafica. Se arma el rango completo aca y no se
    # deja que la pantalla rellene los huecos: un dia sin tareas es un cero
    # que la grafica tiene que dibujar, no un dia que falta.
    por_dia = {
        f["dia"]: f["cuantas"]
        for f in (
            await db.execute(
                text(
                    """
                    -- El dia sale de la zona de la conexion (db.py). Antes
                    -- decia AT TIME ZONE 'UTC' y agrupaba por dia UTC, que
                    -- no es el dia en que la cuidadora hizo el trabajo.
                    SELECT completed_at::date AS dia,
                           count(*) AS cuantas
                    FROM care_tasks
                    WHERE assigned_to_user_id = :uid
                      AND status = 'completed'
                      AND completed_at >= :desde
                      AND deleted_at IS NULL
                    GROUP BY 1
                    """
                ),
                {"uid": user.user_id, "desde": desde},
            )
        ).mappings().all()
    }

    # Tiene que ser el mismo dia con el que agrupa la consulta de arriba,
    # o las etiquetas de la grafica no calzan con sus valores.
    hoy = hoy_local()
    if days == 7:
        serie = [
            ReportPoint(
                label=_DIAS[(hoy - timedelta(days=i)).weekday()],
                value=float(por_dia.get(hoy - timedelta(days=i), 0)),
            )
            for i in range(6, -1, -1)
        ]
    elif days == 30:
        serie = [
            ReportPoint(
                label=(hoy - timedelta(days=i)).strftime("%d/%m"),
                value=float(por_dia.get(hoy - timedelta(days=i), 0)),
            )
            for i in range(29, -1, -1)
        ]
    else:
        # 90 dias por dia son 90 barras ilegibles: se suman por semana,
        # terminando hoy. La etiqueta es el primer dia de cada semana.
        serie = []
        for semana in range(12, -1, -1):
            inicio = hoy - timedelta(days=semana * 7 + 6)
            serie.append(ReportPoint(
                label=inicio.strftime("%d/%m"),
                value=float(sum(por_dia.get(inicio + timedelta(days=d), 0)
                                for d in range(7))),
            ))

    return ReportOut(
        period=f"Ultimos {days} dias",
        days=days,
        tasks_completed=tareas or 0,
        punctuality_pct=puntualidad,
        checkins_on_time=(turnos["cerrados"] if turnos else 0),
        observations_logged=observaciones or 0,
        weekly_tasks=serie,
    )
