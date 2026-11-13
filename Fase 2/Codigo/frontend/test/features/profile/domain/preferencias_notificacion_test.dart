// El conjunto de preferencias que se guarda con PUT
// /users/me/notification-settings.
import 'package:agecare_app/features/profile/domain/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final ajustes = NotificationSettings.fromJson(const {
    'items': [
      {'alert_type': 'fall', 'push_enabled': true, 'is_locked': true},
      {'alert_type': 'missed_dose', 'push_enabled': true, 'is_locked': false},
    ],
  });

  test('apagar un tipo cambia solo ese', () {
    final nuevos = ajustes.copyWithToggled(AlertType.missedDose, false);

    expect(nuevos.items[1].pushEnabled, isFalse);
    expect(nuevos.items[0].pushEnabled, isTrue);
    expect(ajustes.items[1].pushEnabled, isTrue); // el original no cambia
  });

  test('el cuerpo del PUT lleva solo tipo y si esta activado', () {
    expect(ajustes.toJson(), {
      'items': [
        {'alert_type': 'fall', 'push_enabled': true},
        {'alert_type': 'missed_dose', 'push_enabled': true},
      ],
    });
  });

  test('sin items queda vacio', () {
    expect(NotificationSettings.fromJson(const {}).items, isEmpty);
  });
}
