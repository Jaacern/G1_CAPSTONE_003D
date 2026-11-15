// La adherencia a la medicacion del dia (medications_today).
import 'package:agecare_app/features/home/domain/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('es el porcentaje de dosis tomadas sobre el total', () {
    const hoy = MedicationsToday(taken: 3, pending: 0, missed: 1);

    expect(hoy.total, 4);
    expect(hoy.adherencePct, 75);
  });

  test('sin dosis del dia la adherencia es completa', () {
    expect(const MedicationsToday().adherencePct, 100);
  });

  test('se redondea al entero mas cercano', () {
    // 2 de 3 = 66,67 %
    expect(const MedicationsToday(taken: 2, pending: 1).adherencePct, 67);
  });

  test('se lee de la API con la proxima dosis', () {
    final hoy = MedicationsToday.fromJson(const {
      'taken': 1,
      'pending': 2,
      'missed': 0,
      'next_dose': '2026-11-12T20:00:00Z',
    });

    expect(hoy.pending, 2);
    expect(hoy.nextDose, isNotNull);
  });

  test('si la API no manda conteos, el dia queda en cero', () {
    final hoy = MedicationsToday.fromJson(const {});

    expect(hoy.total, 0);
    expect(hoy.nextDose, isNull);
    expect(hoy.adherencePct, 100);
  });
}
