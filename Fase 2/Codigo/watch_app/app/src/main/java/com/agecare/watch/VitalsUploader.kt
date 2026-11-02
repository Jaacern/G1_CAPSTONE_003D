package com.agecare.watch

import android.os.Handler
import android.os.Looper
import okhttp3.Call
import okhttp3.Callback
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import org.json.JSONArray
import org.json.JSONObject
import java.io.IOException
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import java.util.concurrent.TimeUnit

/**
 * Cliente de red del reloj AgeCare. Habla con el backend por el subdominio
 * público (Cloudflare Tunnel) y se autentica como DISPOSITIVO, no como persona.
 *
 * MODELO DE VINCULACIÓN (RF-68):
 * - El reloj pertenece a un paciente, no a una cuenta. Se vincula con un código
 *   de 6 dígitos que genera la cuidadora/familiar desde su app:
 *     POST /devices/link { code, device_fingerprint } -> { device_token, patient_id }
 * - A partir de ahí, todas las llamadas usan Authorization: Bearer <device_token>.
 *   El backend deduce el paciente desde el token; el reloj no manda patient_id.
 * - El token se guarda cifrado en DeviceStore y sobrevive reinicios.
 *
 * Envía varios tipos de vital en un solo POST (batch): ritmo cardíaco, SpO2 y
 * temperatura de piel. También reporta caídas como alerta crítica.
 */
class VitalsUploader(private val store: DeviceStore) {

    companion object {
        // Subdominio público del backend (Cloudflare Tunnel). HTTPS siempre.
        private const val BASE_URL = "https://agecare-api.javiercerna.dev"

        // ── Cloudflare Access · Service Token ──
        // El reloj es headless (no puede hacer login SSO), así que atraviesa
        // Cloudflare Access con un service token en cada petición.
        private const val CF_ACCESS_CLIENT_ID = "f63e84e07abcbd5ab6d1a0444330d028.access"
        private const val CF_ACCESS_CLIENT_SECRET = "cfast_y9UQJ2vFqGFBRTc4Fd6cIvd8eHqXkAzI0Ve3HDZx42aae18f"

        // Rangos fisiológicos de validación: fuera de esto, el dato es ruido del
        // sensor (mala colocación del reloj) y NO se envía.
        const val HR_MIN = 30
        const val HR_MAX = 220
        const val SPO2_MIN = 70
        const val SPO2_MAX = 100
        // Temperatura de piel en °C (no corporal): rango amplio y defensivo.
        const val TEMP_MIN = 20.0
        const val TEMP_MAX = 45.0
    }

    /** Un tipo de vital que la app puede subir. 'code' es el que espera el backend. */
    enum class Vital(val code: String) {
        HEART_RATE("heart_rate"),
        SPO2("spo2"),
        TEMPERATURE("temperature"),
    }

    /** Resultado de una operación de red, con detalle para la UI. */
    sealed class Result {
        object Ok : Result()
        data class Error(val reason: String) : Result()
    }

    /** Resultado del emparejamiento por código. */
    sealed class LinkResult {
        data class Ok(val patientName: String?) : LinkResult()
        data class Error(val reason: String) : LinkResult()
    }

    private val client = OkHttpClient.Builder()
        .connectTimeout(10, TimeUnit.SECONDS)
        .readTimeout(15, TimeUnit.SECONDS)
        .build()
    private val json = "application/json".toMediaType()
    private val main = Handler(Looper.getMainLooper())

