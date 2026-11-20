// El payload de una alerta lo escribe el backend en claves internas. Estas
// pruebas fijan cómo se traduce a la ficha que lee la familia.
import 'package:agecare_app/features/alerts/presentation/alert_detail_screen.dart';
import 'package:flutter_test/flutter_test.dart';

String? _valor(List<AlertDetailRow> filas, String etiqueta) {
  for (final f in filas) {
    if (f.label == etiqueta) return f.value;
  }
  return null;
}

void main() {
  group('alerta de vitales del backend', () {
    final filas = alertMetaRows({
      'reading_id': '5f6a7b8c-1d2e-4f3a-9b8c-7d6e5f4a3b2c',
      'type': 'heart_rate',
      'value': 124.0,
      'min_value': 60.0,
      'max_value': 120.0,
      'measured_at': '2026-11-01T10:15:00+00:00',
    });

    test('traduce el signo y le pone unidad a la lectura', () {
      expect(_valor(filas, 'Signo vital'), 'Ritmo cardíaco');
      expect(_valor(filas, 'Lectura'), '124 bpm');
    });

    test('muestra el rango configurado en vez de min_value y max_value', () {
      expect(_valor(filas, 'Rango configurado'), '60–120 bpm');
      expect(filas.any((f) => f.label == 'min_value'), isFalse);
      expect(filas.any((f) => f.label == 'max_value'), isFalse);
    });

    test('no filtra el id de la lectura ni la fecha en formato ISO', () {
      expect(filas.any((f) => f.value.contains('5f6a7b8c')), isFalse);
      expect(_valor(filas, 'Medida'), isNot(contains('T10:15:00')));
      expect(_valor(filas, 'Medida'),
          matches(RegExp(r'^\d{2}/\d{2} \d{2}:\d{2}$')));
    });

    test('un valor con decimales no se redondea', () {
      expect(
        _valor(
            alertMetaRows({'type': 'temperature', 'value': 36.7}), 'Lectura'),
        '36.7 °C',
      );
    });
  });

  test('la alerta demo describe el vital con sus propias claves', () {
    final filas = alertMetaRows({
      'vital': 'heart_rate',
      'value': 124,
      'unit': 'ppm',
    });

    expect(_valor(filas, 'Signo vital'), 'Ritmo cardíaco');
    expect(_valor(filas, 'Lectura'), '124 ppm');
  });

  test('la confianza se lee en porcentaje', () {
    final filas = alertMetaRows({
      'location': 'Domicilio',
      'confidence': 0.88,
    });

    expect(_valor(filas, 'Ubicación'), 'Domicilio');
    expect(_valor(filas, 'Confianza'), '88 %');
  });

  test('una clave que no está en el diccionario se desenmascara', () {
    final filas = alertMetaRows({'battery_pct': 12});

    expect(_valor(filas, 'battery pct'), '12');
  });

  test('sin payload no hay filas de detalle', () {
    expect(alertMetaRows(null), isEmpty);
    expect(alertMetaRows({}), isEmpty);
  });
}
