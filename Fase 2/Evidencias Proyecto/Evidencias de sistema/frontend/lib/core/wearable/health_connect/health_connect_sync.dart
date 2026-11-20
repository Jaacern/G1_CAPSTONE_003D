import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../features/health/application/health_providers.dart';
import '../../../features/health/data/vitals_repository.dart';
import 'health_connect_service.dart';

/// Fase de la sincronización con Health Connect, para que la UI reaccione.
enum HcSyncPhase { idle, checking, needsPermission, reading, uploading, done, error }

/// Estado de la sincronización con Health Connect.
class HcSyncState {
  const HcSyncState({
    this.phase = HcSyncPhase.idle,
    this.accepted = 0,
    this.read = 0,
    this.message,
  });

  final HcSyncPhase phase;

  /// Lecturas aceptadas por el backend (las no duplicadas).
  final int accepted;

  /// Lecturas leídas del reloj y enviadas.
  final int read;

  /// Mensaje para mostrar (éxito informativo o error).
  final String? message;

  bool get isBusy =>
      phase == HcSyncPhase.checking ||
      phase == HcSyncPhase.reading ||
      phase == HcSyncPhase.uploading;

  HcSyncState copyWith({
    HcSyncPhase? phase,
    int? accepted,
    int? read,
    String? message,
  }) =>
      HcSyncState(
        phase: phase ?? this.phase,
        accepted: accepted ?? this.accepted,
        read: read ?? this.read,
        message: message,
      );
}

/// Orquesta la sincronización: Health Connect → backend `/vitals/batch`.
///
/// Diseño: el servicio (lectura) y el repositorio (subida) ya existen y son
/// independientes; este controlador solo los coordina y publica el estado.
class HealthConnectSyncController extends StateNotifier<HcSyncState> {
  HealthConnectSyncController(this._service, this._vitals, this._onUploaded)
      : super(const HcSyncState());

  final HealthConnectService _service;
  final VitalsRepository _vitals;

  /// Se llama tras subir lecturas para refrescar Hoy, Salud y el semáforo.
  final void Function() _onUploaded;

  /// Lee los últimos [days] días del reloj y los sube al backend para [patientId].
  Future<void> sync(String patientId, {int days = 7}) async {
    try {
      state = const HcSyncState(phase: HcSyncPhase.checking);

      final available = await _service.isAvailable();
      if (!available) {
        state = const HcSyncState(
          phase: HcSyncPhase.error,
          message: 'Health Connect no está disponible. Instálalo desde Play Store.',
        );
        return;
      }

      final granted = await _service.requestPermissions();
      if (!granted) {
        state = const HcSyncState(
          phase: HcSyncPhase.needsPermission,
          message: 'Faltan permisos de salud. Acéptalos para leer el reloj.',
        );
        return;
      }

      state = state.copyWith(phase: HcSyncPhase.reading);
      final to = DateTime.now();
      final from = to.subtract(Duration(days: days));
      final result = await _service.readVitals(from: from, to: to);

      if (result.readings.isEmpty) {
        state = HcSyncState(
          phase: HcSyncPhase.done,
          read: 0,
          accepted: 0,
          message: result.note ?? 'Sin datos nuevos del reloj.',
        );
        return;
      }

      state = state.copyWith(
        phase: HcSyncPhase.uploading,
        read: result.readings.length,
      );
      final accepted = await _vitals.uploadBatch(patientId, result.readings);
      _onUploaded();

      state = HcSyncState(
        phase: HcSyncPhase.done,
        read: result.readings.length,
        accepted: accepted,
        message: 'Se subieron $accepted lecturas nuevas del reloj.',
      );
    } catch (e) {
      state = HcSyncState(
        phase: HcSyncPhase.error,
        message: 'No se pudo sincronizar: $e',
      );
    }
  }

  void reset() => state = const HcSyncState();
}

/// Servicio de Health Connect (sin dependencias de red).
final healthConnectServiceProvider =
    Provider<HealthConnectService>((ref) => HealthConnectService());

/// Controlador de sincronización Health Connect → backend.
final healthConnectSyncProvider =
    StateNotifierProvider<HealthConnectSyncController, HcSyncState>((ref) {
  return HealthConnectSyncController(
    ref.watch(healthConnectServiceProvider),
    ref.watch(vitalsRepositoryProvider),
    () => refreshVitalsViews(ref.invalidate),
  );
});
