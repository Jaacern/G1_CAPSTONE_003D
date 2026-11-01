"""Marketplace: buscar cuidadoras, contactarlas y resenarlas.

Endpoints que la aplicacion ya consume:

    GET  /marketplace/caregivers
    GET  /marketplace/caregivers/{id}
    POST /marketplace/caregivers/{id}/contact
    POST /marketplace/caregivers/{id}/reviews
    GET  /marketplace/products
    GET  /marketplace/products/{id}
"""
from datetime import datetime
from uuid import UUID

from fastapi import APIRouter, Depends, Query
from pydantic import BaseModel, Field, field_validator
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

from app.db import get_db
from app.deps import CurrentUser, get_current_user
from app.errors import ApiError

router = APIRouter(prefix="/api/v1/marketplace", tags=["marketplace"])

# Las ofertas de trabajo cuelgan de /jobs y no de /marketplace/jobs, que es
# como las pide la aplicacion. Van en un router aparte para no inventarles
# una ruta que el front no consulta.
jobs_router = APIRouter(prefix="/api/v1", tags=["marketplace"])

_NO_EXISTE = ApiError(
    status_code=404, code="NOT_FOUND",
    message="El recurso solicitado no existe o no esta disponible.",
)


class CaregiverSummary(BaseModel):
    profile_id:     UUID
    name:           str
    photo_url:      str | None
    headline:       str
    rating:         float
    reviews_count:  int
    zones:          list[str]
    specialties:    list[str]
    price_per_hour: float | None


class CaregiversOut(BaseModel):
    items: list[CaregiverSummary]


