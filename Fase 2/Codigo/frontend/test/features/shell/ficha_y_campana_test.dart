import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:agecare_app/core/theme/app_theme.dart';
import 'package:agecare_app/core/validation/identity_validators.dart';
import 'package:agecare_app/features/auth/domain/models.dart';
import 'package:agecare_app/features/patients/application/patients_providers.dart';
import 'package:agecare_app/features/patients/data/patients_repository.dart';
import 'package:agecare_app/features/patients/domain/models.dart';
import 'package:agecare_app/features/shell/main_shell.dart';

void main() {
  test('las alertas ya no son una pestaña; la Ficha sí, para familia y cuidadora',
      () {
    for (final tabs in [MainShell.familyTabs, MainShell.caregiverTabs]) {
      final etiquetas = tabs.map((t) => t.label).toList();
      expect(etiquetas, isNot(contains('Alertas')));
      expect(etiquetas, contains('Ficha'));
    }
    // Los atajos del inicio familiar se calculan desde la lista.
    expect(MainShell.familyTabs[ShellTabs.familia('Salud')].label, 'Salud');
    expect(
        MainShell.familyTabs[ShellTabs.familia('Mensajes')].label, 'Mensajes');
  });

  testWidgets('la campana muestra cuántas alertas activas hay', (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        myPatientsProvider.overrideWith((ref) async => const [
              PatientCard(
                patientId: 'p1',
                fullName: 'Elena',
                role: RoleType.caregiver,
                wellbeingStatus: WellbeingStatus.warning,
                activeAlertsCount: 2,
              ),
              PatientCard(
                patientId: 'p2',
                fullName: 'Luis',
                role: RoleType.caregiver,
                wellbeingStatus: WellbeingStatus.attention,
                activeAlertsCount: 1,
              ),
            ]),
        patientsRepositoryProvider.overrideWithValue(PatientsRepositoryMock()),
      ],
      child: MaterialApp(
          theme: AppTheme.light(),
          home: const Scaffold(body: Center(child: AlertsBell()))),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    expect(find.byKey(const Key('alertsBell')), findsOne);
    expect(find.bySemanticsLabel(RegExp(r'^Alertas, \d+ activas?$')),
        findsOne);
  });

  test('el catálogo de enfermedades se lee aunque venga con "code"', () {
    final c = ConditionDetail.fromJson(
        {'code': 'hipertension', 'label': 'Hipertensión', 'system': 'cardiovascular'});
    expect(c.condition, 'hipertension');
    expect(c.label, 'Hipertensión');
    // La ficha sigue mandando "condition".
    expect(ConditionDetail.fromJson({'condition': 'epoc'}).label, 'epoc');
  });

  test('alergia escrita a mano: se valida', () {
    expect(validateAllergenName('Vitamina B12'), isNull);
    expect(validateAllergenName('Contraste yodado (IV)'), isNull);
    expect(validateAllergenName(''), isNotNull);
    expect(validateAllergenName('1234'), isNotNull);
    expect(validateAllergenName('<script>'), isNotNull);
    expect(validateAllergenName('k'), isNotNull);
  });
}
