import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../features/health/application/health_providers.dart';
import '../../../features/health/data/vitals_repository.dart';
import 'health_connect_service.dart';
import 'health_connect_sync.dart';

/// Estado del "Modo Live": sondeo periódico de Health Connect.
///
/// NOTA técnica importante: Health Connect NO es un stream en tiempo real.
/// No existe una API que "empuje" el ritmo cardíaco al instante. El Modo Live
/// consulta Health Connect cada [intervalSeconds] y sube SOLO las lecturas
/// nuevas (idempotente en el backend). El retraso real depende de qué tan
/// rápido Samsung Health vuelca los datos del reloj a Health Connect.
class HcLiveState {
  const HcLiveState({
    this.active = false,
    this.ticks = 0,
    this.totalNew = 0,
    this.lastHeartRate,
    this.lastAt,
    this.message,
    this.error = false,
  });

  final bool active;

  /// Nº de sondeos realizados desde que se activó.
  final int ticks;

  /// Lecturas nuevas aceptadas por el backend en toda la sesión Live.
  final int totalNew;

  /// Último ritmo cardíaco leído (para el indicador "latido").
  final double? lastHeartRate;

  /// Hora de la última lectura real recibida.
  final DateTime? lastAt;

  final String? message;
  final bool error;

  HcLiveState copyWith({
    bool? active,
    int? ticks,
    int? totalNew,
    double? lastHeartRate,
    DateTime? lastAt,
    String? message,
    bool? error,
  }) =>
      HcLiveState(
        active: active ?? this.active,
        ticks: ticks ?? this.ticks,
        totalNew: totalNew ?? this.totalNew,
        lastHeartRate: lastHeartRate ?? this.lastHeartRate,
        lastAt: lastAt ?? this.lastAt,
        message: message,
        error: error ?? this.error,
      );
}

/// Controlador del Modo Live: Timer periódico que lee Health Connect y sube
/// lecturas nuevas. No modifica el esquema de la BD; solo inserta filas reales
/// vía `/vitals/batch` (el backend descarta duplicados por su UNIQUE natural).
class HealthConnectLiveController extends StateNotifier<HcLiveState> {
  HealthConnectLiveController(this._service, this._vitals, this._onUploaded)
      : super(const HcLiveState());

  final HealthConnectService _service;
  final VitalsRepository _vitals;
  final void Function() _onUploaded;

  Timer? _timer;
  String? _patientId;
  DateTime? _since; // marca de la última lectura ya procesada

  static const intervalSeconds = 15;

  /// Arranca el sondeo para [patientId]. Pide permisos una sola vez.
  Future<void> start(String patientId) async {
    if (state.active) return;
    _patientId = patientId;

    final available = await _service.isAvailable();
    if (!available) {
      state = state.copyWith(
          error: true,
          message: 'Health Connect no está disponible en este dispositivo.');
      return;
    }
    final granted = await _service.requestPermissions();
    if (!granted) {
      state = state.copyWith(
          error: true, message: 'Faltan permisos de salud para el modo Live.');
      return;
    }

    // Arranca mirando los últimos 10 minutos para "enganchar" lo reciente.
    _since = DateTime.now().subtract(const Duration(minutes: 10));
    state = const HcLiveState(
        active: true, message: 'Modo Live activo. Escuchando el reloj…');

    await _poll(); // primer sondeo inmediato
    _timer = Timer.periodic(
        const Duration(seconds: intervalSeconds), (_) => _poll());
  }

  /// Detiene el sondeo (al apagar el interruptor o salir de la pantalla).
  void stop() {
    _timer?.cancel();
    _timer = null;
    if (mounted) {
      state = state.copyWith(active: false, message: 'Modo Live detenido.');
    }
  }

  Future<void> _poll() async {
    final pid = _patientId;
    if (pid == null) return;
    try {
      final to = DateTime.now();
      // Ventana: desde la última lectura procesada (con 1s de solape) hasta ahora.
      final from = (_since ?? to.subtract(const Duration(minutes: 1)))
          .subtract(const Duration(seconds: 1));
      final result = await _service.readVitals(from: from, to: to);

      var accepted = 0;
      if (result.readings.isNotEmpty) {
        accepted = await _vitals.uploadBatch(pid, result.readings);
        // Avanza el puntero a la lectura más reciente vista.
        _since = result.readings
            .map((r) => r.measuredAt)
            .reduce((a, b) => a.isAfter(b) ? a : b);
        if (accepted > 0) _onUploaded();
      }

      // Último ritmo para el indicador visual.
      final hr = result.readings
          .where((r) => r.type.apiValue == 'heart_rate')
          .fold<double?>(null, (_, r) => r.value);

      state = state.copyWith(
        active: true,
        ticks: state.ticks + 1,
        totalNew: state.totalNew + accepted,
        lastHeartRate: hr,
        lastAt: hr != null ? _since : state.lastAt,
        error: false,
        message: accepted > 0
            ? 'Nuevas lecturas: +$accepted'
            : 'Sin datos nuevos del reloj todavía…',
      );
    } catch (e) {
      state = state.copyWith(
          ticks: state.ticks + 1,
          error: true,
          message: 'Error al leer el reloj: $e');
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}

final healthConnectLiveProvider =
    StateNotifierProvider<HealthConnectLiveController, HcLiveState>((ref) {
  return HealthConnectLiveController(
    ref.watch(healthConnectServiceProvider),
    ref.watch(vitalsRepositoryProvider),
    () => refreshVitalsViews(ref.invalidate),
  );
});
