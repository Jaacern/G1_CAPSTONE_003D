// La lista de pacientes del medico muestra los numeros de cada uno.
//
// Antes la tarjeta traia nombre, motivo y un chip de color, asi que para
// saber en que iba cada paciente habia que entrar a su ficha, mirar, salir y
// entrar al siguiente. Con dos pacientes es molesto; con ocho es inservible.
import 'package:agecare_app/core/theme/app_theme.dart';
import 'package:agecare_app/features/auth/application/auth_controller.dart';
import 'package:agecare_app/features/auth/domain/models.dart';
import 'package:agecare_app/features/doctor/presentation/doctor_home_screen.dart';
import 'package:agecare_app/features/health/data/vitals_repository.dart';
import 'package:agecare_app/features/patients/data/patients_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

void main() {
  setUpAll(() => initializeDateFormatting('es'));

  Future<void> montar(WidgetTester tester) async {
    // Alto generoso: interesa que los valores esten en el arbol, no medir.
    await tester.binding.setSurfaceSize(const Size(400, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(ProviderScope(
      overrides: [
        patientsRepositoryProvider.overrideWithValue(PatientsRepositoryMock()),
        vitalsRepositoryProvider.overrideWithValue(VitalsRepositoryMock()),
        currentUserProvider.overrideWith((ref) => const User(
              userId: 'u-med',
              fullName: 'Dra. Carmen Orellana',
              email: 'medico@agecare.app',
              memberships: [
                Membership(
                    patientId: 'p-elena',
                    patientName: 'Elena Ramírez',
                    role: RoleType.doctor),
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
        home: const DoctorHomeScreen(),
      ),
    ));
    // Una peticion de vitales por paciente, encima de la lista. El mock
    // demora 250 ms cada una.
    await tester.pump();
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }
  }

  testWidgets('los dos pacientes salen en la lista', (tester) async {
    await montar(tester);

    expect(find.text('Elena Ramírez'), findsOneWidget);
    expect(find.text('José Ramírez'), findsOneWidget);
  });

  testWidgets('se ven los valores de cada paciente sin entrar a su ficha',
      (tester) async {
    await montar(tester);

    // Temperatura de los dos, con su decimal.
    expect(find.text('36.7 °C'), findsNWidgets(2));
    // El oxigeno los distingue: Elena 97, José 91 (bajo el minimo de 92).
    expect(find.text('97 %'), findsOneWidget);
    expect(find.text('91 %'), findsOneWidget);
  });

  testWidgets('el valor fuera de rango queda marcado en la propia lista',
      (tester) async {
    await montar(tester);

    // El semaforo ya decia que algo pasaba con José; esto dice que.
    expect(find.byIcon(Icons.error_rounded), findsAtLeastNWidgets(1));
  });

  testWidgets('la temperatura conserva el decimal y el pulso no lo inventa',
      (tester) async {
    await montar(tester);

    expect(find.text('74 bpm'), findsNWidgets(2));
    expect(find.text('74.0 bpm'), findsNothing);
  });
}
