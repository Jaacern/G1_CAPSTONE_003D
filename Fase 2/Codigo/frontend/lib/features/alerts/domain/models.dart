import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';

/// Modelos del centro de alertas (alineados con la Especificación de Endpoints).

/// Tipo de alerta. Cada valor lleva su representación de API, etiqueta e icono.
enum AlertType {
  fall('fall', 'Caída detectada', Icons.personal_injury_rounded),
  vitalOutOfRange('vital_out_of_range', 'Signo vital fuera de rango',
      Icons.monitor_heart_rounded),
  medicationMissed('missed_dose', 'Dosis omitida', Icons.medication_rounded),
  wearableOffline('wearable_offline', 'Wearable sin conexión', Icons.watch_off_rounded),
  sos('sos', 'Alerta SOS', Icons.sos_rounded),
  checkinMissed('checkin_missed', 'Check-in sin realizar', Icons.event_busy_rounded),
  other('other', 'Alerta', Icons.notifications_active_rounded);

  const AlertType(this.apiValue, this.label, this.icon);

  final String apiValue;
  final String label;
  final IconData icon;

  static AlertType fromApi(String value) => AlertType.values.firstWhere(
        (t) => t.apiValue == value,
        orElse: () => AlertType.other,
      );
}

/// Severidad de la alerta, con su color del design system.
enum AlertSeverity {
  critical('critical', 'Crítica', AppColors.critical),
  warning('warning', 'Advertencia', AppColors.statusWarning),
  info('info', 'Informativa', AppColors.primary);

  const AlertSeverity(this.apiValue, this.label, this.color);

  final String apiValue;
  final String label;
  final Color color;

  static AlertSeverity fromApi(String value) => AlertSeverity.values.firstWhere(
        (s) => s.apiValue == value,
        orElse: () => AlertSeverity.info,
      );
}

/// Estado del ciclo de vida de la alerta.
enum AlertStatus {
  active('active', 'Activa'),
  acknowledged('acknowledged', 'Reconocida'),
  resolved('resolved', 'Resuelta');

  const AlertStatus(this.apiValue, this.label);

  final String apiValue;
  final String label;

  static AlertStatus fromApi(String value) => AlertStatus.values.firstWhere(
        (s) => s.apiValue == value,
        orElse: () => AlertStatus.active,
      );
}

class Alert {
  const Alert({
    required this.id,
    required this.patientId,
    required this.patientName,
    required this.type,
    required this.severity,
    required this.title,
    required this.message,
    required this.createdAt,
    required this.status,
    this.acknowledgedBy,
    this.resolvedAt,
    this.meta,
  });

  final String id;
  final String patientId;
  final String patientName;
  final AlertType type;
  final AlertSeverity severity;
  final String title;
  final String message;
  final DateTime createdAt;
  final AlertStatus status;
  final String? acknowledgedBy;
  final DateTime? resolvedAt;
  final Map<String, dynamic>? meta;

  bool get isActive => status == AlertStatus.active;
  bool get isResolved => status == AlertStatus.resolved;

  Alert copyWith({
    AlertStatus? status,
    String? acknowledgedBy,
    DateTime? resolvedAt,
  }) =>
      Alert(
        id: id,
        patientId: patientId,
        patientName: patientName,
        type: type,
        severity: severity,
        title: title,
        message: message,
        createdAt: createdAt,
        status: status ?? this.status,
        acknowledgedBy: acknowledgedBy ?? this.acknowledgedBy,
        resolvedAt: resolvedAt ?? this.resolvedAt,
        meta: meta,
      );

  factory Alert.fromJson(Map<String, dynamic> json) => Alert(
        id: (json['id'] ?? json['alert_id']).toString(),
        patientId: json['patient_id'] as String,
        patientName: (json['patient_name'] ?? '') as String,
        type: AlertType.fromApi((json['type'] ?? 'other') as String),
        severity: AlertSeverity.fromApi((json['severity'] ?? 'info') as String),
        title: (json['title'] ?? '') as String,
        // El backend usa 'detail'; conservamos 'message' como alias de compat.
        message: (json['detail'] ?? json['message'] ?? '') as String,
        createdAt: DateTime.parse(json['created_at'] as String),
        status: AlertStatus.fromApi((json['status'] ?? 'active') as String),
        acknowledgedBy: json['acknowledged_by'] as String?,
        resolvedAt: json['resolved_at'] != null
            ? DateTime.parse(json['resolved_at'] as String)
            : null,
        // El backend usa 'payload' (jsonb); 'meta' es el alias de compat del mock.
        meta: (json['payload'] ?? json['meta']) as Map<String, dynamic>?,
      );
}
