"""Del texto de una receta a borradores de indicacion.

LO QUE HACE Y LO QUE NO
    Lee el texto que salio del OCR y propone, por cada linea que parece una
    indicacion, el nombre del farmaco, la cantidad, la unidad y los horarios.

    No guarda nada, y eso no es una limitacion sino el punto. El OCR se
    equivoca: un 50 mg borroso puede leerse 500, y de aqui salen las dosis
    que se le dan a un adulto mayor. Todo lo que devuelve este modulo es un
    borrador para que un medico lo mire campo por campo y confirme. La
    pantalla de escaneo ya trabaja asi, con los campos editables.

    Tampoco adivina lo que no esta. Si de una linea no sale una cantidad
    clara, la deja vacia en vez de poner un 1: un campo en blanco se ve y se
    llena, un valor inventado se guarda sin que nadie lo note.

POR QUE A MANO Y NO CON UN MODELO
    Una receta chilena impresa sigue un patron bastante fijo, "Farmaco 50 mg
    cada 8 horas", y para eso una expresion regular es mas predecible, no
    cuesta nada y no manda el documento a ningun tercero. El dia que haya que
    leer manuscrito, el que cambia es el motor de OCR, no esto.
"""
from __future__ import annotations

import re
import unicodedata
from dataclasses import dataclass, field

# Las diez que admite el CHECK de medications.dose_unit. No se puede devolver
# ninguna otra: el guardado fallaria con un error de restriccion que la
# pantalla no sabe explicar.
UNIDADES_VALIDAS = {
    "mg", "g", "mcg", "ml", "UI", "gotas",
    "comprimido", "cápsula", "puff", "parche",
}

# Como escribe la gente y como lo lee el OCR, a la unidad que guarda la base.
_SINONIMOS = {
    "mg": "mg", "miligramo": "mg", "miligramos": "mg", "mgs": "mg",
    "g": "g", "gr": "g", "gramo": "g", "gramos": "g",
    "mcg": "mcg", "ug": "mcg", "microgramo": "mcg", "microgramos": "mcg",
    "ml": "ml", "cc": "ml", "mililitro": "ml", "mililitros": "ml",
    "ui": "UI", "u": "UI", "unidad": "UI", "unidades": "UI",
    "gota": "gotas", "gotas": "gotas",
    "comprimido": "comprimido", "comprimidos": "comprimido",
    "tableta": "comprimido", "tabletas": "comprimido",
    "tab": "comprimido", "comp": "comprimido",
    "capsula": "cápsula", "capsulas": "cápsula",
    "cap": "cápsula", "caps": "cápsula",
    "puff": "puff", "puffs": "puff", "inhalacion": "puff",
    "inhalaciones": "puff", "disparo": "puff", "disparos": "puff",
    "parche": "parche", "parches": "parche",
}

# Lineas que no son indicaciones. Se descartan antes de intentar leerlas para
# no proponer "Paciente" o "Fecha" como si fueran farmacos.
_RUIDO = re.compile(
    r"^\s*("
    r"paciente|rut|run|edad|fecha|dr\.?|dra\.?|medico|médico|doctor|doctora|"
    r"indicaciones?|receta|prescripci|centro|hospital|clinica|clínica|"
    r"consultorio|cesfam|ficha|previsi|fonasa|isapre|diagn|firma|timbre|"
    r"direcci|telefono|teléfono|folio|n°|nro"
    r")\b",
    re.IGNORECASE,
)

# "cada 8 horas", "c/8 hrs", "cada 12 h"
_CADA_HORAS = re.compile(r"\bc(?:ada)?\s*/?\s*(\d{1,2})\s*h(?:r?s?|oras?)?\b", re.I)
# "3 veces al dia", "2 veces por dia"
_VECES_DIA = re.compile(r"\b(\d{1,2})\s*veces?\s*(?:al|por)\s*(?:d[ií]a|24\s*h)", re.I)


