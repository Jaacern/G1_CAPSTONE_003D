"""Validadores de datos de identidad que el borde de la API reconoce por completo.

Criterio LangSec del proyecto: todo dato se reconoce contra su formato exacto
en la entrada y se rechaza lo ambiguo, en vez de aceptar texto libre y
esperar que la base lo rechace con un CHECK (que termina en un 500).
"""
from __future__ import annotations

import re

_RUT_SOLO_CARACTERES = re.compile(r"^[0-9]{7,8}[0-9K]$")


def rut_digito_verificador(numero: int) -> str:
    """Dígito verificador de un RUT chileno (módulo 11).

    Es la misma cuenta que hace la función SQL rut_digito_verificador() de
    915_rut_dv.sql. Se repite aquí para responder 422 con un mensaje claro
    antes de llegar al CHECK de la base.
    """
    suma = 0
    multiplo = 2
    n = numero
    while n > 0:
        suma += (n % 10) * multiplo
        multiplo = 2 if multiplo == 7 else multiplo + 1
        n //= 10
    resto = 11 - (suma % 11)
    if resto == 11:
        return "0"
    if resto == 10:
        return "K"
    return str(resto)


def parse_rut(valor: str) -> tuple[int, str]:
    """Devuelve (numero, dv) de un RUT escrito como 12.345.678-5, 12345678-5
    o 123456785. Lanza ValueError si el formato o el dígito no corresponden.
    """
    limpio = re.sub(r"[.\-\s]", "", valor or "").upper()
    if not _RUT_SOLO_CARACTERES.match(limpio):
        raise ValueError("El RUT no tiene un formato válido (ej. 12.345.678-5).")
    numero, dv = int(limpio[:-1]), limpio[-1]
    # Mismo rango que ck_patients_rut_number.
    if not 1_000_000 <= numero <= 99_999_999:
        raise ValueError("El RUT está fuera del rango válido.")
    if rut_digito_verificador(numero) != dv:
        raise ValueError("El dígito verificador del RUT no corresponde.")
    return numero, dv


def clean_person_name(valor: str) -> str:
    """Nombre o apellido de una persona, normalizado.

    Reconoce solo letras (con tildes y ñ), espacios, apostrofe, guion y punto
    (de Mc'Donald, De la Fuente, Mª...). Rechaza dígitos y símbolos: un
    "nombre" como '1234' o '<script>' no es un nombre. Colapsa espacios
    repetidos y recorta los extremos. Lanza ValueError si no es válido.
    """
    s = re.sub(r"\s+", " ", (valor or "").strip())
    if not s:
        raise ValueError("No puede ir vacío.")
    if not s[0].isalpha():
        raise ValueError("Debe comenzar con una letra.")
    for c in s:
        if not (c.isalpha() or c in " '-."):
            raise ValueError("Solo puede contener letras, espacios, apóstrofe, guion o punto.")
    return s


def normalize_phone(valor: str) -> str:
    """Normaliza un teléfono a E.164 (+56912345678).

    Acepta espacios, guiones y paréntesis. Sin prefijo internacional se
    asume Chile y se exigen 9 dígitos. Lanza ValueError si no se puede
    reconocer con certeza: es un número de emergencia, no se adivina.
    """
    s = re.sub(r"[\s\-().]", "", (valor or "").strip())
    if s.startswith("00"):
        s = "+" + s[2:]
    if s.startswith("+"):
        digitos = s[1:]
    elif len(s) == 9:
        digitos = "56" + s
    elif len(s) == 11 and s.startswith("56"):
        digitos = s
    else:
        raise ValueError(
            "El teléfono debe tener 9 dígitos o incluir el prefijo del país (+56...)."
        )
    if not digitos.isdigit() or not 8 <= len(digitos) <= 15:
        raise ValueError("El teléfono no tiene un formato válido.")
    return "+" + digitos
