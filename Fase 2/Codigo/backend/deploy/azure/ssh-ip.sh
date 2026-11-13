#!/usr/bin/env bash
# Define que IPs pueden entrar por SSH a la VM. Sirve cuando tu proveedor te
# cambia la IP o para dar acceso a un companero. REEMPLAZA la lista completa,
# asi que pasa todas las IPs del equipo:
#
#   ./ssh-ip.sh 200.1.2.3 190.4.5.6 181.7.8.9
#
# Se ejecuta desde tu equipo, con la sesion de `az` iniciada.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$DIR/config.env"

if [ "$#" -lt 1 ]; then
  echo "Uso: $0 <ip-v4> [<ip-v4> ...]" >&2
  exit 1
fi

PREFIJOS=()
for ip in "$@"; do
  if ! printf '%s' "$ip" | grep -Eq '^[0-9]{1,3}(\.[0-9]{1,3}){3}$'; then
    echo "IP invalida: $ip" >&2
    exit 1
  fi
  PREFIJOS+=("${ip}/32")
done

az network nsg rule update \
  --resource-group "$RG" \
  --nsg-name "${VM_NAME}NSG" \
  --name permitir-ssh-mi-ip \
  --source-address-prefixes "${PREFIJOS[@]}" \
  --output none
echo "SSH ahora solo acepta: $*"
