// Los signos vitales del resumen del dia, tal como llegan de la API.
import 'package:agecare_app/features/home/domain/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('cada tipo de signo tiene su nombre en espanol', () {
    expect(VitalMeta.of('heart_rate').label, 'Ritmo cardíaco');
    expect(VitalMeta.of('blood_pressure').label, 'Presión arterial');
  });

  test('un tipo desconocido no rompe la pantalla', () {
    expect(VitalMeta.of('peso').label, 'Signo');
  });

  test('el motivo del semaforo se lee sin codigos internos', () {
    expect(humanizeReason('heart_rate fuera de rango (128.0 bpm)'),
        'Ritmo cardíaco fuera de rango (128 bpm)');
    // Los decimales que importan se conservan.
    expect(humanizeReason('temperature 37.5'), 'Temperatura 37.5');
  });
}
