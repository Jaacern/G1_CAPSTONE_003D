import 'package:agecare_app/core/theme/app_theme.dart';
import 'package:agecare_app/features/auth/application/auth_controller.dart';
import 'package:agecare_app/features/auth/domain/models.dart';
import 'package:agecare_app/features/medications/data/medications_repository.dart';
import 'package:agecare_app/features/medications/presentation/medications_screen.dart';
import 'package:agecare_app/features/patients/data/patients_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

/// La pestaña de Medicamentos en un teléfono de 320 dp, vista por un familiar
/// (el rol que menos espacio tiene: al título "Plan de medicación" se le suma
/// el chip "Solo lectura", que el cuidador o el médico no ven).
void main() {
  setUpAll(() => initializeDateFormatting('es'));

  testWidgets('el cuerpo de Medicamentos cabe en 320 dp', (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(ProviderScope(
      overrides: [
        patientsRepositoryProvider
            .overrideWithValue(PatientsRepositoryMock()),
        medicationsRepositoryProvider
            .overrideWithValue(MedicationsRepositoryMock()),
        currentUserProvider.overrideWith((ref) => const User(
              userId: 'u-1',
              fullName: 'Benjamín Camus',
              accountType: RoleType.family,
              email: 'familia@agecare.app',
            )),
      ],
      child: MaterialApp(
        theme: AppTheme.light(),
        // El gráfico de adherencia formatea sus ejes por cultura; sin los
        // delegados que usa la app real, fl_chart lanza LocaleDataException
        // antes de llegar al layout que queremos medir.
        locale: const Locale('es'),
        supportedLocales: const [Locale('es')],
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: const Scaffold(body: MedicationsBody()),
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('Plan de medicación'), findsOneWidget);
    expect(find.text('Solo lectura'), findsOneWidget);
  });
}
