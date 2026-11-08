"""Administracion del catalogo comercial, para el personal de Alloxentric.

QUE RESUELVE
    Las seis tablas que definen que da cada plan (plans, features,
    plan_features, limit_keys, plan_limits y plan_prices) estaban completas
    en el esquema y no tenian ni un endpoint que las escribiera. Armar un
    plan nuevo, o cambiar cuantos pacientes permite el gratuito, se hacia
    con SQL a mano contra la base de produccion.

    Esto lo convierte en una operacion de la aplicacion, con las reglas de
    negocio aplicadas y con registro de quien lo hizo.

QUIEN PUEDE
    Todas las rutas cuelgan de get_staff_user. No es un permiso sobre un
    paciente, es una condicion de la persona, porque el catalogo no
    pertenece a ningun expediente.

LAS REGLAS QUE VIGILA, QUE ANTES NO VIGILABA NADIE
    - Una funcionalidad del nucleo no se puede quitar de ningun plan. La
      columna features.is_core existia justamente para eso y no la miraba
      nadie: hoy nada impedia dejar al plan gratuito sin alertas de
      emergencia.
    - Un plan de pago no se puede publicar sin precio vigente. Si no,
      alguien podria contratar un plan que no sabe cuanto cuesta.
    - El plan gratuito activo no se puede archivar si es el unico. Un
      usuario nuevo se quedaria sin plan al registrarse.
    - Un precio nuevo cierra el anterior en la misma transaccion, asi la
      restriccion de exclusion de la tabla nunca se topa con dos precios
      vigentes solapados.
"""
from __future__ import annotations

from datetime import datetime
from decimal import Decimal
from uuid import UUID

from fastapi import APIRouter, Depends, Path
from pydantic import BaseModel, Field, field_validator
from sqlalchemy import text
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from app.db import get_db
from app.deps import StaffUser, get_staff_user
from app.errors import ApiError

router = APIRouter(prefix="/api/v1/admin", tags=["admin"])

_NO_EXISTE = ApiError(status_code=404, code="NOT_FOUND",
                      message="Ese plan no existe.")


def _texto(v: str) -> str:
    """Rechaza un texto que solo trae espacios.

    El largo minimo de Pydantic no alcanza: '   ' tiene tres caracteres y
    pasa, y despues la base lo rechaza con un CHECK y sale un 500 donde
    deberia haber salido un 422 explicando cual campo esta mal.
    """
    limpio = v.strip()
    if not limpio:
        raise ValueError("No puede ir vacio.")
    return limpio


# ---------------------------------------------------------------------------
# Planes
# ---------------------------------------------------------------------------
class PlanOut(BaseModel):
    id:            UUID
    code:          str
    name:          str
    description:   str | None
    tier:          int
    is_public:     bool
    status:        str
    published_at:  datetime | None
    archived_at:   datetime | None
    features_incluidas: int
    limites_fijados:    int
    precio_vigente:     Decimal | None
    moneda:             str | None
    suscripciones_activas: int


class PlanesOut(BaseModel):
    items: list[PlanOut]


_SELECT_PLANES = """
    SELECT p.id, p.code, p.name, p.description, p.tier, p.is_public,
           p.status, p.published_at, p.archived_at,
           (SELECT count(*) FROM plan_features pf
             WHERE pf.plan_id = p.id AND pf.is_included) AS features_incluidas,
           (SELECT count(*) FROM plan_limits pl
             WHERE pl.plan_id = p.id)                    AS limites_fijados,
           (SELECT pr.amount FROM plan_prices pr
             WHERE pr.plan_id = p.id AND pr.valid_to IS NULL
               AND pr.period = 'monthly'
             ORDER BY pr.valid_from DESC LIMIT 1)        AS precio_vigente,
           (SELECT pr.currency FROM plan_prices pr
             WHERE pr.plan_id = p.id AND pr.valid_to IS NULL
               AND pr.period = 'monthly'
             ORDER BY pr.valid_from DESC LIMIT 1)        AS moneda,
           (SELECT count(*) FROM subscriptions s
             WHERE s.plan_id = p.id AND s.status = 'active')
                                                         AS suscripciones_activas
    FROM plans p
"""


