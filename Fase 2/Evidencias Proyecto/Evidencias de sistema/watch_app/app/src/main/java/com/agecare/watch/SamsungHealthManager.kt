package com.agecare.watch

import android.content.Context
import com.samsung.android.service.health.tracking.ConnectionListener
import com.samsung.android.service.health.tracking.HealthTracker
import com.samsung.android.service.health.tracking.HealthTrackerException
import com.samsung.android.service.health.tracking.HealthTrackingService
import com.samsung.android.service.health.tracking.data.DataPoint
import com.samsung.android.service.health.tracking.data.HealthTrackerType
import com.samsung.android.service.health.tracking.data.ValueKey

/**
 * Orquesta el **Samsung Health Sensor SDK** para leer los sensores del Galaxy
 * Watch. Encapsula la conexión al HealthTrackingService y tres trackers:
 *
 *   - Frecuencia cardíaca → HEART_RATE_CONTINUOUS (flujo continuo, ~1/s).
 *   - SpO2               → SPO2_ON_DEMAND (medición puntual, tarda unos segundos).
 *   - Temperatura piel   → SKIN_TEMPERATURE_ON_DEMAND (medición puntual).
 *
 * Requiere el modo desarrollador de Health Sensor Service activado en el reloj
 * (si no, el SDK responde SDK_POLICY_ERROR). Ver getting-started del SDK.
 *
 * Los valores se entregan por callbacks simples [Listener]; quien orquesta
 * (HeartRateService) decide cuándo iniciar mediciones on-demand y cuándo subir.
 */
class SamsungHealthManager(private val context: Context) {

    interface Listener {
        fun onConnected(spo2Available: Boolean, skinTempAvailable: Boolean)
        fun onConnectionFailed(reason: String)
        fun onHeartRate(bpm: Int, ibiList: List<Int>)
        fun onSpO2(spo2: Int)
        fun onSkinTemperature(celsius: Float)
        fun onMeasurementError(what: String)
        /** Estado legible de la medición de SpO2 en curso (para la UI). */
        fun onSpO2Status(text: String?) {}
    }

    private var listener: Listener? = null

    private var trackingService: HealthTrackingService? = null
    private var hrTracker: HealthTracker? = null
    private var spo2Tracker: HealthTracker? = null
    private var skinTempTracker: HealthTracker? = null

    @Volatile private var spo2Available = false
    @Volatile private var skinTempAvailable = false
    @Volatile var connected = false
        private set

    // Estados de medición según la SDK.
    // SpO2Set.STATUS == 2 → medición completa (API reference oficial).
    //   (0 = calculando/inicial, 1 = midiendo). El valor final llega con 2.
    // SkinTemperatureSet.STATUS == 1 → medición exitosa.
    private companion object {
        const val SPO2_STATUS_COMPLETE = 2
        const val SKIN_TEMP_STATUS_SUCCESS = 1
        // Tope de cada intento de SpO2. La medición dura ~30 s; si a los 40 s
        // no hay valor, se cierra para no dejar el sensor encendido gastando
        // batería y para permitir un intento limpio en el siguiente ciclo.
        const val SPO2_TIMEOUT_MS = 40_000L
    }

    // Timer del intento de SpO2 en curso (se cancela al terminar o detener).
    private val spo2Handler = android.os.Handler(android.os.Looper.getMainLooper())
    private val spo2Timeout = Runnable {
        android.util.Log.w("AgeCareWatch", "SpO2: sin resultado en 40 s, se cierra el intento")
        stopSpO2()
        listener?.onSpO2Status("Sin lectura, reintentando")
    }
    // Último estado registrado: así el log anota solo los cambios y no cada
    // muestra (antes se escribían cientos de líneas por segundo).
    @Volatile private var lastSpo2Status: Int? = null
    @Volatile var spo2Measuring = false
        private set

    fun setListener(l: Listener?) { listener = l }

    // ----------------------------------------------------------------------
    // Conexión
    // ----------------------------------------------------------------------
    private val connectionListener = object : ConnectionListener {
        override fun onConnectionSuccess() {
            android.util.Log.i("AgeCareWatch", "Samsung Health: conectado")
            connected = true
            val svc = trackingService ?: return
            try {
                val caps = svc.trackingCapability.supportHealthTrackerTypes
                spo2Available = caps.contains(HealthTrackerType.SPO2_ON_DEMAND)
                skinTempAvailable = caps.contains(HealthTrackerType.SKIN_TEMPERATURE_ON_DEMAND)
                android.util.Log.i(
                    "AgeCareWatch",
                    "capacidades: spo2=$spo2Available skinTemp=$skinTempAvailable"
                )
            } catch (e: Exception) {
                android.util.Log.e("AgeCareWatch", "capabilities fail: $e")
            }
            listener?.onConnected(spo2Available, skinTempAvailable)
        }

        override fun onConnectionEnded() {
            android.util.Log.i("AgeCareWatch", "Samsung Health: desconectado")
            connected = false
        }

        override fun onConnectionFailed(e: HealthTrackerException) {
            connected = false
            val reason = when {
                e.errorCode == HealthTrackerException.OLD_PLATFORM_VERSION ->
                    "Actualiza Health Sensor Service"
                e.errorCode == HealthTrackerException.PACKAGE_NOT_INSTALLED ->
                    "Health Sensor Service no instalado"
                else -> "No se pudo conectar al sensor (${e.errorCode})"
            }
            android.util.Log.e("AgeCareWatch", "Samsung Health conexión falló: $reason")
            listener?.onConnectionFailed(reason)
        }
    }

