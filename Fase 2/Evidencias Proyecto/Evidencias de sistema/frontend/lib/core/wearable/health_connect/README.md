# ⌚ Integración de reloj real — Health Connect

Lee datos de salud reales de un reloj (p. ej. **Samsung Galaxy Watch 4**)
y los sube al backend de AgeCare. **Gratis, sin servicios de pago.**

## Cómo fluyen los datos

```
⌚ Galaxy Watch 4
   │  Bluetooth
   ▼
📱 Samsung Health (en el teléfono Android)
   │  escribe en
   ▼
📱 Health Connect (misma app del teléfono)
   │  esta app lee
   ▼
📱 AgeCare (Flutter, corriendo EN el teléfono)
   │  HTTP (POST /patients/{id}/vitals/batch)
   ▼
💻 Backend en el PC (http://IP_DEL_PC:8000)
```

> ⚠️ **Importante:** Health Connect es una API **nativa de Android**. La app
> AgeCare debe correr **en el teléfono** (no en Chrome ni en Linux). El WiFi
> solo se usa en el último paso: que el teléfono alcance al backend del PC.

## Archivos

| Archivo | Qué hace |
|---|---|
| `health_connect_service.dart` | Disponibilidad, permisos y **lectura** de HR, pasos, SpO₂ y sueño. Mapea al modelo del backend (`VitalReading`). |
| `health_connect_sync.dart` | Controlador Riverpod que **coordina** lectura → subida (`/vitals/batch`) y publica el estado (idle/reading/uploading/done/error). |

UI: botón **"Sincronizar ahora"** en la pantalla *Vincular wearable*
(`features/wearable/presentation/wearable_link_screen.dart`).

## Requisitos en el teléfono Android

1. **Samsung Health** instalado y el **Galaxy Watch 4 emparejado** (vía la app
   Galaxy Wearable). Que el reloj haya sincronizado al menos una vez.
2. **Health Connect** instalado (en Android 14+ viene integrado; en versiones
   anteriores se instala desde Play Store:
   `com.google.android.apps.healthdata`).
3. En **Samsung Health → Ajustes → Health Connect**, permitir que Samsung
   Health **escriba** ritmo, pasos, SpO₂ y sueño en Health Connect.

## Permisos (ya configurados en el `AndroidManifest.xml`)

```xml
<uses-permission android:name="android.permission.health.READ_HEART_RATE"/>
<uses-permission android:name="android.permission.health.READ_STEPS"/>
<uses-permission android:name="android.permission.health.READ_OXYGEN_SATURATION"/>
<uses-permission android:name="android.permission.health.READ_SLEEP"/>
```
Más el `intent-filter` de *permissions rationale* y el `activity-alias`
(Android 14+), y la entrada `<queries>` para detectar Health Connect.

> Nota build: Health Connect requiere **minSdk 26+** y **compileSdk 34+**. Si
> el build falla por SDK, súbelos en `android/app/build.gradle`.

## Cómo probar (paso a paso)

1. **Arranca el backend** en el PC y anota la IP del PC en el WiFi:
   ```bash
   podman compose up -d db api      # expone 0.0.0.0:8000
   ip addr | grep "inet 192"        # p. ej. 192.168.1.50
   ```
2. **Conecta el teléfono por USB** (con depuración USB activada) y corre la app
   apuntando al backend del PC:
   ```bash
   flutter run \
     --dart-define=USE_MOCKS=false \
     --dart-define=API_BASE_URL=http://192.168.1.50:8000
   ```
   (Reemplaza la IP por la de tu PC. Teléfono y PC en el **mismo WiFi**.)
3. En la app, inicia sesión (familiar/cuidadora/adulto mayor) y ve a
   **Más → Dispositivos / wearables** (o la pantalla de vincular wearable).
4. Toca **"Sincronizar ahora"**. Acepta los permisos de Health Connect la
   primera vez.
5. Vuelve a **Hoy / Salud**: el semáforo y los vitals deberían reflejar los
   datos reales del reloj.

### Alternativa sin cable: `adb reverse`
Si prefieres no exponer la IP, reenvía el puerto por USB y usa `localhost`:
```bash
adb reverse tcp:8000 tcp:8000
flutter run --dart-define=USE_MOCKS=false --dart-define=API_BASE_URL=http://localhost:8000
```

## Qué se lee y cómo se mapea

| Health Connect | Backend (`type`) | Nota |
|---|---|---|
| HEART_RATE | `heart_rate` | una lectura por muestra |
| BLOOD_OXYGEN | `spo2` | fracción 0–1 se convierte a % |
| STEPS | `steps` | se **suma por día** (el backend espera acumulado) |
| SLEEP_ASLEEP | `sleep` | duración de la sesión → **horas** |

Las lecturas se suben con `VitalsRepository.uploadBatch`
(`POST /patients/{id}/vitals/batch`). El backend es idempotente: reenviar las
mismas lecturas no las duplica (cuenta "aceptadas" vs "duplicadas").

## Problemas típicos

- **"Sin datos en el rango":** el reloj aún no sincronizó con Samsung Health, o
  Samsung Health no tiene permiso de escritura en Health Connect.
- **No aparece la app en Health Connect:** revisa el `intent-filter` de
  rationale y que Health Connect esté instalado.
- **No conecta al backend:** teléfono y PC deben estar en el mismo WiFi; prueba
  la IP con el navegador del teléfono: `http://IP_DEL_PC:8000/docs`. Si no
  carga, revisa el firewall del PC. La alternativa `adb reverse` evita esto.

## Limitaciones / pendientes

- Sincronización **manual** (botón). La sincronización en segundo plano (cada X
  horas) queda como mejora futura.
- iOS usaría HealthKit (el paquete `health` lo soporta), pero el flujo descrito
  es para Android + Samsung Health.
