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
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.ContextCompat
import androidx.wear.compose.material.MaterialTheme
import androidx.wear.compose.material.Text

/**
 * Pantalla principal del reloj AgeCare. Tiene dos modos:
 *
 *  1) NO VINCULADO: muestra un teclado numérico para escribir el código de 6
 *     dígitos que la cuidadora/familiar generó en su app. Al vincular, guarda
 *     el token de dispositivo y arranca el monitoreo.
 *
 *  2) VINCULADO: arranca el HeartRateService (foreground) y muestra en vivo
 *     la frecuencia cardíaca, SpO2, temperatura y el estado de envío + caídas.
 */
class MainActivity : ComponentActivity() {

    private lateinit var store: DeviceStore
    private lateinit var uploader: VitalsUploader

    // Estado de emparejamiento.
    private var linked by mutableStateOf(false)
    private var codeInput by mutableStateOf("")
    private var linking by mutableStateOf(false)
    private var linkMessage by mutableStateOf<String?>(null)
    private var patientName by mutableStateOf<String?>(null)

    // Estado de medición.
    private var bpm by mutableIntStateOf(0)
    private var spo2 by mutableIntStateOf(0)
    private var spo2Status by mutableStateOf<String?>(null)
    private var temp by mutableStateOf(0f)
    private var sent by mutableIntStateOf(0)
    private var online by mutableStateOf(false)
    private var spo2Supported by mutableStateOf(false)
    private var tempSupported by mutableStateOf(false)
    private var fallArmed by mutableStateOf(false)
    private var status by mutableStateOf("Iniciando…")

    private val ui = Handler(Looper.getMainLooper())
    private val tick = object : Runnable {
        override fun run() {
            // Si el servidor desvinculó el reloj (desde la app del familiar),
            // el uploader borró el token local: isLinked pasa a false. Volvemos
            // a la pantalla de código para que ambos lados queden sincronizados.
            if (linked && !store.isLinked) {
                onUnlinkedByServer()
                return
            }
            bpm = HeartRateService.lastBpm
            spo2 = HeartRateService.lastSpo2
            spo2Status = HeartRateService.spo2Status
            temp = HeartRateService.lastTemp
            sent = HeartRateService.lastSent
            online = HeartRateService.online
            spo2Supported = HeartRateService.spo2Supported
            tempSupported = HeartRateService.tempSupported
            fallArmed = HeartRateService.fallArmed
            status = when {
                !HeartRateService.running -> "Iniciando…"
                HeartRateService.sensorError != null -> HeartRateService.sensorError!!
                bpm <= 0 -> "Ajusta el reloj en la muñeca"
                online -> "Enviando a AgeCare ✓"
                HeartRateService.lastError != null -> HeartRateService.lastError!!
                else -> "Conectando…"
            }
            ui.postDelayed(this, 1000)
        }
    }

    /** El servidor desvinculó el reloj: detener servicio y volver al código. */
    private fun onUnlinkedByServer() {
        ui.removeCallbacks(tick)
        try { stopService(Intent(this, HeartRateService::class.java)) } catch (_: Exception) {}
        patientName = null
        codeInput = ""
        linkMessage = "El reloj fue desvinculado"
        linked = false
    }

    private val permsLauncher =
        registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
            startMonitoring()
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        store = DeviceStore(this)
        uploader = VitalsUploader(store)
        linked = store.isLinked
        patientName = store.patientName

        setContent {
            MaterialTheme {
                if (linked) {
                    MonitorScreen(
                        patientName, bpm, spo2, temp, status, sent, online,
                        spo2Supported, tempSupported, fallArmed,
                        spo2Status = spo2Status,
                        onUnlink = { unlinkDevice() },
                    )
                } else {
                    PairingScreen(
                        code = codeInput,
                        linking = linking,
                        message = linkMessage,
                        onDigit = { d -> if (codeInput.length < 6) codeInput += d },
                        onDelete = { if (codeInput.isNotEmpty()) codeInput = codeInput.dropLast(1) },
                        onSubmit = { submitCode() },
                    )
                }
            }
        }

