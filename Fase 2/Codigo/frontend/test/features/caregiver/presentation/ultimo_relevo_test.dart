// La ultima nota de relevo en el inicio de la cuidadora (RF-70): lo primero
// que lee quien llega al turno.
import 'package:agecare_app/core/theme/app_theme.dart';
import 'package:agecare_app/features/auth/application/auth_controller.dart';
import 'package:agecare_app/features/auth/domain/models.dart';
import 'package:agecare_app/features/caregiver/data/caregiver_repository.dart';
import 'package:agecare_app/features/caregiver/domain/models.dart';
import 'package:agecare_app/features/caregiver/presentation/caregiver_home_screen.dart';
import 'package:agecare_app/features/home/data/dashboard_repository.dart';
import 'package:agecare_app/features/medications/data/medications_repository.dart';
import 'package:agecare_app/features/patients/data/patients_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

void main() {
  setUpAll(() => initializeDateFormatting('es'));

  Future<void> montar(
    WidgetTester tester, {
    CaregiverRepository? cuidado,
    double ancho = 400,
  }) async {
    await tester.binding.setSurfaceSize(Size(ancho, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(ProviderScope(
      overrides: [
        patientsRepositoryProvider.overrideWithValue(PatientsRepositoryMock()),
        medicationsRepositoryProvider
            .overrideWithValue(MedicationsRepositoryMock()),
        caregiverRepositoryProvider
            .overrideWithValue(cuidado ?? CaregiverRepositoryMock()),
        dashboardRepositoryProvider
            .overrideWithValue(DashboardRepositoryMock()),
        currentUserProvider.overrideWith((ref) => const User(
              userId: 'u-cuid',
              fullName: 'Marisol Tapia',
              accountType: RoleType.caregiver,
              email: 'cuidadora@agecare.app',
              memberships: [
                Membership(
                    patientId: 'p-elena',
                    patientName: 'Elena Ramírez',
                    role: RoleType.caregiver),
              ],
            )),
      ],
      child: MaterialApp(
        theme: AppTheme.light(),
        locale: const Locale('es'),
        supportedLocales: const [Locale('es')],
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: const CaregiverHomeScreen(),
      ),
    ));
    await tester.pump();
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }
  }

  testWidgets('muestra quien dejo la ultima nota y que dijo', (tester) async {
    await montar(tester);

    // La nota de ejemplo del modo de demostracion.
    expect(find.text('Último relevo · Carla Rivas'), findsOneWidget);
    expect(find.textContaining('Turno tranquilo'), findsOneWidget);
  });

  testWidgets('sin notas de relevo no ocupa lugar', (tester) async {
    await montar(tester, cuidado: _SinRelevos());

    expect(find.textContaining('Último relevo'), findsNothing);
    // Lo demas del inicio sigue igual.
    expect(find.text('Medicación de hoy'), findsOneWidget);
  });

  testWidgets('la tarjeta cabe en 320 dp', (tester) async {
    await montar(tester, ancho: 320);

    // Un RenderFlex que no entra revienta la prueba por si solo.
    expect(find.text('Último relevo · Carla Rivas'), findsOneWidget);
  });
}

class _SinRelevos extends CaregiverRepositoryMock {
  @override
  Future<List<HandoverNote>> listHandoverNotes(String patientId) async =>
      const [];
}
