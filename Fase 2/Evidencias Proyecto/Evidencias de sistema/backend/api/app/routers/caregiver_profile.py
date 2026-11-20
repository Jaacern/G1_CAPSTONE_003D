"""Perfil profesional de la cuidadora (RF-72) y su publicación en el
marketplace (RF-75, RF-76).

    GET /caregiver/profile          perfil completo: identidad + profesional
    PUT /caregiver/profile          guarda el perfil entero y, si se pide, lo publica
    GET /caregiver/profile/options  catálogos para la pantalla de edición

QUÉ RESUELVE
    Antes la cuidadora solo podía guardar titular, presentación, años,
    especialidades, idiomas y zonas, y el perfil quedaba para siempre en
    'draft': ningún camino lo publicaba, así que una cuidadora real nunca
    aparecía en la búsqueda de las familias. Tampoco había dónde poner su
    RUT ni separar su nombre.

    Aquí la pantalla guarda en una sola operación la identidad (nombre en
    cuatro partes, RUT, teléfono, que viven en users) y el perfil profesional
    (tarifa, disponibilidad, noches, listas). Publicar exige un perfil
    mínimo completo: una familia no puede contratar a alguien que no sabe
    quién es ni dónde trabaja.
"""
from __future__ import annotations

import re
from decimal import Decimal
from typing import Literal

from fastapi import APIRouter, Depends
from pydantic import BaseModel, Field, field_validator
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

from app.db import get_db
from app.deps import CurrentUser, get_current_user
from app.errors import ApiError
from app.routers.auth import rut_legible
from app.validators import clean_person_name, normalize_phone, parse_rut

router = APIRouter(prefix="/api/v1/caregiver", tags=["caregiver"])

Disponibilidad = Literal["full_time", "part_time", "hourly", "live_in", "weekends"]

_DISPONIBILIDAD = {
    "full_time": "Jornada completa",
    "part_time": "Media jornada",
    "hourly":    "Por horas",
    "live_in":   "Puertas adentro",
    "weekends":  "Fines de semana",
}

# Idiomas que la pantalla ofrece. El motor acepta cualquier código ISO de dos
# letras; esta lista es solo lo que se muestra para elegir.
_IDIOMAS = {
    "es": "Español", "en": "Inglés", "pt": "Portugués", "fr": "Francés",
    "de": "Alemán", "it": "Italiano", "ht": "Criollo haitiano",
}

# Lo que falta para publicar, con el texto que ve la cuidadora.
_REQUISITOS = {
    "rut":         "Tu RUT",
    "phone":       "Un teléfono de contacto",
    "headline":    "Un título para tu perfil",
    "bio":         "Una presentación de al menos 40 caracteres",
    "specialties": "Al menos una especialidad",
    "zones":       "Al menos una comuna donde trabajas",
    "languages":   "Al menos un idioma",
}


# ---------------------------------------------------------------------------
# Esquemas
# ---------------------------------------------------------------------------
class ProfileOut(BaseModel):
    # Identidad (users)
    first_name:       str
    second_name:      str | None
    last_name:        str
    second_last_name: str | None
    rut:              str | None
    phone:            str | None
    email:            str
    # Perfil profesional (caregiver_profiles)
    headline:          str
    bio:               str
    years_experience:  int
    hourly_rate:       int | None
    availability:      str
    accepts_overnight: bool
    specialties:       list[str]   # etiquetas del catálogo
    languages:         list[str]   # códigos ISO
    zones:             list[str]   # códigos de comuna
    certifications:    list[str]   # solo lectura
    # Publicación
    status:              Literal["draft", "published", "suspended"]
    missing_for_publish: list[str]


