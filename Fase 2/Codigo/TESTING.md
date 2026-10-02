# AgeCare API — Guía de pruebas manuales

Base URL: `https://agecare-api.javiercerna.dev`  
Swagger UI: `https://agecare-api.javiercerna.dev/docs`  
Test client: `https://agecare-api.javiercerna.dev/test`

---

## 1. Autenticarse en Swagger

### Paso 1 — Obtener token

**`POST /api/v1/auth/login`** → click **Try it out** → **Execute**

```json
{
  "email": "ja.cernac@duocuc.cl",
  "password": "demo1234"
}
```

Copia el `access_token` de la respuesta.

### Paso 2 — Autorizar

Click en **Authorize 🔒** (arriba a la derecha) → pega el token en `bearerAuth` → **Authorize**.

Todos los endpoints protegidos usarán ese token automáticamente.

---

## 2. Usuarios de prueba

| Nombre | Email | Contraseña | Rol |
|---|---|---|---|
| Javier Cerna | `ja.cernac@duocuc.cl` | `demo1234` | family (familiar) |
| Rosa Medina | `rosa@cuidados.cl` | `demo1234` | caregiver (cuidadora) |

**Patient ID de Elena Rosales** (paciente de demo):
```
33333333-3333-4333-8333-333333333333
```

---

## 3. Endpoints por módulo

### 🔐 Auth

| Método | Endpoint | Notas |
|---|---|---|
| POST | `/api/v1/auth/login` | Devuelve `access_token` + `refresh_token` |
| POST | `/api/v1/auth/register` | Crea cuenta nueva |
| POST | `/api/v1/auth/refresh` | Rota el refresh token |
| POST | `/api/v1/auth/logout` | Revoca el refresh token |
| POST | `/api/v1/auth/password/recovery` | Siempre responde 202 (stub) |
| GET | `/api/v1/users/me` | Perfil del usuario autenticado |
| PATCH | `/api/v1/users/me` | Actualiza nombre o teléfono |

**Registrar cuenta nueva:**
```json
{
  "first_name": "Test",
  "last_name":  "Usuario",
  "email": "test@ejemplo.com",
  "password": "Test1234"
}
```

**Rotar token:**
```json
{
  "refresh_token": "<refresh_token del login>"
}
```

**Cerrar sesión:**
```json
{
  "refresh_token": "<refresh_token del login>"
}
```

**Actualizar perfil:**
```json
{
  "first_name": "Javier",
  "last_name":  "Cerna",
  "phone": "+56912345678"
}
```

---

### 👵 Pacientes

| Método | Endpoint | Notas |
|---|---|---|
| GET | `/api/v1/patients` | Lista mis pacientes |
| POST | `/api/v1/patients` | Crea paciente nuevo |
| GET | `/api/v1/patients/{patient_id}` | Detalle del paciente |
| PATCH | `/api/v1/patients/{patient_id}` | Actualizar datos (solo owner) |
| GET | `/api/v1/patients/{patient_id}/members` | Lista miembros e invitaciones |
| POST | `/api/v1/patients/{patient_id}/invitations` | Genera link de invitación |
| POST | `/api/v1/invitations/accept` | Acepta una invitación |
| POST | `/api/v1/patients/{patient_id}/wearable` | Vincula wearable |
| GET | `/api/v1/patients/{patient_id}/wearable/status` | Estado del wearable |

**Crear paciente:**
```json
{
  "first_name": "Nuevo",
  "last_name":  "Paciente",
  "birth_date": "1945-03-15",
  "sex": "female",
  "conditions": ["hipertension", "diabetes_tipo_2"]
}
```

**Crear invitación** (`patient_id` = `33333333-3333-4333-8333-333333333333`):
```json
{
  "role": "caregiver",
  "email": "nueva@cuidadora.cl"
}
```

**Vincular wearable:**
```json
{
  "serial_number": "SIM-000002",
  "model": "AgeCare Band v1"
}
```

---

### ❤️ Vitales

Todos usan `patient_id = 33333333-3333-4333-8333-333333333333`

| Método | Endpoint | Notas |
|---|---|---|
| GET | `/api/v1/patients/{id}/vitals/latest` | Últimas lecturas por tipo |
| GET | `/api/v1/patients/{id}/summary/today` | Semáforo del día |
| GET | `/api/v1/patients/{id}/vitals` | Serie histórica (requiere parámetros) |
| GET | `/api/v1/patients/{id}/vitals/thresholds` | Umbrales configurados |
| PUT | `/api/v1/patients/{id}/vitals/thresholds/{type}` | Actualizar umbral |
| POST | `/api/v1/patients/{id}/vitals/batch` | Ingesta por lote (wearable) |
| POST | `/api/v1/patients/{id}/vitals/manual` | Vital manual (solo caregiver) |

**Parámetros para la serie histórica (`GET /vitals`):**
```
type        = heart_rate
date_from   = 2026-08-28
date_to     = 2026-09-27
granularity = day
```

Valores válidos para `type`: `heart_rate` · `spo2` · `steps` · `sleep` · `sedentary_min` · `fall_event` · `blood_pressure` · `temperature` · `glucose`  
Valores válidos para `granularity`: `raw` · `hour` · `day` · `week`