    private val iso = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US).apply {
        timeZone = TimeZone.getTimeZone("UTC")
    }

    private fun Request.Builder.withAccess(): Request.Builder {
        if (CF_ACCESS_CLIENT_ID.isNotBlank() &&
            !CF_ACCESS_CLIENT_ID.startsWith("PEGA_AQUI") &&
            CF_ACCESS_CLIENT_SECRET.isNotBlank() &&
            !CF_ACCESS_CLIENT_SECRET.startsWith("PEGA_AQUI")
        ) {
            addHeader("CF-Access-Client-Id", CF_ACCESS_CLIENT_ID)
            addHeader("CF-Access-Client-Secret", CF_ACCESS_CLIENT_SECRET)
        }
        return this
    }

    private fun Request.Builder.withDeviceToken(): Request.Builder {
        val t = store.deviceToken
        if (!t.isNullOrBlank()) addHeader("Authorization", "Bearer $t")
        return this
    }

    // ----------------------------------------------------------------------
    // Validación
    // ----------------------------------------------------------------------
    fun isValid(vital: Vital, value: Double): Boolean = when (vital) {
        Vital.HEART_RATE -> value >= HR_MIN && value <= HR_MAX
        Vital.SPO2 -> value >= SPO2_MIN && value <= SPO2_MAX
        Vital.TEMPERATURE -> value in TEMP_MIN..TEMP_MAX
    }

    // ----------------------------------------------------------------------
    // 1) Vinculación por código (emparejamiento)
    // ----------------------------------------------------------------------
    /**
     * Canjea un código de 6 dígitos por un token de dispositivo. Al tener éxito,
     * guarda token + paciente en el DeviceStore.
     */
    fun linkWithCode(code: String, onResult: (LinkResult) -> Unit) {
        val body = JSONObject()
            .put("code", code)
            .put("device_fingerprint", store.deviceFingerprint)
            .put("device_label", "Reloj AgeCare")
            .put("platform", "android")
            .put("app_version", "0.2")
            .toString().toRequestBody(json)

        val req = Request.Builder()
            .url("$BASE_URL/api/v1/devices/link")
            .withAccess()
            .post(body)
            .build()

        android.util.Log.i("AgeCareWatch", "link -> $BASE_URL (code ****)")
        client.newCall(req).enqueue(object : Callback {
            override fun onFailure(call: Call, e: IOException) {
                android.util.Log.e("AgeCareWatch", "link FAIL: $e")
                replyLink(onResult, LinkResult.Error("Sin conexión al servidor"))
            }
            override fun onResponse(call: Call, response: Response) {
                response.use {
                    val s = it.body?.string()
                    android.util.Log.i("AgeCareWatch", "link resp code=${it.code}")
                    if (it.isSuccessful && s != null) {
                        try {
                            val obj = JSONObject(s)
                            val token = obj.optString("device_token").ifBlank { null }
                            val pid = obj.optString("patient_id").ifBlank { null }
                            val pname = obj.optString("patient_name").ifBlank { null }
                            if (token != null && pid != null) {
                                store.saveLink(token, pid, pname)
                                replyLink(onResult, LinkResult.Ok(pname))
                            } else {
                                replyLink(onResult, LinkResult.Error("Respuesta inválida del servidor"))
                            }
                        } catch (e: Exception) {
                            replyLink(onResult, LinkResult.Error("Respuesta inválida del servidor"))
                        }
                    } else {
                        val reason = when (it.code) {
                            400 -> "Código inválido o expirado"
                            429 -> "Código bloqueado. Pide uno nuevo"
                            else -> "Error del servidor (${it.code})"
                        }
                        replyLink(onResult, LinkResult.Error(reason))
                    }
                }
            }
        })
    }

    // ----------------------------------------------------------------------
    // 2) Envío de mediciones (batch)
    // ----------------------------------------------------------------------
    /**
     * Envía un lote de lecturas (uno o varios tipos) en un solo POST.
     * Las lecturas inválidas se descartan. Si el reloj no está vinculado,
     * responde Error sin llamar.
     */
    fun sendReadings(
        readings: Map<Vital, Double>,
        batteryPct: Int? = null,
        onResult: (Result) -> Unit,
    ) {
        if (!store.isLinked) {
            reply(onResult, Result.Error("Reloj no vinculado"))
            return
        }

        val now = iso.format(Date())
        val arr = JSONArray()
        for ((vital, value) in readings) {
            if (!isValid(vital, value)) {
                android.util.Log.w("AgeCareWatch", "descartado ${vital.code}=$value (fuera de rango)")
                continue
            }
            // Temperatura va con decimales; HR y SpO2 como enteros.
            val outValue: Any = if (vital == Vital.TEMPERATURE) value else value.toInt()
            arr.put(
                JSONObject()
                    .put("type", vital.code)
                    .put("value", outValue)
                    .put("measured_at", now)
                    .put("meta", JSONObject().put("origin", "watch"))
            )
        }
        if (arr.length() == 0) {
            reply(onResult, Result.Error("Sin datos válidos"))
            return
        }
        postBatch(arr, batteryPct, onResult)
    }

    private fun postBatch(readings: JSONArray, batteryPct: Int?, onResult: (Result) -> Unit) {
        val body = JSONObject().put("readings", readings)
        if (batteryPct != null && batteryPct in 0..100) {
            body.put("battery_pct", batteryPct)
        }
        val payload = body.toString().toRequestBody(json)
        val req = Request.Builder()
            .url("$BASE_URL/api/v1/devices/vitals/batch")
            .withAccess()
            .withDeviceToken()
            .post(payload)
            .build()
        client.newCall(req).enqueue(object : Callback {
            override fun onFailure(call: Call, e: IOException) {
                android.util.Log.e("AgeCareWatch", "batch FAIL: $e")
                reply(onResult, Result.Error("Sin conexión al servidor"))
            }
            override fun onResponse(call: Call, response: Response) {
                response.use {
                    android.util.Log.i("AgeCareWatch", "batch resp code=${it.code}")
                    when {
                        it.isSuccessful -> reply(onResult, Result.Ok)
                        it.code == 401 || it.code == 403 -> {
                            // El servidor ya no reconoce este dispositivo: fue
                            // desvinculado desde la app del familiar. Borramos
                            // el emparejamiento local para que el reloj vuelva
                            // a la pantalla de código y ambos lados queden
                            // sincronizados.
                            android.util.Log.w("AgeCareWatch", "401/403: desvinculado por el servidor, limpiando token")
                            store.clear()
                            reply(onResult, Result.Error("Reloj desvinculado"))
                        }
                        else -> reply(onResult, Result.Error("Error del servidor (${it.code})"))
                    }
                }
            }
        })
    }

    // ----------------------------------------------------------------------
    // 3) Reporte de caída (alerta crítica)
    // ----------------------------------------------------------------------
    /**
     * Reporta una caída detectada al backend, que crea una alerta crítica
     * type='fall' para el paciente del reloj.
     *
     * [impactG] es la magnitud del impacto detectado (en g), para trazabilidad.
     */
    fun sendFall(impactG: Float, onResult: (Result) -> Unit) {
        if (!store.isLinked) {
            reply(onResult, Result.Error("Reloj no vinculado"))
            return
        }
        val payload = JSONObject()
            .put("detail", "El reloj detectó una posible caída del paciente.")
            .put(
                "payload",
                JSONObject()
                    .put("impact_g", impactG.toDouble())
                    .put("detected_at", iso.format(Date()))
                    .put("origin", "watch")
            )
            .toString().toRequestBody(json)

        val req = Request.Builder()
            .url("$BASE_URL/api/v1/devices/fall")
            .withAccess()
            .withDeviceToken()
            .post(payload)
            .build()

        android.util.Log.w("AgeCareWatch", "FALL -> enviando alerta (impact=${impactG}g)")
        client.newCall(req).enqueue(object : Callback {
            override fun onFailure(call: Call, e: IOException) {
                android.util.Log.e("AgeCareWatch", "fall FAIL: $e")
                reply(onResult, Result.Error("Sin conexión al servidor"))
            }
            override fun onResponse(call: Call, response: Response) {
                response.use {
                    android.util.Log.w("AgeCareWatch", "fall resp code=${it.code}")
                    if (it.isSuccessful) reply(onResult, Result.Ok)
                    else reply(onResult, Result.Error("Error del servidor (${it.code})"))
                }
            }
        })
    }

    /**
     * Desvincula este reloj EN EL SERVIDOR (el usuario eligió "Desvincular" en
     * el reloj). Llama POST /devices/unlink con el device_token actual, luego
     * borra el token local. Así el cambio se refleja también en la app del
     * familiar. Se ejecuta aunque la red falle (igual se limpia local): lo
     * importante para el usuario es que el reloj quede libre.
     */
    fun unlinkOnServer(onDone: () -> Unit) {
        val t = store.deviceToken
        if (t.isNullOrBlank()) {
            store.clear()
            reply({ onDone() }, Result.Ok)
            return
        }
        val req = Request.Builder()
            .url("$BASE_URL/api/v1/devices/unlink")
            .withAccess()
            .withDeviceToken()
            .post("{}".toRequestBody(json))
            .build()
        client.newCall(req).enqueue(object : Callback {
            override fun onFailure(call: Call, e: IOException) {
                android.util.Log.w("AgeCareWatch", "unlink server FAIL (se limpia local igual): $e")
                store.clear()
                main.post { onDone() }
            }
            override fun onResponse(call: Call, response: Response) {
                response.use {
                    android.util.Log.i("AgeCareWatch", "unlink server resp=${it.code}")
                }
                store.clear()
                main.post { onDone() }
            }
        })
    }

    private fun reply(cb: (Result) -> Unit, r: Result) {
        main.post { cb(r) }
    }

    private fun replyLink(cb: (LinkResult) -> Unit, r: LinkResult) {
        main.post { cb(r) }
    }
}
