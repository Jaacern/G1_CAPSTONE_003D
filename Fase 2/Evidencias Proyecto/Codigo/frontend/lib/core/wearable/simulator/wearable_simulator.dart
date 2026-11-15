import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../features/health/application/health_providers.dart';
import '../../../features/health/data/vitals_repository.dart';
import '../../../features/health/domain/models.dart';

/// Escenarios de datos de prueba. Cada uno sube lecturas con la hora actual,
/// así pasan a ser los "últimos valores" y el semáforo reacciona al instante.
///
/// Umbrales de referencia (seed de Elena): ritmo 50–110 lpm, SpO₂ mín. 92 %.
enum SimScenario {
  normal('Normal', '🟢', 'Ritmo ~72 lpm, SpO₂ 97 %, pasos y sueño normales.'),
  highHeartRate('Ritmo elevado', '🔴', 'Ritmo 128 lpm (sobre el máximo de 110).'),
  lowSpo2('SpO₂ baja', '🟠', 'Saturación 89 % (bajo el mínimo de 92).');

  const SimScenario(this.label, this.emoji, this.description);
  final String label;
  final String emoji;
  final String description;
}

/// Genera las lecturas de un escenario. Puro y determinista salvo el ruido
/// leve, para que sea fácil de probar.
List<VitalReading> buildScenarioReadings(SimScenario scenario,
    {DateTime? now, Random? random}) {
  final t = (now ?? DateTime.now()).toUtc();
  final rng = random ?? Random();
  final meta = {'origin': 'simulator', 'scenario': scenario.name};
  double jitter(double spread) => (rng.nextDouble() * 2 - 1) * spread;

  final readings = <VitalReading>[];

  // Últimas 6 horas de ritmo y SpO₂ en valores normales; la lectura actual
  // (i == 0) es la que define el escenario.
  for (var i = 6; i >= 0; i--) {
    final at = t.subtract(Duration(hours: i));
    final isNow = i == 0;

    final hr = isNow && scenario == SimScenario.highHeartRate
        ? 128.0
        : 72 + jitter(5);
    final spo2 = isNow && scenario == SimScenario.lowSpo2
        ? 89.0
        : 97 + jitter(1);

    readings
      ..add(VitalReading(
          type: VitalType.heartRate,
          value: double.parse(hr.toStringAsFixed(0)),
          measuredAt: at,
          meta: meta))
      ..add(VitalReading(
          type: VitalType.spo2,
          value: double.parse(spo2.toStringAsFixed(1)),
          measuredAt: at,
          meta: meta));
  }

  // Pasos acumulados de hoy y sueño de anoche.
  readings
    ..add(VitalReading(
        type: VitalType.steps,
        value: (2300 + jitter(400)).roundToDouble(),
        measuredAt: t,
        meta: meta))
    ..add(VitalReading(
        type: VitalType.sleep,
        value: double.parse((7.1 + jitter(0.6)).toStringAsFixed(1)),
        measuredAt: DateTime.utc(t.year, t.month, t.day, 10), // ~07:00 Chile
        meta: meta));

  return readings;
}

/// Estado del simulador para la UI.
class SimState {
  const SimState({this.busy = false, this.last, this.message, this.isError = false});
  final bool busy;
  final SimScenario? last;
  final String? message;
  final bool isError;
}

/// Sube un escenario al backend (POST /patients/{id}/vitals/batch) y refresca
/// las pantallas (Hoy, Salud, semáforo de pacientes).
class WearableSimulatorController extends StateNotifier<SimState> {
  WearableSimulatorController(this._ref) : super(const SimState());

  final Ref _ref;

  Future<void> run(String patientId, SimScenario scenario) async {
    state = SimState(busy: true, last: state.last);
    try {
      final readings = buildScenarioReadings(scenario);
      final accepted = await _ref
          .read(vitalsRepositoryProvider)
          .uploadBatch(patientId, readings);
      refreshVitalsViews(_ref.invalidate);
      state = SimState(
        last: scenario,
        message:
            '${scenario.emoji} Escenario "${scenario.label}" cargado: $accepted lecturas. '
            'Revisa Hoy y Salud.',
      );
    } catch (e) {
      state = SimState(
        last: state.last,
        isError: true,
        message: 'No se pudieron cargar los datos de prueba: $e',
      );
    }
  }
}

final wearableSimulatorProvider =
    StateNotifierProvider<WearableSimulatorController, SimState>(
        (ref) => WearableSimulatorController(ref));
