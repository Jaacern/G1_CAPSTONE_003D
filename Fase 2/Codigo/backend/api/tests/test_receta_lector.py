"""Pruebas del lector de recetas.

No toca la base ni la aplicacion: es logica pura sobre el texto que devuelve
el OCR. De aqui salen las dosis que se le dan a un adulto mayor, asi que lo
que mas se comprueba no es lo que acierta sino lo que NO inventa.
"""
import pathlib as _pl
import sys as _sys

_sys.path.insert(0, str(_pl.Path(__file__).resolve().parents[1]))

from app.receta_lector import (  # noqa: E402
    UNIDADES_VALIDAS,
    leer_receta,
    normalizar_unidad,
)

ok = n = 0


def check(nombre, cond, detalle=""):
    global ok, n
    n += 1
    if cond:
        ok += 1
        print(f"  ok   {nombre}")
    else:
        print(f"  FALLA {nombre} {detalle}")


def uno(texto):
    """El unico borrador de una linea, o None."""
    rs = leer_receta(texto)
    return rs[0] if len(rs) == 1 else None


RECETA = """CENTRO DE SALUD FAMILIAR CORONEL

Paciente: Elena Ramirez Soto
RUT: 5.432.109-8 Edad: 78 anos

INDICACIONES:

1. Losartan 50 mg - 1 comprimido cada 24 horas

2. Metformina 850 mg - 1 comprimido cada 12 horas
3. Atorvastatina 20 mg - 1 comprimido en la noche
4. Tramadol gotas 100 mg/ml - 10 gotas cada 8 horas

Dr. Luis Fuentes - Medico Internista
Fecha: 08/11/2026"""


