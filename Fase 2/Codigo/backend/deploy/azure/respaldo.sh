#!/usr/bin/env bash
# Respaldo de la base de datos en un archivo comprimido.
#
#   ./deploy/azure/respaldo.sh [etiqueta]
#
# Deja el archivo en ~/respaldos (o BACKUP_DIR) y borra los de mas de 7
# dias. El archivo contiene datos de salud: permisos 600, y si lo bajas a
# tu equipo hazlo por scp, nunca por un servicio de terceros.
#
# Un respaldo en la misma VM no protege si se pierde la VM: bajalo de vez
# en cuando (ver deploy/azure/README.md).
set -euo pipefail

ETIQUETA="${1:-manual}"
DEST="${BACKUP_DIR:-$HOME/respaldos}"
ARCHIVO="$DEST/agecare-$(date +%Y%m%d-%H%M%S)-${ETIQUETA}.sql.gz"

mkdir -p "$DEST"
chmod 700 "$DEST"
umask 077

# POSTGRES_USER y POSTGRES_DB ya existen dentro del contenedor de la base.
docker exec agecare-db sh -c 'pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" --no-owner' \
  | gzip > "$ARCHIVO"

# Un respaldo vacio o minimo es una falla silenciosa: se detecta aqui.
if [ "$(stat -c %s "$ARCHIVO")" -lt 200 ]; then
  rm -f "$ARCHIVO"
  echo "[respaldo] FALLO: el archivo quedo vacio" >&2
  exit 1
fi

find "$DEST" -name 'agecare-*.sql.gz' -mtime +7 -delete
echo "[respaldo] $ARCHIVO"
