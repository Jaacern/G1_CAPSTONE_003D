// Los accesos al trabajo de la cuidadora desde su pantalla de inicio.
//
// Mi turno, Tareas, Bitacora y Reportes apuntan a cuatro pantallas que
// existian sin ruta y sin ningun widget que las instanciara. Una cuidadora
// no podia abrirlas, y con ellas se caian el check-in, la observacion, el
// incidente y el relevo, cuyos unicos botones viven adentro.
import 'package:agecare_app/core/theme/app_theme.dart';
import 'package:agecare_app/features/auth/application/auth_controller.dart';
import 'package:agecare_app/features/auth/domain/models.dart';
import 'package:agecare_app/features/caregiver/data/caregiver_repository.dart';
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

  Future<void> montar(WidgetTester tester, {double ancho = 400}) async {
    await tester.binding.setSurfaceSize(Size(ancho, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(ProviderScope(
      overrides: [
        patientsRepositoryProvider.overrideWithValue(PatientsRepositoryMock()),
        medicationsRepositoryProvider
            .overrideWithValue(MedicationsRepositoryMock()),
        caregiverRepositoryProvider
            .overrideWithValue(CaregiverRepositoryMock()),
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

  testWidgets('los cuatro accesos estan en su inicio', (tester) async {
    await montar(tester);

    expect(find.text('Mi turno'), findsOneWidget);
    expect(find.text('Tareas'), findsOneWidget);
    expect(find.text('Bitácora'), findsOneWidget);
    expect(find.text('Reportes'), findsOneWidget);
  });

  testWidgets('siguen estando los remedios, que es su trabajo diario',
      (tester) async {
    await montar(tester);

    // Reemplazar su Hoy por la pantalla del turno le habria quitado el
    // registro de dosis, porque no existe una ruta de medicamentos suelta.
    expect(find.text('Medicación de hoy'), findsOneWidget);
  });

  testWidgets('los cuatro accesos caben en 320 dp', (tester) async {
    await montar(tester, ancho: 320);

    // Un RenderFlex que no entra revienta la prueba por si solo.
    expect(find.text('Mi turno'), findsOneWidget);
  });
}
