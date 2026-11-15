import 'package:agecare_app/features/medications/data/treatments_repository.dart';
import 'package:agecare_app/features/medications/domain/treatment.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('un tratamiento nuevo reemplaza al vigente de su especialidad',
      () async {
    final repo = TreatmentsRepositoryMock();
    final antes = await repo.getTreatments('p1');
    expect(antes.vigentes, hasLength(1));

    await repo.createTreatment('p1', specialty: 'general', items: [
      TreatmentItemDraft(
          name: 'Paracetamol',
          doseAmount: 500,
          doseUnit: 'mg',
          times: ['09:00']),
    ]);

    final despues = await repo.getTreatments('p1', history: true);
    final general = despues.bySpecialty.firstWhere((g) => g.specialty == 'general');
    expect(general.current!.items.single.name, 'Paracetamol');
    expect(general.history, hasLength(1), reason: 'el anterior queda de histórico');
  });

  test('otra especialidad convive con la vigente de medicina general',
      () async {
    final repo = TreatmentsRepositoryMock();
    await repo.createTreatment('p1', specialty: 'cardiologia', items: [
      TreatmentItemDraft(
          name: 'Enalapril',
          doseAmount: 10,
          doseUnit: 'mg',
          times: ['08:00']),
    ]);
    final b = await repo.getTreatments('p1');
    expect(b.vigentes.map((g) => g.specialty),
        containsAll(['general', 'cardiologia']));
  });
}
