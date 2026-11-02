import 'package:agecare_app/core/theme/app_theme.dart';
import 'package:agecare_app/features/caregiver/data/caregiver_repository.dart';
import 'package:agecare_app/features/caregiver/presentation/caregiver_log_screen.dart';
import 'package:agecare_app/features/caregiver/presentation/caregiver_tasks_screen.dart';
import 'package:agecare_app/features/patients/data/patients_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

/// Las dos pestañas que más usa la cuidadora en la demo, en un teléfono de
/// 320 dp. Tareas y bitácora son listas de tarjetas con etiqueta de categoría
/// a la izquierda y hora o estado a la derecha: si la etiqueta no cede ancho,
/// la hora se sale de la pantalla.
void main() {
  setUpAll(() => initializeDateFormatting('es'));

  List<Override> overrides() => [
        patientsRepositoryProvider
            .overrideWithValue(PatientsRepositoryMock()),
        caregiverRepositoryProvider.overrideWithValue(CaregiverRepositoryMock()),
      ];

  Future<void> montar(WidgetTester tester, Widget screen) async {
    await tester.binding.setSurfaceSize(const Size(320, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(ProviderScope(
      overrides: overrides(),
      child: MaterialApp(
        theme: AppTheme.light(),
        locale: const Locale('es'),
        supportedLocales: const [Locale('es')],
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: screen,
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('las tarjetas de tareas caben en 320 dp', (tester) async {
    await montar(tester, const CaregiverTasksScreen());

    expect(find.text('Medicación del mediodía'), findsOneWidget);
  });

  testWidgets('las observaciones de la bitácora caben en 320 dp',
      (tester) async {
    await montar(tester, const CaregiverLogScreen());

    expect(find.textContaining('Desayunó bien'), findsOneWidget);
  });
}
