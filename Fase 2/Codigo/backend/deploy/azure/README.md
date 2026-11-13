# Despliegue en Microsoft Azure

Guía para publicar el backend de AgeCare en una máquina virtual (VM) de Azure y
mantenerlo al día. Pensada para que cualquiera del equipo pueda actualizar el
despliegue con un comando.

> **Nota de alcance.** El plan original del proyecto menciona Azure Container
> Apps. Para la entrega se usa una VM con el mismo `docker compose` que corre en
> desarrollo: es lo que menos cambia respecto a lo ya probado. Migrar a
> servicios administrados queda como trabajo futuro.

## Arquitectura

```
Teléfono / Admin web
        │ HTTPS
        ▼
  Cloudflare (túnel)  ◄── única entrada pública
        │
        ▼
┌──────────────── VM Azure (Ubuntu 24.04, Standard_B2s) ─────────────┐
│  cloudflared ─► api :8000 (solo 127.0.0.1)                          │
│                  │                                                  │
│  mantenimiento   │   avisos          db (PostgreSQL, sin puerto)    │
│  (cada hora)     │   (cada 30 s)    volumen pgdata                  │
└─────────────────────────────────────────────────────────────────────┘
        ▲
        │ SSH (puerto 22, solo IPs del equipo)
```

Lo único abierto en el firewall de Azure es SSH, y solo para las IPs del equipo.
La base de datos no publica ningún puerto y pgAdmin no arranca en producción.

## Archivos

| Archivo | Para qué |
|---------|----------|
| `backend/docker-compose.azure.yml` | Override de producción: cierra puertos y deja pgAdmin fuera |
| `backend/deploy/azure/config.env.example` | Plantilla de parámetros de la VM (copiar a `config.env`) |
| `backend/deploy/azure/crear-vm.sh` | Crea grupo de recursos, VM, IP fija y firewall (desde tu equipo) |
| `backend/deploy/azure/ssh-ip.sh` | Cambia las IPs que pueden entrar por SSH (desde tu equipo) |
| `backend/deploy/azure/instalar-vm.sh` | Primera preparación de la VM: Docker, `.env`, respaldo diario |
| `backend/deploy/azure/actualizar.sh` | Trae lo último de GitHub, reconstruye y verifica |
| `backend/deploy/azure/respaldo.sh` | Respaldo comprimido de la base |
| `backend/deploy/azure/smoke-test.sh` | Comprueba que la API y los contenedores están arriba |

## Requisitos previos

- Suscripción de Azure activa (Azure for Students sirve; un fin de semana cuesta
  unos pocos dólares).
- Azure CLI en tu equipo. En Ubuntu/Debian: `curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash`.
  En sistemas inmutables (Bazzite, Fedora Atomic) no hay `apt-get`: crea un
  envoltorio `~/.local/bin/az` que ejecute
  `podman run --rm -it -v ~/.azure:/root/.azure:Z -v ~/.ssh:/root/.ssh:Z mcr.microsoft.com/azure-cli:latest az "$@"`
  y dale permiso de ejecución. Luego `az login --use-device-code`.
- El túnel de Cloudflare ya creado, con su carpeta `~/.cloudflared` en tu
  equipo (contiene `config.yml` y el archivo de credenciales).

## 1. Crear la VM (una sola vez, desde tu equipo)

```bash
cd "Fase 2/Codigo/backend/deploy/azure"
cp config.env.example config.env
nano config.env        # completa MI_IP con tu IP pública
./crear-vm.sh
```

El script pide confirmación antes de crear nada y al final imprime la IP pública
de la VM. Si Azure rechaza el tamaño o la región (pasa con cuentas de
estudiante), cambia `LOCATION` o `VM_SIZE` en `config.env` y repite.

### 1b. Alternativa: crear la VM desde el portal

Algunas cuentas institucionales (por ejemplo, correos de Duoc UC) tienen una
política de acceso condicional que bloquea `az login`: aparece "No tiene
permiso para acceder a este recurso". El portal web sí funciona, así que la VM
se crea ahí. Los pasos 2 en adelante no cambian.

1. En tu equipo, si no tienes clave SSH: `ssh-keygen -t ed25519`. Luego copia
   la clave pública con `cat ~/.ssh/id_ed25519.pub`.
2. Portal > **Crear un recurso** > **Máquina virtual**.
3. Básico:
   - Suscripción: Azure for Students. Grupo de recursos: nuevo, `agecare-rg`.
   - Nombre: `agecare-vm`. Región: la que el portal permita (prueba Brazil
     South, East US 2 o Central US). Opciones de disponibilidad: sin redundancia.
   - Imagen: Ubuntu Server 24.04 LTS - x64 Gen2.
   - Tamaño: `Standard_B2s`. Si no aparece, usa `Standard_B2ls_v2` o
     `Standard_B2as_v2`.
   - Autenticación: clave pública SSH. Nombre de usuario: `azureuser`. Origen:
     usar clave pública existente y pega la clave del paso 1.
   - Puertos de entrada públicos: permitir los seleccionados, **SSH (22)**.
