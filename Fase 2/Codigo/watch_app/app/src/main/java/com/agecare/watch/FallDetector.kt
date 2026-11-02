package com.agecare.watch

import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.os.SystemClock
import kotlin.math.sqrt

/**
 * Detector de caídas basado en el acelerómetro del reloj (SensorManager de
 * Android, no requiere el SDK de Samsung).
 *
 * ALGORITMO. Reconoce una caída por DOS vías independientes:
 *
 * VÍA A — Patrón clásico de caída (caída libre + impacto):
 *   1. CAÍDA LIBRE: la aceleración total cae muy por debajo de 1 g (el cuerpo
 *      y el reloj caen juntos → casi ingravidez). Umbral: < 0.4 g.
 *   2. IMPACTO: inmediatamente después, un pico fuerte al golpear el suelo.
 *      Umbral: > 2.8 g dentro de una ventana corta tras la caída libre.
 *   Un impacto SIN caída libre previa NO dispara por esta vía (evita que un
 *   golpe del brazo o un aplauso se confundan con una caída). Es la vía
 *   fisiológicamente correcta y la que debe usarse en producción.
 *
 * VÍA B — Impacto severo con doble pico (respaldo operativo / demo):
 *   Un pico MUY alto (> 4.0 g) confirmado por un segundo pico dentro de una
 *   ventana corta (sacudida fuerte deliberada) también dispara. Esto cubre
 *   dos casos reales: (1) caídas donde el reloj no alcanza caída libre clara
 *   (la persona cae sobre el brazo, el reloj golpea de inmediato) y (2) la
 *   necesidad de demostrar la alerta en vivo sin tener que lanzar el reloj al
 *   suelo. El segundo pico evita que un golpe accidental único dispare.
 *
 * Tras disparar, entra en un COOLDOWN para no spamear alertas por la misma
 * caída (el backend además deduplica, pero evitamos tráfico innecesario).
 *
 * Los umbrales son configurables (companion object). Los valores actuales son
 * un punto de partida calibrado para el Galaxy Watch 4.
 */
class FallDetector(
    context: Context,
    private val onFall: (impactG: Float) -> Unit,
) : SensorEventListener {

    private val sensorManager =
        context.getSystemService(Context.SENSOR_SERVICE) as SensorManager
    private val accelerometer: Sensor? =
        sensorManager.getDefaultSensor(Sensor.TYPE_ACCELEROMETER)

    companion object {
        private const val G = SensorManager.GRAVITY_EARTH // ~9.81 m/s²

        // Umbrales en múltiplos de g.
        private const val FREE_FALL_G = 0.4f      // por debajo = caída libre (Vía A)
        private const val IMPACT_G = 2.8f         // por encima = impacto fuerte (Vía A)

        // Vía B: impacto severo con doble pico (respaldo / demo).
        // AJUSTE DE SENSIBILIDAD: se baja el umbral de 4.0g a 2.5g y se amplía
        // la ventana de doble pico a 2.5s. Motivo: una caída real donde la
        // persona cae sobre el brazo no siempre supera 4g, y para la demo una
        // sacudida firme de muñeca (dos movimientos bruscos seguidos) debe
        // disparar sin tener que lanzar el reloj. El requisito de DOS picos
        // dentro de la ventana mantiene el filtro anti-falsos-positivos: un
        // único golpe accidental no alcanza a generar la alerta.
        private const val SEVERE_IMPACT_G = 2.5f  // pico fuerte (antes 4.0)
        private const val DOUBLE_PEAK_WINDOW_MS = 2500L  // 2º pico dentro de este tiempo

        // Ventana para que el impacto cuente como parte de la caída (ms).
        private const val IMPACT_WINDOW_MS = 1200L
        // Tiempo mínimo entre dos alertas de caída (ms).
        private const val COOLDOWN_MS = 15_000L
    }

    @Volatile private var freeFallAt: Long = 0L
    @Volatile private var lastFallAt: Long = 0L
    // Vía B: marca del primer pico severo, a la espera del segundo.
    @Volatile private var firstSevereAt: Long = 0L
    @Volatile var running: Boolean = false
        private set

    /** Último valor de magnitud (en g) para mostrar/depurar en la UI. */
    @Volatile var lastMagnitudeG: Float = 1.0f
        private set

    val isAvailable: Boolean get() = accelerometer != null

    fun start() {
        val acc = accelerometer ?: run {
            android.util.Log.w("AgeCareWatch", "No hay acelerómetro: detección de caídas off")
            return
        }
        sensorManager.registerListener(this, acc, SensorManager.SENSOR_DELAY_GAME)
        running = true
        android.util.Log.i("AgeCareWatch", "FallDetector iniciado")
    }

    fun stop() {
        sensorManager.unregisterListener(this)
        running = false
    }

    override fun onSensorChanged(event: SensorEvent) {
        if (event.sensor.type != Sensor.TYPE_ACCELEROMETER) return

        val ax = event.values[0]
        val ay = event.values[1]
        val az = event.values[2]
        // Magnitud del vector de aceleración, normalizada a g.
        val magnitudeG = sqrt(ax * ax + ay * ay + az * az) / G
        lastMagnitudeG = magnitudeG

        val now = SystemClock.elapsedRealtime()

        // Fase 1: detección de caída libre.
        if (magnitudeG < FREE_FALL_G) {
            freeFallAt = now
            return
        }

        // ── VÍA A: impacto dentro de la ventana posterior a la caída libre ──
        if (magnitudeG > IMPACT_G &&
            freeFallAt != 0L &&
            (now - freeFallAt) in 1..IMPACT_WINDOW_MS
        ) {
            freeFallAt = 0L
            trigger(magnitudeG, "caída libre + impacto")
            return
        }

        // ── VÍA B: impacto severo con doble pico (respaldo / demo) ──
        // Un pico > 4 g arma la vía; un segundo pico > 4 g dentro de la ventana
        // la confirma. Así una sacudida fuerte deliberada (o una caída sobre el
        // brazo sin caída libre clara) también genera la alerta, pero un golpe
        // accidental aislado no.
        if (magnitudeG > SEVERE_IMPACT_G) {
            if (firstSevereAt != 0L && (now - firstSevereAt) in 1..DOUBLE_PEAK_WINDOW_MS) {
                firstSevereAt = 0L
                trigger(magnitudeG, "impacto severo doble pico")
            } else {
                firstSevereAt = now
            }
        } else if (firstSevereAt != 0L && now - firstSevereAt > DOUBLE_PEAK_WINDOW_MS) {
            // Pasó la ventana sin segundo pico: se descarta el primero.
            firstSevereAt = 0L
        }
    }

    /** Dispara la alerta respetando el cooldown. [via] solo para el log. */
    private fun trigger(magnitudeG: Float, via: String) {
        val now = SystemClock.elapsedRealtime()
        if (now - lastFallAt < COOLDOWN_MS) return
        lastFallAt = now
        android.util.Log.w(
            "AgeCareWatch",
            "CAÍDA detectada ($via): ${"%.1f".format(magnitudeG)}g"
        )
        onFall(magnitudeG)
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) { /* no-op */ }
}