@router.get("/plans", response_model=PlanesOut)
async def listar_planes(
    staff: StaffUser = Depends(get_staff_user),
    db: AsyncSession = Depends(get_db),
):
    """Todos los planes, con de un vistazo lo que define a cada uno.

    Se devuelven tambien los archivados. Quien administra necesita verlos
    para entender por que hay gente con un plan que ya no se ofrece.
    """
    filas = (
        await db.execute(text(_SELECT_PLANES + " ORDER BY p.tier, p.created_at"))
    ).mappings().all()
    return PlanesOut(items=[PlanOut(**f) for f in filas])


class PlanNuevoIn(BaseModel):
    code:        str = Field(min_length=3, max_length=20,
                             pattern=r"^[a-z][a-z0-9_]{2,19}$")
    name:        str = Field(min_length=1, max_length=60)
    description: str | None = Field(default=None, max_length=300)
    tier:        int = Field(ge=0, le=10)
    is_public:   bool = True

    _n = field_validator("name")(_texto)


@router.post("/plans", response_model=PlanOut, status_code=201)
async def crear_plan(
    payload: PlanNuevoIn,
    staff: StaffUser = Depends(get_staff_user),
    db: AsyncSession = Depends(get_db),
):
    """Crea un plan en borrador.

    Nace en 'draft' siempre, sin importar lo que manden. Es lo que permite
    armarlo completo (sus funcionalidades, sus limites, su precio) antes de
    que nadie lo pueda contratar. Publicarlo es un paso aparte y con sus
    propias condiciones.
    """
    try:
        fila = (
            await db.execute(
                text(
                    """
                    INSERT INTO plans (code, name, description, tier,
                                       is_public, status, created_by)
                    VALUES (:code, :name, :desc, :tier, :pub, 'draft', :uid)
                    RETURNING id
                    """
                ),
                {"code": payload.code, "name": payload.name,
                 "desc": payload.description, "tier": payload.tier,
                 "pub": payload.is_public, "uid": staff.user_id},
            )
        ).mappings().first()
    except IntegrityError:
        await db.rollback()
        raise ApiError(
            status_code=409, code="PLAN_CODE_TAKEN",
            message=f"Ya existe un plan con el codigo '{payload.code}'.",
        )
    await db.commit()
    return await _detalle_plan_simple(db, str(fila["id"]))


async def _detalle_plan_simple(db: AsyncSession, plan_id: str) -> PlanOut:
    fila = (
        await db.execute(text(_SELECT_PLANES + " WHERE p.id = :pid"),
                         {"pid": plan_id})
    ).mappings().first()
    if fila is None:
        raise _NO_EXISTE
    return PlanOut(**fila)


class PlanEditIn(BaseModel):
    name:        str | None = Field(default=None, min_length=1, max_length=60)
    description: str | None = Field(default=None, max_length=300)
    tier:        int | None = Field(default=None, ge=0, le=10)
    is_public:   bool | None = None

    _n = field_validator("name")(lambda v: v if v is None else _texto(v))


@router.patch("/plans/{plan_id}", response_model=PlanOut)
async def editar_plan(
    payload: PlanEditIn,
    plan_id: UUID = Path(...),
    staff: StaffUser = Depends(get_staff_user),
    db: AsyncSession = Depends(get_db),
):
    """Cambia nombre, descripcion, jerarquia o visibilidad.

    El codigo no se puede cambiar. Es el identificador estable por el que
    la aplicacion reconoce al plan, y renombrarlo con gente suscrita rompe
    cualquier cosa que lo tenga escrito.
    """
    cambios = payload.model_dump(exclude_unset=True)
    if not cambios:
        return await _detalle_plan_simple(db, str(plan_id))

    campos = {"name": "name", "description": "description",
              "tier": "tier", "is_public": "is_public"}
    sets = ", ".join(f"{campos[k]} = :{k}" for k in cambios)
    cambios["pid"] = str(plan_id)

    try:
        r = await db.execute(
            text(f"UPDATE plans SET {sets}, updated_at = now() WHERE id = :pid"),
            cambios,
        )
    except IntegrityError:
        await db.rollback()
        raise ApiError(
            status_code=409, code="PLAN_TIER_TAKEN",
            message="Ya hay otro plan gratuito activo. Solo puede haber uno.",
        )
    if r.rowcount == 0:
        raise _NO_EXISTE
    await db.commit()
    return await _detalle_plan_simple(db, str(plan_id))


