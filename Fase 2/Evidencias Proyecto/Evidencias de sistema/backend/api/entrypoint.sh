#!/bin/sh
# Arranque de la API.
#
# Pone la base al dia ANTES de servir. El orden importa: una API que ya
# acepta peticiones contra un esquema viejo devuelve errores raros en
# endpoints sueltos, y eso cuesta mucho mas de diagnosticar que un
# contenedor que no parte.
#
# Si la migracion falla, el contenedor no arranca. Es a proposito: servir
# con el esquema equivocado es peor que no servir.
set -e

echo "[arranque] poniendo la base al dia"
python -m app.migrate --auto

echo "[arranque] levantando la API"
exec uvicorn app.main:app --host 0.0.0.0 --port 8000
