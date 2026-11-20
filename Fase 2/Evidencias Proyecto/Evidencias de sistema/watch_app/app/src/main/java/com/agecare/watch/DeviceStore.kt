package com.agecare.watch

import android.content.Context
import android.content.SharedPreferences
import android.provider.Settings
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey

/**
 * Guarda de forma persistente y cifrada el emparejamiento del reloj con un
 * paciente: el token de dispositivo (session token) y el patient_id/nombre.
 *
 * MODELO (RF-68): el reloj NO inicia sesión como una persona. Se vincula a un
 * paciente con un código de un solo uso y, a cambio, el backend le entrega un
 * device_token. Ese token es la credencial del aparato y se guarda aquí
 * cifrado con la Keystore del sistema (EncryptedSharedPreferences). Si falla
 * el cifrado en algún dispositivo, cae a SharedPreferences normales para no
 * dejar la app inutilizable en la demo.
 *
 * El device_fingerprint identifica físicamente este reloj ante el backend
 * (permite re-emparejar el mismo aparato sin chocar con el UNIQUE del server).
 */
class DeviceStore(context: Context) {

    private val appContext = context.applicationContext

    private val prefs: SharedPreferences = try {
        val masterKey = MasterKey.Builder(appContext)
            .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
            .build()
        EncryptedSharedPreferences.create(
            appContext,
            "agecare_device_secure",
            masterKey,
            EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
            EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
        )
    } catch (e: Exception) {
        android.util.Log.w("AgeCareWatch", "EncryptedSharedPreferences no disponible, fallback: $e")
        appContext.getSharedPreferences("agecare_device", Context.MODE_PRIVATE)
    }

    /** Token de sesión del dispositivo, o null si aún no está vinculado. */
    var deviceToken: String?
        get() = prefs.getString(KEY_TOKEN, null)
        set(value) { prefs.edit().putString(KEY_TOKEN, value).apply() }

    /** Paciente al que está vinculado este reloj. */
    var patientId: String?
        get() = prefs.getString(KEY_PATIENT_ID, null)
        set(value) { prefs.edit().putString(KEY_PATIENT_ID, value).apply() }

    var patientName: String?
        get() = prefs.getString(KEY_PATIENT_NAME, null)
        set(value) { prefs.edit().putString(KEY_PATIENT_NAME, value).apply() }

    /** true si el reloj ya fue vinculado a un paciente. */
    val isLinked: Boolean
        get() = !deviceToken.isNullOrBlank() && !patientId.isNullOrBlank()

    /**
     * Huella estable de este reloj. Usa ANDROID_ID, que persiste entre
     * reinicios de la app pero no identifica a la persona.
     */
    val deviceFingerprint: String
        get() {
            @Suppress("HardwareIds")
            val androidId = Settings.Secure.getString(
                appContext.contentResolver, Settings.Secure.ANDROID_ID
            )
            return if (!androidId.isNullOrBlank()) "watch-$androidId" else "watch-unknown"
        }

    /** Guarda el resultado de un emparejamiento exitoso. */
    fun saveLink(token: String, patientId: String, patientName: String?) {
        prefs.edit()
            .putString(KEY_TOKEN, token)
            .putString(KEY_PATIENT_ID, patientId)
            .putString(KEY_PATIENT_NAME, patientName)
            .apply()
    }

    /** Borra el emparejamiento (desvincular / reintentar). */
    fun clear() {
        prefs.edit()
            .remove(KEY_TOKEN)
            .remove(KEY_PATIENT_ID)
            .remove(KEY_PATIENT_NAME)
            .apply()
    }

    companion object {
        private const val KEY_TOKEN = "device_token"
        private const val KEY_PATIENT_ID = "patient_id"
        private const val KEY_PATIENT_NAME = "patient_name"
    }
}
