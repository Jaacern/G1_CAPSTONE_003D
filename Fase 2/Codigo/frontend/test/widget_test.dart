import 'package:flutter_test/flutter_test.dart';

import 'package:agecare_app/core/config/app_config.dart';

void main() {
  test('AppConfig expone el nombre de la app', () {
    expect(AppConfig.appName, 'AgeCare');
  });
}
