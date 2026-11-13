#!/usr/bin/env bash
# Prueba rapida despues de un despliegue: la API responde y el contenedor
# de cada servicio esta arriba.
#
#   ./deploy/azure/smoke-test.sh                       # prueba local en la VM
#   PUBLIC_URL=https://api.tu-dominio.cl ./deploy/azure/smoke-test.sh
#                                                      # ademas, por el tunel
#
# Si el dominio esta protegido con Cloudflare Access, agrega el service token
# (el mismo que usa la app):
#   export CF_ACCESS_CLIENT_ID=...   CF_ACCESS_CLIENT_SECRET=...
set -euo pipefail

verificar() {
  local url="$1" intentos=30
  # Si la URL esta detras de Cloudflare Access, sin el service token responde
  # 403 antes de llegar a la API. Se pasan por variable de entorno para que
  # no queden en el historial ni en pantalla.
  local cabeceras=()
  if [ -n "${CF_ACCESS_CLIENT_ID:-}" ] && [ -n "${CF_ACCESS_CLIENT_SECRET:-}" ]; then
    cabeceras=(-H "CF-Access-Client-Id: ${CF_ACCESS_CLIENT_ID}"
               -H "CF-Access-Client-Secret: ${CF_ACCESS_CLIENT_SECRET}")
  fi
  for _ in $(seq 1 "$intentos"); do
    if curl -fsS --max-time 5 "${cabeceras[@]}" "$url" 2>/dev/null | grep -q agecare-api; then
      echo "[smoke] OK  $url"
      return 0
    fi
    sleep 2
  done
  echo "[smoke] FALLO  $url no respondio tras $intentos intentos" >&2
  return 1
}

verificar "http://127.0.0.1:8000/"

if [ -n "${PUBLIC_URL:-}" ]; then
  verificar "${PUBLIC_URL%/}/"
fi

for c in agecare-db agecare-api agecare-mantenimiento agecare-avisos; do
  estado="$(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null || echo ausente)"
  if [ "$estado" != "running" ]; then
    echo "[smoke] FALLO  $c esta '$estado'" >&2
    echo "        Revisa: docker logs --tail 50 $c" >&2
    exit 1
  fi
  echo "[smoke] OK  $c"
done