_MOMENTOS = [
    (re.compile(r"\b(ma[ñn]ana|desayuno|ayunas|am\b)", re.I), "08:00"),
    (re.compile(r"\b(mediod[ií]a|almuerzo)", re.I),     "13:00"),
    (re.compile(r"\b(tarde|merienda)\b", re.I),         "17:00"),
    (re.compile(r"\b(noche|cena|acostar|dormir|pm\b)", re.I), "22:00"),
]
# "1 comprimido", "10 gotas", "50 mg", "2,5 ml"
_CANTIDAD_UNIDAD = re.compile(
    r"(\d+(?:[.,]\d+)?)\s*([a-zA-ZáéíóúÁÉÍÓÚñÑ/]{1,12})", re.UNICODE
)


@dataclass
class Borrador:
    """Una indicacion propuesta. Todos los campos pueden venir vacios."""
    name: str = ""
    dose: str = ""
    unit: str = ""
    schedule: list[str] = field(default_factory=list)
    instructions: str = ""
    # La linea tal como la leyo el OCR, para que la pantalla pueda mostrarla
    # al lado del campo y el medico compare sin volver a la foto.
    origen: str = ""

    def to_json(self) -> dict:
        return {
            "name": self.name,
            "dose": self.dose,
            "unit": self.unit,
            "schedule": self.schedule,
            "instructions": self.instructions,
            "origen": self.origen,
        }

    @property
    def utilizable(self) -> bool:
        """Si vale la pena mostrarlo.

        Un nombre solo ya sirve: el medico completa la dosis. Una dosis sin
        nombre, no: no se sabe de que.
        """
        return bool(self.name.strip())


def _sin_tildes(s: str) -> str:
    return "".join(
        c for c in unicodedata.normalize("NFD", s)
        if unicodedata.category(c) != "Mn"
    ).lower()


def normalizar_unidad(bruta: str) -> str:
    """Lleva lo que diga la receta a una de las diez que admite la base."""
    limpia = _sin_tildes(bruta).strip(" .,:;-/")
    return _SINONIMOS.get(limpia, "")


