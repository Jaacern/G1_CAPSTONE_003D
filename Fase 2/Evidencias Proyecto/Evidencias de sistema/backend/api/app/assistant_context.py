"""Contexto historico del asistente: busca en el expediente lo que se pregunta.

Antes el modelo recibia siempre lo mismo: la ultima medicion, diez notas de
bitacora y las alertas activas. Con eso no podia contestar "como estuvo la
presion esta semana" o "se olvido alguna dosis el mes pasado": el dato
existia en la base pero nunca llegaba al prompt.

Aqui la pregunta se interpreta (que periodo y que tema) y se traen solo los
datos que la responden, ya resumidos por SQL (promedio, minimo, maximo y
una linea por dia). El modelo no consulta la base: recibe un texto armado
aca, con el paciente ya validado por la API, asi el control de acceso sigue
siendo de la API y no depende del modelo.

`interpretar_pregunta` es una funcion pura (no toca la base) para poder
probarla sola.
"""
from __future__ import annotations

import re
from dataclasses import dataclass, field
from datetime import date, timedelta

from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

from app.assistant_safety import limpiar_texto_libre, normalizar

MAX_DIAS = 90
DIAS_POR_DEFECTO = 7
# Tope del bloque historico. Mas texto no mejora la respuesta: la empeora y
# la encarece.
MAX_CHARS = 7000

# ---------------------------------------------------------------------------
# Vocabulario (sobre texto sin tildes)
# ---------------------------------------------------------------------------
_VITALES = {
    "heart_rate":     r"pulso|frecuencia\s+cardiaca|latido|cardiac|corazon|bpm|taquicard|bradicard",
    "blood_pressure": r"presion|tension|arterial|hipertens|hipotens",
    "spo2":           r"oxigen|saturacion|spo2|satura",
    "temperature":    r"temperatura|fiebre|febril|calentura",
    "glucose":        r"glucosa|azucar|glicemia|glucemia|diabet",
    "sleep":          r"sueno|dormi|durmio|descans|insomnio",
    "steps":          r"pasos|camino|caminata|actividad\s+fisica",
    "sedentary_min":  r"sedentari",
    "fall_event":     r"caida|se\s+cayo|cayo|caer",
}
_VITALES_RE = {k: re.compile(v) for k, v in _VITALES.items()}

# Con el nombre comun entre parentesis: preguntado por la "oxigenacion", el
# modelo contestaba que no habia datos porque el bloque decia "Saturacion".
_ETIQUETA_VITAL = {
    "heart_rate": ("Frecuencia cardíaca (pulso)", "bpm"),
    "blood_pressure": ("Presión arterial (tensión)", "mmHg"),
    "spo2": ("Saturación de oxígeno (oxigenación, SpO2)", "%"),
    "temperature": ("Temperatura", "°C"),
    "glucose": ("Glucosa (azúcar en sangre)", "mg/dL"),
    "sleep": ("Sueño", "h"),
    "steps": ("Pasos", "pasos"),
    "sedentary_min": ("Tiempo sedentario", "min"),
    "fall_event": ("Eventos de caída", ""),
}
# Estos se registran una vez al dia y lo que importa es el total del dia; el
# resto (pulso, presion...) son muestras y lo que importa es el promedio.
_SUMA_DIARIA = {"steps", "sleep", "sedentary_min", "fall_event"}

_TEMAS = {
    "bitacora": r"bitacora|observac|nota|animo|humor|comio|comida|alimenta|apetito|almuerz|desayun|cena\b|higiene|bano|ducha|aseo|visita|dolor|duele|molest|como\s+(?:estuvo|esta|ha\s+estado|amanecio|se\s+sintio|lo\s+paso)|que\s+paso|novedad|amanec|relevo|cuidadora|incidente|se\s+cayo|desorient|rechaz",
    "dosis":    r"medica(?!cion\s+de|cion\s+del)\w*|dosis|pastilla|remedio|tomo|tomado|olvid|omit|salt|adherencia|receta|cumpl|medicament",
    "alertas":  r"alerta|aviso|emergencia|sos|urgenc|alarma|incidente",
    "tareas":   r"tarea|turno|pendiente|por\s+hacer|actividades?\s+de\s+cuidado",
}
_TEMAS_RE = {k: re.compile(v) for k, v in _TEMAS.items()}
_GENERAL = re.compile(
    r"resumen|como\s+(?:ha\s+)?estado|como\s+(?:esta|anda|va)|reporte|informe|"
    r"general|todo|balance|ultimos?\s+dias|que\s+tal"
)

