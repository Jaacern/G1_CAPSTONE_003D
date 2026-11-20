// Quitar a alguien del circulo de cuidado (RF-14), en el modo de
// demostracion, que tiene que portarse igual que la API.
import 'package:agecare_app/core/network/api_client.dart';
import 'package:agecare_app/features/patients/data/patients_repository.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('el miembro quitado ya no aparece en el equipo', () async {
    final repo = PatientsRepositoryMock();
    expect((await repo.listMembers('p-elena')).map((m) => m.userId),
        contains('u2'));

    await repo.removeMember('p-elena', 'u2');

    final equipo = await repo.listMembers('p-elena');
    expect(equipo.map((m) => m.userId), isNot(contains('u2')));
    expect(equipo.map((m) => m.userId), contains('u1'));
  });

  test('al administrador no se le puede quitar', () async {
    final repo = PatientsRepositoryMock();

    await expectLater(
      repo.removeMember('p-elena', 'u1'),
      throwsA(isA<ApiException>()
          .having((e) => e.code, 'code', 'CANNOT_REMOVE_OWNER')),
    );
    expect((await repo.listMembers('p-elena')).map((m) => m.userId),
        contains('u1'));
  });
}
