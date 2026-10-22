package com.agecare.watch

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.os.IBinder
import androidx.health.services.client.HealthServices
import androidx.health.services.client.MeasureCallback
import androidx.health.services.client.data.Availability
import androidx.health.services.client.data.DataPointContainer
import androidx.health.services.client.data.DataType
import androidx.health.services.client.data.DeltaDataType
import androidx.health.services.client.data.SampleDataPoint

/**
 * Servicio en primer plano que recibe el ritmo cardíaco EN VIVO vía
 * **Health Services de Wear OS (MeasureClient)**. A diferencia de
 * PassiveMonitoring (lotes espaciados), MeasureClient entrega muestras
 * continuas (~1/s) mientras el callback está registrado. El servicio foreground
 * mantiene el registro activo aunque la pantalla esté apagada.
 *
 * Cada muestra se sube al backend (POST /vitals/batch) con origin=watch.
 */
class HeartRateService : Service() {

    companion object {
        const val CHANNEL_ID = "agecare_hr"
        const val NOTIF_ID = 1001
        @Volatile var lastBpm: Int = 0
        @Volatile var lastSent: Int = 0
        @Volatile var online: Boolean = false
        @Volatile var running: Boolean = false
    }

    private val uploader = VitalsUploader()
    private val measureClient by lazy { HealthServices.getClient(this).measureClient }

    private val callback = object : MeasureCallback {
        override fun onAvailabilityChanged(
            dataType: DeltaDataType<*, *>,
            availability: Availability,
        ) {
            android.util.Log.i("AgeCareWatch", "availability=$availability")
        }

        override fun onDataReceived(data: DataPointContainer) {
            val samples = data.getData(DataType.HEART_RATE_BPM)
            android.util.Log.i("AgeCareWatch", "onDataReceived samples=${samples.size}")
            for (p in samples) {
                val bpm = (p as SampleDataPoint<Double>).value.toInt()
                android.util.Log.i("AgeCareWatch", "bpm=$bpm")
                if (bpm <= 0) continue
                lastBpm = bpm
                uploader.sendHeartRate(bpm) { ok ->
                    online = ok
                    if (ok) lastSent += 1
                    android.util.Log.i("AgeCareWatch", "sent bpm=$bpm ok=$ok")
                }
            }
        }
    }

    override fun onCreate() {
        super.onCreate()
        startInForeground()
        try {
            measureClient.registerMeasureCallback(DataType.HEART_RATE_BPM, callback)
            android.util.Log.i("AgeCareWatch", "MeasureClient registrado OK")
        } catch (e: Exception) {
            online = false
            android.util.Log.e("AgeCareWatch", "registro falló: $e")
        }
        running = true
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int = START_STICKY

    private fun startInForeground() {
        val mgr = getSystemService(NotificationManager::class.java)
        mgr.createNotificationChannel(
            NotificationChannel(CHANNEL_ID, "Monitoreo AgeCare",
                NotificationManager.IMPORTANCE_LOW)
        )
        val notif: Notification = Notification.Builder(this, CHANNEL_ID)
            .setContentTitle("AgeCare")
            .setContentText("Midiendo el ritmo cardíaco")
            .setSmallIcon(android.R.drawable.ic_menu_mylocation)
            .setOngoing(true)
            .build()
        startForeground(NOTIF_ID, notif)
    }

    override fun onDestroy() {
        super.onDestroy()
        try {
            measureClient.unregisterMeasureCallbackAsync(DataType.HEART_RATE_BPM, callback)
        } catch (_: Exception) {}
        running = false
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
