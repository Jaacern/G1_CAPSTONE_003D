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
# hoy() entra con nombre propio: en este modulo 'hoy' ya es una variable.
from app.fechas import hoy as hoy_local
from app.fechas import instante

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


# ---------------------------------------------------------------------------
# Perfil profesional del marketplace
# ---------------------------------------------------------------------------
class ProfileOut(BaseModel):
    headline:         str
    bio:              str
    years_experience: int
    specialties:      list[str]
    languages:        list[str]
    zones:            list[str]
    certifications:   list[str]


async def _perfil(db: AsyncSession, user_id: str) -> ProfileOut:
    """Arma el perfil, o uno vacio si la cuidadora todavia no lo creo.

    La pantalla de perfil se abre igual aunque no haya nada escrito, asi
    que devolver 404 la dejaria sin poder empezar. Un perfil vacio es la
    respuesta util.
    """
    perfil = (
        await db.execute(
            text(
                """
                SELECT id, headline, bio, years_experience
                FROM caregiver_profiles
                WHERE user_id = :uid AND deleted_at IS NULL
                """
            ),
            {"uid": user_id},
        )
    ).mappings().first()

    if perfil is None:
        return ProfileOut(headline="", bio="", years_experience=0,
                          specialties=[], languages=[], zones=[],
                          certifications=[])

    pid = str(perfil["id"])

    especialidades = (
        await db.execute(
            text(
                """
                SELECT s.label
                FROM caregiver_specialties cs
                JOIN specialties s ON s.code = cs.specialty_code
                WHERE cs.profile_id = :pid
                ORDER BY s.label
                """
            ),
            {"pid": pid},
        )
    ).scalars().all()

    idiomas = (
        await db.execute(
            text("SELECT language_code FROM caregiver_languages "
                 "WHERE profile_id = :pid ORDER BY language_code"),
            {"pid": pid},
        )
    ).scalars().all()

    zonas = (
        await db.execute(
            text("SELECT commune_code FROM caregiver_zones "
                 "WHERE profile_id = :pid ORDER BY commune_code"),
            {"pid": pid},
        )
    ).scalars().all()

    certificaciones = (
        await db.execute(
            text("SELECT name FROM caregiver_certifications "
                 "WHERE profile_id = :pid AND deleted_at IS NULL "
                 "ORDER BY issued_at DESC NULLS LAST, name"),
            {"pid": pid},
        )
    ).scalars().all()

    return ProfileOut(
        headline=perfil["headline"],
        bio=perfil["bio"] or "",
        years_experience=perfil["years_experience"],
        specialties=list(especialidades),
        languages=list(idiomas),
        zones=list(zonas),
        certifications=list(certificaciones),
    )