@router.get("/caregivers", response_model=CaregiversOut)
async def list_caregivers(
    zone: str | None = Query(default=None, max_length=8),
    specialty: str | None = Query(default=None, max_length=40),
    user: CurrentUser = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Busca cuidadoras publicadas, con filtro por comuna y especialidad.

    Solo salen los perfiles publicados y no suspendidos. Un perfil a medio
    escribir no deberia aparecerle a una familia que esta eligiendo a quien
    le deja a su madre.

    Las dos listas se traen en la misma consulta con agregacion, no una
    consulta por cuidadora: con cien perfiles en pantalla eso serian
    doscientas consultas.
    """
    filas = (
        await db.execute(
            text(
                """
                SELECT cp.id, cp.headline, cp.rating_avg, cp.rating_count,
                       cp.hourly_rate, u.full_name, u.avatar_url,
                       coalesce(z.zonas, ARRAY[]::text[])        AS zonas,
                       coalesce(e.especialidades, ARRAY[]::text[]) AS especialidades
                FROM caregiver_profiles cp
                JOIN users u ON u.id = cp.user_id
                LEFT JOIN LATERAL (
                    SELECT array_agg(cz.commune_code ORDER BY cz.commune_code) AS zonas
                    FROM caregiver_zones cz WHERE cz.profile_id = cp.id
                ) z ON true
                LEFT JOIN LATERAL (
                    SELECT array_agg(s.label ORDER BY s.label) AS especialidades
                    FROM caregiver_specialties cs
                    JOIN specialties s ON s.code = cs.specialty_code
                    WHERE cs.profile_id = cp.id
                ) e ON true
                WHERE cp.status = 'published'
                  AND cp.suspended_at IS NULL
                  AND cp.deleted_at IS NULL
                  AND u.is_active
                  AND u.deleted_at IS NULL
                  -- Los parametros van con CAST: usados solo dentro de un IS NULL
                  -- el motor no tiene como deducir de que tipo son y rechaza
                  -- la consulta. Se escribe CAST(...) y no ::text porque
                  -- text() de SQLAlchemy confunde los dos puntos del cast
                  -- con el inicio de otro parametro.
                  AND (CAST(:zona AS text) IS NULL OR EXISTS (
                        SELECT 1 FROM caregiver_zones cz
                        WHERE cz.profile_id = cp.id
                          AND cz.commune_code = CAST(:zona AS text)))
                  AND (CAST(:esp AS text) IS NULL OR EXISTS (
                        SELECT 1 FROM caregiver_specialties cs
                        JOIN specialties s ON s.code = cs.specialty_code
                        WHERE cs.profile_id = cp.id
                          AND (cs.specialty_code = CAST(:esp AS text)
                               OR lower(s.label) = lower(CAST(:esp AS text)))))
                ORDER BY cp.rating_avg DESC NULLS LAST,
                         cp.rating_count DESC,
                         u.full_name
                LIMIT 100
                """
            ),
            {"zona": zone, "esp": specialty},
        )
    ).mappings().all()

    return CaregiversOut(items=[
        CaregiverSummary(
            profile_id=f["id"],
            name=f["full_name"],
            photo_url=f["avatar_url"],
            headline=f["headline"],
            rating=float(f["rating_avg"] or 0),
            reviews_count=f["rating_count"],
            zones=list(f["zonas"]),
            specialties=list(f["especialidades"]),
            price_per_hour=float(f["hourly_rate"]) if f["hourly_rate"] is not None else None,
        )
        for f in filas
    ])


class ReviewOut(BaseModel):
    author_name: str
    rating:      int
    comment:     str
    created_at:  datetime


class CaregiverDetail(CaregiverSummary):
    bio:              str
    years_experience: int
    languages:        list[str]
    certifications:   list[str]
    reviews:          list[ReviewOut]


@router.get("/caregivers/{profile_id}", response_model=CaregiverDetail)
async def get_caregiver(
    profile_id: UUID,
    user: CurrentUser = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Ficha completa de una cuidadora, con sus resenas."""
    f = (
        await db.execute(
            text(
                """
                SELECT cp.id, cp.headline, cp.bio, cp.years_experience,
                       cp.rating_avg, cp.rating_count, cp.hourly_rate,
                       u.full_name, u.avatar_url
                FROM caregiver_profiles cp
                JOIN users u ON u.id = cp.user_id
                WHERE cp.id = :pid
                  AND cp.status = 'published'
                  AND cp.suspended_at IS NULL
                  AND cp.deleted_at IS NULL
                  AND u.is_active
                  AND u.deleted_at IS NULL
                """
            ),
            {"pid": str(profile_id)},
        )
    ).mappings().first()

    if f is None:
        raise _NO_EXISTE

    pid = str(f["id"])

    async def _lista(consulta: str) -> list[str]:
        return list(
            (await db.execute(text(consulta), {"pid": pid})).scalars().all()
        )

    zonas = await _lista(
        "SELECT commune_code FROM caregiver_zones "
        "WHERE profile_id = :pid ORDER BY commune_code")
    especialidades = await _lista(
        "SELECT s.label FROM caregiver_specialties cs "
        "JOIN specialties s ON s.code = cs.specialty_code "
        "WHERE cs.profile_id = :pid ORDER BY s.label")
    idiomas = await _lista(
        "SELECT language_code FROM caregiver_languages "
        "WHERE profile_id = :pid ORDER BY language_code")

    # Solo las certificaciones verificadas. En la ficha publica son una
    # credencial, y mostrar como tal un titulo que nadie reviso seria
    # exactamente lo que la familia no puede permitirse creer.
    certificaciones = await _lista(
        "SELECT name FROM caregiver_certifications "
        "WHERE profile_id = :pid AND deleted_at IS NULL "
        "AND verified_at IS NOT NULL "
        "ORDER BY issued_at DESC NULLS LAST, name")

    resenas = (
        await db.execute(
            text(
                """
                SELECT u.full_name, r.rating, r.comment, r.created_at
                FROM caregiver_reviews r
                JOIN users u ON u.id = r.author_id
                WHERE r.profile_id = :pid AND r.deleted_at IS NULL
                ORDER BY r.created_at DESC
                LIMIT 50
                """
            ),
            {"pid": pid},
        )
    ).mappings().all()

    return CaregiverDetail(
        profile_id=f["id"],
        name=f["full_name"],
        photo_url=f["avatar_url"],
        headline=f["headline"],
        rating=float(f["rating_avg"] or 0),
        reviews_count=f["rating_count"],
        zones=zonas,
        specialties=especialidades,
        price_per_hour=float(f["hourly_rate"]) if f["hourly_rate"] is not None else None,
        bio=f["bio"] or "",
        years_experience=f["years_experience"],
        languages=idiomas,
        certifications=certificaciones,
        reviews=[
            ReviewOut(author_name=r["full_name"], rating=r["rating"],
                      comment=r["comment"] or "", created_at=r["created_at"])
            for r in resenas
        ],
    )


async def _perfil_publicado(db: AsyncSession, profile_id: UUID):
    fila = (
        await db.execute(
            text(
                """
                SELECT cp.id, cp.user_id
                FROM caregiver_profiles cp
                JOIN users u ON u.id = cp.user_id
                WHERE cp.id = :pid
                  AND cp.status = 'published'
                  AND cp.suspended_at IS NULL
                  AND cp.deleted_at IS NULL
                  AND u.is_active AND u.deleted_at IS NULL
                """
            ),
            {"pid": str(profile_id)},
        )
    ).mappings().first()
    if fila is None:
        raise _NO_EXISTE
    return fila


class ContactIn(BaseModel):
    message:    str = Field(min_length=1, max_length=1000)
    patient_id: UUID | None = None

    @field_validator("message")
    @classmethod
    def _limpiar(cls, v: str) -> str:
        limpio = v.strip()
        if not limpio:
            raise ValueError("El mensaje no puede quedar vacio.")
        return limpio


class ContactOut(BaseModel):
    id:         UUID
    status:     str
    created_at: datetime


@router.post("/caregivers/{profile_id}/contact", response_model=ContactOut,
             status_code=201)
async def contact_caregiver(
    profile_id: UUID,
    payload: ContactIn,
    user: CurrentUser = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Envia una solicitud de contacto a la cuidadora."""
    perfil = await _perfil_publicado(db, profile_id)

    if str(perfil["user_id"]) == user.user_id:
        raise ApiError(
            status_code=422, code="VALIDATION_ERROR",
            message="No puedes enviarte una solicitud de contacto a ti misma.",
        )

    if payload.patient_id is not None:
        miembro = (
            await db.execute(
                text(
                    """
                    SELECT 1 FROM patient_members
                    WHERE patient_id = :pid AND user_id = :uid
                      AND removed_at IS NULL
                    """
                ),
                {"pid": str(payload.patient_id), "uid": user.user_id},
            )
        ).first()
        if miembro is None:
            raise _NO_EXISTE

    # ux_contact_requests_pendiente deja una sola solicitud pendiente entre
    # las mismas dos personas. Reenviar no es un error del usuario: es que
    # no le han respondido y vuelve a escribir. Se actualiza el mensaje de
    # la que ya existe en vez de fallar.
    fila = (
        await db.execute(
            text(
                """
                INSERT INTO contact_requests (
                    profile_id, requester_id, patient_id, message
                ) VALUES (:perfil, :uid, :paciente, :mensaje)
                ON CONFLICT (profile_id, requester_id)
                    WHERE status = 'pending'
                DO UPDATE SET message = EXCLUDED.message,
                              patient_id = EXCLUDED.patient_id,
                              updated_at = now()
                RETURNING id, status, created_at
                """
            ),
            {
                "perfil": str(perfil["id"]), "uid": user.user_id,
                "paciente": str(payload.patient_id) if payload.patient_id else None,
                "mensaje": payload.message,
            },
        )
    ).mappings().first()
    await db.commit()

    return ContactOut(id=fila["id"], status=fila["status"],
                      created_at=fila["created_at"])


class ReviewIn(BaseModel):
    rating:     int = Field(ge=1, le=5)
    comment:    str = Field(default="", max_length=1000)
    patient_id: UUID | None = None


@router.post("/caregivers/{profile_id}/reviews", response_model=ReviewOut,
             status_code=201)
async def add_review(
    profile_id: UUID,
    payload: ReviewIn,
    user: CurrentUser = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Deja una resena a una cuidadora (RF-78).

    Solo puede resenar quien de verdad compartio el cuidado de un paciente
    con ella. Las dos claves foraneas compuestas de la tabla lo garantizan
    en el motor, asi que una resena inventada no entra ni por error de
    programacion. Aca se resuelve cual es ese paciente y se devuelven
    errores que se entienden, en vez de dejar que el motor responda con un
    503.
    """
    perfil = await _perfil_publicado(db, profile_id)
    cuidadora = str(perfil["user_id"])

    if cuidadora == user.user_id:
        raise ApiError(
            status_code=422, code="VALIDATION_ERROR",
            message="No puedes resenarte a ti misma.",
        )

    # Pacientes donde los dos son miembros vivos. Es exactamente lo que las
    # dos FK compuestas van a exigir despues.
    compartidos = (
        await db.execute(
            text(
                """
                SELECT a.patient_id
                FROM patient_members a
                JOIN patient_members b ON b.patient_id = a.patient_id
                JOIN patients p ON p.id = a.patient_id
                WHERE a.user_id = :autor
                  AND b.user_id = :cuidadora
                  AND a.removed_at IS NULL
                  AND b.removed_at IS NULL
                  AND p.deleted_at IS NULL
                ORDER BY a.created_at
                """
            ),
            {"autor": user.user_id, "cuidadora": cuidadora},
        )
    ).scalars().all()

    if not compartidos:
        raise ApiError(
            status_code=403, code="FORBIDDEN",
            message="Solo puedes resenar a una cuidadora con la que compartiste "
                    "el cuidado de un paciente.",
        )

    if payload.patient_id is not None:
        if payload.patient_id not in compartidos:
            raise ApiError(
                status_code=403, code="FORBIDDEN",
                message="No compartiste el cuidado de ese paciente con esta cuidadora.",
            )
        paciente = str(payload.patient_id)
    else:
        paciente = str(compartidos[0])

    # uq_caregiver_reviews_autor deja una resena por persona. Cambiar de
    # opinion es legitimo, asi que la segunda reemplaza a la primera en vez
    # de rechazarse. El trigger recalcula el promedio del perfil solo.
    fila = (
        await db.execute(
            text(
                """
                INSERT INTO caregiver_reviews (
                    profile_id, reviewed_user_id, author_id, patient_id,
                    rating, comment
                ) VALUES (
                    :perfil, :cuidadora, :autor, :paciente, :nota, :comentario
                )
                ON CONFLICT (profile_id, author_id) DO UPDATE
                   SET rating = EXCLUDED.rating,
                       comment = EXCLUDED.comment,
                       patient_id = EXCLUDED.patient_id,
                       deleted_at = NULL,
                       updated_at = now()
                RETURNING rating, comment, created_at
                """
            ),
            {
                "perfil": str(perfil["id"]), "cuidadora": cuidadora,
                "autor": user.user_id, "paciente": paciente,
                "nota": payload.rating,
                "comentario": payload.comment.strip() or None,
            },
        )
    ).mappings().first()
    await db.commit()

    return ReviewOut(
        author_name=user.full_name,
        rating=fila["rating"],
        comment=fila["comment"] or "",
        created_at=fila["created_at"],
    )


# ---------------------------------------------------------------------------
# Catalogo de ayudas tecnicas
# ---------------------------------------------------------------------------
class ProductOut(BaseModel):
    id:           UUID
    name:         str
    description:  str
    category:     str
    price:        float
    currency:     str
    supplier:     str | None
    supplier_url: str | None
    image_url:    str | None


class ProductsOut(BaseModel):
    items: list[ProductOut]


_CATEGORIAS = {"mobility", "bathroom", "bedroom", "hygiene",
               "monitoring", "nutrition", "other"}


def _producto(f) -> ProductOut:
    from app.storage import get_storage
    return ProductOut(
        id=f["id"],
        name=f["name"],
        description=f["description"],
        category=f["category"],
        # La pantalla espera un numero y muestra el precio formateado. Un
        # producto sin precio de referencia sale en cero, que ella ya sabe
        # dibujar, en vez de romperle el modelo con un nulo.
        price=float(f["price"]) if f["price"] is not None else 0.0,
        currency=f["currency"],
        supplier=f["supplier"],
        supplier_url=f["supplier_url"],
        image_url=(get_storage().file_url(file_id=str(f["image_file_id"]),
                                          storage_key="")
                   if f["image_file_id"] else None),
    )


_COLUMNAS = ("id, name, description, category, price, currency, "
             "supplier, supplier_url, image_file_id")


@router.get("/products", response_model=ProductsOut)
async def list_products(
    category: str | None = Query(default=None, max_length=20),
    user: CurrentUser = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Catalogo de ayudas tecnicas, con filtro por categoria."""
    if category is not None and category not in _CATEGORIAS:
        raise ApiError(
            status_code=422, code="VALIDATION_ERROR",
            message="Esa categoria de producto no existe.",
            details=[{"field": "category",
                      "message": f"Valores aceptados: {', '.join(sorted(_CATEGORIAS))}."}],
        )

    filas = (
        await db.execute(
            text(
                f"""
                SELECT {_COLUMNAS}
                FROM market_products
                WHERE status = 'published'
                  AND deleted_at IS NULL
                  AND (CAST(:cat AS text) IS NULL OR category = CAST(:cat AS text))
                ORDER BY category, name
                LIMIT 200
                """  # noqa: S608
            ),
            {"cat": category},
        )
    ).mappings().all()

    return ProductsOut(items=[_producto(f) for f in filas])


@router.get("/products/{product_id}", response_model=ProductOut)
async def get_product(
    product_id: UUID,
    user: CurrentUser = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Detalle de un producto del catalogo."""
    f = (
        await db.execute(
            text(
                f"""
                SELECT {_COLUMNAS}
                FROM market_products
                WHERE id = :pid
                  AND status = 'published'
                  AND deleted_at IS NULL
                """  # noqa: S608
            ),
            {"pid": str(product_id)},
        )
    ).mappings().first()

    if f is None:
        raise _NO_EXISTE

    return _producto(f)


# ---------------------------------------------------------------------------
# Ofertas de trabajo
# ---------------------------------------------------------------------------
class JobOut(BaseModel):
    id:          UUID
    title:       str
    zone:        str
    pay:         str
    description: str


class JobsOut(BaseModel):
    items: list[JobOut]


_PERIODO = {
    "hour":  "por hora",
    "day":   "por dia",
    "shift": "por turno",
    "month": "mensual",
}


def _plata(monto) -> str:
    """Formato chileno: separador de miles con punto y sin decimales."""
    return f"${int(monto):,}".replace(",", ".")


def _pago(f) -> str:
    """El texto de pago que la pantalla muestra.

    Se arma aca y no en la pantalla porque depende de tres columnas y de
    si el rango esta completo. Si no hay monto, se dice que se conversa,
    que es lo que pasa de verdad, en vez de mostrar un cero.
    """
    periodo = _PERIODO.get(f["pay_period"], f["pay_period"])
    minimo, maximo = f["pay_min"], f["pay_max"]
    if minimo is None and maximo is None:
        return "A convenir"
    if minimo is not None and maximo is not None and minimo != maximo:
        return f"{_plata(minimo)} a {_plata(maximo)} {periodo}"
    return f"Desde {_plata(minimo)} {periodo}" if maximo is None \
        else f"{_plata(maximo)} {periodo}"


@jobs_router.get("/jobs", response_model=JobsOut)
async def list_jobs(
    zone: str | None = Query(default=None, max_length=8),
    user: CurrentUser = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Ofertas de trabajo abiertas, lo mas nuevo primero."""
    filas = (
        await db.execute(
            text(
                """
                SELECT id, title, description, commune_code,
                       pay_min, pay_max, pay_period
                FROM job_offers
                WHERE status = 'published'
                  AND deleted_at IS NULL
                  AND (CAST(:zona AS text) IS NULL
                       OR commune_code = CAST(:zona AS text))
                ORDER BY published_at DESC
                LIMIT 100
                """
            ),
            {"zona": zone},
        )
    ).mappings().all()

    return JobsOut(items=[
        JobOut(
            id=f["id"],
            title=f["title"],
            zone=f["commune_code"],
            pay=_pago(f),
            description=f["description"],
        )
        for f in filas
    ])