_CATEGORIAS_BITACORA = {
    "mood":       r"animo|humor|triste|contento|deprim|alegre|enojad|angusti",
    "food":       r"comio|comida|alimenta|apetito|almuerz|desayun|cena\b|comer",
    "hygiene":    r"higiene|bano|ducha|aseo",
    "sleep":      r"sueno|dormi|durmio|insomnio|desperto",
    "mobility":   r"movil|camin|andador|caida|se\s+cayo|cayo|silla\s+de\s+ruedas",
    "pain":       r"dolor|duele|molest",
    "medication": r"medica(?!cion\s+de|cion\s+del)\w*|pastilla|remedio|medicament",
    "visit":      r"visita|visito",
}
_CATEGORIAS_RE = {k: re.compile(v) for k, v in _CATEGORIAS_BITACORA.items()}
_ETIQUETA_CATEGORIA = {
    "mood": "Ánimo", "food": "Alimentación", "hygiene": "Higiene",
    "sleep": "Sueño", "mobility": "Movilidad", "pain": "Dolor",
    "medication": "Medicación", "visit": "Visita", "other": "Otro",
}
_ETIQUETA_ALERTA = {
    "fall": "Caída", "vital_out_of_range": "Signo vital fuera de rango",
    "missed_dose": "Dosis omitida", "sos": "SOS",
    "wearable_offline": "Reloj sin conexión",
}
_ESTADO_ALERTA = {"active": "activa", "acknowledged": "vista",
                  "resolved": "resuelta"}
_ETIQUETA_INCIDENTE = {
    "fall": "Caída", "wandering": "Fuga", "aggression": "Agresión",
    "refusal": "Rechazo", "injury": "Golpe o lesión", "choking": "Atragantamiento",
    "disorientation": "Desorientación", "adverse_reaction": "Reacción adversa",
    "medical_emergency": "Emergencia médica", "other": "Otro",
}
_GRAVEDAD = {"low": "leve", "moderate": "moderada", "high": "grave",
             "critical": "crítica"}
_ESTADO_DOSIS = {"skipped": "omitida a propósito", "missed": "no tomada",
                 "postponed": "postergada", "pending": "sin registrar"}
_ESTADO_TAREA = {"pending": "pendiente", "in_progress": "en curso",
                 "completed": "completada", "cancelled": "cancelada"}

_MESES = {"enero": 1, "febrero": 2, "marzo": 3, "abril": 4, "mayo": 5,
          "junio": 6, "julio": 7, "agosto": 8, "septiembre": 9, "setiembre": 9,
          "octubre": 10, "noviembre": 11, "diciembre": 12}
_NUMEROS = {"un": 1, "una": 1, "dos": 2, "tres": 3, "cuatro": 4, "cinco": 5,
            "seis": 6, "siete": 7, "diez": 10, "quince": 15, "veinte": 20,
            "treinta": 30}


@dataclass(frozen=True)
class Consulta:
    """Lo que la pregunta pide: que periodo y que partes del expediente."""

    desde: date
    hasta: date
    vitales: tuple[str, ...] = ()
    temas: frozenset[str] = field(default_factory=frozenset)
    categorias: tuple[str, ...] = ()
    general: bool = False
    # Partes del dia que nombra la pregunta ("amanecio" -> manana).
    momentos: tuple[str, ...] = ()

    @property
    def dias(self) -> int:
        return (self.hasta - self.desde).days + 1

    @property
    def etiqueta(self) -> str:
        if self.desde == self.hasta:
            return self.desde.strftime("%d-%m-%Y")
        return f"{self.desde.strftime('%d-%m-%Y')} al {self.hasta.strftime('%d-%m-%Y')}"