@router.post("/plans/{plan_id}/publish", response_model=PlanOut)
async def publicar_plan(
    plan_id: UUID = Path(...),
    staff: StaffUser = Depends(get_staff_user),
    db: AsyncSession = Depends(get_db),
):
    """Deja el plan disponible para contratar.

    Dos condiciones antes de abrirlo, y las dos tapan un problema real.

    Un plan de pago sin precio vigente no se publica: alguien podria
    contratarlo y el sistema no sabria cuanto cobrarle.

    Y el plan no puede quedar sin las funcionalidades del nucleo. Si se
    publica un plan al que le falta alguna, se agrega sola antes de
    publicar, en vez de rechazar la operacion: olvidar marcarla es un
    descuido esperable y el resultado correcto es el mismo.
    """
    plan = (
        await db.execute(
            text("SELECT id, tier, status FROM plans WHERE id = :pid"),
            {"pid": str(plan_id)},
        )
    ).mappings().first()
    if plan is None:
        raise _NO_EXISTE
    if plan["status"] == "archived":
        raise ApiError(
            status_code=409, code="PLAN_ARCHIVED",
            message="Un plan archivado no se puede volver a publicar. "
                    "Crea uno nuevo si hay que volver a ofrecerlo.",
        )

    if plan["tier"] > 0:
        con_precio = (
            await db.execute(
                text(
                    """
                    SELECT 1 FROM plan_prices
                     WHERE plan_id = :pid AND valid_to IS NULL LIMIT 1
                    """
                ),
                {"pid": str(plan_id)},
            )
        ).first()
        if con_precio is None:
            raise ApiError(
                status_code=409, code="PLAN_SIN_PRECIO",
                message="Este plan es de pago y no tiene precio vigente. "
                        "Agregale un precio antes de publicarlo.",
            )

    # Las del nucleo entran solas si faltaban.
    await db.execute(
        text(
            """
            INSERT INTO plan_features (plan_id, feature_code, is_included, note)
            SELECT :pid, f.code, true, 'Del nucleo: se agrego al publicar.'
              FROM features f
             WHERE f.is_core
               AND NOT EXISTS (SELECT 1 FROM plan_features pf
                                WHERE pf.plan_id = :pid
                                  AND pf.feature_code = f.code)
            """
        ),
        {"pid": str(plan_id)},
    )
    await db.execute(
        text(
            """
            UPDATE plan_features pf SET is_included = true
              FROM features f
             WHERE f.code = pf.feature_code
               AND pf.plan_id = :pid AND f.is_core AND NOT pf.is_included
            """
        ),
        {"pid": str(plan_id)},
    )

    if plan["status"] == "draft":
        try:
            await db.execute(
                text(
                    """
                    UPDATE plans
                       SET status = 'active', published_at = now(),
                           updated_at = now()
                     WHERE id = :pid
                    """
                ),
                {"pid": str(plan_id)},
            )
        except IntegrityError:
            await db.rollback()
            raise ApiError(
                status_code=409, code="PLAN_GRATUITO_DUPLICADO",
                message="Ya hay un plan gratuito activo. Archiva el actual "
                        "antes de publicar otro.",
            )
    await db.commit()
    return await _detalle_plan_simple(db, str(plan_id))


