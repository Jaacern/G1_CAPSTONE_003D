package com.agecare.watch

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.BatteryManager
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.SystemClock

/**
 * Servicio en primer plano que orquesta la captura de signos vitales del Galaxy
 * Watch con el **Samsung Health Sensor SDK** y la **detección de caídas** con el
 * acelerómetro, enviando todo al backend de AgeCare con el token de dispositivo.
 *
 * SENSORES:
 *   - Frecuencia cardíaca: continuo (Samsung SDK), última lectura se sube por batch.
 *   - SpO2: medición on-demand disparada periódicamente.
 *   - Temperatura de piel: medición on-demand disparada periódicamente.
 *   - Caídas: acelerómetro continuo; al detectar, dispara alerta crítica.
 *
 * THROTTLING: la FC llega ~1/s. Guardamos la última de cada tipo y subimos un
 * batch como máximo cada [UPLOAD_INTERVAL_MS]. SpO2 y temperatura se miden cada
 * [ONDEMAND_INTERVAL_MS] porque son costosas en batería.
 *
 * El servicio solo mide si el reloj está VINCULADO (DeviceStore.isLinked).
 */
class HeartRateService : Service() {

    companion object {
        const val CHANNEL_ID = "agecare_hr"
        const val NOTIF_ID = 1001

        const val UPLOAD_INTERVAL_MS = 10_000L      // subida de batch
        const val ONDEMAND_INTERVAL_MS = 60_000L    // medición SpO2 + temperatura

        // Estado observable por la UI.
        @Volatile var lastBpm: Int = 0
        @Volatile var lastSpo2: Int = 0
        // Estado legible de la medición de SpO2 en curso, o null si no hay.
        @Volatile var spo2Status: String? = null
        @Volatile var lastTemp: Float = 0f
        @Volatile var lastSent: Int = 0
        @Volatile var online: Boolean = false
        @Volatile var running: Boolean = false
        @Volatile var spo2Supported: Boolean = false
        @Volatile var tempSupported: Boolean = false
        @Volatile var fallArmed: Boolean = false
        @Volatile var lastFallAt: Long = 0L
        @Volatile var lastBattery: Int = -1
        @Volatile var sensorError: String? = null
        @Volatile var lastError: String? = null
    }

    private lateinit var store: DeviceStore
    private lateinit var uploader: VitalsUploader
    private lateinit var samsung: SamsungHealthManager
    private var fallDetector: FallDetector? = null

    private val handler = Handler(Looper.getMainLooper())

    // Últimas muestras pendientes de enviar.
    @Volatile private var pendingBpm: Int = 0
    @Volatile private var pendingSpo2: Int = 0
    @Volatile private var pendingTemp: Float = 0f
    @Volatile private var lastUploadAt: Long = 0L
    @Volatile private var lastOnDemandAt: Long = 0L
    @Volatile private var uploading: Boolean = false

    // ----------------------------------------------------------------------
    private val samsungListener = object : SamsungHealthManager.Listener {
        override fun onConnected(spo2Available: Boolean, skinTempAvailable: Boolean) {
            spo2Supported = spo2Available
            tempSupported = skinTempAvailable
            sensorError = null
            samsung.startHeartRate()
            // Primera medición on-demand enseguida.
            triggerOnDemand(force = true)
        }

        override fun onConnectionFailed(reason: String) {
            sensorError = reason
        }

        override fun onHeartRate(bpm: Int, ibiList: List<Int>) {
            lastBpm = bpm
            pendingBpm = bpm
            maybeUpload()
            maybeOnDemand()
        }

        override fun onSpO2(spo2: Int) {
            lastSpo2 = spo2
            pendingSpo2 = spo2
            maybeUpload()
        }

        override fun onSkinTemperature(celsius: Float) {
            lastTemp = celsius
            pendingTemp = celsius
            maybeUpload()
        }

        override fun onMeasurementError(what: String) {
            sensorError = what
        }

        override fun onSpO2Status(text: String?) {
            spo2Status = text
        }
    }

