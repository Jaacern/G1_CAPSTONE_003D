# AgeCare — Backend

Backend de **AgeCare**, una suite de cuidado de adultos mayores. Expone una API REST
construida con **FastAPI** sobre **PostgreSQL**, pensada para acompañar a la familia,
la cuidadora, el médico y el propio adulto mayor en el seguimiento diario: signos
vitales, medicación, alertas y emergencias.

Este repositorio contiene:

- El **esquema de base de datos** (carpeta `sql/`), con 17 tablas y datos de demostración.
- La **API** en FastAPI (carpeta `api/`), con los módulos ya implementados.
- La orquestación con **Docker/Podman Compose** (base de datos + pgAdmin + API).

---

## Tabla de contenidos

- [Arquitectura](#arquitectura)
- [Stack tecnológico](#stack-tecnológico)
- [Estructura del proyecto](#estructura-del-proyecto)
- [Puesta en marcha](#puesta-en-marcha)
- [Cómo probar la API](#cómo-probar-la-api)
- [Usuarios y datos de demostración](#usuarios-y-datos-de-demostración)
- [Convenciones de la API](#convenciones-de-la-api)
- [Endpoints implementados](#endpoints-implementados)
- [Endpoints faltantes](#endpoints-faltantes)
- [Solución de problemas](#solución-de-problemas)

---

## Arquitectura

```
┌──────────────┐      HTTP/JSON       ┌──────────────────┐     asyncpg      ┌────────────────┐
│  Cliente     │  ───────────────▶    │   API FastAPI    │  ─────────────▶  │  PostgreSQL 16 │
│ (app / web / │                      │  (Python 3.12)   │                  │  (17 tablas)   │
│  Swagger)    │  ◀───────────────    │  Uvicorn :8000   │  ◀─────────────  │                │
└──────────────┘                      └──────────────────┘                  └────────────────┘
                                              │
                                              ▼
                                       ┌──────────────┐
                                       │   pgAdmin    │  (administración de la BD)
                                       └──────────────┘
```

- La API **no gestiona el esquema**: las tablas las crea el SQL de la carpeta `sql/`,
  que Postgres ejecuta automáticamente la primera vez que se levanta el contenedor.
- La autorización de cada recurso se valida contra la membresía del usuario en el
  paciente (tabla `patient_members`).

---

## Stack tecnológico

| Componente        | Tecnología                                   |
|-------------------|----------------------------------------------|
| API               | FastAPI 0.115 (Python 3.12)                  |
| Validación        | Pydantic v2                                  |
| Acceso a datos    | SQLAlchemy 2 (async) + asyncpg               |
| Base de datos     | PostgreSQL 16                                |
| Autenticación     | JWT (HS256) + refresh tokens rotatorios      |
| Hash de claves    | bcrypt (passlib)                             |
| Contenedores      | Docker / Podman Compose                      |
| Administración BD | pgAdmin 4                                    |

---

## Estructura del proyecto

```
agecare-backend/
├── api/                       # La API FastAPI
│   ├── app/
│   │   ├── main.py            # Punto de entrada, registra routers y CORS
│   │   ├── config.py          # Configuración desde variables de entorno
│   │   ├── db.py              # Motor async y sesión de BD
│   │   ├── deps.py            # Dependencias de auth y autorización por membresía
│   │   ├── errors.py          # Formato estándar de errores
│   │   ├── security.py        # JWT, bcrypt, tokens de refresco
│   │   └── routers/
│   │       ├── health.py      # Healthcheck
│   │       ├── auth.py        # Módulo 3: autenticación
│   │       ├── patients.py    # Módulo 4: pacientes y onboarding
│   │       ├── vitals.py      # Módulo 5: vitals y semáforo
│   │       ├── medications.py # Módulo 6: medicamentos y adherencia
│   │       └── alerts.py      # Módulo 9: alertas y SOS
│   ├── Dockerfile
│   └── requirements.txt
├── sql/                       # Esquema de la base de datos (se ejecuta en orden)
│   ├── 001_base.sql           # Función compartida set_updated_at
│   ├── 101_users.sql ...      # Bloque 1: identidad y acceso
│   ├── 201_wearables.sql ...  # Bloque 2: vitals y wearable
│   ├── 301_medications.sql ...# Bloque 3: medicación
│   ├── 401_alerts.sql ...     # Bloque 4: alertas y emergencias
│   └── 900_seed_dev.sql       # Datos de demostración (solo desarrollo)
├── docker-compose.yml
├── .env.example
└── README.md
```

---

## Puesta en marcha

### Requisitos

- **Docker** o **Podman** con Compose. En este proyecto se usa Podman
  (con alias `docker=podman`). Los comandos son equivalentes.

### 1. Configurar variables de entorno

Copia la plantilla y ajusta los valores:

```bash
cp .env.example .env
```

Contenido esperado del `.env`:

```env
POSTGRES_USER=agecare
POSTGRES_PASSWORD=agecare_local_2026
POSTGRES_DB=agecare

PGADMIN_EMAIL=admin@agecare.com
PGADMIN_PASSWORD=admin_local_2026

JWT_SECRET=dev-secret-local-cambiar-en-produccion
```

> El correo de pgAdmin no puede usar dominios reservados como `.local`
> (pgAdmin los rechaza). Usa un dominio normal como `.com`.

### 2. Levantar todo

```bash
podman compose up -d --build
```

Esto levanta tres servicios:

| Servicio           | Contenedor         | URL / Puerto                 |
|--------------------|--------------------|------------------------------|
| API                | `agecare-api`      | http://127.0.0.1:8000        |
| Base de datos      | `agecare-db`       | `127.0.0.1:5432`             |
| pgAdmin            | `agecare-pgadmin`  | http://127.0.0.1:5050        |

La **primera vez**, Postgres ejecuta automáticamente todos los `.sql` de la carpeta
`sql/` (crea las 17 tablas y carga 30 días de datos de demostración).

### 3. Verificar que responde

```bash
curl http://127.0.0.1:8000/health       # {"status":"ok"}
curl http://127.0.0.1:8000/health/db    # {"status":"ok","database":"up"}
```

### Comandos útiles

```bash
podman ps                          # ver contenedores en ejecución
podman compose logs -f api         # ver logs de la API en vivo
podman compose up -d --build api   # reconstruir la API tras cambiar código
podman compose down                # apagar todo (conserva los datos)
podman compose down -v             # apagar y BORRAR los datos (re-ejecuta los .sql)
```

> Los scripts `.sql` solo se ejecutan cuando el volumen de datos está vacío. Si
> editas un `.sql` y quieres reaplicarlo, usa `down -v` (esto borra todos los datos).

---

## Cómo probar la API

### Opción A — Swagger UI (recomendado)

FastAPI genera documentación interactiva automáticamente. No se instala nada:

- **Swagger UI:** http://127.0.0.1:8000/docs
- **ReDoc:** http://127.0.0.1:8000/redoc
- **Esquema OpenAPI:** http://127.0.0.1:8000/openapi.json

Flujo de prueba:

1. Abre `/docs`.
2. Ejecuta `POST /api/v1/auth/login` con un usuario de demo (ver más abajo).
3. Copia el `access_token` de la respuesta.
4. Clic en **Authorize** 🔒 (arriba a la derecha), pega el token y confirma.
5. Ya puedes ejecutar cualquier endpoint. Donde pida `patient_id`, usa el de
   Elena Rosales: `33333333-3333-4333-8333-333333333333`.

### Opción B — curl

```bash
# 1. Login (guarda el token)
TOKEN=$(curl -s -X POST http://127.0.0.1:8000/api/v1/auth/login \
  -H "Content-Type: application/json" \
  -d '{"email":"ja.cernac@duocuc.cl","password":"demo1234"}' \
  | python3 -c "import sys,json;print(json.load(sys.stdin)['access_token'])")

# 2. Usar el token en llamadas protegidas
curl http://127.0.0.1:8000/api/v1/patients \
  -H "Authorization: Bearer $TOKEN"

# 3. Semáforo del día de un paciente
PID=33333333-3333-4333-8333-333333333333
curl http://127.0.0.1:8000/api/v1/patients/$PID/summary/today \
  -H "Authorization: Bearer $TOKEN"
```

### Opción C — Desde el frontend de un compañero (misma red WiFi)

La API se publica en `0.0.0.0:8000`, accesible desde otras máquinas de la red local.
El compañero apunta su HTML/JavaScript a la **IP local de quien corre el backend**,
por ejemplo:

```js
const API = "http://192.168.18.31:8000/api/v1";
```

> Reemplaza `192.168.18.31` por la IP que tenga la máquina del backend
> (`ip a` o `hostname -I` para averiguarla). **CORS** ya está habilitado en la API,
> así que las llamadas desde el navegador funcionan. La base de datos y pgAdmin
> siguen restringidos a `127.0.0.1` por seguridad.

---

## Usuarios y datos de demostración

Los datos de demostración se cargan desde `sql/900_seed_dev.sql`. **La contraseña de
todos los usuarios de prueba es `demo1234`.**

| Correo               | Rol        | Descripción                          |
|----------------------|------------|--------------------------------------|
| `ja.cernac@duocuc.cl` | family     | Familiar administrador (Javier Cerna)|
| `rosa@cuidados.cl`   | caregiver  | Cuidadora                            |

**Paciente de demostración:** Elena Rosales
`patient_id = 33333333-3333-4333-8333-333333333333`

Incluye 30 días de historia: ~720 lecturas de frecuencia cardíaca, saturación, sueño
y pasos; plan de medicamentos (Losartán, Metformina) con dosis programadas; 8 alertas
de distintos tipos; un evento SOS; y contactos de emergencia.

---

## Convenciones de la API

- **URL base:** todas las rutas de negocio cuelgan de `/api/v1`.
- **Autenticación:** salvo los endpoints públicos de `auth`, toda petición requiere
  el encabezado `Authorization: Bearer <access_token>`.
- **Tokens:** el access token es un JWT (HS256) con vigencia de 30 minutos. El refresh
  token dura 30 días, es opaco (se guarda su hash SHA-256) y rota en cada uso.
- **Fechas:** ISO 8601 UTC (sufijo `Z`) para fechas-hora; `YYYY-MM-DD` para fechas.
- **Autorización por recurso:** cada endpoint de paciente valida que el usuario tenga
  una membresía viva en ese paciente (tabla `patient_members`) con el rol requerido.

### Formato estándar de error

```json
{
  "error": {
    "code": "INVALID_CREDENTIALS",
    "message": "Correo o contraseña incorrectos.",
    "details": null,
    "request_id": "8f3a..."
  }
}
```

### Roles

| Rol        | Idea                          |
|------------|-------------------------------|
| family     | Observa; el owner administra  |
| caregiver  | Opera (registra vitals/dosis) |
| doctor     | Prescribe                     |
| elder      | El propio adulto mayor        |

---

## Endpoints implementados

Estos módulos están implementados sobre las tablas que existen hoy en `sql/`.
Todas las rutas cuelgan de `/api/v1`.

### Salud del servicio

| Método | Ruta          | Descripción                          |
|--------|---------------|--------------------------------------|
| GET    | `/health`     | Liveness (la API responde)           |
| GET    | `/health/db`  | Readiness (conexión a la BD)         |

### Módulo 3 — Autenticación (`auth`)

| # | Método | Ruta                              | Roles      | Descripción                                    |
|---|--------|-----------------------------------|------------|------------------------------------------------|
| 3.1 | POST | `/auth/register`                  | Público    | Crear cuenta (acepta `invitation_token`)       |
| 3.2 | POST | `/auth/login`                     | Público    | Login; devuelve tokens + membresías            |
| 3.3 | POST | `/auth/refresh`                   | Público*   | Rota el refresh token (detecta reuso)          |
| 3.4 | POST | `/auth/logout`                    | Autenticado| Revoca el refresh token; desactiva dispositivo |
| 3.5 | POST | `/auth/password/recovery`         | Público    | Solicitar recuperación (siempre 202)           |
| 3.6 | POST | `/auth/password/reset`            | Público    | Restablecer contraseña (ver nota)              |
| 3.7 | GET  | `/users/me`                       | Autenticado| Perfil propio + membresías                     |
| 3.8 | PATCH| `/users/me`                       | Autenticado| Actualizar perfil propio                       |
| 3.9 | POST | `/users/me/devices`               | Autenticado| Registrar dispositivo push                     |

> **Nota 3.6:** el restablecimiento de contraseña queda como stub hasta que exista
> la tabla de tokens de recuperación en el esquema. Devuelve `INVALID_RESET_TOKEN`.

**Ejemplo — login:**

```bash
curl -X POST http://127.0.0.1:8000/api/v1/auth/login \
  -H "Content-Type: application/json" \
  -d '{"email":"ja.cernac@duocuc.cl","password":"demo1234"}'
```

### Módulo 4 — Pacientes y onboarding (`patients`)

| # | Método | Ruta                                              | Roles             | Descripción                          |
|---|--------|---------------------------------------------------|-------------------|--------------------------------------|
| 4.1 | POST   | `/patients`                                     | family            | Crear paciente (queda como owner)    |
| 4.2 | GET    | `/patients`                                     | Cualquiera        | Listar mis pacientes                 |
| 4.3 | GET    | `/patients/{patient_id}`                        | Miembro           | Detalle del paciente + wearable      |
| 4.4 | PATCH  | `/patients/{patient_id}`                        | family (owner)    | Actualizar paciente                  |
| 4.5 | POST   | `/patients/{patient_id}/invitations`            | family (owner)    | Invitar al círculo de cuidado        |
| 4.6 | POST   | `/invitations/accept`                           | Autenticado       | Aceptar invitación                   |
| 4.7 | GET    | `/patients/{patient_id}/members`                | family, doctor    | Listar miembros + invitaciones       |
| 4.8 | DELETE | `/patients/{patient_id}/members/{user_id}`      | family (owner)    | Quitar miembro                       |
| 4.9 | POST   | `/patients/{patient_id}/wearable`               | family, caregiver | Vincular wearable                    |
| 4.10| GET    | `/patients/{patient_id}/wearable/status`        | Miembro           | Estado de sincronización del wearable|

### Módulo 5 — Vitals y semáforo (`vitals`)

| # | Método | Ruta                                                    | Roles                    | Descripción                          |
|---|--------|---------------------------------------------------------|--------------------------|--------------------------------------|
| 5.1 | POST | `/patients/{patient_id}/vitals/batch`                   | caregiver, elder, family | Ingesta por lote (idempotente)       |
| 5.2 | POST | `/patients/{patient_id}/vitals/manual`                  | caregiver                | Registrar vital manual               |
| 5.3 | GET  | `/patients/{patient_id}/vitals`                         | Miembro                  | Series y tendencias                  |
| 5.4 | GET  | `/patients/{patient_id}/vitals/latest`                  | Miembro                  | Últimos valores por tipo             |
| 5.5 | GET  | `/patients/{patient_id}/vitals/thresholds`              | Miembro                  | Listar umbrales                      |
| 5.6 | PUT  | `/patients/{patient_id}/vitals/thresholds/{type}`       | family, doctor           | Configurar umbral                    |
| 5.7 | GET  | `/patients/{patient_id}/summary/today`                  | Miembro                  | Semáforo de bienestar del día        |
| 5.8 | GET  | `/users/me/dashboard`                                   | Cualquiera               | Tablero multi-paciente               |

**Tipos de vital:** `heart_rate`, `spo2`, `sleep`, `steps`, `sedentary_min`,
`fall_event`, `blood_pressure`, `temperature`, `glucose`.

### Módulo 6 — Medicamentos y adherencia (`medications`)

| # | Método | Ruta                                                    | Roles             | Descripción                          |
|---|--------|---------------------------------------------------------|-------------------|--------------------------------------|
| 6.1 | POST   | `/patients/{patient_id}/medications`                  | caregiver, doctor | Crear medicamento del plan           |
| 6.2 | GET    | `/patients/{patient_id}/medications`                  | Miembro           | Listar plan                          |
| 6.3 | PATCH  | `/patients/{patient_id}/medications/{medication_id}`  | caregiver, doctor | Actualizar medicamento               |
| 6.4 | DELETE | `/patients/{patient_id}/medications/{medication_id}`  | caregiver, doctor | Descontinuar (baja lógica)           |
| 6.5 | GET    | `/patients/{patient_id}/doses`                        | Miembro           | Dosis del día + próxima toma         |
| 6.6 | POST   | `/doses/{dose_id}/log`                                | caregiver         | Registrar administración de dosis    |
| 6.7 | GET    | `/patients/{patient_id}/adherence`                    | Miembro           | Métricas de adherencia               |

### Módulo 9 — Alertas y SOS (`alerts`)

| # | Método | Ruta                                     | Roles             | Descripción                          |
|---|--------|------------------------------------------|-------------------|--------------------------------------|
| 9.1 | GET  | `/users/me/alerts`                       | Cualquiera        | Centro de alertas (todos los pacientes)|
| 9.2 | POST | `/alerts/{alert_id}/acknowledge`         | family, caregiver | Marcar alerta como atendida          |
| 9.3 | POST | `/alerts/{alert_id}/resolve`             | family, caregiver | Resolver alerta                      |
| 9.4 | GET  | `/users/me/notification-settings`        | Cualquiera        | Preferencias de notificación         |
| 9.5 | PUT  | `/users/me/notification-settings`        | Cualquiera        | Actualizar preferencias              |
| 9.6 | POST | `/patients/{patient_id}/sos`             | caregiver, elder  | Disparar SOS (alerta crítica)        |

> Las alertas de tipo `fall` y `sos` no se pueden silenciar (regla de negocio en la BD).

---

## Endpoints faltantes

Los siguientes módulos de la especificación **aún no están implementados** porque
sus tablas no existen todavía en `sql/`. Se documentan aquí para dejar clara la hoja
de ruta; se agregarán cuando el esquema incorpore las tablas correspondientes.

### Módulo 7 — Observaciones, incidentes, relevos y check-in

Requiere las tablas `observations`, `incidents`, `handover_notes`, `elder_checkins`.

| # | Método | Ruta                                        | Descripción                                  |
|---|--------|---------------------------------------------|----------------------------------------------|
| 7.1 | POST | `/patients/{patient_id}/observations`       | Registrar observación (ánimo, sueño, etc.)   |
| 7.2 | GET  | `/patients/{patient_id}/observations`       | Bitácora de observaciones (paginada)         |
| 7.3 | POST | `/patients/{patient_id}/incidents`          | Registrar incidente (caída, dolor, etc.)     |
| 7.4 | POST | `/patients/{patient_id}/handover-notes`     | Nota de relevo entre turnos                  |
| 7.5 | GET  | `/patients/{patient_id}/handover-notes`     | Consultar notas de relevo                    |
| 7.6 | POST | `/patients/{patient_id}/checkin`            | Check-in emocional del adulto mayor          |

### Módulo 8 — Archivos y documentos médicos

Requiere las tablas `uploads`, `documents` y almacenamiento tipo Blob con URLs firmadas.

| # | Método | Ruta                                   | Descripción                              |
|---|--------|----------------------------------------|------------------------------------------|
| 8.1 | POST   | `/uploads`                            | Solicitar URL de subida firmada          |
| 8.2 | POST   | `/patients/{patient_id}/documents`    | Registrar documento médico               |
| 8.3 | GET    | `/patients/{patient_id}/documents`    | Listar documentos                        |
| 8.4 | GET    | `/documents/{document_id}/download`   | Descargar (URL firmada)                  |
| 8.5 | DELETE | `/documents/{document_id}`            | Eliminar documento                       |

También pendiente **6.8** `POST /patients/{patient_id}/prescriptions/scan` (OCR de
recetas), que requiere un servicio de reconocimiento de documentos.

### Módulo 10 — Asistente IA

Requiere `assistant_conversations`, `assistant_messages` y un modelo LLM.

| # | Método | Ruta                                                        | Descripción                     |
|---|--------|-------------------------------------------------------------|---------------------------------|
| 10.1 | POST | `/patients/{patient_id}/assistant/messages`                 | Preguntar al asistente          |
| 10.2 | GET  | `/patients/{patient_id}/assistant/conversations`            | Listar conversaciones           |
| 10.3 | GET  | `/assistant/conversations/{conversation_id}/messages`       | Historial de una conversación   |

### Módulo 11 — Mensajes / chat

Requiere `chat_messages`, `chat_read_pointers` y WebSocket.

| # | Método | Ruta                                        | Descripción                          |
|---|--------|---------------------------------------------|--------------------------------------|
| 11.1 | GET  | `/patients/{patient_id}/chat/messages`      | Historial del chat (cursor)          |
| 11.2 | POST | `/patients/{patient_id}/chat/messages`      | Enviar mensaje                       |
| 11.3 | WS   | `/ws/patients/{patient_id}/chat`            | Canal en tiempo real                 |
| 11.4 | POST | `/patients/{patient_id}/chat/read`          | Marcar mensajes como leídos          |

### Módulo 12 — Vista del adulto mayor (fotos y entretenimiento)

Requiere `photos`, `photo_reactions`, `content_items` y servicios de TTS/STT.

| # | Método | Ruta                                     | Descripción                          |
|---|--------|------------------------------------------|--------------------------------------|
| 12.1 | POST   | `/patients/{patient_id}/photos`        | Compartir foto a la galería          |
| 12.2 | GET    | `/patients/{patient_id}/photos`        | Galería de fotos                     |
| 12.3 | POST   | `/photos/{photo_id}/reactions`         | Reaccionar a una foto                |
| 12.4 | DELETE | `/photos/{photo_id}`                   | Eliminar foto                        |
| 12.5 | GET    | `/content/feed`                        | Feed de entretenimiento              |
| 12.6 | POST   | `/tts`                                 | Sintetizar voz                       |
| 12.7 | POST   | `/stt`                                 | Transcribir voz a texto              |

### Módulos 13 y 14 — Vista de la cuidadora y marketplace

Requieren `care_tasks`, `caregiver_profiles`, `caregiver_subscriptions`,
`job_offers`, `marketplace_products`, `caregiver_reviews`, `contact_requests`.

Incluyen: check-in del día de la cuidadora, tareas del día, perfil profesional,
plan free/premium, ofertas de trabajo, reportes, búsqueda y contacto de cuidadoras,
reseñas y catálogo de productos.

---

## Solución de problemas

| Síntoma                                   | Causa probable / solución                                            |
|-------------------------------------------|----------------------------------------------------------------------|
| `401 UNAUTHORIZED` en Swagger             | El access token expiró (30 min). Vuelve a hacer login y **Authorize**.|
| `403 FORBIDDEN`                           | El rol del usuario no tiene permiso para esa acción (es lo esperado). |
| La API no levanta / error de importación  | `podman compose logs api` para ver el traceback.                     |
| Las tablas no existen                     | El volumen se creó vacío sin los `.sql`. Usa `down -v` y `up -d`.    |
| pgAdmin no arranca                        | El `PGADMIN_EMAIL` usa un dominio reservado (`.local`). Usa `.com`.   |
| El frontend del compañero no conecta      | Verifica misma red WiFi y la IP local correcta; CORS ya está activo. |
| Cambié código y no se refleja             | Reconstruye: `podman compose up -d --build api`.                     |
```
