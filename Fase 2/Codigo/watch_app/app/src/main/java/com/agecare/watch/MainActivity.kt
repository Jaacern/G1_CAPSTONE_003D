package com.agecare.watch

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.ContextCompat
import androidx.wear.compose.material.MaterialTheme
import androidx.wear.compose.material.Text

/**
 * Pantalla de AgeCare Watch. Al abrir, pide permisos y arranca el
 * [HeartRateService] (foreground), que sigue midiendo y enviando AUNQUE la
 * pantalla se apague. La UI solo refleja el estado del servicio.
 */
class MainActivity : ComponentActivity() {

    private var bpm by mutableIntStateOf(0)
    private var sent by mutableIntStateOf(0)
    private var online by mutableStateOf(false)
    private var status by mutableStateOf("Iniciando…")

    private val ui = Handler(Looper.getMainLooper())
    private val tick = object : Runnable {
        override fun run() {
            bpm = HeartRateService.lastBpm
            sent = HeartRateService.lastSent
            online = HeartRateService.online
            status = when {
                !HeartRateService.running -> "Iniciando…"
                bpm <= 0 -> "Ajusta el reloj en la muñeca"
                online -> "Enviando a AgeCare ✓"
                else -> "Sin conexión al servidor"
            }
            ui.postDelayed(this, 1000)
        }
    }

    private val permsLauncher =
        registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
            startService()
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            MaterialTheme { WatchScreen(bpm, status, sent, online) }
        }
        ensurePermsAndStart()
    }

    private fun ensurePermsAndStart() {
        val needed = mutableListOf(
            Manifest.permission.BODY_SENSORS,
            Manifest.permission.ACTIVITY_RECOGNITION, // Health Services passive HR
        )
        if (Build.VERSION.SDK_INT >= 33) {
            needed.add(Manifest.permission.POST_NOTIFICATIONS)
        }
        val missing = needed.filter {
            ContextCompat.checkSelfPermission(this, it) != PackageManager.PERMISSION_GRANTED
        }
        if (missing.isEmpty()) startService()
        else permsLauncher.launch(missing.toTypedArray())
    }

    private fun startService() {
        val intent = Intent(this, HeartRateService::class.java)
        ContextCompat.startForegroundService(this, intent)
    }

    override fun onResume() {
        super.onResume()
        ui.post(tick)
    }

    override fun onPause() {
        super.onPause()
        ui.removeCallbacks(tick)
        // OJO: NO detenemos el servicio aquí. Sigue midiendo con la pantalla apagada.
    }
}

@androidx.compose.runtime.Composable
private fun WatchScreen(bpm: Int, status: String, sent: Int, online: Boolean) {
    Column(
        modifier = Modifier.fillMaxSize().padding(horizontal = 20.dp, vertical = 10.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Text("❤\uFE0F AgeCare", fontSize = 13.sp, fontWeight = FontWeight.Bold)
        Text(
            if (bpm > 0) "$bpm" else "--",
            fontSize = 52.sp,
            fontWeight = FontWeight.Bold,
            color = MaterialTheme.colors.primary,
        )
        Text("lpm", fontSize = 13.sp)
        Text(
            status,
            fontSize = 11.sp,
            textAlign = TextAlign.Center,
            color = if (status.startsWith("Sin conexión")) Color(0xFFE04B43) else Color(0xFFBFC7D2),
            modifier = Modifier.padding(top = 6.dp),
        )
        if (sent > 0) {
            Text(
                "${if (online) "🟢" else "🔴"} $sent enviadas",
                fontSize = 10.sp,
                color = Color(0xFF8A97A6),
                modifier = Modifier.padding(top = 2.dp),
            )
        }
    }
}