# ---------------------------------------------------------------------------
# Interpretacion de la pregunta (pura)
# ---------------------------------------------------------------------------
def _periodo(n: str, hoy: date) -> tuple[date, date]:
    """Periodo [desde, hasta] que nombra la pregunta. Sin pista: 7 dias."""
    # Fecha explicita: "el 12 de octubre", "el 03/11", "el 3-11-2026".
    m = re.search(r"\b(\d{1,2})\s+de\s+([a-z]+)(?:\s+(?:de|del)\s+(\d{4}))?\b", n)
    if m and m.group(2) in _MESES:
        return _fecha_unica(int(m.group(1)), _MESES[m.group(2)], m.group(3), hoy)
    m = re.search(r"\b(\d{1,2})[/-](\d{1,2})(?:[/-](\d{2,4}))?\b", n)
    if m:
        r = _fecha_unica(int(m.group(1)), int(m.group(2)), m.group(3), hoy)
        if r:
            return r

    if re.search(r"anteayer|antes\s+de\s+ayer|antiayer", n):
        d = hoy - timedelta(days=2)
        return d, d
    if re.search(r"\bayer\b", n):
        d = hoy - timedelta(days=1)
        return d, d
    if re.search(r"semana\s+pasada|semana\s+anterior", n):
        return hoy - timedelta(days=13), hoy - timedelta(days=7)
    if re.search(r"mes\s+pasado|mes\s+anterior", n):
        return hoy - timedelta(days=59), hoy - timedelta(days=30)

    # "ultimos 10 dias", "hace 3 semanas", "dos semanas", "5 dias".
    m = re.search(r"\b(\d{1,3}|" + "|".join(_NUMEROS) + r")\s+(dias?|semanas?|mes(?:es)?)\b", n)
    if m:
        cant = int(m.group(1)) if m.group(1).isdigit() else _NUMEROS[m.group(1)]
        unidad = m.group(2)
        dias = cant * (7 if unidad.startswith("semana") else 30 if unidad.startswith("mes") else 1)
        return hoy - timedelta(days=min(max(dias, 1), MAX_DIAS) - 1), hoy
    if re.search(r"quincena", n):
        return hoy - timedelta(days=13), hoy
    if re.search(r"trimestre|historial|historico|desde\s+el\s+inicio|siempre|"
                 r"evolucion|tendencia", n):
        return hoy - timedelta(days=MAX_DIAS - 1), hoy
    if re.search(r"este\s+mes|ultimo\s+mes|\bmes\b|mensual", n):
        return hoy - timedelta(days=29), hoy
    if re.search(r"esta\s+semana|ultima\s+semana|\bsemana\b|semanal|ultimos\s+dias", n):
        return hoy - timedelta(days=6), hoy
    if re.search(r"ultim[oa]\s+(?:medicion|lectura|valor|registro)|ahora|actual|"
                 r"en\s+este\s+momento", n):
        return hoy - timedelta(days=1), hoy
    if re.search(r"\bhoy\b|esta\s+(?:manana|tarde|noche)|\banoche\b", n):
        if re.search(r"\banoche\b", n):
            return hoy - timedelta(days=1), hoy
        return hoy, hoy
    # "como amanecio", "como va la manana", "como va el dia": se pregunta
    # por hoy aunque no se diga. Sin esto caia en los 7 dias por defecto y el
    # modelo contestaba con lo de otro dia.
    # "como paso la noche" es la ultima noche: empieza ayer y termina hoy.
    if re.search(r"paso\s+(?:la|mala|buena)\s+noche|la\s+ultima\s+noche", n):
        return hoy - timedelta(days=1), hoy
    if re.search(r"amanec|como\s+va\s+(?:la\s+|el\s+)?(?:manana|tarde|dia|noche)|"
                 r"como\s+(?:ha\s+)?(?:pasado|estado)\s+(?:la\s+|el\s+)?(?:manana|tarde|dia)",
                 n):
        return hoy, hoy
    return hoy - timedelta(days=DIAS_POR_DEFECTO - 1), hoy


# Momentos del dia, igual que logbook.momento_del_dia: madrugada 0-6,
# manana 6-12, tarde 12-19, noche 19-24. Con estas pistas la bitacora se
# acota a esa parte del dia ("como amanecio" mira la manana).
_MOMENTOS = {
    "manana":    r"amanec|al\s+despertar|se\s+desperto|esta\s+manana|en\s+la\s+manana|"
                 r"la\s+manana|de\s+manana|desayun",
    "tarde":     r"esta\s+tarde|en\s+la\s+tarde|la\s+tarde|de\s+tarde|almuerz|siesta|\bonce\b",
    "noche":     r"anoche|esta\s+noche|en\s+la\s+noche|la\s+noche|de\s+noche|\bcena\b|"
                 r"paso\s+(?:mala|buena)\s+noche",
    "madrugada": r"madrugada|anoche|en\s+la\s+noche|la\s+noche|"
                 r"paso\s+(?:mala|buena)\s+noche",
}
_MOMENTOS_RE = {k: re.compile(v) for k, v in _MOMENTOS.items()}
_HORAS_MOMENTO = {"madrugada": (0, 6), "manana": (6, 12),
                  "tarde": (12, 19), "noche": (19, 24)}
_ETIQUETA_MOMENTO = {"madrugada": "Madrugada", "manana": "Mañana",
                     "tarde": "Tarde", "noche": "Noche"}


def _fecha_unica(dia: int, mes: int, anio: str | None, hoy: date):
    """Una fecha con dia y mes (y quiza anio). Sin anio, la mas reciente."""
    try:
        if anio:
            a = int(anio)
            a = a + 2000 if a < 100 else a
            d = date(a, mes, dia)
        else:
            d = date(hoy.year, mes, dia)
            if d > hoy:
                d = date(hoy.year - 1, mes, dia)
    except ValueError:
        return None
    if d > hoy:
        return None
    # Mas alla de lo que se consulta no hay datos utiles.
    if (hoy - d).days >= MAX_DIAS:
        return hoy - timedelta(days=MAX_DIAS - 1), hoy
    return d, d