@router.post("/plans/{plan_id}/archive", response_model=PlanOut)
async def archivar_plan(
    plan_id: UUID = Path(...),
    staff: StaffUser = Depends(get_staff_user),
    db: AsyncSession = Depends(get_db),
):
    """Deja de ofrecer el plan, sin tocar a quien ya lo tiene.

    Archivar no es borrar. Quien esta suscrito lo conserva, y por eso se
    permite archivar un plan con suscripciones activas: es la unica forma
    de dejar de vender algo sin echar a los clientes que ya lo compraron.

    Lo que si se bloquea es archivar el ultimo plan gratuito activo. Sin un
    plan gratuito vigente, un usuario nuevo se queda sin plan al
    registrarse, y eso no se nota hasta que alguien se registra.
    """
    plan = (
        await db.execute(
            text("SELECT tier, status FROM plans WHERE id = :pid"),
            {"pid": str(plan_id)},
        )
    ).mappings().first()
    if plan is None:
        raise _NO_EXISTE
    if plan["status"] != "active":
        raise ApiError(
            status_code=409, code="PLAN_NO_ACTIVO",
            message="Solo se puede archivar un plan que este activo.",
        )

    if plan["tier"] == 0:
        otros = (
            await db.execute(
                text(
                    """
                    SELECT count(*) FROM plans
                     WHERE tier = 0 AND status = 'active' AND id <> :pid
                    """
                ),
                {"pid": str(plan_id)},
            )
        ).scalar()
        if not otros:
            raise ApiError(
                status_code=409, code="ULTIMO_PLAN_GRATUITO",
                message="Es el unico plan gratuito activo. Publica otro "
                        "antes de archivar este, o quien se registre se "
                        "quedaria sin plan.",
            )

    await db.execute(
        text(
            """
            UPDATE plans SET status = 'archived', archived_at = now(),
                             updated_at = now()
             WHERE id = :pid
            """
        ),
        {"pid": str(plan_id)},
    )
    await db.commit()
    return await _detalle_plan_simple(db, str(plan_id))


# ---------------------------------------------------------------------------
# Detalle de un plan: que incluye, cuanto permite, cuanto cuesta
# ---------------------------------------------------------------------------
class FeatureDelPlan(BaseModel):
    code:        str
    label:       str
    description: str
    module:      str
    is_core:     bool
    is_included: bool
    note:        str | None


class LimiteDelPlan(BaseModel):
    key:         str
    label:       str
    description: str
    unit:        str
    value:       int | None
    fijado:      bool


class PrecioOut(BaseModel):
    id:         UUID
    currency:   str
    period:     str
    amount:     Decimal
    valid_from: datetime
    valid_to:   datetime | None


class PlanDetalleOut(BaseModel):
    plan:     PlanOut
    features: list[FeatureDelPlan]
    limites:  list[LimiteDelPlan]
    precios:  list[PrecioOut]


@router.get("/plans/{plan_id}", response_model=PlanDetalleOut)
async def detalle_plan(
    plan_id: UUID = Path(...),
    staff: StaffUser = Depends(get_staff_user),
    db: AsyncSession = Depends(get_db),
):
    """Todo lo que define al plan, en una sola respuesta.

    Las funcionalidades y los limites se devuelven desde el CATALOGO
    completo, no desde lo que el plan tiene cargado. O sea, aparecen
    tambien los que este plan no incluye, marcados como tales.

    Es la diferencia entre una pantalla donde se ve que falta y una donde
    solo se ve lo que ya esta. Para decidir que da un plan hay que poder
    ver todo lo que PODRIA dar.
    """
    plan = await _detalle_plan_simple(db, str(plan_id))

    features = (
        await db.execute(
            text(
                """
                SELECT f.code, f.label, f.description, f.module, f.is_core,
                       coalesce(pf.is_included, false) AS is_included,
                       pf.note
                  FROM features f
                  LEFT JOIN plan_features pf
                         ON pf.feature_code = f.code AND pf.plan_id = :pid
                 ORDER BY f.module, f.code
                """
            ),
            {"pid": str(plan_id)},
        )
    ).mappings().all()

    limites = (
        await db.execute(
            text(
                """
                SELECT lk.key, lk.label, lk.description, lk.unit,
                       pl.limit_value AS value,
                       (pl.plan_id IS NOT NULL) AS fijado
                  FROM limit_keys lk
                  LEFT JOIN plan_limits pl
                         ON pl.limit_key = lk.key AND pl.plan_id = :pid
                 ORDER BY lk.key
                """
            ),
            {"pid": str(plan_id)},
        )
    ).mappings().all()

    precios = (
        await db.execute(
            text(
                """
                SELECT id, currency, period, amount, valid_from, valid_to
                  FROM plan_prices WHERE plan_id = :pid
                 ORDER BY period, valid_from DESC
                """
            ),
            {"pid": str(plan_id)},
        )
    ).mappings().all()

    return PlanDetalleOut(
        plan=plan,
        features=[FeatureDelPlan(**f) for f in features],
        limites=[LimiteDelPlan(**l) for l in limites],
        precios=[PrecioOut(**p) for p in precios],
    )