class ProfileIn(BaseModel):
    """El perfil entero, no un parche: las listas se reemplazan completas.

    Los campos de identidad son opcionales para no romper a quien todavía
    manda solo la parte profesional: ausente significa no tocarlo.
    """
    first_name:       str | None = Field(default=None, max_length=60)
    second_name:      str | None = Field(default=None, max_length=60)
    last_name:        str | None = Field(default=None, max_length=60)
    second_last_name: str | None = Field(default=None, max_length=60)
    rut:              str | None = None
    phone:            str | None = None

    headline:          str = Field(default="", max_length=120)
    bio:               str = Field(default="", max_length=2000)
    years_experience:  int = Field(default=0, ge=0, le=70)
    hourly_rate:       int | None = Field(default=None, ge=0, le=1_000_000)
    availability:      Disponibilidad | None = None
    accepts_overnight: bool | None = None
    specialties:       list[str] = Field(default_factory=list, max_length=20)
    languages:         list[str] = Field(default_factory=list, max_length=10)
    zones:             list[str] = Field(default_factory=list, max_length=60)
    # Se acepta por compatibilidad y se ignora: cada certificación puede
    # estar verificada por el personal y tener un archivo; no se reescribe
    # desde un formulario de texto.
    certifications:    list[str] = Field(default_factory=list)
    # True: publicar (si está completo). False: retirar del marketplace.
    # None: dejar el estado como está.
    published:         bool | None = None

    @field_validator("first_name", "last_name")
    @classmethod
    def _nombre(cls, v: str | None) -> str | None:
        return clean_person_name(v) if v is not None else None

    @field_validator("second_name", "second_last_name")
    @classmethod
    def _nombre_opcional(cls, v: str | None) -> str | None:
        if v is None:
            return None
        return clean_person_name(v) if v.strip() else ""

    @field_validator("rut")
    @classmethod
    def _rut(cls, v: str | None) -> str | None:
        if v is None or not v.strip():
            return None
        n, dv = parse_rut(v)
        return f"{n}-{dv}"

    @field_validator("phone")
    @classmethod
    def _telefono(cls, v: str | None) -> str | None:
        return normalize_phone(v) if v and v.strip() else None


class Opcion(BaseModel):
    code:  str
    label: str


class OptionsOut(BaseModel):
    specialties:  list[Opcion]
    languages:    list[Opcion]
    availability: list[Opcion]


# ---------------------------------------------------------------------------
# Lectura
# ---------------------------------------------------------------------------
async def _exigir_cuidadora(db: AsyncSession, user_id: str) -> None:
    """El perfil profesional es de quien cuida: cuenta de cuidador(a) o
    alguien que ya cuida a un paciente en algún círculo."""
    es = (await db.execute(
        text(
            """
            SELECT 1 FROM users u
             WHERE u.id = :uid
               AND (u.account_type = 'caregiver'
                    OR EXISTS (SELECT 1 FROM patient_members pm
                                WHERE pm.user_id = u.id AND pm.role = 'caregiver'
                                  AND pm.removed_at IS NULL))
            """
        ),
        {"uid": user_id},
    )).first()
    if not es:
        raise ApiError(
            status_code=403, code="FORBIDDEN",
            message="El perfil profesional es solo para cuentas de cuidador(a).",
        )


def _faltantes(p: dict) -> list[str]:
    falta = []
    if not p["rut"]:
        falta.append("rut")
    if not p["phone"]:
        falta.append("phone")
    if not p["headline"].strip():
        falta.append("headline")
    if len(p["bio"].strip()) < 40:
        falta.append("bio")
    for lista in ("specialties", "zones", "languages"):
        if not p[lista]:
            falta.append(lista)
    return falta


async def _perfil(db: AsyncSession, user_id: str) -> ProfileOut:
    """El perfil, o uno vacío con la identidad si todavía no lo creó: la
    pantalla se abre igual y un 404 la dejaría sin poder empezar."""
    u = (await db.execute(
        text("SELECT first_name, second_name, last_name, second_last_name, "
             "rut_number, rut_dv, phone, email FROM users WHERE id = :uid"),
        {"uid": user_id},
    )).mappings().first()

    perfil = (await db.execute(
        text(
            """
            SELECT id, headline, bio, years_experience, hourly_rate,
                   availability, accepts_overnight, status
              FROM caregiver_profiles
             WHERE user_id = :uid AND deleted_at IS NULL
            """
        ),
        {"uid": user_id},
    )).mappings().first()

    datos = {
        "first_name": u["first_name"], "second_name": u["second_name"],
        "last_name": u["last_name"], "second_last_name": u["second_last_name"],
        "rut": rut_legible(u["rut_number"], u["rut_dv"]),
        "phone": u["phone"], "email": u["email"],
        "headline": "", "bio": "", "years_experience": 0, "hourly_rate": None,
        "availability": "part_time", "accepts_overnight": False,
        "specialties": [], "languages": [], "zones": [], "certifications": [],
        "status": "draft",
    }

    if perfil is not None:
        pid = str(perfil["id"])
        tarifa = perfil["hourly_rate"]
        datos.update(
            headline=perfil["headline"],
            bio=perfil["bio"] or "",
            years_experience=perfil["years_experience"],
            hourly_rate=int(tarifa) if isinstance(tarifa, Decimal) else tarifa,
            availability=perfil["availability"],
            accepts_overnight=perfil["accepts_overnight"],
            status=perfil["status"],
            specialties=list((await db.execute(
                text("SELECT s.label FROM caregiver_specialties cs "
                     "JOIN specialties s ON s.code = cs.specialty_code "
                     "WHERE cs.profile_id = :pid ORDER BY s.label"),
                {"pid": pid})).scalars().all()),
            languages=list((await db.execute(
                text("SELECT language_code FROM caregiver_languages "
                     "WHERE profile_id = :pid ORDER BY language_code"),
                {"pid": pid})).scalars().all()),
            zones=list((await db.execute(
                text("SELECT commune_code FROM caregiver_zones "
                     "WHERE profile_id = :pid ORDER BY commune_code"),
                {"pid": pid})).scalars().all()),
            certifications=list((await db.execute(
                text("SELECT name FROM caregiver_certifications "
                     "WHERE profile_id = :pid AND deleted_at IS NULL "
                     "ORDER BY issued_at DESC NULLS LAST, name"),
                {"pid": pid})).scalars().all()),
        )

    datos["missing_for_publish"] = [_REQUISITOS[k] for k in _faltantes(datos)]
    return ProfileOut(**datos)


