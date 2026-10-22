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

/**
 * Sube lecturas de ritmo cardíaco al backend de AgeCare (POST /vitals/batch),
 * directo por WiFi desde el reloj. No pasa por Samsung Health ni Health Connect.
 *
 * CONFIGURACIÓN IMPORTANTE:
 * - El reloj NO puede usar "localhost" (eso es del PC/teléfono con adb reverse).
 *   Debe apuntar a la IP del PC que ejecuta el backend en la red local.
 * - El paciente y las credenciales son los del seed de desarrollo.
 * Ajusta [BASE_URL] a la IP local de tu backend (ver `ip addr`).
 */
class VitalsUploader {

    companion object {
        // IP del PC que corre el backend en la red local + puerto.
        // Reemplaza TU_IP_LOCAL por la IP de tu máquina (p. ej. 192.168.x.x).
        private const val BASE_URL = "http://TU_IP_LOCAL:8000"
        // Credenciales del seed de desarrollo (datos ficticios, no reales).
        private const val EMAIL = "elena@agecare.cl"      // cuenta elder del seed
        private const val PASSWORD = "demo1234"
        private const val PATIENT_ID = "33333333-3333-4333-8333-333333333333"
    }

    private val client = OkHttpClient()
    private val json = "application/json".toMediaType()
    private val main = Handler(Looper.getMainLooper())

    @Volatile private var token: String? = null
    @Volatile private var loggingIn = false

    // Con milisegundos: el backend deduplica por (paciente, tipo, measured_at,
    // fuente) con precisión de segundo. Sin ms, varias lecturas del mismo
    // segundo se descartarían como duplicadas. Con ms, cada lectura es única.
    private val iso = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US).apply {
        timeZone = TimeZone.getTimeZone("UTC")
    }

    /** Envía una lectura de ritmo; hace login automático si no hay token. */
    fun sendHeartRate(bpm: Int, onResult: (Boolean) -> Unit) {
        val t = token
        if (t == null) {
            login { ok -> if (ok) postHeartRate(bpm, onResult) else reply(onResult, false) }
        } else {
            postHeartRate(bpm, onResult)
        }
    }

    private fun login(cb: (Boolean) -> Unit) {
        if (loggingIn) { cb(false); return }
        loggingIn = true
        val body = JSONObject()
            .put("email", EMAIL)
            .put("password", PASSWORD)
            .toString().toRequestBody(json)
        val req = Request.Builder()
            .url("$BASE_URL/api/v1/auth/login")
            .post(body)
            .build()
        android.util.Log.i("AgeCareWatch", "login -> $BASE_URL")
        client.newCall(req).enqueue(object : Callback {
            override fun onFailure(call: Call, e: IOException) {
                loggingIn = false
                android.util.Log.e("AgeCareWatch", "login FAIL: $e")
                cb(false)
            }
            override fun onResponse(call: Call, response: Response) {
                loggingIn = false
                response.use {
                    val s = it.body?.string()
                    android.util.Log.i("AgeCareWatch", "login resp code=${it.code}")
                    if (it.isSuccessful && s != null) {
                        token = JSONObject(s).optString("access_token").ifBlank { null }
                        cb(token != null)
                    } else cb(false)
                }
            }
        })
    }

    private fun postHeartRate(bpm: Int, onResult: (Boolean) -> Unit) {
        val reading = JSONObject()
            .put("type", "heart_rate")
            .put("value", bpm)
            .put("measured_at", iso.format(Date()))
            .put("meta", JSONObject().put("origin", "watch"))
        val payload = JSONObject().put("readings", JSONArray().put(reading))
            .toString().toRequestBody(json)
        val req = Request.Builder()
            .url("$BASE_URL/api/v1/patients/$PATIENT_ID/vitals/batch")
            .addHeader("Authorization", "Bearer ${token ?: ""}")
            .post(payload)
            .build()
        client.newCall(req).enqueue(object : Callback {
            override fun onFailure(call: Call, e: IOException) {
                android.util.Log.e("AgeCareWatch", "batch FAIL: $e")
                reply(onResult, false)
            }
            override fun onResponse(call: Call, response: Response) {
                response.use {
                    android.util.Log.i("AgeCareWatch", "batch resp code=${it.code}")
                    if (it.code == 401) { token = null } // forzar re-login la próxima
                    reply(onResult, it.isSuccessful)
                }
            }
        })
    }

    private fun reply(cb: (Boolean) -> Unit, ok: Boolean) {
        main.post { cb(ok) }
    }
}