class FeatureDelPlanIn(BaseModel):
    is_included: bool
    note:        str | None = Field(default=None, max_length=200)


@router.put("/plans/{plan_id}/features/{feature_code}",
            response_model=FeatureDelPlan)
async def fijar_feature(
    payload: FeatureDelPlanIn,
    plan_id: UUID = Path(...),
    feature_code: str = Path(..., max_length=40),
    staff: StaffUser = Depends(get_staff_user),
    db: AsyncSession = Depends(get_db),
):
    """Decide si el plan incluye esa funcionalidad.

    Aca vive la regla mas importante de toda la administracion: una
    funcionalidad del nucleo no se puede quitar de ningun plan.

    features.is_core existia desde el principio y no la consultaba nadie,
    asi que hasta hoy nada impedia dejar al plan gratuito sin alertas en
    tiempo real. Ese es el tipo de cambio que se hace sin querer, en una
    pantalla de administracion, un martes, y que nadie nota hasta que a
    una familia no le llega el aviso de una caida.
    """
    f = (
        await db.execute(
            text("SELECT code, is_core, label FROM features WHERE code = :c"),
            {"c": feature_code},
        )
    ).mappings().first()
    if f is None:
        raise ApiError(status_code=404, code="NOT_FOUND",
                       message="Esa funcionalidad no existe en el catalogo.")

    existe = (
        await db.execute(text("SELECT 1 FROM plans WHERE id = :pid"),
                         {"pid": str(plan_id)})
    ).first()
    if existe is None:
        raise _NO_EXISTE

    if f["is_core"] and not payload.is_included:
        raise ApiError(
            status_code=409, code="FEATURE_DEL_NUCLEO",
            message=f"'{f['label']}' es del nucleo y ningun plan puede "
                    "quitarla.",
        )

    await db.execute(
        text(
            """
            INSERT INTO plan_features (plan_id, feature_code, is_included, note)
            VALUES (:pid, :code, :inc, :note)
            ON CONFLICT (plan_id, feature_code) DO UPDATE
                SET is_included = EXCLUDED.is_included,
                    note        = EXCLUDED.note
            """
        ),
        {"pid": str(plan_id), "code": feature_code,
         "inc": payload.is_included, "note": payload.note},
    )
    await db.commit()

    fila = (
        await db.execute(
            text(
                """
                SELECT f.code, f.label, f.description, f.module, f.is_core,
                       pf.is_included, pf.note
                  FROM features f
                  JOIN plan_features pf ON pf.feature_code = f.code
                 WHERE f.code = :c AND pf.plan_id = :pid
                """
            ),
            {"c": feature_code, "pid": str(plan_id)},
        )
    ).mappings().first()
    return FeatureDelPlan(**fila)


class LimiteIn(BaseModel):
    # Nulo significa SIN LIMITE, que es distinto de cero. Cero es
    # "permitido cero veces", o sea prohibido.
    value: int | None = Field(default=None, ge=0)


