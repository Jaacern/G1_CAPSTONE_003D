import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../home/application/home_providers.dart';
import '../../patients/application/patients_providers.dart';
import '../data/vitals_repository.dart';
import '../domain/models.dart';

/// Últimos valores por vital del paciente seleccionado (GET /vitals/latest).
final latestVitalsProvider = FutureProvider<List<LatestVital>>((ref) async {
  final patient = ref.watch(selectedPatientProvider);
  if (patient == null) return [];
  return ref.watch(vitalsRepositoryProvider).getLatest(patient.patientId);
});

/// Umbrales (rangos normales) del paciente seleccionado (GET 5.5).
final thresholdsProvider =
    FutureProvider<List<Threshold>>((ref) async {
  final patient = ref.watch(selectedPatientProvider);
  if (patient == null) return [];
  return ref.watch(vitalsRepositoryProvider).getThresholds(patient.patientId);
});

/// Mini-serie de 7 días por tipo, para la sparkline de cada tarjeta de vital.
final sparkSeriesProvider =
    FutureProvider.family<VitalSeries?, VitalType>((ref, type) async {
  final patient = ref.watch(selectedPatientProvider);
  if (patient == null) return null;
  final to = DateTime.now();
  final from = to.subtract(const Duration(days: 7));
  return ref.watch(vitalsRepositoryProvider).getSeries(
        patient.patientId,
        type,
        from: from,
        to: to,
        granularity: 'day',
      );
});

/// Resumen de fuentes de hoy para el ritmo cardíaco (transparencia).
/// Devuelve cuántas lecturas aportó cada origen y si el reloj está "en vivo"
/// (hay lecturas origin=watch en los últimos minutos).
class SourcesToday {
  const SourcesToday({this.counts = const {}, this.watchLastAt});
  final Map<VitalSource, int> counts;
  final DateTime? watchLastAt;

  int get total => counts.values.fold(0, (a, b) => a + b);
  int countOf(VitalSource s) => counts[s] ?? 0;

  /// Reloj "emitiendo" si hubo una lectura suya en los últimos 2 minutos.
  bool get watchLive =>
      watchLastAt != null &&
      DateTime.now().difference(watchLastAt!.toLocal()).inMinutes < 2;
}

/// Lee la serie de hoy (granularidad raw no; usamos day pero con sources) para
/// obtener el desglose de orígenes del ritmo cardíaco.
final sourcesTodayProvider =
    FutureProvider.autoDispose<SourcesToday>((ref) async {
  final patient = ref.watch(selectedPatientProvider);
  if (patient == null) return const SourcesToday();
  final now = DateTime.now();
  final series = await ref.watch(vitalsRepositoryProvider).getSeries(
        patient.patientId,
        VitalType.heartRate,
        from: DateTime(now.year, now.month, now.day),
        to: now,
        granularity: 'day',
      );
  // watchLastAt: lo aproximamos con la última lectura latest si es de reloj.
  DateTime? watchLastAt;
  try {
    final latest =
        await ref.watch(vitalsRepositoryProvider).getLatest(patient.patientId);
    final hr = latest.where((v) => v.type == VitalType.heartRate);
    if (hr.isNotEmpty && hr.first.source == VitalSource.watch) {
      watchLastAt = hr.first.measuredAt;
    }
  } catch (_) {}
  return SourcesToday(counts: series.sources, watchLastAt: watchLastAt);
});

/// Refresca todas las vistas que dependen de los vitals tras subir lecturas
/// (reloj real o datos de prueba): Salud, Hoy, semáforo de pacientes y detalle.
///
/// Recibe `ref.invalidate` para funcionar igual con `Ref` y con `WidgetRef`:
///   refreshVitalsViews(ref.invalidate);
void refreshVitalsViews(void Function(ProviderOrFamily) invalidate) {
  invalidate(latestVitalsProvider);
  invalidate(sparkSeriesProvider);
  invalidate(sourcesTodayProvider);
  invalidate(todaySummaryProvider);
  invalidate(myPatientsProvider);
  invalidate(selectedPatientDetailProvider);
}

// ---------------------------------------------------------------------------
// Modo "En vivo": auto-refresco de las vistas de salud SONDEANDO EL BACKEND.
// No escribe nada en la BD; solo vuelve a pedir /vitals/latest y las series
// (puro GET) cada [_period] para que lo que sube el reloj aparezca solo en el
// teléfono, sin que el usuario tenga que arrastrar para refrescar.
// ---------------------------------------------------------------------------
class LiveState {
  const LiveState({this.enabled = false, this.lastRefresh});
  final bool enabled;
  final DateTime? lastRefresh;

  LiveState copyWith({bool? enabled, DateTime? lastRefresh}) => LiveState(
        enabled: enabled ?? this.enabled,
        lastRefresh: lastRefresh ?? this.lastRefresh,
      );
}

class LiveController extends StateNotifier<LiveState> {
  LiveController(this._ref) : super(const LiveState());

  final Ref _ref;
  Timer? _timer;

  static const _period = Duration(seconds: 10);

  void toggle() => state.enabled ? stop() : start();

  void start() {
    if (state.enabled) return;
    state = state.copyWith(enabled: true, lastRefresh: DateTime.now());
    _timer?.cancel();
    _timer = Timer.periodic(_period, (_) => _tick());
    _tick(); // primer refresco inmediato
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    state = state.copyWith(enabled: false);
  }

  void _tick() {
    // Solo relecturas (GET). No toca la BD.
    refreshVitalsViews(_ref.invalidate);
    state = state.copyWith(lastRefresh: DateTime.now());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}

final liveControllerProvider =
    StateNotifierProvider<LiveController, LiveState>((ref) => LiveController(ref));
