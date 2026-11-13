#!/usr/bin/env bash
# Prepara la VM la primera vez: instala Docker, crea el .env con secretos
# nuevos, programa el respaldo diario y levanta la plataforma.
#
# Se ejecuta DENTRO de la VM, desde el repo ya clonado:
#
#   cd ~/agecare/Fase\ 2/Codigo/backend
#   PUBLIC_URL=https://api.tu-dominio.cl ./deploy/azure/instalar-vm.sh
#
# PUBLIC_URL es la direccion que usa el telefono para llegar a la API (la
# del tunel de Cloudflare). Es idempotente: se puede repetir sin danio.
set -euo pipefail

BACKEND_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$BACKEND_DIR"

if [ -z "${PUBLIC_URL:-}" ]; then
  echo "Falta PUBLIC_URL. Ejemplo: PUBLIC_URL=https://api.tu-dominio.cl $0" >&2
  exit 1
fi
case "$PUBLIC_URL" in
  https://*) ;;
  *) echo "PUBLIC_URL debe empezar con https://" >&2; exit 1 ;;
esac

# --- 1. Docker ---------------------------------------------------------
if ! command -v docker >/dev/null 2>&1; then
  echo "[instalar] instalando Docker"
  sudo apt-get update -y
  sudo apt-get install -y ca-certificates curl
  sudo install -m 0755 -d /etc/apt/keyrings
  sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    -o /etc/apt/keyrings/docker.asc
  sudo chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
  sudo apt-get update -y
  sudo apt-get install -y docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin
  sudo systemctl enable --now docker
fi

if ! docker ps >/dev/null 2>&1; then
  sudo usermod -aG docker "$USER"
  echo
  echo "Docker quedo instalado. Cierra la sesion SSH, vuelve a entrar y"
  echo "ejecuta este mismo comando otra vez (el grupo 'docker' aplica al"
  echo "iniciar sesion)."
  exit 0
fi

# --- 2. .env con secretos nuevos ---------------------------------------
if [ ! -f .env ]; then
  echo "[instalar] creando .env con secretos nuevos"
  cp .env.example .env
  umask 077
  JWT="$(openssl rand -hex 32)"
  DBPASS="$(openssl rand -hex 24)"
  PGAPASS="$(openssl rand -hex 16)"
  sed -i "s|^JWT_SECRET=.*|JWT_SECRET=${JWT}|" .env
  sed -i "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=${DBPASS}|" .env
  sed -i "s|^PGADMIN_PASSWORD=.*|PGADMIN_PASSWORD=${PGAPASS}|" .env
  sed -i "s|^STORAGE_PUBLIC_BASE_URL=.*|STORAGE_PUBLIC_BASE_URL=${PUBLIC_URL}|" .env
  # El pago simulado aprueba sin cobrar: no va en produccion.
  printf '\nPAYMENT_PROVIDER=none\n' >> .env
  chmod 600 .env
  echo "[instalar] .env creado (permisos 600). Revisalo y agrega las claves"
  echo "           de correo, IA o Firebase que necesites: nano .env"
else
  echo "[instalar] .env ya existe, no se toca"
fi

# --- 3. Tunel de Cloudflare --------------------------------------------
if [ ! -f "$HOME/.cloudflared/config.yml" ]; then
  echo
  echo "AVISO: falta ~/.cloudflared/config.yml (credenciales del tunel)."
  echo "Copialas desde tu equipo con scp (ver deploy/azure/README.md) y"
  echo "vuelve a ejecutar este script. Mientras tanto la API queda sin"
  echo "salida publica."
fi

# --- 4. Respaldo diario (03:00 hora de la VM, que es UTC) ---------------
mkdir -p "$HOME/respaldos"
CRON_LINEA="0 3 * * * cd \"$BACKEND_DIR\" && ./deploy/azure/respaldo.sh diario >> \"$HOME/respaldos/cron.log\" 2>&1"
( crontab -l 2>/dev/null | grep -v 'deploy/azure/respaldo.sh' ; echo "$CRON_LINEA" ) | crontab -
echo "[instalar] respaldo diario programado"

# --- 5. Levantar --------------------------------------------------------
chmod +x deploy/azure/*.sh
./deploy/azure/actualizar.sh --sin-pull