@router.put("/plans/{plan_id}/limits/{limit_key}", response_model=LimiteDelPlan)
async def fijar_limite(
    payload: LimiteIn,
    plan_id: UUID = Path(...),
    limit_key: str = Path(..., max_length=40),
    staff: StaffUser = Depends(get_staff_user),
    db: AsyncSession = Depends(get_db),
):
    """Fija cuanto permite el plan de ese limite.

    Vacio es SIN LIMITE y cero es PROHIBIDO. Son dos cosas distintas y la
    pantalla tiene que dejarlas elegir por separado: el plan premium no
    tiene tope de pacientes (vacio) y el gratuito permite cero consultas al
    asistente (cero). Un solo campo numerico sin esa distincion obligaria a
    inventar un 999999 para representar "sin tope", que es un tope igual,
    solo que escondido.
    """
    lk = (
        await db.execute(
            text("SELECT key, label FROM limit_keys WHERE key = :k"),
            {"k": limit_key},
        )
    ).mappings().first()
    if lk is None:
        raise ApiError(status_code=404, code="NOT_FOUND",
                       message="Ese limite no existe en el catalogo.")
    existe = (
        await db.execute(text("SELECT 1 FROM plans WHERE id = :pid"),
                         {"pid": str(plan_id)})
    ).first()
    if existe is None:
        raise _NO_EXISTE

    await db.execute(
        text(
            """
            INSERT INTO plan_limits (plan_id, limit_key, limit_value)
            VALUES (:pid, :k, :v)
            ON CONFLICT (plan_id, limit_key) DO UPDATE
                SET limit_value = EXCLUDED.limit_value,
                    updated_at  = now()
            """
        ),
        {"pid": str(plan_id), "k": limit_key, "v": payload.value},
    )
    await db.commit()

    fila = (
        await db.execute(
            text(
                """
                SELECT lk.key, lk.label, lk.description, lk.unit,
                       pl.limit_value AS value, true AS fijado
                  FROM limit_keys lk
                  JOIN plan_limits pl ON pl.limit_key = lk.key
                 WHERE lk.key = :k AND pl.plan_id = :pid
                """
            ),
            {"k": limit_key, "pid": str(plan_id)},
        )
    ).mappings().first()
    return LimiteDelPlan(**fila)


@router.delete("/plans/{plan_id}/limits/{limit_key}", status_code=204)
async def soltar_limite(
    plan_id: UUID = Path(...),
    limit_key: str = Path(..., max_length=40),
    staff: StaffUser = Depends(get_staff_user),
    db: AsyncSession = Depends(get_db),
):
    """Quita el limite del plan, que no es lo mismo que ponerlo sin tope.

    Sin fila, el plan no declara nada sobre ese limite. Con fila y valor
    vacio, declara explicitamente que no tiene tope. La diferencia importa
    el dia que se agrega un limite nuevo al catalogo: los planes sin fila
    son los que nadie reviso todavia.
    """
    await db.execute(
        text("DELETE FROM plan_limits WHERE plan_id = :pid AND limit_key = :k"),
        {"pid": str(plan_id), "k": limit_key},
    )
    await db.commit()


# ---------------------------------------------------------------------------
# Precios
# ---------------------------------------------------------------------------
class PrecioNuevoIn(BaseModel):
    period:   str = Field(pattern="^(monthly|yearly|once)$")
    amount:   Decimal = Field(ge=0, max_digits=12, decimal_places=2)
    currency: str = Field(default="CLP", pattern="^[A-Z]{3}$")