        if (linked) ensurePermsAndStart()
    }

    // ----------------------------------------------------------------------
    // Emparejamiento
    // ----------------------------------------------------------------------
    private fun submitCode() {
        if (codeInput.length != 6 || linking) return
        linking = true
        linkMessage = "Vinculando…"
        uploader.linkWithCode(codeInput) { result ->
            linking = false
            when (result) {
                is VitalsUploader.LinkResult.Ok -> {
                    patientName = result.patientName ?: store.patientName
                    linkMessage = null
                    linked = true
                    ensurePermsAndStart()
                }
                is VitalsUploader.LinkResult.Error -> {
                    linkMessage = result.reason
                    codeInput = ""
                }
            }
        }
    }

    // ----------------------------------------------------------------------
    // Monitoreo
    // ----------------------------------------------------------------------
    private fun ensurePermsAndStart() {
        val needed = mutableListOf(
            Manifest.permission.BODY_SENSORS,
            Manifest.permission.ACTIVITY_RECOGNITION,
        )
        if (Build.VERSION.SDK_INT >= 33) {
            needed.add(Manifest.permission.POST_NOTIFICATIONS)
        }
        val missing = needed.filter {
            ContextCompat.checkSelfPermission(this, it) != PackageManager.PERMISSION_GRANTED
        }
        if (missing.isEmpty()) startMonitoring()
        else permsLauncher.launch(missing.toTypedArray())
    }

    private fun startMonitoring() {
        val intent = Intent(this, HeartRateService::class.java)
        ContextCompat.startForegroundService(this, intent)
    }

    /**
     * Olvida el emparejamiento en este reloj: detiene el servicio, avisa al
     * servidor (para que el cambio se refleje en la app del familiar), borra el
     * token local y vuelve a la pantalla de código. Útil para reasignar el
     * reloj a otro paciente.
     */
    private fun unlinkDevice() {
        ui.removeCallbacks(tick)
        try {
            stopService(Intent(this, HeartRateService::class.java))
        } catch (_: Exception) {}
        // Avisa al backend con el token actual y LUEGO limpia local. Si la red
        // falla, igual se limpia local (unlinkOnServer lo garantiza).
        uploader.unlinkOnServer {
            patientName = null
            codeInput = ""
            linkMessage = null
            linked = false
        }
    }

    override fun onResume() {
        super.onResume()
        if (linked) ui.post(tick)
    }

    override fun onPause() {
        super.onPause()
        ui.removeCallbacks(tick)
        // NO detenemos el servicio: sigue midiendo con la pantalla apagada.
    }
}

// Paleta de marca AgeCare, tema claro. Los tonos de estado son algo más
// oscuros que los de la app del celular para que el texto se lea sobre blanco.
private val AgeBlue = Color(0xFF2E6BE6)
private val AgeGreen = Color(0xFF1E9E48)
private val AgeRed = Color(0xFFD13A32)
private val AgeAmber = Color(0xFFB86E00)
private val AgeDim = Color(0xFF5B6878)
private val AgeBg = Color(0xFFF5F8FC)
private val AgeText = Color(0xFF16202B)

// --------------------------------------------------------------------------
// Pantalla de emparejamiento (teclado numérico)
// --------------------------------------------------------------------------
@androidx.compose.runtime.Composable
private fun PairingScreen(
    code: String,
    linking: Boolean,
    message: String?,
    onDigit: (String) -> Unit,
    onDelete: () -> Unit,
    onSubmit: () -> Unit,
) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(AgeBg)
            .padding(horizontal = 10.dp, vertical = 6.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Text("⌚ AgeCare", fontSize = 13.sp, fontWeight = FontWeight.Bold, color = AgeBlue)
        Text("Escribe el código del celular", fontSize = 9.sp, color = AgeDim)
        Spacer(Modifier.height(6.dp))

        // Código: muestra los dígitos ya escritos y guiones para los que faltan.
        val shown = buildString {
            for (i in 0 until 6) {
                append(if (i < code.length) code[i] else '–')
                if (i < 5) append(' ')
            }
        }
        Text(
            shown,
            fontSize = 20.sp,
            fontWeight = FontWeight.Bold,
            color = if (code.length == 6) AgeGreen else AgeText,
        )
        Spacer(Modifier.height(6.dp))

        if (message != null) {
            Text(
                message,
                fontSize = 10.sp,
                textAlign = TextAlign.Center,
                color = if (linking) AgeDim else AgeRed,
            )
            Spacer(Modifier.height(4.dp))
        }

        if (!linking) {
            // Teclado 1-9 en 3 filas + fila (borrar, 0, OK).
            val rows = listOf(listOf("1", "2", "3"), listOf("4", "5", "6"), listOf("7", "8", "9"))
            for (row in rows) {
                Row(horizontalArrangement = Arrangement.Center) {
                    for (d in row) KeyButton(d) { onDigit(d) }
                }
            }
            Row(horizontalArrangement = Arrangement.Center, verticalAlignment = Alignment.CenterVertically) {
                KeyButton("⌫", AgeDim) { onDelete() }
                KeyButton("0") { onDigit("0") }
                KeyButton("✓", if (code.length == 6) AgeGreen else AgeDim) {
                    if (code.length == 6) onSubmit()
                }
            }
        }
    }
}

@androidx.compose.runtime.Composable
private fun KeyButton(label: String, color: Color = AgeBlue, onClick: () -> Unit) {
    Box(
        modifier = Modifier
            .padding(2.dp)
            .size(30.dp)
            .clip(CircleShape)
            .background(color.copy(alpha = 0.18f))
            .clickable { onClick() },
        contentAlignment = Alignment.Center,
    ) {
        Text(label, fontSize = 15.sp, fontWeight = FontWeight.Bold, color = color)
    }
}

