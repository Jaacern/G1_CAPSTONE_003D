import 'package:agecare_app/core/theme/app_theme.dart';
import 'package:agecare_app/features/health/data/vitals_repository.dart';
import 'package:agecare_app/features/health/presentation/health_screen.dart';
import 'package:agecare_app/features/patients/data/patients_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// La pantalla de Salud en el teléfono más angosto que atendemos (320 dp).
/// Un RenderFlex que no alcanza a entrar revienta la prueba por sí solo, así
/// que acá lo que se busca es que no aparezca la franja de desborde.
void main() {
  testWidgets('las tarjetas de Salud caben en 320 dp', (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(ProviderScope(
      overrides: [
        patientsRepositoryProvider
            .overrideWithValue(PatientsRepositoryMock()),
        vitalsRepositoryProvider.overrideWithValue(VitalsRepositoryMock()),
      ],
      child: MaterialApp(
          theme: AppTheme.light(), home: const Scaffold(body: HealthScreen())),
    ));
    await tester.pumpAndSettle(const Duration(milliseconds: 500));

    expect(find.text('Ritmo cardíaco'), findsOneWidget);
  });
}
