"""Alergias que no están en el catálogo ("Otra"): se aceptan escritas a mano
si son un nombre, y se rechazan si son basura que terminaría impresa en la
hoja de emergencia."""
import os
os.environ.setdefault("POSTGRES_HOST", "127.0.0.1")
os.environ.setdefault("POSTGRES_PORT", "5432")
os.environ.setdefault("STORAGE_LOCAL_DIR", "/tmp/agecare-files-test")
os.environ.setdefault("STORAGE_PUBLIC_BASE_URL", "http://testserver")

import pathlib as _pl
import sys as _sys
_sys.path.insert(0, str(_pl.Path(__file__).resolve().parents[1]))

from pydantic import ValidationError  # noqa: E402

from app.routers.patients import AllergyIn  # noqa: E402

ok = fallo = 0


def check(nombre, cond, detalle=""):
    global ok, fallo
    if cond:
        ok += 1
        print(f"  ok   {nombre}")
    else:
        fallo += 1
        print(f"  FALLA {nombre} {detalle}")


def acepta(valor):
    try:
        return AllergyIn(substance=valor).substance
    except ValidationError:
        return None


check("un código del catálogo pasa igual", acepta("penicilina") == "penicilina")
check("texto libre con número: Vitamina B12",
      acepta("Vitamina B12") == "Vitamina B12")
check("con paréntesis y espacios de más se limpia",
      acepta("  Contraste   yodado (IV) ") == "Contraste yodado (IV)")
check("con tildes y ñ", acepta("Piña") == "Piña")
check("solo números se rechaza", acepta("1234") is None)
check("etiquetas HTML se rechazan", acepta("<script>") is None)
check("símbolos se rechazan", acepta("kiwi#@") is None)
check("una sola letra se rechaza", acepta("k") is None)

print(f"\n{ok} ok, {fallo} fallas")
_sys.exit(1 if fallo else 0)