    fun connect() {
        try {
            trackingService = HealthTrackingService(connectionListener, context)
            trackingService?.connectService()
        } catch (e: Exception) {
            android.util.Log.e("AgeCareWatch", "connectService fail: $e")
            listener?.onConnectionFailed("Error iniciando el sensor")
        }
    }

    fun disconnect() {
        stopHeartRate()
        stopSpO2()
        stopSkinTemperature()
        try { trackingService?.disconnectService() } catch (_: Exception) {}
        trackingService = null
        connected = false
    }

    // ----------------------------------------------------------------------
    // Frecuencia cardíaca (continuo)
    // ----------------------------------------------------------------------
    private val hrListener = object : HealthTracker.TrackerEventListener {
        override fun onDataReceived(dataPoints: List<DataPoint>) {
            for (dp in dataPoints) {
                try {
                    val status = dp.getValue(ValueKey.HeartRateSet.HEART_RATE_STATUS)
                    val hr = dp.getValue(ValueKey.HeartRateSet.HEART_RATE)
                    // status 1 = medición válida. Otros = sin contacto / ruido.
                    if (status == 1 && hr != null && hr > 0) {
                        val ibi = try {
                            dp.getValue(ValueKey.HeartRateSet.IBI_LIST) ?: emptyList()
                        } catch (_: Exception) { emptyList<Int>() }
                        listener?.onHeartRate(hr, ibi)
                    }
                } catch (e: Exception) {
                    android.util.Log.e("AgeCareWatch", "HR read fail: $e")
                }
            }
        }
        override fun onFlushCompleted() {}
        override fun onError(error: HealthTracker.TrackerError) {
            handleTrackerError("HR", error)
        }
    }

    fun startHeartRate() {
        val svc = trackingService ?: return
        try {
            hrTracker = svc.getHealthTracker(HealthTrackerType.HEART_RATE_CONTINUOUS)
            hrTracker?.setEventListener(hrListener)
            android.util.Log.i("AgeCareWatch", "HR tracker iniciado (Samsung SDK)")
        } catch (e: Exception) {
            android.util.Log.e("AgeCareWatch", "startHeartRate fail: $e")
            listener?.onMeasurementError("No se pudo iniciar el pulso")
        }
    }

    fun stopHeartRate() {
        try { hrTracker?.unsetEventListener() } catch (_: Exception) {}
        hrTracker = null
    }

    // ----------------------------------------------------------------------
    // SpO2 (on-demand): se inicia, entrega un valor y se detiene solo.
    // ----------------------------------------------------------------------
    private val spo2Listener = object : HealthTracker.TrackerEventListener {
        override fun onDataReceived(dataPoints: List<DataPoint>) {
            for (dp in dataPoints) {
                try {
                    val status = dp.getValue(ValueKey.SpO2Set.STATUS)
                    val value = dp.getValue(ValueKey.SpO2Set.SPO2)
                    // Log solo cuando cambia el estado (diagnóstico sin spam).
                    if (status != lastSpo2Status) {
                        lastSpo2Status = status
                        android.util.Log.i(
                            "AgeCareWatch", "SpO2 estado=$status valor=$value"
                        )
                        listener?.onSpO2Status(spo2StatusText(status))
                    }
                    // Aceptamos el valor en cuanto sea fisiológicamente válido
                    // (70–100%), SIN exigir estrictamente status==COMPLETE: en
                    // el Galaxy Watch 4 el valor final a veces llega con un
                    // código de estado intermedio. El rango lo valida igual el
                    // backend. Si el status es de error explícito (<0), se
                    // ignora esa muestra.
                    if (value != null && value in 70..100 &&
                        (status == null || status >= 0)
                    ) {
                        android.util.Log.i("AgeCareWatch", "SpO2 OK = $value%")
                        listener?.onSpO2(value)
                        listener?.onSpO2Status(null)
                        stopSpO2() // on-demand: una medición válida y paramos.
                        return
                    }
                } catch (e: Exception) {
                    android.util.Log.e("AgeCareWatch", "SpO2 read fail: $e")
                }
            }
        }
        override fun onFlushCompleted() {}
        override fun onError(error: HealthTracker.TrackerError) {
            handleTrackerError("SpO2", error)
            stopSpO2()
        }
    }

