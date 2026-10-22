import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../patients/application/patients_providers.dart';
import '../data/vitals_repository.dart';
import '../domain/models.dart';

/// Resumen de salud ESTRUCTURADO y SANITIZADO del paciente.
///
/// Objetivo: ser la ÚNICA fuente de contexto de salud que se le pasará al chat
/// con IA (fase futura). Por eso es determinista, valida los valores contra
/// rangos fisiológicos plausibles y descarta ruido (NaN, 0 espurios, valores
/// imposibles). Nada de "graficar en tiempo real": entrega agregados limpios.
///
/// Lo que produce por cada vital con dato válido:
///   - valor + unidad
///   - en_rango (según umbral del paciente, si existe)
///   - origen (reloj / Samsung Health / prueba / manual)
///   - antigüedad de la lectura
///   - tendencia de 7 días (promedio, mín, máx, nº de puntos)
/// Y además marca explícitamente los vitales SIN dato, para que la IA no
/// invente: si no hay dato, el resumen lo dice.
class VitalSummary {
  const VitalSummary({
    required this.type,
    required this.value,
    required this.unit,
    required this.inRange,
    required this.source,
    required this.measuredAt,
    this.trend7d,
  });

  final VitalType type;
  final double value;
  final String unit;
  final bool inRange;
  final VitalSource source;
  final DateTime measuredAt;
  final TrendStats? trend7d;

  Duration get age => DateTime.now().difference(measuredAt.toLocal());

  /// Representación compacta y sin ambigüedad, pensada para el prompt de la IA.
  /// Ej: "Ritmo cardíaco: 80 bpm (en rango, fuente ❤️ Reloj AgeCare, hace 2 min;
  /// 7d prom 76, mín 58, máx 101)".
  Map<String, dynamic> toContext() => {
        'tipo': type.apiValue,
        'etiqueta': type.label,
        'valor': value,
        'unidad': unit,
        'en_rango': inRange,
        'origen': source.apiValue,
        'origen_etiqueta': source.label,
        'medido_hace_min': age.inMinutes,
        if (trend7d != null) 'tendencia_7d': trend7d!.toContext(),
      };
}

/// Estadísticos de la tendencia de 7 días de un vital (agregado, no crudo).
class TrendStats {
  const TrendStats({
    required this.avg,
    required this.min,
    required this.max,
    required this.points,
  });

  final double avg;
  final double min;
  final double max;
  final int points;

  Map<String, dynamic> toContext() => {
        'promedio': double.parse(avg.toStringAsFixed(1)),
        'min': double.parse(min.toStringAsFixed(1)),
        'max': double.parse(max.toStringAsFixed(1)),
        'muestras': points,
      };
}

/// Resumen completo listo para el chat IA.
class HealthSummary {
  const HealthSummary({
    required this.patientId,
    required this.generatedAt,
    required this.vitals,
    required this.missing,
  });

  final String patientId;
  final DateTime generatedAt;

  /// Vitales con dato válido y sanitizado.
  final List<VitalSummary> vitals;

  /// Vitales que la plataforma soporta pero que NO tienen dato (la IA debe
  /// decir "no hay registro" en vez de inventar).
  final List<VitalType> missing;

  /// Estructura determinista para inyectar en el prompt del asistente. Esta es
  /// la "fuente quirúrgica" que evita que el modelo alucine: solo hechos.
  Map<String, dynamic> toContext() => {
        'paciente_id': patientId,
        'generado_en': generatedAt.toUtc().toIso8601String(),
        'vitales': [for (final v in vitals) v.toContext()],
        'sin_datos': [for (final t in missing) t.apiValue],
        'nota':
            'Solo datos reales del backend. Si un vital está en "sin_datos", '
                'no existe lectura: no lo inventes ni estimes.',
      };
}

// ---------------------------------------------------------------------------
// Sanitización: rangos fisiológicos plausibles por tipo. Fuera de esto se
// considera ruido de sensor y se descarta (no entra al resumen de la IA).
// ---------------------------------------------------------------------------
class _Plausible {
  const _Plausible(this.min, this.max);
  final double min;
  final double max;
}

const _plausibleRanges = <VitalType, _Plausible>{
  VitalType.heartRate: _Plausible(25, 250),
  VitalType.spo2: _Plausible(50, 100),
  VitalType.bloodPressure: _Plausible(40, 300),
  VitalType.temperature: _Plausible(30, 45),
  VitalType.glucose: _Plausible(20, 600),
  VitalType.sleep: _Plausible(0, 24),
  VitalType.steps: _Plausible(0, 100000),
  VitalType.sedentaryMin: _Plausible(0, 1440),
};

/// true si el valor es fisiológicamente plausible para ese tipo (no ruido).
bool _isPlausible(VitalType type, double value) {
  if (value.isNaN || value.isInfinite) return false;
  final r = _plausibleRanges[type];
  if (r == null) return value > 0;
  return value >= r.min && value <= r.max;
}

/// Provider del resumen de salud sanitizado. Reutiliza /vitals/latest y las
/// series de 7 días por tipo. Pensado como insumo del futuro chat IA.
final healthSummaryProvider =
    FutureProvider.autoDispose<HealthSummary?>((ref) async {
  final patient = ref.watch(selectedPatientProvider);
  if (patient == null) return null;
  final repo = ref.watch(vitalsRepositoryProvider);

  final latest = await repo.getLatest(patient.patientId);
  final byType = {for (final v in latest) v.type: v};

  final now = DateTime.now();
  final from = now.subtract(const Duration(days: 7));

  final vitals = <VitalSummary>[];
  final missing = <VitalType>[];

  for (final type in VitalType.expected) {
    final lv = byType[type];
    if (lv == null || !lv.hasData || !_isPlausible(type, lv.value)) {
      missing.add(type);
      continue;
    }

    // Tendencia de 7 días (agregada por día). Se descartan puntos no plausibles.
    TrendStats? trend;
    try {
      final series = await repo.getSeries(patient.patientId, type,
          from: from, to: now, granularity: 'day');
      final vals = series.points
          .map((p) => p.value)
          .where((v) => _isPlausible(type, v))
          .toList();
      if (vals.isNotEmpty) {
        final avg = vals.reduce((a, b) => a + b) / vals.length;
        trend = TrendStats(
          avg: avg,
          min: vals.reduce((a, b) => a < b ? a : b),
          max: vals.reduce((a, b) => a > b ? a : b),
          points: vals.length,
        );
      }
    } catch (_) {
      // Sin tendencia: el resumen sigue siendo válido con el último valor.
    }

    vitals.add(VitalSummary(
      type: type,
      value: double.parse(lv.value.toStringAsFixed(1)),
      unit: type.unit,
      inRange: lv.inRange,
      source: lv.source,
      measuredAt: lv.measuredAt,
      trend7d: trend,
    ));
  }

  return HealthSummary(
    patientId: patient.patientId,
    generatedAt: now,
    vitals: vitals,
    missing: missing,
  );
});
