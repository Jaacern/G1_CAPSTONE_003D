// Las preferencias de notificacion por tipo de alerta.
import 'package:agecare_app/features/profile/domain/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('los cinco tipos de la API tienen su nombre en espanol', () {
    expect(AlertType.values, hasLength(5));
    expect(AlertType.fromApi('missed_dose').label, 'Medicación no tomada');
    expect(AlertType.fromApi('wearable_offline').label, 'Wearable sin datos');
  });

  test('una preferencia se lee y se envia con los nombres de la API', () {
    final s = NotificationSetting.fromJson(const {
      'alert_type': 'sos',
      'push_enabled': true,
      'is_locked': true,
    });

    expect(s.alertType, AlertType.sos);
    expect(s.isLocked, isTrue);
    // is_locked lo decide el servidor: no se manda de vuelta.
    expect(s.toJson(), {'alert_type': 'sos', 'push_enabled': true});
  });
}
