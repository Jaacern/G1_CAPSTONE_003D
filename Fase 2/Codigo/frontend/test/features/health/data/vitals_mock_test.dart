import 'package:flutter_test/flutter_test.dart';

import 'package:agecare_app/features/health/data/vitals_repository.dart';
import 'package:agecare_app/features/health/domain/models.dart';

/// El mock de constantes vitales, que es el que se ve en modo demo.
void main() {
  LatestVital fc(List<LatestVital> vitales) =>
      vitales.firstWhere((v) => v.type == VitalType.heartRate);

  test('el rango del paciente manda sobre el médico al pintar el indicador',
      () async {
    final repo = VitalsRepositoryMock();
    // 74 lpm está dentro del rango médico (50–110).
    expect(fc(await repo.getLatest('p-elena')).inRange, isTrue);

    await repo.setThreshold('p-elena', VitalType.heartRate,
        minValue: 30, maxValue: 70);

    // Editado el umbral en Umbrales, la tarjeta de Salud tiene que decir
    // "fuera de rango"; antes el mock miraba sólo la tabla base.
    expect(fc(await repo.getLatest('p-elena')).inRange, isFalse);
  });

  test('el umbral editado se lleva en la serie, no sólo en el último valor',
      () async {
    final repo = VitalsRepositoryMock();
    await repo.setThreshold('p-elena', VitalType.heartRate,
        minValue: 45, maxValue: 95);

    final serie = await repo.getSeries(
      'p-elena',
      VitalType.heartRate,
      from: DateTime(2026, 10, 1),
      to: DateTime(2026, 10, 31),
    );

    expect(serie.threshold?.maxValue, 95);
    expect(serie.threshold?.minValue, 45);
  });

  test('lo editado para un paciente no cambia la ficha del otro', () async {
    final repo = VitalsRepositoryMock();
    await repo.setThreshold('p-elena', VitalType.heartRate, maxValue: 70);

    expect(fc(await repo.getLatest('p-jose')).inRange, isTrue);
  });

  test('un vital sin umbral definido se muestra en rango', () async {
    final repo = VitalsRepositoryMock();
    final pasos = (await repo.getLatest('p-elena'))
        .firstWhere((v) => v.type == VitalType.steps);

    expect(pasos.inRange, isTrue);
  });
}
