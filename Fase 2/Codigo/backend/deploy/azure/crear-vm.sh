#!/usr/bin/env bash
# Crea en Azure la VM donde corre AgeCare. Se ejecuta UNA vez, desde tu
# equipo, con `az` instalado y la sesion iniciada (`az login`).
#
# Crea: grupo de recursos, VM Ubuntu 24.04, IP publica fija y firewall con
# SSH abierto solo a MI_IP. No abre ningun otro puerto: el trafico de la app
# entra por el tunel de Cloudflare.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
if [ ! -f "$DIR/config.env" ]; then
  echo "Falta $DIR/config.env. Copia config.env.example y ajustalo." >&2
  exit 1
fi
# shellcheck disable=SC1091
source "$DIR/config.env"

if [ -z "${MI_IP:-}" ]; then
  echo "MI_IP esta vacia en config.env. Pon tu IP publica." >&2
  exit 1
fi

if ! az account show >/dev/null 2>&1; then
  echo "No hay sesion de Azure. Ejecuta: az login" >&2
  exit 1
fi

echo "Suscripcion: $(az account show --query name -o tsv)"
echo "Se creara '$VM_NAME' ($VM_SIZE) en '$LOCATION', grupo '$RG'."
read -r -p "Continuar? [s/N] " resp
[ "$resp" = "s" ] || { echo "Cancelado."; exit 0; }

az group create --name "$RG" --location "$LOCATION" --output none

# --nsg-rule NONE: no abre SSH al mundo; la regla se agrega abajo.
az vm create \
  --resource-group "$RG" \
  --name "$VM_NAME" \
  --image "Canonical:ubuntu-24_04-lts:server:latest" \
  --size "$VM_SIZE" \
  --admin-username "$ADMIN_USER" \
  --generate-ssh-keys \
  --public-ip-sku Standard \
  --os-disk-size-gb 64 \
  --storage-sku StandardSSD_LRS \
  --nsg-rule NONE \
  --output none

az network nsg rule create \
  --resource-group "$RG" \
  --nsg-name "${VM_NAME}NSG" \
  --name permitir-ssh-mi-ip \
  --priority 1000 \
  --direction Inbound \
  --access Allow \
  --protocol Tcp \
  --destination-port-ranges 22 \
  --source-address-prefixes "${MI_IP}/32" \
  --output none

IP="$(az vm show -d -g "$RG" -n "$VM_NAME" --query publicIps -o tsv)"
echo
echo "Listo. IP publica de la VM: $IP"
echo "Conectate con:  ssh ${ADMIN_USER}@${IP}"
echo "Siguiente paso: ver deploy/azure/README.md, seccion 'Preparar la VM'."