def interpretar_pregunta(pregunta: str, hoy: date) -> Consulta:
    """Decide que periodo y que partes del expediente hay que traer."""
    n = normalizar(pregunta or "")
    desde, hasta = _periodo(n, hoy)
    if desde > hasta:
        desde, hasta = hasta, desde

    vitales = tuple(k for k, rx in _VITALES_RE.items() if rx.search(n))
    temas = frozenset(k for k, rx in _TEMAS_RE.items() if rx.search(n))
    categorias = tuple(k for k, rx in _CATEGORIAS_RE.items() if rx.search(n))
    # "sueno" y "caida" son a la vez dato del reloj y categoria de bitacora:
    # la pregunta puede ser sobre cualquiera, asi que se traen los dos.
    if vitales and ("sleep" in vitales or "fall_event" in vitales):
        temas = temas | {"bitacora"}

    momentos = tuple(k for k, rx in _MOMENTOS_RE.items() if rx.search(n))
    # Preguntar por un momento del dia es preguntar por lo que se anoto.
    if momentos:
        temas = temas | {"bitacora"}

    general = bool(_GENERAL.search(n)) or not (vitales or temas)
    return Consulta(desde=desde, hasta=hasta, vitales=vitales, temas=temas,
                    categorias=categorias, general=general, momentos=momentos)


def heredar_tema(actual: Consulta, pregunta_actual: str,
                 anterior: str | None, hoy: date) -> Consulta:
    """Un seguimiento corto ("y ayer?", "y la semana pasada?") hereda el tema.

    Si la pregunta nueva no nombra ningun tema ni pide un resumen, se toma
    el tema de la pregunta anterior y se conserva el periodo de la nueva.
    """
    if not anterior or actual.vitales or actual.temas:
        return actual
    if _GENERAL.search(normalizar(pregunta_actual or "")):
        return actual
    previa = interpretar_pregunta(anterior, hoy)
    if previa.general and not (previa.vitales or previa.temas):
        return actual
    from dataclasses import replace
    return replace(actual, vitales=previa.vitales, temas=previa.temas,
                   categorias=previa.categorias, general=previa.general,
                   momentos=actual.momentos or previa.momentos)


# ---------------------------------------------------------------------------
# Formato
# ---------------------------------------------------------------------------
def _num(v) -> str:
    """Numero para leer: sin ceros de mas ('72' en vez de '72.0')."""
    if v is None:
        return "?"
    f = float(v)
    return str(int(f)) if f == int(f) else f"{f:.1f}".rstrip("0").rstrip(".")


def _rango(a, b, unidad: str) -> str:
    return f"{_num(a)}-{_num(b)} {unidad}".strip()


# ---------------------------------------------------------------------------
# Consultas
# ---------------------------------------------------------------------------
_PERIODO_VITAL = """
    patient_id = :pid
    AND measured_at >= CAST(:desde AS date)
    AND measured_at <  CAST(:hasta AS date) + 1
"""


