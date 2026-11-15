"""Pruebas del filtro clinico del asistente.

No tocan base de datos ni red: `assistant_safety` son funciones puras y la
prohibicion de diagnosticar no puede depender de que haya un modelo arriba.

Dos frentes:

    SALIDA    lo que el modelo escribio no puede llegar al familiar si es un
              diagnostico, una indicacion de dosis o una cifra que no esta
              en el expediente.
    PREGUNTA  reconocer cuando la pregunta pide criterio clinico, para que
              el prompt le avise al modelo antes de responder.
"""
import pathlib as _pl
import sys as _sys
_sys.path.insert(0, str(_pl.Path(__file__).resolve().parents[1]))

from app.assistant_safety import (  # noqa: E402
    DERIVACION,
    SIN_RESPUESTA_CONFIABLE,
    pide_criterio_clinico,
    sanitizar_respuesta,
)

ok = 0
n = 0


def revisar(titulo, condicion):
    global ok, n
    n += 1
    if condicion:
        ok += 1
        print(f"  ok   {titulo}")
    else:
        print(f"  FALLA {titulo}")


EXPEDIENTE = """=== EXPEDIENTE ===
Paciente: Rosa Nunez, 78 anos.
Condiciones registradas: hipertension, diabetes tipo 2.
Signos vitales 11-11-2026: presion 152/95 mmHg, pulso 91, saturacion 93%.
Adherencia del 05-11-2026 al 11-11-2026: 38 tomadas de 44 programadas.
TOTAL · omitidas a proposito: 1 · no tomadas: 3 · postergadas: 2 · sin registrar: 0
Nota de la cuidadora 11-11-2026: refiere dolor de cabeza en la manana.
"""

# --------------------------------------------------------------------------
# SALIDA: nada de diagnosticar ni de indicar tratamiento
# --------------------------------------------------------------------------
print("\nsalida del modelo, lo que no puede pasar")

DIAGNOSTICOS = [
    "Rosa presenta hipertension mal controlada.",
    "Esto indica que el tratamiento no esta funcionando.",
    "La presion de 152/95 esta sobre el rango normal y es preocupante.",
    "Posiblemente se trate de un cuadro de deshidratacion.",
    "Los valores se mantienen estables, no hay nada de que preocuparse.",
    "Parece que tiene una infeccion.",
    "Ese valor es compatible con una crisis hipertensiva.",
]
for frase in DIAGNOSTICOS:
    r = sanitizar_respuesta(frase, EXPEDIENTE)
    revisar(f"corta el diagnostico: {frase[:46]}",
            r.modificada and "diagnostico" in r.motivos
            and r.texto == DERIVACION)

TRATAMIENTOS = [
    "Deberia aumentar la dosis del losartan a 100 mg diarios.",
    "Dele una pastilla mas de metformina si sigue alta.",
    "Lo mejor es que suspenda el remedio por unos dias.",
    "Te recomiendo reducir la insulina de la noche.",
]
for frase in TRATAMIENTOS:
    r = sanitizar_respuesta(frase, EXPEDIENTE)
    revisar(f"corta la indicacion: {frase[:46]}",
            r.modificada and "tratamiento" in r.motivos
            and r.texto == DERIVACION)

# Cifras que no estan en el expediente: inventar un dato de salud es peor
# que no responder.
r = sanitizar_respuesta("La presion del 12-11-2026 fue de 160/100 mmHg.",
                        EXPEDIENTE)
revisar("corta una fecha que no esta en el expediente",
        r.modificada and r.texto == SIN_RESPUESTA_CONFIABLE)

r = sanitizar_respuesta("Hay 6 dosis sin registrar en la semana.", EXPEDIENTE)
revisar("corta un desglose que no cuadra con el total",
        r.modificada and r.texto == SIN_RESPUESTA_CONFIABLE)

# --------------------------------------------------------------------------
# SALIDA: el dato registrado si tiene que llegar
# --------------------------------------------------------------------------
print("\nsalida del modelo, lo que si tiene que pasar")

LEGITIMAS = [
    "El 11-11-2026 se registro presion 152/95 mmHg, pulso 91 y saturacion 93%.",
    "Entre el 05-11-2026 y el 11-11-2026 se registraron 38 tomas de 44 programadas.",
    "La cuidadora dejo una nota el 11-11-2026: refiere dolor de cabeza en la manana.",
    "No puedo interpretar si ese valor es normal. Consulta con el medico tratante.",
]
for frase in LEGITIMAS:
    r = sanitizar_respuesta(frase, EXPEDIENTE)
    revisar(f"deja pasar el dato: {frase[:46]}",
            not r.modificada and r.texto == frase)

# Una respuesta mixta conserva el dato y corta solo la interpretacion.
r = sanitizar_respuesta(
    "El 11-11-2026 se registro presion 152/95 mmHg. "
    "Eso sugiere una crisis hipertensiva.", EXPEDIENTE)
revisar("de una respuesta mixta conserva el dato y corta la interpretacion",
        "152/95" in r.texto and "crisis" not in r.texto
        and DERIVACION in r.texto)

# --------------------------------------------------------------------------
# PREGUNTA: reconocer que pide criterio clinico
# --------------------------------------------------------------------------
print("\npreguntas que piden criterio clinico")

PIDEN = [
    "que tiene mi mama?",
    "es normal 152/95?",
    "debo subir la dosis?",
    "que me recetaron?",
    # Primera persona sin verbo modal: la forma en que de verdad pregunta un
    # familiar, y la que antes se escapaba.
    "le subo la dosis?",
    "le doy otra pastilla?",
    "le bajo el remedio?",
    "le cambio el tratamiento?",
    "le quito la pastilla de la noche?",
    "le aumento la dosis de metformina?",
    "le doy mas insulina?",
]
for q in PIDEN:
    revisar(f"marca: {q}", pide_criterio_clinico(q))

NO_PIDEN = [
    "cuantas dosis tomo esta semana?",
    "muestrame la presion de ayer",
    "a que hora le toca la pastilla?",
    "quien dejo la ultima nota?",
    "que dice la bitacora de ayer?",
    "cuantas alertas hubo este mes?",
]
for q in NO_PIDEN:
    revisar(f"no marca: {q}", not pide_criterio_clinico(q))

print()
print(f"resultado: {ok} de {n}")
_sys.exit(0 if ok == n else 1)