@router.get("/profile", response_model=ProfileOut)
async def get_profile(
    user: CurrentUser = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    await _exigir_cuidadora(db, user.user_id)
    return await _perfil(db, user.user_id)


@router.get("/profile/options", response_model=OptionsOut)
async def get_options(
    user: CurrentUser = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Catálogos para elegir en vez de escribir: la especialidad mal escrita
    no encuentra a nadie en la búsqueda de las familias."""
    filas = (await db.execute(
        text("SELECT code, label FROM specialties ORDER BY label"))).mappings().all()
    return OptionsOut(
        specialties=[Opcion(**f) for f in filas],
        languages=[Opcion(code=c, label=l) for c, l in _IDIOMAS.items()],
        availability=[Opcion(code=c, label=l) for c, l in _DISPONIBILIDAD.items()],
    )


# ---------------------------------------------------------------------------
# Escritura
# ---------------------------------------------------------------------------
def _normaliza(s: str) -> str:
    tabla = str.maketrans("áàäâãéèëêíìïîóòöôõúùüûñç",
                          "aaaaaeeeeiiiiooooouuuunc")
    return s.strip().lower().translate(tabla)


def _validados(valores: list[str], patron: str, campo: str, ayuda: str,
               transformar=lambda s: s.strip()) -> list[str]:
    """Recorta, valida contra el patrón y quita repetidos conservando el orden."""
    limpios: dict[str, bool] = {}
    for v in valores:
        x = transformar(v)
        if not x:
            continue
        if not re.fullmatch(patron, x):
            raise ApiError(
                status_code=422, code="VALIDATION_ERROR", message=ayuda,
                details=[{"field": campo, "message": f"Valor recibido: {v}."}],
            )
        limpios[x] = True
    return list(limpios)


async def _codigos_especialidad(db: AsyncSession, valores: list[str]) -> list[str]:
    """Acepta la etiqueta ("Alzheimer y demencias") o el código. Una que no
    está en el catálogo se rechaza en vez de inventar un código."""
    if not valores:
        return []
    filas = (await db.execute(
        text("SELECT code, label FROM specialties"))).mappings().all()
    por_etiqueta = {_normaliza(f["label"]): f["code"] for f in filas}
    codigos = {f["code"] for f in filas}
    out: dict[str, bool] = {}
    for s in valores:
        limpio = s.strip()
        if not limpio:
            continue
        codigo = limpio if limpio in codigos else por_etiqueta.get(_normaliza(limpio))
        if codigo is None:
            raise ApiError(
                status_code=422, code="VALIDATION_ERROR",
                message="Esa especialidad no está en el catálogo.",
                details=[{"field": "specialties", "message": f"Valor recibido: {s}."}],
            )
        out[codigo] = True
    return list(out)


async def _reemplazar(db: AsyncSession, tabla: str, columna: str,
                      perfil_id: str, valores: list[str]) -> None:
    """Deja la lista exactamente como la mandó la pantalla. Son tablas de
    unión sin nada propio que perder (sin id ni historial)."""
    await db.execute(text(f"DELETE FROM {tabla} WHERE profile_id = :pid"),  # noqa: S608
                     {"pid": perfil_id})
    for v in valores:
        await db.execute(
            text(f"INSERT INTO {tabla} (profile_id, {columna}) VALUES (:pid, :v)"),  # noqa: S608
            {"pid": perfil_id, "v": v},
        )


@router.put("/profile", response_model=ProfileOut)
async def save_profile(
    payload: ProfileIn,
    user: CurrentUser = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Guarda identidad y perfil profesional en una sola transacción.

    Si published es true y falta algo, responde 422 con la lista de lo que
    falta y no guarda nada: así la pantalla no queda creyendo que publicó.
    """
    await _exigir_cuidadora(db, user.user_id)

    # Se valida todo antes de escribir.
    especialidades = await _codigos_especialidad(db, payload.specialties)
    idiomas = _validados(
        payload.languages, r"[a-z]{2}", "languages",
        "Usa el código del idioma, como 'es' o 'en'.",
        transformar=lambda s: s.strip().lower(),
    )
    zonas = _validados(
        payload.zones, r"[0-9]{5}", "zones",
        "Usa el código de cinco dígitos de la comuna, como '08101'.",
    )

    # ── Identidad ─────────────────────────────────────────────────────────
    cambios: dict[str, object] = {}
    for campo in ("first_name", "last_name", "phone"):
        valor = getattr(payload, campo)
        if valor is not None:
            cambios[campo] = valor
    for campo in ("second_name", "second_last_name"):
        valor = getattr(payload, campo)
        if valor is not None:
            cambios[campo] = valor or None   # "" quita el dato
    if payload.rut is not None:
        n, dv = payload.rut.split("-")
        if (await db.execute(
            text("SELECT 1 FROM users WHERE rut_number = :n AND id <> :uid"),
            {"n": int(n), "uid": user.user_id},
        )).first():
            raise ApiError(status_code=409, code="RUT_ALREADY_EXISTS",
                           message="Ese RUT ya está registrado en otra cuenta.")
        cambios["rut_number"] = int(n)
        cambios["rut_dv"] = dv
    if cambios:
        sets = ", ".join(f"{k} = :{k}" for k in cambios)
        await db.execute(text(f"UPDATE users SET {sets} WHERE id = :uid"),  # noqa: S608
                         {**cambios, "uid": user.user_id})

    # ── Perfil profesional ────────────────────────────────────────────────
    actual = (await db.execute(
        text("SELECT id, status, availability, accepts_overnight "
             "FROM caregiver_profiles WHERE user_id = :uid AND deleted_at IS NULL"),
        {"uid": user.user_id},
    )).mappings().first()

    headline = payload.headline.strip()
    if not headline:
        # headline es NOT NULL y la pantalla deja empezar sin él.
        headline = f"Cuidador(a) con {payload.years_experience} años de experiencia"
    valores = {
        "tit": headline,
        "bio": payload.bio.strip() or None,
        "anios": payload.years_experience,
        "tarifa": payload.hourly_rate,
        "disp": payload.availability or (actual["availability"] if actual else "part_time"),
        "noche": (payload.accepts_overnight if payload.accepts_overnight is not None
                  else (actual["accepts_overnight"] if actual else False)),
    }
    if actual is None:
        pid = str((await db.execute(
            text(
                """
                INSERT INTO caregiver_profiles
                    (user_id, headline, bio, years_experience, hourly_rate,
                     availability, accepts_overnight)
                VALUES (:uid, :tit, :bio, :anios, :tarifa, :disp, :noche)
                RETURNING id
                """
            ),
            {**valores, "uid": user.user_id},
        )).scalar())
        estado = "draft"
    else:
        pid = str(actual["id"])
        estado = actual["status"]
        await db.execute(
            text(
                """
                UPDATE caregiver_profiles
                   SET headline = :tit, bio = :bio, years_experience = :anios,
                       hourly_rate = :tarifa, availability = :disp,
                       accepts_overnight = :noche, updated_at = now()
                 WHERE id = :pid
                """
            ),
            {**valores, "pid": pid},
        )

    await _reemplazar(db, "caregiver_specialties", "specialty_code", pid, especialidades)
    await _reemplazar(db, "caregiver_languages", "language_code", pid, idiomas)
    await _reemplazar(db, "caregiver_zones", "commune_code", pid, zonas)

    # ── Publicación ───────────────────────────────────────────────────────
    if payload.published is not None:
        if estado == "suspended":
            await db.rollback()
            raise ApiError(
                status_code=409, code="PROFILE_SUSPENDED",
                message="Tu perfil está suspendido por el equipo de AgeCare. "
                        "Escríbenos para revisarlo.",
            )
        if payload.published:
            await db.flush()
            borrador = await _perfil(db, user.user_id)
            if borrador.missing_for_publish:
                await db.rollback()
                raise ApiError(
                    status_code=422, code="PROFILE_INCOMPLETE",
                    message="Para publicar tu perfil completa: "
                            + ", ".join(borrador.missing_for_publish).lower() + ".",
                    details=[{"field": "published", "message": m}
                             for m in borrador.missing_for_publish],
                )
            if estado != "published":
                await db.execute(
                    text("UPDATE caregiver_profiles SET status = 'published', "
                         "published_at = now() WHERE id = :pid"), {"pid": pid})
        elif estado == "published":
            await db.execute(
                text("UPDATE caregiver_profiles SET status = 'draft', "
                     "published_at = NULL WHERE id = :pid"), {"pid": pid})

    await db.commit()
    return await _perfil(db, user.user_id)
