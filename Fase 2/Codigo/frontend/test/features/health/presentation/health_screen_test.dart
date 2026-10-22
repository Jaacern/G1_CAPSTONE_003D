// Pruebas de la pantalla Salud: tarjetas agrupadas por vitales/actividad
// y sus indicadores de estado (AGE-304 / DAC05-62).
//
// Cubre el criterio de aceptación AC1 del ticket: las tarjetas de
// SpO2/FC/Temperatura muestran un indicador de estado según los rangos
// médicos normales, y además el agrupamiento "Vitales" / "Actividad" que
// pide el wireframe (DAC05-60), incluyendo la Temperatura que antes no
// existía en el modelo de datos.
import 'package:agecare_app/core/theme/app_theme.dart';
import 'package:agecare_app/features/auth/domain/models.dart';
import 'package:agecare_app/features/health/data/vitals_repository.dart';
import 'package:agecare_app/features/health/presentation/health_screen.dart';
import 'package:agecare_app/features/patients/application/patients_providers.dart';
import 'package:agecare_app/features/patients/data/patients_repository.dart';
import 'package:agecare_app/features/patients/domain/models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  List<Override> overrides() => [
        patientsRepositoryProvider.overrideWithValue(PatientsRepositoryMock()),
        vitalsRepositoryProvider.overrideWithValue(VitalsRepositoryMock()),
      ];

  testWidgets(
      'agrupa las tarjetas en "Vitales" (FC/SpO2/Temperatura) y "Actividad", como pide el wireframe',
      (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: overrides(),
      child: MaterialApp(
          theme: AppTheme.light(), home: const Scaffold(body: HealthScreen())),
    ));
    await tester.pumpAndSettle(const Duration(milliseconds: 500));

    expect(find.text('Vitales'), findsOneWidget);
    expect(find.text('Actividad'), findsOneWidget);

    // Grupo "Vitales": los 3 signos núcleo del AC1, con la Temperatura que
    // antes faltaba en el modelo de datos.
    expect(find.text('Ritmo cardíaco'), findsOneWidget);
    expect(find.text('Oxígeno (SpO2)'), findsOneWidget);
    expect(find.text('Temperatura'), findsOneWidget);
    expect(find.text('36.7'), findsOneWidget); // 1 decimal, no redondeado

    // Grupo "Actividad": el resto (sueño/pasos) no son vitales núcleo.
    expect(find.text('Sueño'), findsOneWidget);
    expect(find.text('Pasos'), findsOneWidget);

    // "Vitales" se dibuja antes que "Actividad", tal como en el wireframe.
    final vitalesY = tester.getTopLeft(find.text('Vitales')).dy;
    final actividadY = tester.getTopLeft(find.text('Actividad')).dy;
    expect(vitalesY, lessThan(actividadY));
  });

  testWidgets('con valores dentro de rango no muestra el ícono de alerta (AC1)',
      (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: overrides(),
      child: MaterialApp(
          theme: AppTheme.light(), home: const Scaffold(body: HealthScreen())),
    ));
    await tester.pumpAndSettle(const Duration(milliseconds: 500));

    // Elena (auto-seleccionada, 1era de la lista) no simula valores fuera
    // de rango.
    expect(find.byIcon(Icons.error_rounded), findsNothing);
  });

  testWidgets(
      'al cambiar a un paciente con SpO2 fuera de rango, la tarjeta muestra el ícono de alerta (AC1)',
      (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: overrides(),
      child: MaterialApp(
        theme: AppTheme.light(),
        home: Consumer(builder: (context, ref, _) {
          return Scaffold(
            body: Column(
              children: [
                TextButton(
                  key: const Key('switchPatient'),
                  onPressed: () => ref.read(selectedPatientProvider.notifier).select(
                        const PatientCard(
                          patientId: 'p-jose',
                          fullName: 'José Ramírez',
                          role: RoleType.family,
                          wellbeingStatus: WellbeingStatus.warning,
                        ),
                      ),
                  child: const Text('cambiar'),
                ),
                const Expanded(child: HealthScreen()),
              ],
            ),
          );
        }),
      ),
    ));
    await tester.pumpAndSettle(const Duration(milliseconds: 500));

    await tester.tap(find.byKey(const Key('switchPatient')));
    await tester.pumpAndSettle(const Duration(milliseconds: 500));

    // 'p-jose' simula SpO2 91 (bajo el mínimo normal de 92): debe verse el
    // ícono de alerta en su tarjeta, sin refrescar nada a mano (el provider
    // de vitals observa selectedPatientProvider y se reconstruye solo).
    expect(find.byIcon(Icons.error_rounded), findsOneWidget);
  });
}