    /**
     * Inicia una medición puntual de SpO2. No hace nada si no está soportado.
     *
     * Corrige un bug anterior: cada 60 s se abría una medición nueva sin
     * cerrar la que seguía activa, y se acumulaban varias a la vez (cientos de
     * muestras repetidas y más consumo de batería). Ahora:
     *  - si ya hay una medición en curso, no se abre otra;
     *  - cada intento se cierra solo a los 40 s si no entrega valor.
     */
    fun measureSpO2() {
        if (!spo2Available) return
        if (spo2Measuring) return
        val svc = trackingService ?: return
        try {
            stopSpO2() // por seguridad: nunca dos listeners a la vez.
            lastSpo2Status = null
            spo2Tracker = svc.getHealthTracker(HealthTrackerType.SPO2_ON_DEMAND)
            spo2Tracker?.setEventListener(spo2Listener)
            spo2Measuring = true
            spo2Handler.postDelayed(spo2Timeout, SPO2_TIMEOUT_MS)
            listener?.onSpO2Status("Midiendo, no te muevas")
            android.util.Log.i("AgeCareWatch", "SpO2 medición iniciada")
        } catch (e: Exception) {
            spo2Measuring = false
            android.util.Log.e("AgeCareWatch", "measureSpO2 fail: $e")
        }
    }

    fun stopSpO2() {
        spo2Handler.removeCallbacks(spo2Timeout)
        try { spo2Tracker?.unsetEventListener() } catch (_: Exception) {}
        spo2Tracker = null
        spo2Measuring = false
    }

    /**
     * Texto para la UI según SpO2Set.STATUS. 0/1 = en curso, 2 = completo.
     * Los negativos son lecturas fallidas; no tenemos confirmado el significado
     * exacto de cada uno, así que se muestra un mensaje genérico de señal.
     */
    private fun spo2StatusText(status: Int?): String? = when {
        status == null -> null
        status >= 0 && status < SPO2_STATUS_COMPLETE -> "Midiendo, no te muevas"
        status == SPO2_STATUS_COMPLETE -> null
        else -> "Señal baja: ajusta el reloj"
    }

    // ----------------------------------------------------------------------
    // Temperatura de piel (on-demand)
    // ----------------------------------------------------------------------
    private val skinTempListener = object : HealthTracker.TrackerEventListener {
        override fun onDataReceived(dataPoints: List<DataPoint>) {
            for (dp in dataPoints) {
                try {
                    val status = dp.getValue(ValueKey.SkinTemperatureSet.STATUS)
                    if (status != null && status == SKIN_TEMP_STATUS_SUCCESS) {
                        val temp = dp.getValue(ValueKey.SkinTemperatureSet.OBJECT_TEMPERATURE)
                        if (temp != null && temp > 0f) {
                            listener?.onSkinTemperature(temp)
                        }
                    }
                } catch (e: Exception) {
                    android.util.Log.e("AgeCareWatch", "SkinTemp read fail: $e")
                }
            }
            stopSkinTemperature() // on-demand: una medición y paramos.
        }
        override fun onFlushCompleted() {}
        override fun onError(error: HealthTracker.TrackerError) {
            handleTrackerError("SkinTemp", error)
            stopSkinTemperature()
        }
    }

    /** Inicia una medición puntual de temperatura de piel. */
    fun measureSkinTemperature() {
        if (!skinTempAvailable) return
        val svc = trackingService ?: return
        try {
            skinTempTracker = svc.getHealthTracker(HealthTrackerType.SKIN_TEMPERATURE_ON_DEMAND)
            skinTempTracker?.setEventListener(skinTempListener)
            android.util.Log.i("AgeCareWatch", "SkinTemp medición iniciada")
        } catch (e: Exception) {
            android.util.Log.e("AgeCareWatch", "measureSkinTemperature fail: $e")
        }
    }

    fun stopSkinTemperature() {
        try { skinTempTracker?.unsetEventListener() } catch (_: Exception) {}
        skinTempTracker = null
    }

    // ----------------------------------------------------------------------
    private fun handleTrackerError(which: String, error: HealthTracker.TrackerError) {
        val msg = when (error) {
            HealthTracker.TrackerError.PERMISSION_ERROR -> "Permiso de sensores denegado"
            HealthTracker.TrackerError.SDK_POLICY_ERROR ->
                "Activa el modo desarrollador en el reloj"
            else -> "Error del sensor ($which)"
        }
        android.util.Log.e("AgeCareWatch", "$which error: $msg")
        listener?.onMeasurementError(msg)
    }
}