@router.post("/plans/{plan_id}/prices", response_model=PrecioOut, status_code=201)
async def nuevo_precio(
    payload: PrecioNuevoIn,
    plan_id: UUID = Path(...),
    staff: StaffUser = Depends(get_staff_user),
    db: AsyncSession = Depends(get_db),
):
    """Pone un precio nuevo y cierra el anterior en el mismo instante.

    POR QUE NO SE EDITA EL PRECIO QUE YA ESTABA
        Porque los cobros ya emitidos apuntan al precio con que se
        cobraron. Editar la fila cambiaria retroactivamente lo que decia
        una boleta de marzo, y entonces el historial dejaria de cuadrar
        con la contabilidad.

        Subir un precio es un hecho con fecha, no una correccion. Se cierra
        el vigente y nace otro.

    POR QUE LOS DOS PASOS VAN JUNTOS
        La tabla tiene una restriccion de exclusion que prohibe dos precios
        vigentes que se solapen para el mismo plan, moneda y periodo.
        Insertar primero y cerrar despues la violaria en el intervalo entre
        las dos sentencias. Cerrando el anterior en la misma transaccion y
        en el mismo instante, los rangos se tocan sin solaparse y la base
        nunca ve un estado invalido.
    """
    existe = (
        await db.execute(text("SELECT 1 FROM plans WHERE id = :pid"),
                         {"pid": str(plan_id)})
    ).first()
    if existe is None:
        raise _NO_EXISTE

    ahora = (await db.execute(text("SELECT now()"))).scalar()

    await db.execute(
        text(
            """
            UPDATE plan_prices SET valid_to = :ahora
             WHERE plan_id = :pid AND currency = :cur AND period = :per
               AND valid_to IS NULL
            """
        ),
        {"pid": str(plan_id), "cur": payload.currency,
         "per": payload.period, "ahora": ahora},
    )

    try:
        fila = (
            await db.execute(
                text(
                    """
                    INSERT INTO plan_prices (plan_id, currency, period, amount,
                                             valid_from, created_by)
                    VALUES (:pid, :cur, :per, :amt, :ahora, :uid)
                    RETURNING id, currency, period, amount, valid_from, valid_to
                    """
                ),
                {"pid": str(plan_id), "cur": payload.currency,
                 "per": payload.period, "amt": payload.amount,
                 "ahora": ahora, "uid": staff.user_id},
            )
        ).mappings().first()
    except IntegrityError:
        await db.rollback()
        raise ApiError(
            status_code=409, code="PRECIO_SOLAPADO",
            message="Ya hay un precio vigente para ese periodo y moneda que "
                    "se cruza con este. Revisa las vigencias.",
        )
    await db.commit()
    return PrecioOut(**fila)


# ---------------------------------------------------------------------------
# Catalogos: funcionalidades y limites
# ---------------------------------------------------------------------------
class FeatureOut(BaseModel):
    code:        str
    label:       str
    description: str
    module:      str
    is_core:     bool
    planes_que_la_incluyen: int


class FeaturesOut(BaseModel):
    items: list[FeatureOut]


_MODULOS = ("health", "medication", "alerts", "logbook", "documents",
            "chat", "assistant", "elder", "marketplace", "reports")


@router.get("/features", response_model=FeaturesOut)
async def listar_features(
    staff: StaffUser = Depends(get_staff_user),
    db: AsyncSession = Depends(get_db),
):
    """El catalogo de funcionalidades, con en cuantos planes esta cada una.

    Ese conteo es lo que permite decidir si una funcionalidad vale la pena:
    una que no incluye ningun plan es trabajo que nadie esta vendiendo.
    """
    filas = (
        await db.execute(
            text(
                """
                SELECT f.code, f.label, f.description, f.module, f.is_core,
                       (SELECT count(*) FROM plan_features pf
                         JOIN plans p ON p.id = pf.plan_id
                        WHERE pf.feature_code = f.code AND pf.is_included
                          AND p.status <> 'archived') AS planes_que_la_incluyen
                  FROM features f ORDER BY f.module, f.code
                """
            )
        )
    ).mappings().all()
    return FeaturesOut(items=[FeatureOut(**f) for f in filas])


class FeatureNuevaIn(BaseModel):
    code:        str = Field(pattern=r"^[a-z][a-z0-9_]{2,39}$")
    label:       str = Field(min_length=1, max_length=80)
    description: str = Field(min_length=1, max_length=300)
    module:      str
    is_core:     bool = False

    _l = field_validator("label")(_texto)
    _d = field_validator("description")(_texto)

    @field_validator("module")
    @classmethod
    def _modulo(cls, v: str) -> str:
        if v not in _MODULOS:
            raise ValueError(f"Modulo invalido. Opciones: {', '.join(_MODULOS)}.")
        return v