async def _bloque_vitales(db: AsyncSession, pid: str, q: Consulta):
    """Resumen de mediciones del periodo y, si se pregunto por una, su serie."""
    from app.assistant_provider import Fuente

    resumen = (await db.execute(text(f"""
        SELECT type, count(*) AS n,
               round(avg(value), 1) AS prom, min(value) AS mn, max(value) AS mx,
               round(avg(value_secondary), 0) AS prom2,
               min(value_secondary) AS mn2, max(value_secondary) AS mx2,
               sum(value) AS total, count(DISTINCT date_trunc('day', measured_at)) AS dias,
               (array_agg(id ORDER BY measured_at DESC))[1] AS ult_id
        FROM vital_readings WHERE {_PERIODO_VITAL}
        GROUP BY type
    """), {"pid": pid, "desde": q.desde, "hasta": q.hasta})).mappings().all()

    por_tipo = {r["type"]: r for r in resumen}
    pedidos = list(q.vitales) if q.vitales else [
        t for t in _ETIQUETA_VITAL if t in por_tipo
    ]
    if not pedidos:
        return None, []

    lineas, fuentes = [], []
    for tipo in pedidos:
        etiqueta, unidad = _ETIQUETA_VITAL[tipo]
        r = por_tipo.get(tipo)
        if r is None:
            lineas.append(f"- {etiqueta}: sin mediciones registradas en este período.")
            continue
        if tipo == "blood_pressure":
            linea = (f"- {etiqueta}: {r['n']} mediciones; promedio "
                     f"{_num(r['prom'])}/{_num(r['prom2'])} {unidad}; sistólica "
                     f"{_rango(r['mn'], r['mx'], '')}, diastólica "
                     f"{_rango(r['mn2'], r['mx2'], '')} {unidad}")
        elif tipo in _SUMA_DIARIA:
            promedio_dia = float(r["total"]) / max(int(r["dias"]), 1)
            linea = (f"- {etiqueta}: {r['dias']} días con registro; "
                     f"promedio por día {_num(promedio_dia)} {unidad}; "
                     f"mínimo {_num(r['mn'])}, máximo {_num(r['mx'])}")
            if tipo == "fall_event":
                linea = f"- {etiqueta}: {_num(r['total'])} en el período"
        else:
            linea = (f"- {etiqueta}: {r['n']} mediciones; promedio "
                     f"{_num(r['prom'])} {unidad}; mínimo {_num(r['mn'])}, "
                     f"máximo {_num(r['mx'])}")
        lineas.append(linea)
        fuentes.append(Fuente(tabla="vital_readings", id=str(r["ult_id"]),
                              label="Mediciones"))

    # Serie diaria solo cuando se pregunto por ese signo: en un resumen
    # general seria ruido. Pasado un mes se agrupa por semana.
    if q.vitales:
        paso = "week" if q.dias > 31 else "day"
        for tipo in q.vitales:
            if tipo not in por_tipo or tipo == "fall_event":
                continue
            etiqueta, unidad = _ETIQUETA_VITAL[tipo]
            agregado = "sum(value)" if tipo in _SUMA_DIARIA else "round(avg(value), 1)"
            serie = (await db.execute(text(f"""
                SELECT date_trunc(CAST(:paso AS text), measured_at)::date AS dia,
                       {agregado} AS v, min(value) AS mn, max(value) AS mx,
                       round(avg(value_secondary), 0) AS v2,
                       min(value_secondary) AS mn2, max(value_secondary) AS mx2,
                       count(*) AS n
                FROM vital_readings
                WHERE {_PERIODO_VITAL} AND type = :tipo
                GROUP BY 1 ORDER BY 1 DESC LIMIT 31
            """), {"pid": pid, "desde": q.desde, "hasta": q.hasta,
                   "tipo": tipo, "paso": paso})).mappings().all()
            if not serie:
                continue
            cabecera = "por semana (desde el lunes)" if paso == "week" else "por día"
            filas = []
            for s in reversed(serie):
                dia = s["dia"].strftime("%d-%m")
                if tipo == "blood_pressure":
                    filas.append(f"{dia}: {_num(s['v'])}/{_num(s['v2'])} "
                                 f"(rango {_num(s['mn'])}-{_num(s['mx'])}/"
                                 f"{_num(s['mn2'])}-{_num(s['mx2'])}, {s['n']} med.)")
                elif tipo in _SUMA_DIARIA:
                    filas.append(f"{dia}: {_num(s['v'])}")
                else:
                    filas.append(f"{dia}: {_num(s['v'])} "
                                 f"(rango {_num(s['mn'])}-{_num(s['mx'])}, {s['n']} med.)")
            lineas.append(f"  Serie {cabecera} de {etiqueta} ({unidad}): "
                          + " | ".join(filas))
    return "Mediciones del período:\n" + "\n".join(lineas), fuentes


