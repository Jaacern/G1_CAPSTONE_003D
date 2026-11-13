#!/usr/bin/env bash
# Actualiza AgeCare en la VM con lo ultimo de GitHub. Es el comando que
# cualquiera del equipo corre despues de hacer push.
#
#   ./deploy/azure/actualizar.sh               # rama main
#   ./deploy/azure/actualizar.sh mi-rama       # otra rama
#   ./deploy/azure/actualizar.sh a1b2c3d       # volver a un commit anterior
#   ./deploy/azure/actualizar.sh --sin-pull    # reconstruir lo que ya hay
#
# Antes de tocar nada saca un respaldo de la base. Si el despliegue sale
# mal, vuelve con el commit anterior que este script imprime al inicio.
set -euo pipefail

BACKEND_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$BACKEND_DIR"

REF="${1:-main}"
COMPOSE=(docker compose -f docker-compose.yml -f docker-compose.azure.yml)
SERVICIOS=(db api mantenimiento avisos)
# Sin credenciales del tunel el contenedor reinicia en bucle: no se levanta.
if [ -f "$HOME/.cloudflared/config.yml" ]; then
  SERVICIOS+=(cloudflared)
fi

if [ ! -f .env ]; then
  echo "Falta .env. Ejecuta primero deploy/azure/instalar-vm.sh" >&2
  exit 1
fi

ANTES="$(git rev-parse --short HEAD)"
echo "[actualizar] commit actual: $ANTES  (para volver: ./deploy/azure/actualizar.sh $ANTES)"

# --- Respaldo previo (solo si la base ya esta corriendo) ----------------
if docker ps --format '{{.Names}}' | grep -qx agecare-db; then
  ./deploy/azure/respaldo.sh antes-de-actualizar
else
  echo "[actualizar] la base aun no corre: sin respaldo previo"
fi

# --- Traer el codigo ----------------------------------------------------
if [ "$REF" != "--sin-pull" ]; then
  git fetch origin
  if git show-ref --verify --quiet "refs/remotes/origin/$REF"; then
    git checkout "$REF"
    # ff-only: si la VM tiene cambios propios, falla en vez de mezclar a ciegas.
    git pull --ff-only origin "$REF"
  else
    git checkout "$REF"
  fi
  echo "[actualizar] ahora en: $(git rev-parse --short HEAD)"
fi

# --- Reconstruir y levantar ---------------------------------------------
# La API aplica las migraciones sola al arrancar (app.migrate --auto).
"${COMPOSE[@]}" up -d --build "${SERVICIOS[@]}"

# --- Verificar ----------------------------------------------------------
./deploy/azure/smoke-test.sh
echo "[actualizar] listo"
