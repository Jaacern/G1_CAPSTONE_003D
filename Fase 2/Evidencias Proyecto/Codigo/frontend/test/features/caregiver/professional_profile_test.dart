import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:agecare_app/core/network/api_client.dart';
import 'package:agecare_app/features/caregiver/data/caregiver_repository.dart';
import 'package:agecare_app/features/caregiver/data/professional_profile_repository.dart';
import 'package:agecare_app/features/caregiver/domain/professional_profile.dart';
import 'package:agecare_app/features/caregiver/presentation/professional_profile_screen.dart';

void main() {
  group('reglas de publicación (modo de prueba, igual que el servidor)', () {
    test('publicar sin RUT ni comunas se rechaza y dice qué falta', () async {
      final repo = ProfessionalProfileRepositoryMock();
      const incompleto = ProfessionalProfile(
        firstName: 'Marta',
        lastName: 'Pérez',
        email: 'm@t.cl',
        headline: 'Cuidadora',
        bio: 'Corta',
        languages: ['es'],
      );
      await expectLater(
        repo.save(incompleto, published: true),
        throwsA(isA<ApiException>()
            .having((e) => e.code, 'code', 'PROFILE_INCOMPLETE')
            .having((e) => e.message, 'message', contains('tu rut'))),
      );
      final faltan = ProfessionalProfileRepositoryMock.faltantes(incompleto);
      expect(faltan, containsAll(['Tu RUT', 'Al menos una comuna donde trabajas']));
    });

    test('un perfil completo se publica y se puede retirar', () async {
      final repo = ProfessionalProfileRepositoryMock();
      final actual = await repo.get();
      expect(actual.missingForPublish, isEmpty);

      final publicado = await repo.save(actual, published: true);
      expect(publicado.status, ProfileStatus.published);

      final retirado = await repo.save(publicado, published: false);
      expect(retirado.status, ProfileStatus.draft);
    });
  });

  test('el informe de 30 días es Premium: en plan gratuito responde 402',
      () async {
    final repo = CaregiverRepositoryMock();
    await expectLater(
      repo.getReport(days: 30),
      throwsA(isA<ApiException>()
          .having((e) => e.code, 'code', 'PREMIUM_REQUIRED')),
    );
    final semana = await repo.getReport();
    expect(semana.weeklyTasks, hasLength(7));

    await repo.upgradePlan();
    expect((await repo.getReport(days: 30)).weeklyTasks, hasLength(30));
    expect((await repo.getReport(days: 90)).weeklyTasks, hasLength(13));
  });

  testWidgets('la pantalla muestra identidad separada, RUT y el estado',
      (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        professionalProfileRepositoryProvider
            .overrideWithValue(ProfessionalProfileRepositoryMock()),
      ],
      child: const MaterialApp(home: ProfessionalProfileScreen()),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('Borrador: las familias aún no te ven'), findsOne);
    expect(find.text('Datos personales'), findsOne);
    expect(find.widgetWithText(TextFormField, 'Nombre'), findsOne);
    expect(find.widgetWithText(TextFormField, 'Segundo apellido (opcional)'),
        findsOne);
    expect(find.text('15.234.567-4'), findsOne);
  });
}