async def _bloque_bitacora(db: AsyncSession, pid: str, q: Consulta):
    from app.assistant_provider import Fuente

    filtros = []
    params = {"pid": pid, "desde": q.desde, "hasta": q.hasta}
    # Con una categoria clara se filtra; con varias o ninguna se trae todo,
    # para no perder una nota relevante por una palabra mal leida.
    if len(q.categorias) == 1 and not q.general:
        filtros.append("AND o.category = :cat")
        params["cat"] = q.categorias[0]
    # "Como amanecio" mira la manana; "como paso la noche", la noche y la
    # madrugada. La hora sale en la zona de la conexion (db.py), la de la casa.
    if q.momentos and not q.general:
        rangos = []
        for i, m in enumerate(q.momentos):
            ini, fin = _HORAS_MOMENTO[m]
            rangos.append(f"(extract(hour FROM o.observed_at) >= :h{i}a "
                          f"AND extract(hour FROM o.observed_at) < :h{i}b)")
            params[f"h{i}a"], params[f"h{i}b"] = ini, fin
        filtros.append("AND (" + " OR ".join(rangos) + ")")

    filas = (await db.execute(text(f"""
        SELECT o.id, o.category, o.note, u.full_name AS autor,
               to_char(o.observed_at, 'DD-MM-YYYY') AS dia,
               to_char(o.observed_at, 'HH24:MI') AS hora,
               extract(hour FROM o.observed_at)::int AS h
        FROM care_observations o
        JOIN users u ON u.id = o.author_id
        WHERE o.patient_id = :pid AND o.deleted_at IS NULL
          AND o.observed_at >= CAST(:desde AS date)
          AND o.observed_at <  CAST(:hasta AS date) + 1
          {' '.join(filtros)}
        ORDER BY o.observed_at DESC LIMIT 30
    """), params)).mappings().all()

    fuentes = [Fuente(tabla="care_observations", id=str(f["id"]), label="Bitácora")
               for f in filas[:5]]
    partes = []
    if q.momentos and not q.general:
        nombres = " y ".join(_ETIQUETA_MOMENTO[m].lower() for m in q.momentos)
        cabecera = f"Bitácora del período, solo {nombres} (más reciente primero):"
    else:
        cabecera = "Bitácora del período (más reciente primero):"
    if filas:
        items = []
        for f in filas:
            momento = next(k for k, (a, b) in _HORAS_MOMENTO.items() if a <= f["h"] < b)
            cat = _ETIQUETA_CATEGORIA.get(f["category"], f["category"])
            items.append(f"{f['dia']} {f['hora']} · {_ETIQUETA_MOMENTO[momento]} "
                         f"[{cat}] {limpiar_texto_libre(f['note'], 260)} "
                         f"(anotó {limpiar_texto_libre(f['autor'], 60)})")
        partes.append(cabecera + "\n- " + "\n- ".join(items))
    else:
        partes.append(cabecera.rstrip(":") + ": sin notas registradas.")

    # Notas de relevo: lo que una cuidadora le deja a la siguiente al cambiar
    # de turno. Es bitacora tambien, y suele ser el mejor resumen del turno.
    relevos = (await db.execute(text("""
        SELECT s.id, s.note, s.shift, u.full_name AS autor,
               to_char(s.shift_date, 'DD-MM-YYYY') AS dia
        FROM shift_notes s JOIN users u ON u.id = s.author_id
        WHERE s.patient_id = :pid AND s.deleted_at IS NULL
          AND s.shift_date BETWEEN CAST(:desde AS date) AND CAST(:hasta AS date)
        ORDER BY s.shift_date DESC, s.created_at DESC LIMIT 6
    """), {"pid": pid, "desde": q.desde, "hasta": q.hasta})).mappings().all()
    if relevos:
        turno = {"morning": "turno mañana", "afternoon": "turno tarde",
                 "night": "turno noche"}
        partes.append("Notas de relevo entre turnos:\n- " + "\n- ".join(
            f"{r['dia']} {turno.get(r['shift'], r['shift'])}: "
            f"{limpiar_texto_libre(r['note'], 300)} (dejó {limpiar_texto_libre(r['autor'], 60)})"
            for r in relevos))
        fuentes += [Fuente(tabla="shift_notes", id=str(r["id"]), label="Relevos")
                    for r in relevos[:2]]

    # Incidentes que reporto la cuidadora (caida, rechazo, desorientacion...).
    # No son alertas del sistema: los escribe una persona en la bitacora.
    incidentes = (await db.execute(text("""
        SELECT i.id, i.type, i.severity, i.description,
               to_char(i.occurred_at, 'DD-MM-YYYY HH24:MI') AS cuando
        FROM incidents i
        WHERE i.patient_id = :pid
          AND i.occurred_at >= CAST(:desde AS date)
          AND i.occurred_at <  CAST(:hasta AS date) + 1
        ORDER BY i.occurred_at DESC LIMIT 8
    """), {"pid": pid, "desde": q.desde, "hasta": q.hasta})).mappings().all()
    if incidentes:
        partes.append("Incidentes reportados en la bitácora:\n- " + "\n- ".join(
            f"{i['cuando']} {_ETIQUETA_INCIDENTE.get(i['type'], i['type'])} "
            f"(gravedad {_GRAVEDAD.get(i['severity'], i['severity'])}): "
            f"{limpiar_texto_libre(i['description'], 260)}"
            for i in incidentes))
        fuentes += [Fuente(tabla="incidents", id=str(i["id"]), label="Incidentes")
                    for i in incidentes[:2]]

    return "\n\n".join(partes), fuentes


