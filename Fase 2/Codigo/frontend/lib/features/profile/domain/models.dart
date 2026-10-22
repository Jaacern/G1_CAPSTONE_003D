/// Preferencias de notificaciones del usuario (módulo 9 del backend).
///
/// El backend expone exactamente 5 tipos de alerta y, por cada uno, si el
/// push está activado y si está "bloqueado" (las críticas —caída y SOS— no se
/// pueden desactivar). Contrato:
///   GET/PUT /users/me/notification-settings
///   { "items": [ { "alert_type", "push_enabled", "is_locked" }, ... ] }
library;

/// Los 5 tipos de alerta soportados por el backend, con su etiqueta en español.
enum AlertType {
  fall('fall', 'Caídas', 'Detección de caídas del paciente.'),
  vitalOutOfRange(
      'vital_out_of_range', 'Signos fuera de rango',
      'Ritmo, SpO₂ u otros valores fuera de los umbrales.'),
  missedDose('missed_dose', 'Medicación no tomada',
      'Dosis fuera de su ventana de administración.'),
  sos('sos', 'Botón SOS', 'Emergencia activada por el paciente o la cuidadora.'),
  wearableOffline('wearable_offline', 'Wearable sin datos',
      'El dispositivo dejó de enviar lecturas.');

  const AlertType(this.apiValue, this.label, this.description);

  final String apiValue;
  final String label;
  final String description;

  static AlertType fromApi(String v) => AlertType.values
      .firstWhere((t) => t.apiValue == v, orElse: () => AlertType.fall);
}

/// Preferencia de un tipo de alerta.
class NotificationSetting {
  const NotificationSetting({
    required this.alertType,
    required this.pushEnabled,
    required this.isLocked,
  });

  final AlertType alertType;
  final bool pushEnabled;

  /// Las alertas críticas (caída y SOS) no pueden desactivarse.
  final bool isLocked;

  NotificationSetting copyWith({bool? pushEnabled}) => NotificationSetting(
        alertType: alertType,
        pushEnabled: pushEnabled ?? this.pushEnabled,
        isLocked: isLocked,
      );

  factory NotificationSetting.fromJson(Map<String, dynamic> json) =>
      NotificationSetting(
        alertType: AlertType.fromApi(json['alert_type'] as String),
        pushEnabled: (json['push_enabled'] ?? true) as bool,
        isLocked: (json['is_locked'] ?? false) as bool,
      );

  Map<String, dynamic> toJson() => {
        'alert_type': alertType.apiValue,
        'push_enabled': pushEnabled,
      };
}

/// Conjunto completo de preferencias de notificación.
class NotificationSettings {
  const NotificationSettings({this.items = const []});

  final List<NotificationSetting> items;

  NotificationSettings copyWithToggled(AlertType type, bool enabled) {
    return NotificationSettings(
      items: [
        for (final it in items)
          it.alertType == type ? it.copyWith(pushEnabled: enabled) : it,
      ],
    );
  }

  factory NotificationSettings.fromJson(Map<String, dynamic> json) =>
      NotificationSettings(
        items: ((json['items'] ?? const []) as List)
            .map((e) => NotificationSetting.fromJson(e as Map<String, dynamic>))
            .toList(),
      );

  /// Cuerpo del PUT: solo { items: [{alert_type, push_enabled}] }.
  Map<String, dynamic> toJson() =>
      {'items': items.map((e) => e.toJson()).toList()};
}
