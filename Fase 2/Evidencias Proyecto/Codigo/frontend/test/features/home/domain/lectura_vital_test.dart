// Una lectura de signo vital (item de latest_vitals).
import 'package:agecare_app/features/home/domain/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('un valor entero se muestra sin ".0"', () {
    final r = VitalReading.fromJson(const {
      'type': 'heart_rate',
      'value': 72.0,
      'unit': 'bpm',
      'measured_at': '2026-11-12T10:00:00Z',
      'in_range': true,
    });

    expect(r.value, '72');
    expect(r.display, '72 bpm');
    expect(r.label, 'Ritmo cardíaco');
    expect(r.measuredAt, isNotNull);
  });

  test('los decimales que importan se mantienen', () {
    final r = VitalReading.fromJson(const {
      'type': 'temperature',
      'value': 37.8,
      'unit': '°C',
      'in_range': false,
    });

    expect(r.value, '37.8');
    expect(r.inRange, isFalse);
    expect(r.measuredAt, isNull);
  });

  test('sin unidad se muestra solo el valor', () {
    final r = VitalReading.fromJson(const {'type': 'steps', 'value': 3500});

    expect(r.display, '3500');
    expect(r.inRange, isTrue); // si la API no lo dice, se asume en rango
  });
}