@router.post("/features", response_model=FeatureOut, status_code=201)
async def crear_feature(
    payload: FeatureNuevaIn,
    staff: StaffUser = Depends(get_staff_user),
    db: AsyncSession = Depends(get_db),
):
    """Agrega una funcionalidad al catalogo.

    La descripcion es obligatoria porque es el texto que ve el cliente en
    la pantalla de comparacion de planes. Si fuera opcional, tarde o
    temprano habria una linea sin explicacion y el usuario tendria que
    adivinar que esta contratando.

    Crear una funcionalidad NO la agrega a ningun plan. Nace fuera de
    todos, y se decide plan por plan, que es justamente el control que la
    empresa pidio tener.
    """
    try:
        await db.execute(
            text(
                """
                INSERT INTO features (code, label, description, module, is_core)
                VALUES (:c, :l, :d, :m, :core)
                """
            ),
            {"c": payload.code, "l": payload.label, "d": payload.description,
             "m": payload.module, "core": payload.is_core},
        )
    except IntegrityError:
        await db.rollback()
        raise ApiError(
            status_code=409, code="FEATURE_CODE_TAKEN",
            message=f"Ya existe una funcionalidad con el codigo "
                    f"'{payload.code}'.",
        )
    await db.commit()
    fila = (
        await db.execute(
            text(
                """
                SELECT code, label, description, module, is_core,
                       0 AS planes_que_la_incluyen
                  FROM features WHERE code = :c
                """
            ),
            {"c": payload.code},
        )
    ).mappings().first()
    return FeatureOut(**fila)


class LimitKeyOut(BaseModel):
    key:         str
    label:       str
    description: str
    unit:        str
    planes_que_lo_fijan: int


class LimitKeysOut(BaseModel):
    items: list[LimitKeyOut]


_UNIDADES = ("count", "days", "months", "megabytes", "per_month", "per_day")


@router.get("/limit-keys", response_model=LimitKeysOut)
async def listar_limites(
    staff: StaffUser = Depends(get_staff_user),
    db: AsyncSession = Depends(get_db),
):
    """El catalogo de limites que un plan puede imponer."""
    filas = (
        await db.execute(
            text(
                """
                SELECT lk.key, lk.label, lk.description, lk.unit,
                       (SELECT count(*) FROM plan_limits pl
                         JOIN plans p ON p.id = pl.plan_id
                        WHERE pl.limit_key = lk.key
                          AND p.status <> 'archived') AS planes_que_lo_fijan
                  FROM limit_keys lk ORDER BY lk.key
                """
            )
        )
    ).mappings().all()
    return LimitKeysOut(items=[LimitKeyOut(**f) for f in filas])


class LimitKeyNuevaIn(BaseModel):
    key:         str = Field(pattern=r"^[a-z][a-z0-9_]{2,39}$")
    label:       str = Field(min_length=1, max_length=80)
    description: str = Field(min_length=1, max_length=300)
    unit:        str

    _l = field_validator("label")(_texto)
    _d = field_validator("description")(_texto)

    @field_validator("unit")
    @classmethod
    def _unidad(cls, v: str) -> str:
        if v not in _UNIDADES:
            raise ValueError(f"Unidad invalida. Opciones: {', '.join(_UNIDADES)}.")
        return v


@router.post("/limit-keys", response_model=LimitKeyOut, status_code=201)
async def crear_limite(
    payload: LimitKeyNuevaIn,
    staff: StaffUser = Depends(get_staff_user),
    db: AsyncSession = Depends(get_db),
):
    """Agrega un limite al catalogo.

    La unidad vive aca y no en plan_limits. Es la correccion de segunda
    forma normal del modelo: la unidad depende del limite y de nada mas,
    asi que repetirla en cada plan permitiria que dos planes dijeran que
    el mismo limite se mide en cosas distintas.
    """
    try:
        await db.execute(
            text(
                """
                INSERT INTO limit_keys (key, label, description, unit)
                VALUES (:k, :l, :d, :u)
                """
            ),
            {"k": payload.key, "l": payload.label,
             "d": payload.description, "u": payload.unit},
        )
    except IntegrityError:
        await db.rollback()
        raise ApiError(
            status_code=409, code="LIMIT_KEY_TAKEN",
            message=f"Ya existe un limite con la clave '{payload.key}'.",
        )
    await db.commit()
    fila = (
        await db.execute(
            text(
                """
                SELECT key, label, description, unit, 0 AS planes_que_lo_fijan
                  FROM limit_keys WHERE key = :k
                """
            ),
            {"k": payload.key},
        )
    ).mappings().first()
    return LimitKeyOut(**fila)