4. Discos: SSD estándar. Tamaño del disco del SO: 64 GiB.
5. Redes: deja la IP pública nueva (SKU Standard, asignación estática).
6. Revisar y crear.
7. **Inmediatamente después**, restringe SSH: VM > Redes > regla de entrada
   `SSH` > Origen: *Direcciones IP* > escribe la IP pública de cada integrante
   (separadas por coma) > Guardar. Sin esto el puerto 22 queda abierto a todo
   internet.

Anota la IP pública de la VM (página de información general).

## 2. Preparar la VM

Conéctate y clona el repositorio:

```bash
ssh azureuser@<IP-de-la-VM>
git clone https://github.com/Jaacern/G1_CAPSTONE_003D.git agecare
```

Si el repositorio es privado, usa una *deploy key* de solo lectura en lugar de
tu cuenta personal:

```bash
ssh-keygen -t ed25519 -N "" -f ~/.ssh/agecare_deploy
cat ~/.ssh/agecare_deploy.pub
# GitHub > repo > Settings > Deploy keys > Add (sin permiso de escritura)
printf 'Host github.com\n  IdentityFile ~/.ssh/agecare_deploy\n' >> ~/.ssh/config
git clone git@github.com:Jaacern/G1_CAPSTONE_003D.git agecare
```

Las credenciales del túnel se copian **al final** (sección 7), no antes, para que
nunca haya dos conectores con el mismo túnel. Cuando llegue el momento, copia
solo `config.yml` y el archivo `<id-del-túnel>.json` desde tu equipo. **No
copies `cert.pem`**: da permisos sobre toda la cuenta de Cloudflare y la VM no
lo necesita para ejecutar el túnel.

```bash
ssh -i <tu-clave.pem> azureuser@<IP-de-la-VM> 'mkdir -p ~/.cloudflared'
scp -i <tu-clave.pem> ~/.cloudflared/config.yml ~/.cloudflared/<id>.json \
  azureuser@<IP-de-la-VM>:~/.cloudflared/
```

Verifica que `config.yml` apunte a un destino que el contenedor `cloudflared`
alcance por la red de Docker: `http://api:8000`. Con `http://localhost:8000`
no funcionaría dentro del contenedor.

Ejecuta el instalador dentro de la VM:

```bash
cd ~/agecare/"Fase 2"/Codigo/backend
PUBLIC_URL=https://api.tu-dominio.cl ./deploy/azure/instalar-vm.sh
```

La primera vez instala Docker y pide que cierres sesión y vuelvas a entrar; el
mismo comando se repite sin problema. El instalador:

- crea `.env` con `JWT_SECRET` y claves de base **nuevas**, generadas en la VM;
- fija `PAYMENT_PROVIDER=none` (el pago simulado aprueba sin cobrar y no debe
  quedar en producción);
- programa un respaldo diario a las 03:00 (hora de la VM, que es UTC);
- levanta los servicios y corre la prueba de humo.

Después revisa `nano .env` si necesitas correo, asistente de IA o Firebase. Esas
claves se escriben en la VM y no se suben a GitHub. Tras cambiar `.env`, aplica
con `./deploy/azure/actualizar.sh --sin-pull`.

## 3. Flujo diario del equipo

Cada integrante trabaja y compila en su equipo como siempre. Para publicar un
cambio:

1. `git push` a `main` (o a una rama).
2. Entra a la VM y actualiza:

```bash
ssh azureuser@<IP-de-la-VM>
cd ~/agecare/"Fase 2"/Codigo/backend
./deploy/azure/actualizar.sh            # main
./deploy/azure/actualizar.sh mi-rama    # otra rama
```

El script saca un respaldo de la base, trae el código con `git pull --ff-only`,
reconstruye, y corre la prueba de humo. Tarda unos minutos. Las migraciones SQL
nuevas se aplican solas al arrancar la API. El script imprime el commit que
había antes de actualizar.

**Acceso del equipo.** Cada integrante agrega su clave pública a
`~/.ssh/authorized_keys` de la VM, y se abre el firewall a todas las IPs juntas
(el comando reemplaza la lista completa):

```bash
./ssh-ip.sh <ip-1> <ip-2> <ip-3>
```

**Cambios en la app móvil o el admin web.** Se compilan en cada equipo. Solo
cambian si la URL pública de la API cambia (ver `lib/core/config.dart` en
`admin_web` y la configuración equivalente en `frontend`).

## 3b. Versión web (demostración desde un computador)

La API sirve también las dos apps Flutter compiladas para web, en el mismo
dominio, así que la demostración se hace abriendo un link:

| Ruta | Qué es | Carpeta en la imagen |
|------|--------|----------------------|
| `/app/` | App principal (familiar, cuidadora, médico, adulto mayor) | `api/app/static/app_web` |
| `/admin/` | Panel de administración | `api/app/static/admin_web` |