def _horarios(linea: str) -> list[str]:
    """Horas de toma a partir de como se describe la frecuencia.

    Las horas son una propuesta razonable, no una lectura: una receta que
    dice "cada 8 horas" no dice a que hora se empieza. Se reparte desde las
    08:00 porque es lo que hace el resto de la aplicacion, y el medico las
    mueve en el formulario.
    """
    m = _CADA_HORAS.search(linea)
    if m:
        cada = int(m.group(1))
        if 1 <= cada <= 24:
            # 24 h -> una sola toma; 8 h -> tres; 12 h -> dos.
            cuantas = max(1, 24 // cada)
            return [f"{(8 + i * cada) % 24:02d}:00" for i in range(cuantas)]

    m = _VECES_DIA.search(linea)
    if m:
        cuantas = int(m.group(1))
        if 1 <= cuantas <= 6:
            paso = 24 // cuantas
            return [f"{(8 + i * paso) % 24:02d}:00" for i in range(cuantas)]

    horas = [hora for patron, hora in _MOMENTOS if patron.search(linea)]
    return sorted(set(horas))


def _cantidad_y_unidad(linea: str) -> tuple[str, str]:
    """La primera pareja numero + unidad que se entienda.

    Se recorren todas porque una linea trae varias: "Losartan 50 mg - 1
    comprimido cada 24 horas" tiene 50 mg, 1 comprimido y 24 horas. Se toma
    la primera cuya palabra sea una unidad conocida, asi "24 horas" no se
    confunde con una dosis.
    """
    for m in _CANTIDAD_UNIDAD.finditer(linea):
        unidad = normalizar_unidad(m.group(2))
        if unidad:
            return m.group(1).replace(",", "."), unidad
    return "", ""


# Frases de frecuencia que el modelo de horarios diarios no cubre, para no
# perderlas cuando no se pueden volcar a horas.
_FRASE_FRECUENCIA = re.compile(
    r"\b(?:c(?:ada)?\s*/?\s*\d{1,3}\s*(?:h(?:r?s?|oras?)?|d[ií]as?|semanas?)"
    r"|segun\s+necesidad|s\.?o\.?s\.?|por\s+\d{1,2}\s*d[ií]as?)\b",
    re.IGNORECASE,
)


def _frase_de_frecuencia(linea: str) -> str:
    m = _FRASE_FRECUENCIA.search(linea)
    return m.group(0).strip() if m else ""


# Cuantas palabras puede tener un nombre de farmaco antes de que lo que
# sigue sea, casi seguro, una indicacion y no parte del nombre. Tres cubre
# los compuestos reales ("Amoxicilina con acido clavulanico" se abrevia, y
# "Losartan potasico" son dos).
_MAX_PALABRAS_NOMBRE = 3


def _nombre_e_instrucciones(linea: str) -> tuple[str, str]:
    """Separa el nombre del farmaco del resto de la linea.

    El nombre es lo que viene antes de la primera cantidad. Cuando la linea
    no trae ningun numero ("Paracetamol segun necesidad") eso dejaria la
    frase completa como nombre, asi que se corta en las primeras palabras y
    lo que sobra pasa a las instrucciones: no se pierde, y el campo del
    nombre queda limpio para buscarlo o compararlo.
    """
    sin_numero = re.sub(r"^\s*\d{1,2}\s*[.)\-]\s*", "", linea)
    m = re.search(r"\d", sin_numero)
    cabeza = sin_numero[: m.start()] if m else sin_numero
    # Fuera la frecuencia antes de partir en palabras. Si no, una linea sin
    # ningun numero como "Paracetamol segun necesidad" se lleva el "segun
    # necesidad" dentro del nombre, y encima repetido en las instrucciones.
    cabeza = _FRASE_FRECUENCIA.sub(" ", cabeza)
    cabeza = cabeza.strip(" .,:;-–—/|()[]")

    palabras = cabeza.split()
    nombre = " ".join(palabras[:_MAX_PALABRAS_NOMBRE])
    sobra = " ".join(palabras[_MAX_PALABRAS_NOMBRE:]).strip(" .,:;-–—/|")

    # Dos letras no son un nombre de farmaco; suele ser ruido del OCR.
    if len(nombre) < 3:
        return "", ""
    return nombre, sobra


def leer_receta(texto: str, *, maximo: int = 12) -> list[Borrador]:
    """Borradores de indicacion a partir del texto de una receta.

    [maximo] es un techo por si el OCR devuelve una pagina entera de ruido:
    mas de doce farmacos en una receta es rarisimo, y una lista de cincuenta
    borradores no la revisa nadie.
    """
    borradores: list[Borrador] = []
    vistos: set[str] = set()

    for linea in texto.splitlines():
        linea = linea.strip()
        if len(linea) < 6 or _RUIDO.match(linea):
            continue

        nombre, sobra = _nombre_e_instrucciones(linea)
        if not nombre:
            continue

        # El mismo farmaco dos veces suele ser la misma indicacion partida en
        # dos lineas por el OCR, no dos indicaciones.
        clave = _sin_tildes(nombre)
        if clave in vistos:
            continue

        dose, unit = _cantidad_y_unidad(linea)
        horarios = _horarios(linea)

        # Si la frecuencia no se pudo volcar a horas del dia, se guarda la
        # frase tal cual en las instrucciones. Pasa con los esquemas que el
        # modelo de horarios diarios no cubre, como un parche cada 72 horas:
        # perder ese "cada 72 horas" seria perder la indicacion.
        notas = [s for s in (sobra,) if s]
        if not horarios:
            frecuencia = _frase_de_frecuencia(linea)
            if frecuencia and frecuencia.lower() not in " ".join(notas).lower():
                notas.append(frecuencia)

        b = Borrador(
            name=nombre,
            dose=dose,
            unit=unit,
            schedule=horarios,
            instructions=". ".join(notas),
            origen=linea,
        )
        if not b.utilizable:
            continue

        vistos.add(clave)
        borradores.append(b)
        if len(borradores) >= maximo:
            break

    return borradores