async def _bloque_dosis(db: AsyncSession, pid: str, q: Consulta):
    from app.assistant_provider import Fuente

    base = """
        FROM scheduled_doses d JOIN medications m ON m.id = d.medication_id
        WHERE m.patient_id = :pid
          AND d.scheduled_at >= CAST(:desde AS date)
          AND d.scheduled_at <  CAST(:hasta AS date) + 1
          AND d.scheduled_at <= now()
    """
    params = {"pid": pid, "desde": q.desde, "hasta": q.hasta}
    resumen = (await db.execute(text(f"""
        SELECT m.name,
               count(*) AS total,
               count(*) FILTER (WHERE d.status = 'taken') AS tomadas,
               count(*) FILTER (WHERE d.status = 'skipped') AS omitidas,
               count(*) FILTER (WHERE d.status = 'missed') AS no_tomadas,
               count(*) FILTER (WHERE d.status = 'postponed') AS postergadas,
               count(*) FILTER (WHERE d.status = 'pending') AS sin_registro
        {base} GROUP BY m.name ORDER BY m.name LIMIT 30
    """), params)).mappings().all()
    if not resumen:
        return "Dosis del período: no hay dosis programadas en este período.", []

    # Las cuentas se hacen aqui y no en el modelo: en las pruebas el modelo
    # sumaba mal ("21 dosis" de una que tenia 13) cuando le tocaba sumar.
    # Se le entregan los totales cerrados y la regla del prompt le prohibe
    # recalcular.
    def _desglose(r) -> str:
        partes = []
        if r["omitidas"]: partes.append(f"{r['omitidas']} omitidas a propósito")
        if r["no_tomadas"]: partes.append(f"{r['no_tomadas']} no tomadas")
        if r["postergadas"]: partes.append(f"{r['postergadas']} postergadas")
        if r["sin_registro"]: partes.append(f"{r['sin_registro']} sin registrar")
        return ", ".join(partes)

    lineas = []
    tot = {k: 0 for k in ("total", "tomadas", "omitidas", "no_tomadas",
                          "postergadas", "sin_registro")}
    for r in resumen:
        for k in tot:
            tot[k] += int(r[k] or 0)
        faltan = int(r["total"]) - int(r["tomadas"])
        # Por medicamento solo el total: con el desglose de cada uno a la
        # vista, el modelo tomaba la cifra de un medicamento y la ponia en el
        # desglose general (decia 6 sin registrar porque Metformina tenia 6).
        lineas.append(f"- {limpiar_texto_libre(r['name'], 60)}: {r['tomadas']} "
                      f"tomadas de {r['total']} programadas; {faltan} sin tomar")
    faltan_tot = tot["total"] - tot["tomadas"]
    resumen_total = (f"- TOTAL del período (todos los medicamentos): {tot['tomadas']} "
                     f"tomadas de {tot['total']} programadas; {faltan_tot} sin tomar")
    # El desglose del total va en una linea por estado: en un parentesis
    # corrido el modelo cruzaba cifras (ponia el 6 de "omitidas" en "sin
    # registrar").
    for etiqueta, clave in (("omitidas a propósito", "omitidas"),
                            ("no tomadas", "no_tomadas"),
                            ("postergadas", "postergadas"),
                            ("sin registrar", "sin_registro")):
        if tot[clave]:
            resumen_total += f"\n    · {etiqueta}: {tot[clave]}"
    lineas.insert(0, resumen_total)
    # Respuesta directa a "se olvido alguna dosis?". El modelo leia "sin
    # registrar" como "todo registrado" y contestaba que no: se le da la
    # conclusion escrita, y que significa cada estado.
    if faltan_tot:
        lineas.insert(0, f"SÍ hubo dosis que no se tomaron en este período: "
                         f"{faltan_tot} de {tot['total']} programadas.")
    else:
        lineas.insert(0, f"No hubo dosis sin tomar en este período: las "
                         f"{tot['total']} programadas figuran como tomadas.")
    lineas.append("  Significado: 'omitida a propósito' = se decidió no darla "
                  "(con motivo); 'no tomada' = se marcó como no tomada; "
                  "'sin registrar' = pasó la hora y nadie anotó si se tomó.")

    detalle = (await db.execute(text(f"""
        SELECT d.id, m.name, d.status, d.reason,
               to_char(d.scheduled_at, 'DD-MM-YYYY HH24:MI') AS cuando
        {base} AND d.status IN ('skipped', 'missed', 'postponed')
        ORDER BY d.scheduled_at DESC LIMIT 10
    """), params)).mappings().all()
    if detalle:
        lineas.append("  Ejemplos de dosis no tomadas o postergadas (las 10 más "
                      "recientes; ya están contadas en los totales de arriba):")
        for d in detalle:
            motivo = (f" — motivo: {limpiar_texto_libre(d['reason'], 120)}"
                      if d["reason"] else "")
            lineas.append(f"  · {d['cuando']} {limpiar_texto_libre(d['name'], 60)}: "
                          f"{_ESTADO_DOSIS.get(d['status'], d['status'])}{motivo}")
    fuentes = [Fuente(tabla="scheduled_doses", id=str(d["id"]), label="Dosis")
               for d in detalle[:3]]
    return "Dosis del período:\n" + "\n".join(lineas), fuentes