Los builds no se versionan (pesan decenas de MB). Para publicar un cambio de
interfaz, compila en tu equipo:

```bash
cd "Fase 2/Codigo/frontend"
flutter build web --release --base-href /app/ \
  --dart-define=USE_MOCKS=false \
  --dart-define=API_BASE_URL=https://<tu-dominio>
tar -C build/web -czf /tmp/app_web.tgz .

cd ../admin_web
flutter build web --release --base-href /admin/
tar -C build/web -czf /tmp/admin_web.tgz .
```

Cópialos a la VM y extráelos en su carpeta:

```bash
scp -i <tu-clave.pem> /tmp/app_web.tgz /tmp/admin_web.tgz azureuser@<IP-de-la-VM>:/tmp/
ssh -i <tu-clave.pem> azureuser@<IP-de-la-VM>
S=~/agecare/"Fase 2"/Codigo/backend/api/app/static
for n in app_web admin_web; do rm -rf "$S/$n"; mkdir -p "$S/$n"; tar -xzf /tmp/$n.tgz -C "$S/$n"; done
cd ~/agecare/"Fase 2"/Codigo/backend && ./deploy/azure/actualizar.sh --sin-pull
```

La imagen copia `app/` al construirse, por eso hace falta `actualizar.sh` después
de extraer. El `--base-href` tiene que coincidir con la ruta (`/app/`, `/admin/`):
con otro valor la página queda en blanco.

En la versión web no funcionan las notificaciones push, el reloj ni la
grabación de voz; el resto del flujo sí.

## 4. Volver atrás

Si una actualización sale mal, vuelve al commit anterior que el script imprimió:

```bash
./deploy/azure/actualizar.sh a1b2c3d
```

Eso deja la VM en modo "commit fijo". Para volver a seguir `main`, ejecuta
`./deploy/azure/actualizar.sh main`.

## 5. Respaldos y restauración

Respaldo manual:

```bash
./deploy/azure/respaldo.sh manual       # queda en ~/respaldos
```

Restaurar sobre una base vacía (detén la API antes para que no escriba):

```bash
gunzip -c ~/respaldos/<archivo>.sql.gz \
  | docker exec -i agecare-db sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB"'
```

Los respaldos viven en la misma VM; no protegen si la VM se pierde. Baja uno a
tu equipo antes de la presentación, por `scp`, nunca por un servicio de
terceros: contiene datos de salud.

```bash
scp azureuser@<IP-de-la-VM>:~/respaldos/<archivo>.sql.gz .
```

## 6. Diagnóstico

```bash
docker ps                                  # estado de los contenedores
docker logs --tail 50 agecare-api          # errores de la API
docker logs --tail 50 agecare-cloudflared  # problemas del túnel
./deploy/azure/smoke-test.sh               # prueba rápida
```

Si la API no arranca, casi siempre es una migración que falló: el contenedor se
detiene a propósito en lugar de servir con el esquema equivocado. El motivo está
en `docker logs agecare-api`.

## 7. Cambio de servidor local a Azure

El túnel de Cloudflare no puede tener dos conectores activos con el mismo
nombre: el tráfico se reparte y parte de las peticiones iría al servidor viejo.
Orden recomendado:

1. Levantar y verificar la VM (pasos 1 y 2) **sin** `~/.cloudflared` en la VM:
   el script no levanta `cloudflared` si no están las credenciales.
2. Apagar `cloudflared` en el servidor local (`docker compose stop cloudflared`
   o `podman stop agecare-cloudflared`).
3. Copiar `config.yml` y el `.json` a la VM (sección 2) y levantar
   `cloudflared`: `./deploy/azure/actualizar.sh --sin-pull`.
4. Probar con `PUBLIC_URL=https://api.tu-dominio.cl ./deploy/azure/smoke-test.sh`.

Si algo falla, el plan B es volver a levantar `cloudflared` en el servidor local.

## 8. Costos y apagado

Una VM `Standard_B2s` cuesta del orden de 0,05 USD por hora. Para no gastar
cuando ya no se use, desasígnala desde tu equipo (apagarla desde dentro del
sistema sigue cobrando):

```bash
az vm deallocate -g agecare-rg -n agecare-vm      # pausa el cómputo
az vm start      -g agecare-rg -n agecare-vm      # la vuelve a encender
az group delete  -g agecare-rg                    # borra TODO (irreversible)
```

## 9. Lista de verificación antes de la presentación

- [ ] `./deploy/azure/smoke-test.sh` con `PUBLIC_URL` responde OK.
- [ ] Login desde el teléfono real contra la URL pública.
- [ ] `docker ps` en la VM muestra `db`, `api`, `mantenimiento`, `avisos` y
      `cloudflared` arriba.
- [ ] Un respaldo reciente bajado a tu equipo.
- [ ] El túnel del servidor local está apagado.
- [ ] `PAYMENT_PROVIDER` en `.env` de la VM es `none`.
- [ ] El saldo de la suscripción de Azure cubre hasta la fecha de entrega.