    // ----------------------------------------------------------------------
    override fun onCreate() {
        super.onCreate()
        store = DeviceStore(this)
        uploader = VitalsUploader(store)
        samsung = SamsungHealthManager(this)
        startInForeground()

        if (!store.isLinked) {
            // Sin vincular: el servicio queda vivo pero no mide. La UI pedirá
            // el código de emparejamiento.
            lastError = "Reloj no vinculado"
            running = false
            return
        }

        samsung.setListener(samsungListener)
        samsung.connect()

        // Detección de caídas (acelerómetro nativo).
        fallDetector = FallDetector(this) { impactG -> onFallDetected(impactG) }.also {
            if (it.isAvailable) {
                it.start()
                fallArmed = true
            }
        }

        running = true
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int = START_STICKY

    // ----------------------------------------------------------------------
    // Caída detectada → alerta crítica al backend.
    // ----------------------------------------------------------------------
    private fun onFallDetected(impactG: Float) {
        lastFallAt = System.currentTimeMillis()
        uploader.sendFall(impactG) { result ->
            when (result) {
                is VitalsUploader.Result.Ok ->
                    android.util.Log.w("AgeCareWatch", "Alerta de caída enviada ✓")
                is VitalsUploader.Result.Error ->
                    android.util.Log.e("AgeCareWatch", "Alerta de caída falló: ${result.reason}")
            }
        }
    }

    // ----------------------------------------------------------------------
    // Mediciones on-demand (SpO2 + temperatura) cada ONDEMAND_INTERVAL_MS.
    // ----------------------------------------------------------------------
    private fun maybeOnDemand() {
        val now = SystemClock.elapsedRealtime()
        if (now - lastOnDemandAt < ONDEMAND_INTERVAL_MS) return
        triggerOnDemand(force = false)
    }

    private fun triggerOnDemand(force: Boolean) {
        val now = SystemClock.elapsedRealtime()
        if (!force && now - lastOnDemandAt < ONDEMAND_INTERVAL_MS) return
        lastOnDemandAt = now
        if (spo2Supported) samsung.measureSpO2()
        if (tempSupported) samsung.measureSkinTemperature()
    }

    // ----------------------------------------------------------------------
    // Subida por batch (throttled).
    // ----------------------------------------------------------------------
    private fun maybeUpload() {
        val now = SystemClock.elapsedRealtime()
        if (uploading) return
        if (now - lastUploadAt < UPLOAD_INTERVAL_MS) return

        val readings = mutableMapOf<VitalsUploader.Vital, Double>()
        if (uploader.isValid(VitalsUploader.Vital.HEART_RATE, pendingBpm.toDouble())) {
            readings[VitalsUploader.Vital.HEART_RATE] = pendingBpm.toDouble()
        }
        if (pendingSpo2 > 0 &&
            uploader.isValid(VitalsUploader.Vital.SPO2, pendingSpo2.toDouble())
        ) {
            readings[VitalsUploader.Vital.SPO2] = pendingSpo2.toDouble()
        }
        if (pendingTemp > 0f &&
            uploader.isValid(VitalsUploader.Vital.TEMPERATURE, pendingTemp.toDouble())
        ) {
            readings[VitalsUploader.Vital.TEMPERATURE] = pendingTemp.toDouble()
        }
        if (readings.isEmpty()) return

        uploading = true
        lastUploadAt = now
        uploader.sendReadings(readings, batteryPct = readBatteryPct()) { result ->
            uploading = false
            when (result) {
                is VitalsUploader.Result.Ok -> {
                    online = true
                    lastError = null
                    lastSent += 1
                    // Los valores on-demand ya se enviaron: se consumen.
                    pendingSpo2 = 0
                    pendingTemp = 0f
                }
                is VitalsUploader.Result.Error -> {
                    online = false
                    lastError = result.reason
                }
            }
        }
    }

    private fun readBatteryPct(): Int? {
        val bm = getSystemService(Context.BATTERY_SERVICE) as? BatteryManager ?: return null
        val pct = bm.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY)
        return if (pct in 0..100) {
            lastBattery = pct
            pct
        } else null
    }

    // ----------------------------------------------------------------------
    private fun startInForeground() {
        val mgr = getSystemService(NotificationManager::class.java)
        mgr.createNotificationChannel(
            NotificationChannel(CHANNEL_ID, "Monitoreo AgeCare", NotificationManager.IMPORTANCE_LOW)
        )
        val notif: Notification = Notification.Builder(this, CHANNEL_ID)
            .setContentTitle("AgeCare")
            .setContentText("Midiendo signos vitales")
            .setSmallIcon(android.R.drawable.ic_menu_mylocation)
            .setOngoing(true)
            .build()
        startForeground(NOTIF_ID, notif)
    }

    override fun onDestroy() {
        super.onDestroy()
        try { samsung.disconnect() } catch (_: Exception) {}
        try { fallDetector?.stop() } catch (_: Exception) {}
        handler.removeCallbacksAndMessages(null)
        running = false
        fallArmed = false
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