def main():
    # ---------------- una receta completa ----------------
    rs = leer_receta(RECETA)
    check("saca los 4 farmacos de la receta", len(rs) == 4, [b.name for b in rs])

    nombres = [b.name for b in rs]
    check("descarta el encabezado del centro de salud",
          not any("CENTRO" in x.upper() for x in nombres), nombres)
    check("descarta el nombre del paciente",
          not any("Elena" in x for x in nombres), nombres)
    check("descarta el RUT y la edad",
          not any(x.upper().startswith(("RUT", "EDAD")) for x in nombres), nombres)
    check("descarta la palabra INDICACIONES",
          not any("INDICACION" in x.upper() for x in nombres), nombres)
    check("descarta al medico que firma",
          not any(x.upper().startswith(("DR", "DRA", "MEDICO")) for x in nombres),
          nombres)
    check("descarta la fecha", not any("Fecha" in x for x in nombres), nombres)

    # ---------------- la frecuencia a horas ----------------
    b = uno("Losartan 50 mg cada 24 horas")
    check("cada 24 horas es una sola toma", b and b.schedule == ["08:00"],
          b.schedule if b else None)
    b = uno("Metformina 850 mg cada 12 horas")
    check("cada 12 horas son dos tomas",
          b and b.schedule == ["08:00", "20:00"], b.schedule if b else None)
    b = uno("Amoxicilina 500 mg c/8 h")
    check("c/8 h abreviado tambien se entiende",
          b and len(b.schedule) == 3, b.schedule if b else None)
    b = uno("Omeprazol 20 mg 2 veces al dia")
    check("2 veces al dia son dos tomas",
          b and len(b.schedule) == 2, b.schedule if b else None)
    b = uno("Atorvastatina 20 mg en la noche")
    check("en la noche se vuelve una hora", b and b.schedule == ["22:00"],
          b.schedule if b else None)
    b = uno("Levotiroxina 0,075 mg en ayunas")
    check("en ayunas se vuelve la manana", b and b.schedule == ["08:00"],
          b.schedule if b else None)

    # ---------------- lo que no se inventa ----------------
    b = uno("Paracetamol segun necesidad")
    check("sin cantidad deja la dosis vacia, no pone un 1",
          b and b.dose == "" and b.unit == "",
          (b.dose, b.unit) if b else None)
    check("el nombre no se come la frase entera",
          b and b.name == "Paracetamol", b.name if b else None)
    check("la frase que no es dosis queda en las instrucciones",
          b and "necesidad" in b.instructions, b.instructions if b else None)

    b = uno("Fentanilo 1 parche cada 72 horas")
    check("cada 72 horas no cabe en horarios diarios y queda vacio",
          b and b.schedule == [], b.schedule if b else None)
    check("pero la frecuencia no se pierde",
          b and "72" in b.instructions, b.instructions if b else None)

    check("una linea de basura del OCR no propone nada",
          leer_receta("rn4 ;;; ||| .. 8") == [], None)
    check("un texto que es solo encabezado no propone nada",
          leer_receta("Dr. Luis Fuentes\nFecha: 08/11/2026\nRUT 1-9") == [], None)
    check("texto vacio no propone nada", leer_receta("") == [], None)

    # ---------------- la concentracion no es la dosis ----------------
    b = uno("Tramadol gotas 100 mg/ml - 10 gotas cada 8 horas")
    check("no confunde la concentracion con la dosis",
          b and b.dose == "10" and b.unit == "gotas",
          (b.dose, b.unit) if b else None)

    b = uno("Ibuprofeno 400 mg cada 8 horas")
    check("no confunde las horas con la dosis",
          b and b.dose == "400" and b.unit == "mg",
          (b.dose, b.unit) if b else None)

    # ---------------- unidades ----------------
    for bruta, esperada in [
        ("TABLETAS", "comprimido"), ("tableta", "comprimido"),
        ("comp", "comprimido"), ("capsulas", "cápsula"),
        ("cc", "ml"), ("ug", "mcg"), ("U", "UI"),
        ("gota", "gotas"), ("puffs", "puff"), ("gr", "g"),
    ]:
        check(f"'{bruta}' se normaliza a '{esperada}'",
              normalizar_unidad(bruta) == esperada, normalizar_unidad(bruta))

    check("lo que no es unidad devuelve vacio",
          normalizar_unidad("horas") == "" and normalizar_unidad("mg/ml") == "",
          None)

    # La restriccion del backend es la que manda: si el lector devuelve una
    # unidad que el CHECK no admite, el guardado falla con un error que la
    # pantalla no sabe explicar.
    todas = {b.unit for b in leer_receta(RECETA) if b.unit}
    check("toda unidad propuesta la admite el CHECK de medications",
          todas <= UNIDADES_VALIDAS, todas - UNIDADES_VALIDAS)

    # ---------------- duplicados y techo ----------------
    rs = leer_receta("Losartan 50 mg cada 24 horas\nLosartan 50 mg cada 24 horas")
    check("el mismo farmaco dos veces se propone una sola",
          len(rs) == 1, len(rs))

    muchas = "\n".join(f"Farmaco{i} {i}0 mg cada 24 horas" for i in range(30))
    check("hay un techo para no devolver una lista que nadie revisa",
          len(leer_receta(muchas)) <= 12, len(leer_receta(muchas)))

    # ---------------- la linea original viaja ----------------
    b = uno("Metformina 850 mg - 1 comprimido cada 12 horas")
    check("cada borrador trae la linea tal como la leyo el OCR",
          b and "850" in b.origen and "comprimido" in b.origen,
          b.origen if b else None)

    # ---------------- espacios que el OCR se come ----------------
    # Tesseract junta palabras cuando la linea viene apretada. Pasa en casi
    # toda foto de receta y, sin tratarlo, la frecuencia se pierde entera.
    print("espacios perdidos por el OCR")
    b = uno("Metformina 850 mg - 1 comprimidocada 12 horas")
    check("'comprimidocada 12 horas' sigue dando dos horarios",
          b is not None and b.schedule == ["08:00", "20:00"],
          b.schedule if b else None)
    check("y no se lleva el pegote al nombre",
          b is not None and b.name.lower() == "metformina",
          b.name if b else None)
    check("origen conserva la linea pegada, que es lo que leyo el motor",
          b is not None and "comprimidocada" in b.origen,
          b.origen if b else None)
    b = uno("Paracetamol 500 mg - 1 comprimido3 veces al dia")
    check("'comprimido3 veces al dia' tambien se recupera",
          b is not None and len(b.schedule) == 3,
          b.schedule if b else None)
    # Lo que NO debe hacer: partir una palabra de verdad.
    b = uno("Cadaverina 10 mg cada 24 horas")
    check("no parte una palabra que empieza con esas letras",
          b is not None and b.name.lower() == "cadaverina",
          b.name if b else None)

    print()
    print(f"resultado: {ok} de {n}")
    # Codigo de salida para que el CI lo vea.
    return 0 if ok == n else 1


if __name__ == "__main__":
    import sys
    sys.exit(main())