// --------------------------------------------------------------------------
// Pantalla de monitoreo
// --------------------------------------------------------------------------
@OptIn(ExperimentalFoundationApi::class)
@androidx.compose.runtime.Composable
private fun MonitorScreen(
    patientName: String?,
    bpm: Int,
    spo2: Int,
    temp: Float,
    status: String,
    sent: Int,
    online: Boolean,
    spo2Supported: Boolean,
    tempSupported: Boolean,
    fallArmed: Boolean,
    spo2Status: String? = null,
    onUnlink: () -> Unit,
) {
    var confirmUnlink by androidx.compose.runtime.remember { mutableStateOf(false) }
    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(AgeBg)
            .padding(horizontal = 14.dp, vertical = 6.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        // Mantener presionado el logo ofrece desvincular (reasignar el reloj).
        Image(
            painter = painterResource(id = R.drawable.agecare_logo),
            contentDescription = "AgeCare",
            contentScale = ContentScale.Fit,
            modifier = Modifier
                .size(34.dp)
                .clip(RoundedCornerShape(8.dp))
                .combinedClickable(
                    onClick = {},
                    onLongClick = { confirmUnlink = true },
                ),
        )
        if (confirmUnlink) {
            Spacer(Modifier.height(4.dp))
            Text("¿Desvincular reloj?", fontSize = 11.sp, color = AgeAmber)
            Row {
                Text(
                    "Sí",
                    fontSize = 13.sp,
                    fontWeight = FontWeight.Bold,
                    color = AgeRed,
                    modifier = Modifier
                        .padding(horizontal = 10.dp)
                        .clickable { confirmUnlink = false; onUnlink() },
                )
                Text(
                    "No",
                    fontSize = 13.sp,
                    fontWeight = FontWeight.Bold,
                    color = AgeDim,
                    modifier = Modifier
                        .padding(horizontal = 10.dp)
                        .clickable { confirmUnlink = false },
                )
            }
        }
        // Nombre del paciente con punto de estado (verde si enviando).
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(
                modifier = Modifier
                    .size(6.dp)
                    .clip(CircleShape)
                    .background(if (online) AgeGreen else AgeDim),
            )
            Spacer(Modifier.width(5.dp))
            Text(
                patientName ?: "AgeCare",
                fontSize = 12.sp,
                fontWeight = FontWeight.Bold,
                color = AgeText,
            )
        }
        Spacer(Modifier.height(6.dp))

        // ── Tarjeta de Frecuencia Cardíaca (métrica principal) ──
        MetricCard(
            icon = "❤\uFE0F",
            value = if (bpm > 0) "$bpm" else "--",
            unit = "lpm",
            color = AgeRed,
            measuring = bpm <= 0,
        )

        // ── Tarjeta de SpO2 (siempre visible; "midiendo" mientras llega) ──
        if (spo2Supported) {
            Spacer(Modifier.height(6.dp))
            MetricCard(
                icon = "\uD83E\uDEC1",
                value = if (spo2 > 0) "$spo2" else "--",
                unit = "SpO₂ %",
                color = AgeBlue,
                measuring = spo2 <= 0 || spo2Status != null,
                hint = spo2Status,
            )
        }

        Spacer(Modifier.height(8.dp))

        // Estado de envío.
        Text(
            status,
            fontSize = 10.sp,
            textAlign = TextAlign.Center,
            color = when {
                online -> AgeGreen
                status.startsWith("Ajusta") || status == "Iniciando…" || status == "Conectando…" -> AgeDim
                else -> AgeRed
            },
        )

        Spacer(Modifier.height(4.dp))
        // Pie: envíos + escudo de caídas.
        Row(verticalAlignment = Alignment.CenterVertically) {
            if (sent > 0) {
                Text("↑ $sent", fontSize = 9.sp, color = AgeDim)
                Spacer(Modifier.width(10.dp))
            }
            Text(
                if (fallArmed) "🛡 caídas activas" else "caídas off",
                fontSize = 9.sp,
                color = if (fallArmed) AgeGreen else AgeDim,
            )
        }
    }
}

/// Tarjeta de una métrica vital: ícono + valor grande + unidad, sobre un panel
/// con el color de la métrica. Si [measuring] y no hay valor, muestra un punto
/// de "midiendo…" para que no parezca que está roto.
@androidx.compose.runtime.Composable
private fun MetricCard(
    icon: String,
    value: String,
    unit: String,
    color: Color,
    measuring: Boolean,
    hint: String? = null,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(14.dp))
            .background(color.copy(alpha = 0.14f))
            .padding(horizontal = 14.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(icon, fontSize = 18.sp)
        Spacer(Modifier.width(10.dp))
        Column {
            Row(verticalAlignment = Alignment.Bottom) {
                Text(
                    value,
                    fontSize = 30.sp,
                    fontWeight = FontWeight.Bold,
                    color = color,
                )
                Spacer(Modifier.width(4.dp))
                Text(unit, fontSize = 10.sp, color = AgeDim, modifier = Modifier.padding(bottom = 4.dp))
            }
            if (measuring) {
                // Motivo concreto si lo hay ("no te muevas", "señal baja").
                Text(hint ?: "midiendo…", fontSize = 8.sp, color = AgeDim)
            }
        }
    }
}
