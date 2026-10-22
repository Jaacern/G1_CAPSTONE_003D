import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';

/// Catálogo de metadatos de presentación por tipo de signo vital.
/// El backend solo entrega `type` (código), `value`, `unit`, `measured_at` e
/// `in_range`; aquí derivamos la etiqueta, el emoji y el icono en español.
class VitalMeta {
  const VitalMeta(this.label, this.emoji, this.icon);
  final String label;
  final String emoji;
  final IconData icon;

  static VitalMeta of(String type) =>
      _byType[type] ?? const VitalMeta('Signo', '📈', Icons.insights_rounded);

  static const Map<String, VitalMeta> _byType = {
    'heart_rate': VitalMeta('Ritmo cardíaco', '❤️', Icons.favorite_rounded),
    'spo2': VitalMeta('SpO₂', '🫁', Icons.air_rounded),
    'sleep': VitalMeta('Sueño', '😴', Icons.bedtime_rounded),
    'steps': VitalMeta('Actividad', '🚶', Icons.directions_walk_rounded),
    'sedentary_min': VitalMeta('Sedentarismo', '🪑', Icons.chair_rounded),
    'blood_pressure':
        VitalMeta('Presión arterial', '🩸', Icons.monitor_heart_rounded),
    'temperature': VitalMeta('Temperatura', '🌡️', Icons.thermostat_rounded),
    'glucose': VitalMeta('Glucosa', '💧', Icons.water_drop_rounded),
    'fall_event': VitalMeta('Caída', '⚠️', Icons.warning_rounded),
  };
}

/// Traduce los motivos del semáforo que manda el backend con códigos internos
/// ("heart_rate fuera de rango (128.0 bpm)") a texto legible
/// ("Ritmo cardíaco fuera de rango (128 bpm)").
String humanizeReason(String reason) {
  var out = reason;
  for (final e in VitalMeta._byType.entries) {
    out = out.replaceAll(RegExp('\\b${e.key}\\b'), e.value.label);
  }
  // 128.0 -> 128
  return out.replaceAllMapped(RegExp(r'(\d+)\.0\b'), (m) => m.group(1)!);
}

/// Última lectura de un signo vital (item de `latest_vitals` del backend).
class VitalReading {
  const VitalReading({
    required this.type,
    required this.value,
    this.unit,
    this.measuredAt,
    this.inRange = true,
  });

  final String type;
  final String value;
  final String? unit;
  final DateTime? measuredAt;
  final bool inRange;

  String get label => VitalMeta.of(type).label;
  String get emoji => VitalMeta.of(type).emoji;
  IconData get icon => VitalMeta.of(type).icon;
  String get display => unit == null || unit!.isEmpty ? value : '$value $unit';

  factory VitalReading.fromJson(Map<String, dynamic> json) => VitalReading(
        type: (json['type'] ?? '').toString(),
        // value llega como número; lo normalizamos a texto sin decimales inútiles.
        value: _fmt(json['value']),
        unit: json['unit'] as String?,
        measuredAt: json['measured_at'] != null
            ? DateTime.parse(json['measured_at'] as String)
            : null,
        inRange: (json['in_range'] ?? true) as bool,
      );

  static String _fmt(dynamic v) {
    if (v == null) return '';
    if (v is num) {
      // Entero si no tiene parte decimal (72.0 -> "72").
      if (v == v.roundToDouble()) return v.toInt().toString();
      return v.toString();
    }
    return v.toString();
  }
}

/// Conteo de dosis de hoy (campo `medications_today` del backend).
class MedicationsToday {
  const MedicationsToday({
    this.taken = 0,
    this.pending = 0,
    this.missed = 0,
    this.nextDose,
  });

  final int taken;
  final int pending;
  final int missed;
  final DateTime? nextDose;

  int get total => taken + pending + missed;

  /// Porcentaje de adherencia del día (tomadas / total). 100% si no hay dosis.
  int get adherencePct =>
      total == 0 ? 100 : ((taken / total) * 100).round();

  factory MedicationsToday.fromJson(Map<String, dynamic> json) =>
      MedicationsToday(
        taken: (json['taken'] ?? 0) as int,
        pending: (json['pending'] ?? 0) as int,
        missed: (json['missed'] ?? 0) as int,
        nextDose: json['next_dose'] != null
            ? DateTime.parse(json['next_dose'] as String)
            : null,
      );
}

/// Alerta activa resumida (item de `active_alerts` del summary).
class ActiveAlertBrief {
  const ActiveAlertBrief({
    required this.id,
    required this.type,
    required this.severity,
    required this.title,
    this.detail,
  });

  final String id;
  final String type;
  final String severity; // info | warning | critical
  final String title;
  final String? detail;

  bool get isCritical => severity == 'critical';

  factory ActiveAlertBrief.fromJson(Map<String, dynamic> json) =>
      ActiveAlertBrief(
        id: (json['id'] ?? '').toString(),
        type: (json['type'] ?? '').toString(),
        severity: (json['severity'] ?? 'info').toString(),
        title: (json['title'] ?? '').toString(),
        detail: json['detail'] as String?,
      );
}

/// Resumen del día de un paciente (GET /patients/{id}/summary/today).
/// Fiel al contrato del backend (SummaryTodayOut).
class TodaySummary {
  const TodaySummary({
    required this.wellbeingStatus,
    this.statusReasons = const [],
    this.activeAlerts = const [],
    this.latestVitals = const [],
    this.medicationsToday = const MedicationsToday(),
  });

  final WellbeingStatus wellbeingStatus;
  final List<String> statusReasons;
  final List<ActiveAlertBrief> activeAlerts;
  final List<VitalReading> latestVitals;
  final MedicationsToday medicationsToday;

  int get activeAlertsCount => activeAlerts.length;
  bool get hasAlerts => activeAlerts.isNotEmpty;

  /// Razón principal del semáforo (primera de la lista).
  String? get topReason =>
      statusReasons.isNotEmpty ? statusReasons.first : null;

  int get adherencePct => medicationsToday.adherencePct;

  factory TodaySummary.fromJson(Map<String, dynamic> json) => TodaySummary(
        wellbeingStatus: WellbeingStatus.fromApi(
            (json['wellbeing_status'] ?? 'ok') as String),
        statusReasons: ((json['status_reasons'] ?? const []) as List)
            .map((e) => humanizeReason(e.toString()))
            .toList(),
        activeAlerts: ((json['active_alerts'] ?? const []) as List)
            .map((e) => ActiveAlertBrief.fromJson(e as Map<String, dynamic>))
            .toList(),
        latestVitals: ((json['latest_vitals'] ?? const []) as List)
            .map((e) => VitalReading.fromJson(e as Map<String, dynamic>))
            .toList(),
        medicationsToday: json['medications_today'] != null
            ? MedicationsToday.fromJson(
                json['medications_today'] as Map<String, dynamic>)
            : const MedicationsToday(),
      );
}