async def _bloque_alertas(db: AsyncSession, pid: str, q: Consulta):
    from app.assistant_provider import Fuente

    filas = (await db.execute(text("""
        SELECT id, type, severity, title, status, resolution_note,
               to_char(created_at, 'DD-MM-YYYY HH24:MI') AS cuando
        FROM alerts
        WHERE patient_id = :pid
          AND created_at >= CAST(:desde AS date)
          AND created_at <  CAST(:hasta AS date) + 1
        ORDER BY created_at DESC LIMIT 15
    """), {"pid": pid, "desde": q.desde, "hasta": q.hasta})).mappings().all()
    if not filas:
        return "Alertas del período: ninguna registrada.", []
    items = [f"Total: {len(filas)} alertas en el período"
             + (" (se muestran las 15 más recientes)" if len(filas) >= 15 else "")]
    for a in filas:
        nota = (f" — resolución: {limpiar_texto_libre(a['resolution_note'], 120)}"
                if a["resolution_note"] else "")
        items.append(f"{a['cuando']} {_ETIQUETA_ALERTA.get(a['type'], a['type'])} "
                     f"({a['severity']}, {_ESTADO_ALERTA.get(a['status'], a['status'])}): "
                     f"{limpiar_texto_libre(a['title'], 120)}{nota}")
    return ("Historial de alertas del período (más reciente primero; el estado "
            "entre paréntesis es el actual: solo las 'activa' siguen abiertas):\n- "
            + "\n- ".join(items)), [
        Fuente(tabla="alerts", id=str(a["id"]), label="Alertas") for a in filas[:5]
    ]


async def _bloque_tareas(db: AsyncSession, pid: str, q: Consulta):
    from app.assistant_provider import Fuente

    filas = (await db.execute(text("""
        SELECT id, title, category, status,
               to_char(due_date, 'DD-MM-YYYY') AS vence
        FROM care_tasks
        WHERE patient_id = :pid AND deleted_at IS NULL
          AND due_date BETWEEN CAST(:desde AS date) AND CAST(:hasta AS date)
        ORDER BY due_date DESC, due_time DESC NULLS LAST LIMIT 15
    """), {"pid": pid, "desde": q.desde, "hasta": q.hasta})).mappings().all()
    if not filas:
        return "Tareas de cuidado del período: ninguna registrada.", []
    items = [f"vence {t['vence']}: {limpiar_texto_libre(t['title'], 120)} "
             f"({_ESTADO_TAREA.get(t['status'], t['status'])})" for t in filas]
    return ("Tareas de cuidado del período (la fecha es el día en que vencía "
            "cada tarea, no hoy):\n- " + "\n- ".join(items)), [
        Fuente(tabla="care_tasks", id=str(t["id"]), label="Tareas") for t in filas[:3]
    ]


# ---------------------------------------------------------------------------
# Entrada publica
# ---------------------------------------------------------------------------
async def contexto_historico(db: AsyncSession, patient_id: str,
                             q: Consulta) -> tuple[str, list]:
    """Datos del periodo y tema que pide la pregunta, ya resumidos.

    En una pregunta general (resumen, "como ha estado") se trae un poco de
    todo; en una especifica ("la presion de ayer") solo lo que corresponde.
    """
    bloques: list[str] = []
    fuentes: list = []

    def sumar(res):
        texto, fs = res
        if texto:
            bloques.append(texto)
            fuentes.extend(fs)

    if q.general or q.vitales:
        sumar(await _bloque_vitales(db, patient_id, q))
    if q.general or "bitacora" in q.temas:
        sumar(await _bloque_bitacora(db, patient_id, q))
    if q.general or "dosis" in q.temas:
        sumar(await _bloque_dosis(db, patient_id, q))
    if q.general or "alertas" in q.temas:
        sumar(await _bloque_alertas(db, patient_id, q))
    if q.general or "tareas" in q.temas:
        sumar(await _bloque_tareas(db, patient_id, q))

    if not bloques:
        return "", []
    cuerpo = (f"[Datos del período consultado: {q.etiqueta} ({q.dias} días)]\n"
              + "\n\n".join(bloques))
    if len(cuerpo) > MAX_CHARS:
        cuerpo = cuerpo[:MAX_CHARS].rstrip() + "\n[Se omitieron datos por largo]"
    return cuerpo, fuentes
