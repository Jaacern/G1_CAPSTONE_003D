import 'package:flutter_test/flutter_test.dart';

import 'package:agecare_app/features/medications/data/medications_repository.dart';
import 'package:agecare_app/features/medications/domain/models.dart';

/// 6.6 (`POST /doses/{dose_id}/log`) tiene reglas de cuerpo propias y distintas
/// del historial que devuelve. Estas pruebas dejan por escrito qué viaja en
/// cada caso para que un cambio de contrato rompa acá y no en el teléfono.
void main() {
  final prevista = DateTime(2026, 11, 1, 8, 0);

  group('cuerpoLogDosis', () {
    test('taken manda administered_at y nada de motivo', () {
      final cuerpo = cuerpoLogDosis(DoseStatus.taken, ahora: prevista);

      expect(cuerpo['status'], 'taken');
      expect(cuerpo['administered_at'], prevista.toIso8601String());
      expect(cuerpo.containsKey('reason'), isFalse);
      expect(cuerpo.containsKey('postponed_until'), isFalse);
    });

    test('postponed exige postponed_until', () {
      final hasta = prevista.add(const Duration(hours: 1));
      final cuerpo = cuerpoLogDosis(DoseStatus.postponed,
          postponedUntil: hasta, ahora: prevista);

      expect(cuerpo['status'], 'postponed');
      expect(cuerpo['postponed_until'], hasta.toIso8601String());
      expect(cuerpo.containsKey('administered_at'), isFalse);
    });

    test('postponed sin hora propuesta cae en la hora de referencia', () {
      final cuerpo = cuerpoLogDosis(DoseStatus.postponed, ahora: prevista);

      expect(cuerpo['postponed_until'], prevista.toIso8601String());
    });

    test('missed viaja siempre con reason: sin él el backend responde 400', () {
      final cuerpo =
          cuerpoLogDosis(DoseStatus.missed, note: 'Se durmió', ahora: prevista);

      expect(cuerpo['status'], 'missed');
      expect(cuerpo['reason'], 'Se durmió');
    });

    test('missed sin motivo igual manda la clave, vacía', () {
      final cuerpo = cuerpoLogDosis(DoseStatus.missed, ahora: prevista);

      expect(cuerpo.containsKey('reason'), isTrue);
      expect(cuerpo['reason'], '');
    });

    test('el motivo se recorta', () {
      final cuerpo = cuerpoLogDosis(DoseStatus.missed,
          note: '  estaba dormida  ', ahora: prevista);

      expect(cuerpo['reason'], 'estaba dormida');
    });

    test('skipped se traduce a missed: 6.6 no lo admite como estado', () {
      final cuerpo = cuerpoLogDosis(DoseStatus.skipped,
          note: 'sin ganas', ahora: prevista);

      expect(cuerpo['status'], 'missed');
      expect(cuerpo['reason'], 'sin ganas');
    });
  });

  group('DoseStatus', () {
    test('postponed se lee del historial y tiene etiqueta propia', () {
      expect(DoseStatus.fromApi('postponed'), DoseStatus.postponed);
      expect(DoseStatus.postponed.label, 'Pospuesta');
    });

    test('skipped sigue leyéndose aunque no se pueda enviar',
        () => expect(DoseStatus.fromApi('skipped'), DoseStatus.skipped));

    test('un estado desconocido no rompe la lista',
        () => expect(DoseStatus.fromApi('tomada_hoy'), DoseStatus.pending));
  });
}
