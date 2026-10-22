import 'package:flutter/material.dart';

/// Origen de un dato de salud (transparencia de fuente: nada oculto).
/// El backend lo entrega en meta.origin (o source) de cada lectura.
enum VitalSource {
  watch('watch', 'Reloj AgeCare', '❤️'),
  healthConnect('health_connect', 'Samsung Health', '⌚'),
  simulator('simulator', 'Datos de prueba', '🧪'),
  manual('manual', 'Registro manual', '✍️'),
  wearable('wearable', 'Wearable', '📟'),
  unknown('', 'Origen desconocido', '•');

  const VitalSource(this.apiValue, this.label, this.emoji);
  final String apiValue;
  final String label;
  final String emoji;

  /// Resuelve a partir de origin (meta) o source. origin tiene prioridad.
  static VitalSource resolve(String? origin, String? source) {
    final key = (origin != null && origin.isNotEmpty) ? origin : (source ?? '');
    return VitalSource.values.firstWhere(
      (s) => s.apiValue == key,
      orElse: () => VitalSource.unknown,
    );
  }
}

/// Tipos de vital (alineados con enum VitalType de la API).
enum VitalType {
  heartRate('heart_rate', 'Ritmo cardíaco', 'bpm', '❤️', Icons.favorite_rounded),
  spo2('spo2', 'Oxígeno (SpO2)', '%', '🫁', Icons.air_rounded),
  bloodPressure('blood_pressure', 'Presión arterial', 'mmHg', '🩸', Icons.bloodtype_rounded),
  temperature('temperature', 'Temperatura', '°C', '🌡️', Icons.thermostat_rounded),
  glucose('glucose', 'Glucosa', 'mg/dL', '🍬', Icons.water_drop_rounded),
  sleep('sleep', 'Sueño', 'h', '😴', Icons.bedtime_rounded),
  steps('steps', 'Pasos', 'pasos', '🚶', Icons.directions_walk_rounded),
  sedentaryMin('sedentary_min', 'Tiempo sedentario', 'min', '🪑', Icons.chair_rounded),
  fallEvent('fall_event', 'Caídas', 'eventos', '⚠️', Icons.warning_rounded);

  /// true para los signos vitales "clínicos" que se muestran en el grupo
  /// Vitales: ritmo cardíaco, SpO2, presión, temperatura y glucosa. El resto
  /// (sueño, pasos, sedentarismo, caídas) son datos de actividad, que se
  /// agrupan aparte.
  bool get isCoreVital =>
      this == heartRate ||
      this == spo2 ||
      this == bloodPressure ||
      this == temperature ||
      this == glucose;

  /// Tipos que esperamos ver en Salud aunque hoy no tengan lecturas, para que
  /// la pantalla sea completa y transparente (no esconder un vital solo porque
  /// aún no llegó dato). Las caídas no son un "valor" que graficar.
  static const expected = [
    heartRate,
    spo2,
    bloodPressure,
    temperature,
    glucose,
    sleep,
    steps,
    sedentaryMin,
  ];

  const VitalType(this.apiValue, this.label, this.unit, this.emoji, this.icon);

  final String apiValue;
  final String label;
  final String unit;
  final String emoji;
  final IconData icon;

  static VitalType fromApi(String v) => VitalType.values
      .firstWhere((t) => t.apiValue == v, orElse: () => VitalType.heartRate);
}

class VitalReading {
  const VitalReading({
    required this.type,
    required this.value,
    required this.measuredAt,
    this.meta,
  });

  final VitalType type;
  final double value;
  final DateTime measuredAt;
  final Map<String, dynamic>? meta;

  Map<String, dynamic> toJson() => {
        'type': type.apiValue,
        'value': value,
        'measured_at': measuredAt.toUtc().toIso8601String(),
        if (meta != null) 'meta': meta,
      };
}

class VitalPoint {
  const VitalPoint({required this.ts, required this.value, this.min, this.max});

  final DateTime ts;
  final double value;
  final double? min;
  final double? max;

  factory VitalPoint.fromJson(Map<String, dynamic> json) => VitalPoint(
        ts: DateTime.parse(json['ts'] as String),
        value: (json['value'] as num).toDouble(),
        min: (json['min'] as num?)?.toDouble(),
        max: (json['max'] as num?)?.toDouble(),
      );
}

class Threshold {
  const Threshold({required this.type, this.minValue, this.maxValue});

  final VitalType type;
  final double? minValue;
  final double? maxValue;

  bool isOutOfRange(double value) =>
      (minValue != null && value < minValue!) ||
      (maxValue != null && value > maxValue!);

  factory Threshold.fromJson(Map<String, dynamic> json) => Threshold(
        type: VitalType.fromApi(json['type'] as String),
        minValue: (json['min_value'] as num?)?.toDouble(),
        maxValue: (json['max_value'] as num?)?.toDouble(),
      );
}

class VitalSeries {
  const VitalSeries({
    required this.type,
    required this.points,
    this.threshold,
    this.sources = const {},
  });

  final VitalType type;
  final List<VitalPoint> points;
  final Threshold? threshold;

  /// Conteo de lecturas por origen en el rango (transparencia de fuente).
  /// Ej: {VitalSource.watch: 2964, VitalSource.healthConnect: 327}.
  final Map<VitalSource, int> sources;
}

class LatestVital {
  const LatestVital({
    required this.type,
    required this.value,
    required this.measuredAt,
    this.inRange = true,
    this.source = VitalSource.unknown,
    this.hasData = true,
  });

  /// Marcador para un vital que aún NO tiene lecturas (se muestra la tarjeta
  /// con "sin datos aún" en vez de ocultarla). value/measuredAt son inválidos.
  factory LatestVital.empty(VitalType type) => LatestVital(
        type: type,
        value: 0,
        measuredAt: DateTime.fromMillisecondsSinceEpoch(0),
        source: VitalSource.unknown,
        hasData: false,
      );

  final VitalType type;
  final double value;
  final DateTime measuredAt;
  final bool inRange;

  /// false cuando es un placeholder (no hay lecturas de este tipo todavía).
  final bool hasData;

  /// De dónde viene este dato (reloj, Samsung Health, prueba…).
  final VitalSource source;

  factory LatestVital.fromJson(Map<String, dynamic> json) => LatestVital(
        type: VitalType.fromApi(json['type'] as String),
        value: (json['value'] as num).toDouble(),
        measuredAt: DateTime.parse(json['measured_at'] as String),
        inRange: (json['in_range'] ?? true) as bool,
        source: VitalSource.resolve(
            json['origin'] as String?, json['source'] as String?),
      );

  String get displayValue {
    switch (type) {
      case VitalType.steps:
      case VitalType.sedentaryMin:
      case VitalType.fallEvent:
        return value.toInt().toString();
      case VitalType.sleep:
        final h = value.floor();
        final m = ((value - h) * 60).round();
        return '${h}h ${m.toString().padLeft(2, '0')}m';
      case VitalType.temperature:
        return value.toStringAsFixed(1);
      default:
        return value.toStringAsFixed(0);
    }
  }
}