@router.get("/profile", response_model=ProfileOut)
async def get_profile(
    user: CurrentUser = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Perfil profesional de la cuidadora."""
    return await _perfil(db, user.user_id)


class ProfileIn(BaseModel):
    headline:         str = Field(default="", max_length=120)
    bio:              str = Field(default="", max_length=2000)
    years_experience: int = Field(default=0, ge=0, le=70)
    specialties:      list[str] = Field(default_factory=list)
    languages:        list[str] = Field(default_factory=list)
    zones:            list[str] = Field(default_factory=list)
    certifications:   list[str] = Field(default_factory=list)


@router.put("/profile", response_model=ProfileOut)
async def save_profile(
    payload: ProfileIn,
    user: CurrentUser = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Guarda el perfil profesional.

    La pantalla manda el perfil completo, no un parche, asi que las listas
    se reemplazan enteras: lo que no viene es lo que la cuidadora quito.

    Las certificaciones NO se tocan aca. Cada una puede estar verificada
    por Alloxentric y llevar un archivo adjunto, asi que borrarlas y
    reescribirlas desde una pantalla de texto perderia la verificacion y
    dejaria el archivo huerfano. Se devuelven para mostrar, y se
    administran por su propio camino.
    """
    headline = payload.headline.strip()
    if not headline:
        # headline es NOT NULL y la pantalla permite dejarlo vacio al
        # empezar. Un texto neutro es mejor que un error que no deja
        # guardar el resto de lo que si escribio.
        headline = f"Cuidadora, {payload.years_experience} anios de experiencia"

    perfil_id = (
        await db.execute(
            text("SELECT id FROM caregiver_profiles "
                 "WHERE user_id = :uid AND deleted_at IS NULL"),
            {"uid": user.user_id},
        )
    ).scalar()

    if perfil_id is None:
        perfil_id = (
            await db.execute(
                text(
                    """
                    INSERT INTO caregiver_profiles (
                        user_id, headline, bio, years_experience
                    ) VALUES (:uid, :tit, :bio, :anios)
                    RETURNING id
                    """
                ),
                {"uid": user.user_id, "tit": headline,
                 "bio": payload.bio.strip() or None,
                 "anios": payload.years_experience},
            )
        ).scalar()
    else:
        await db.execute(
            text(
                """
                UPDATE caregiver_profiles
                   SET headline = :tit, bio = :bio,
                       years_experience = :anios, updated_at = now()
                 WHERE id = :pid
                """
            ),
            {"pid": str(perfil_id), "tit": headline,
             "bio": payload.bio.strip() or None,
             "anios": payload.years_experience},
        )

    pid = str(perfil_id)

    # Especialidades: la pantalla manda etiquetas y la tabla guarda codigos.
    # Una etiqueta que no existe en el catalogo se rechaza en vez de
    # inventar un codigo, porque specialties es la lista que alimenta el
    # buscador del marketplace.
    codigos: list[str] = []
    if payload.specialties:
        catalogo = {
            _normaliza(fila["label"]): fila["code"]
            for fila in (
                await db.execute(text("SELECT code, label FROM specialties"))
            ).mappings().all()
        }
        validos = set(catalogo.values())
        for s in payload.specialties:
            limpio = s.strip()
            if not limpio:
                continue
            codigo = limpio if limpio in validos else catalogo.get(_normaliza(limpio))
            if codigo is None:
                raise ApiError(
                    status_code=422, code="VALIDATION_ERROR",
                    message="Esa especialidad no esta en el catalogo.",
                    details=[{"field": "specialties",
                              "message": f"Valor recibido: {s}."}],
                )
            codigos.append(codigo)

    # El motor exige el formato exacto: dos letras para el idioma y cinco
    # digitos para la comuna. Si no se valida aca, un dato mal escrito llega
    # al CHECK y el usuario recibe un 500 en vez de saber que corregir.
    idiomas = _validados(
        payload.languages, r"^[a-z]{2}$", "languages",
        "Usa el codigo de dos letras del idioma, como 'es' o 'en'.",
        transformar=lambda s: s.strip().lower(),
    )
    zonas = _validados(
        payload.zones, r"^[0-9]{5}$", "zones",
        "Usa el codigo de cinco digitos de la comuna, como '08101'.",
    )

    await _reemplazar(db, "caregiver_specialties", "specialty_code", pid,
                      dict.fromkeys(codigos))
    await _reemplazar(db, "caregiver_languages", "language_code", pid, idiomas)
    await _reemplazar(db, "caregiver_zones", "commune_code", pid, zonas)

    await db.commit()
    return await _perfil(db, user.user_id)


class ReportPoint(BaseModel):
    label: str
    value: float


class ReportOut(BaseModel):
    period:             str
    tasks_completed:    int
    punctuality_pct:    float
    checkins_on_time:   int
    observations_logged: int
    weekly_tasks:       list[ReportPoint]


_DIAS = ["lun", "mar", "mie", "jue", "vie", "sab", "dom"]


@router.get("/reports", response_model=ReportOut)
async def reports(
    user: CurrentUser = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Desempeno de la cuidadora en los ultimos siete dias.

    Es sobre su propio trabajo, no sobre un paciente: cuenta lo que hizo
    ella en todos los circulos donde participa.
    """
    desde = datetime.now(timezone.utc) - timedelta(days=7)

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

    # Serie por dia para la grafica. Se arma la semana completa aca y no se
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
    semana = [
        ReportPoint(
            label=_DIAS[(hoy - timedelta(days=i)).weekday()],
            value=float(por_dia.get(hoy - timedelta(days=i), 0)),
        )
        for i in range(6, -1, -1)
    ]

    return ReportOut(
        period="Ultimos 7 dias",
        tasks_completed=tareas or 0,
        punctuality_pct=puntualidad,
        checkins_on_time=(turnos["cerrados"] if turnos else 0),
        observations_logged=observaciones or 0,
        weekly_tasks=semana,
    )


def _validados(valores: list[str], patron: str, campo: str, ayuda: str,
               transformar=lambda s: s.strip()) -> dict:
    """Recorta, valida contra el patron y quita repetidos conservando el orden."""
    import re as _re
    limpios = {}
    for v in valores:
        x = transformar(v)
        if not x:
            continue
        if not _re.match(patron, x):
            raise ApiError(
                status_code=422, code="VALIDATION_ERROR",
                message=ayuda,
                details=[{"field": campo, "message": f"Valor recibido: {v}."}],
            )
        limpios[x] = True
    return limpios


def _normaliza(s: str) -> str:
    tabla = str.maketrans("áàäâãéèëêíìïîóòöôõúùüûñç",
                          "aaaaaeeeeiiiiooooouuuunc")
    return s.strip().lower().translate(tabla)


async def _reemplazar(db: AsyncSession, tabla: str, columna: str,
                      perfil_id: str, valores) -> None:
    """Deja la lista exactamente como la mando la pantalla.

    Se borra y se vuelve a insertar porque son tablas de union sin nada
    propio que perder: no tienen id, ni historial, ni nada que apunte a
    ellas. Para las certificaciones esto no valdria, y por eso no se hacen
    aca.
    """
    await db.execute(
        text(f"DELETE FROM {tabla} WHERE profile_id = :pid"),  # noqa: S608
        {"pid": perfil_id},
    )
    for v in valores:
        await db.execute(
            text(f"INSERT INTO {tabla} (profile_id, {columna}) "  # noqa: S608
                 f"VALUES (:pid, :valor)"),
            {"pid": perfil_id, "valor": v},
        )