**Ingesta por lote:**
```json
{
  "readings": [
    {"type": "heart_rate", "value": 72, "measured_at": "2026-09-27T10:00:00Z"},
    {"type": "spo2",       "value": 97, "measured_at": "2026-09-27T10:01:00Z"},
    {"type": "steps",      "value": 1800, "measured_at": "2026-09-27T10:02:00Z"}
  ]
}
```

**Vital manual** (requiere login como **Rosa**):
```json
{
  "type": "blood_pressure",
  "value": 130,
  "value_secondary": 85,
  "note": "Medición post almuerzo"
}
```

**Actualizar umbral** (`type` = `heart_rate`):
```json
{
  "min_value": 50,
  "max_value": 110
}
```

---

### 💊 Medicamentos

Todos usan `patient_id = 33333333-3333-4333-8333-333333333333`

| Método | Endpoint | Notas |
|---|---|---|
| GET | `/api/v1/patients/{id}/medications` | Plan activo (`active_only=true`) |
| POST | `/api/v1/patients/{id}/medications` | Crear medicamento (caregiver/doctor) |
| PATCH | `/api/v1/patients/{id}/medications/{med_id}` | Actualizar plan |
| DELETE | `/api/v1/patients/{id}/medications/{med_id}` | Descontinuar |
| GET | `/api/v1/patients/{id}/doses` | Dosis del día (o de una fecha) |
| POST | `/api/v1/doses/{dose_id}/log` | Registrar administración (caregiver) |
| GET | `/api/v1/patients/{id}/adherence` | Métricas de adherencia |

**Crear medicamento** (requiere login como **Rosa**):
```json
{
  "name": "Aspirina",
  "dose": "100 mg",
  "times": ["08:00", "20:00"],
  "start_date": "2026-09-27",
  "instructions": "Con un vaso de agua",
  "grace_window_min": 60
}
```

**Parámetros para dosis del día:**
```
date = 2026-09-27   (vacío = hoy)
```

**Registrar dosis** (requiere login como **Rosa**, sacar `dose_id` del GET /doses):
```json
{
  "status": "taken"
}
```

Para `missed` el motivo es obligatorio:
```json
{
  "status": "missed",
  "reason": "Paciente no quiso tomarlo"
}
```

**Parámetros para adherencia:**
```
date_from = 2026-08-28
date_to   = 2026-09-27
```

---

### 🔔 Alertas y notificaciones

| Método | Endpoint | Notas |
|---|---|---|
| GET | `/api/v1/users/me/alerts` | Centro de alertas de todos mis pacientes |
| POST | `/api/v1/alerts/{alert_id}/acknowledge` | Marcar como atendida |
| POST | `/api/v1/alerts/{alert_id}/resolve` | Resolver alerta |
| GET | `/api/v1/users/me/notification-settings` | Preferencias de notificación |
| PUT | `/api/v1/users/me/notification-settings` | Actualizar preferencias |
| POST | `/api/v1/patients/{id}/sos` | Disparar SOS (caregiver/elder) |

**Parámetros para listar alertas:**
```
status    = active | acknowledged | resolved | all
page_size = 50
```

**IDs de alertas de demo:**
```
aaaaaaa1-0000-4000-8000-000000000008  → activa   (wearable_offline)
aaaaaaa1-0000-4000-8000-000000000007  → acknowledged (FC muy elevada)
```

**Resolver alerta:**
```json
{
  "resolution_note": "Revisado y normalizado"
}
```

**Actualizar preferencias de notificación:**
```json
{
  "items": [
    {"alert_type": "missed_dose",        "push_enabled": true},
    {"alert_type": "vital_out_of_range", "push_enabled": true},
    {"alert_type": "wearable_offline",   "push_enabled": false}
  ]
}
```

> ⚠️ `fall` y `sos` no se pueden desactivar — devuelven `400 CRITICAL_ALERT_LOCKED`.

**SOS** (requiere login como **Rosa**):
```json
{
  "note": "Prueba de botón SOS"
}
```

---

## 4. Cambiar de usuario en Swagger

Para probar endpoints que requieren **caregiver** (Rosa):

1. `POST /auth/login` con `rosa@cuidados.cl` / `demo1234`
2. Copia el nuevo `access_token`
3. Click **Authorize 🔒** → borra el anterior → pega el nuevo → **Authorize**

---

## 5. Errores esperados (normales)

| Código | Error | Causa |
|---|---|---|
| `401` | `INVALID_CREDENTIALS` | Token expirado — hacer login de nuevo |
| `403` | `FORBIDDEN` | Endpoint requiere otro rol |
| `400` | `INVALID_RESET_TOKEN` | `/password/reset` es stub, tabla pendiente |
| `400` | `CRITICAL_ALERT_LOCKED` | Intentó desactivar alerta de caída o SOS |
| `409` | `DOSE_ALREADY_LOGGED` | La dosis ya fue registrada |
| `409` | `ALERT_ALREADY_CLOSED` | La alerta ya fue resuelta o atendida |
| `409` | `EMAIL_ALREADY_EXISTS` | El correo ya tiene cuenta |
| `422` | `VALIDATION_ERROR` | Falta un campo requerido o tiene formato incorrecto |
