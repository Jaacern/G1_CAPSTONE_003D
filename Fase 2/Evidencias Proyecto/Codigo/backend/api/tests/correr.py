#!/usr/bin/env python3
"""Corre todas las pruebas del backend y devuelve un codigo de salida.

POR QUE NO ES PYTEST
    Cada archivo de esta carpeta es un guion que habla con el esquema real:
    aplica datos, llama al endpoint y comprueba lo que quedo en la base. Son
    pruebas de integracion, no unitarias, y varias dependen del orden en que
    tocan sus propias filas. Portarlas a pytest obligaria a reescribir casi
    cuatrocientas comprobaciones, con el riesgo de traducir mal alguna y
    cambiar lo que se esta probando sin darse cuenta. Se prefirio dejarlas
    como estan, que funcionan, y darles un corredor que el CI pueda usar.

COMO SE USA
    Desde backend/api, con una base levantada y el esquema aplicado:

        python tests/correr.py

    La conexion sale de las mismas variables que usa la aplicacion
    (POSTGRES_HOST, POSTGRES_PORT, POSTGRES_USER...). Cada archivo pone un
    valor por omision con setdefault, asi que el entorno siempre gana.

    Se puede acotar a unas pocas pasando partes del nombre:

        python tests/correr.py dosis alertas

CADA ARCHIVO EN SU PROCESO
    Y no importados aqui, por dos razones. Varios fijan variables de entorno
    antes de importar la aplicacion, asi que en un mismo proceso el primero
    decidiria por todos. Y si uno revienta, los demas siguen corriendo en vez
    de caerse con el.
"""
from __future__ import annotations

import pathlib
import subprocess
import sys
import time

AQUI = pathlib.Path(__file__).resolve().parent
RAIZ = AQUI.parent  # backend/api, donde vive el paquete app


def archivos(filtros: list[str]) -> list[pathlib.Path]:
    todos = sorted(AQUI.glob("test_*.py"))
    if not filtros:
        return todos
    return [p for p in todos if any(f.lower() in p.name.lower() for f in filtros)]


def main(argv: list[str]) -> int:
    pruebas = archivos(argv)
    if not pruebas:
        print(f"No hay pruebas que coincidan con {argv}")
        return 2

    print(f"Corriendo {len(pruebas)} archivos de prueba desde {RAIZ}\n")
    fallaron: list[tuple[str, int]] = []
    inicio = time.monotonic()

    for p in pruebas:
        print(f"{'=' * 70}\n{p.name}\n{'=' * 70}")
        r = subprocess.run(
            [sys.executable, str(p)],
            cwd=RAIZ,
            # Sin capturar: la salida de cada prueba va directa a la consola,
            # que es lo que uno quiere leer cuando el CI se pone rojo.
        )
        if r.returncode != 0:
            fallaron.append((p.name, r.returncode))
            print(f"--> {p.name} FALLO (codigo {r.returncode})")
        print()

    segundos = time.monotonic() - inicio
    print("=" * 70)
    if fallaron:
        print(f"FALLARON {len(fallaron)} de {len(pruebas)} en {segundos:.0f}s:")
        for nombre, codigo in fallaron:
            print(f"   {nombre} (codigo {codigo})")
        return 1

    print(f"Pasaron los {len(pruebas)} archivos en {segundos:.0f}s.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
