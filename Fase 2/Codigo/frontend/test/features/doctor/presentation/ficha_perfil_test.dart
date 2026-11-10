// La cabecera de la ficha clinica: quien es el paciente.
//
// Sin la edad, un valor vital no se puede interpretar. Cincuenta y cuatro
// latidos por minuto son bradicardia a los cincuenta anos y pueden ser
// normales a los noventa, asi que mostrar el pulso sin la edad obliga al
// profesional a buscar el dato por otro lado antes de decidir. Lo mismo con
// las enfermedades de base.
import 'package:agecare_app/core/theme/app_theme.dart';
import 'package:agecare_app/features/auth/application/auth_controller.dart';
import 'package:agecare_app/features/auth/domain/models.dart';
import 'package:agecare_app/features/caregiver/data/caregiver_repository.dart';
import 'package:agecare_app/features/doctor/presentation/doctor_patient_screen.dart';
import 'package:agecare_app/features/health/data/vitals_repository.dart';
import 'package:agecare_app/features/medications/data/medications_repository.dart';
import 'package:agecare_app/features/patients/data/patients_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

void main() {
  setUpAll(() => initializeDateFormatting('es'));

  Future<void> montar(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(ProviderScope(
      overrides: [
        patientsRepositoryProvider.overrideWithValue(PatientsRepositoryMock()),
        vitalsRepositoryProvider.overrideWithValue(VitalsRepositoryMock()),
        medicationsRepositoryProvider
            .overrideWithValue(MedicationsRepositoryMock()),
        caregiverRepositoryProvider
            .overrideWithValue(CaregiverRepositoryMock()),
        currentUserProvider.overrideWith((ref) => const User(
              userId: 'u-med',
              fullName: 'Dra. Carmen Orellana',
              accountType: RoleType.doctor,
              doctorVerified: true,
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
        home: const DoctorPatientScreen(patientId: 'p-elena'),
      ),
    ));
    await tester.pump();
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }
  }

  testWidgets('la cabecera muestra la edad del paciente', (tester) async {
    await montar(tester);

    // Elena nacio en marzo de 1948. La edad se calcula, no se guarda, asi
    // que se afirma el formato y no un numero que caduca cada marzo.
    expect(find.textContaining(RegExp(r'\d+ años')), findsOneWidget);
  });

  testWidgets('la cabecera muestra el sexo en palabras', (tester) async {
    await montar(tester);

    // La base guarda una sola letra. "F" no es algo que se muestre a nadie.
    expect(find.textContaining('Femenino'), findsOneWidget);
    expect(find.textContaining('F ·'), findsNothing);
  });

  testWidgets('las enfermedades de base salen en el resumen', (tester) async {
    await montar(tester);

    // El detalle clinico se movio de la cabecera fija (que se repetia en las
    // cinco pestanas) al Resumen. El rotulo va en mayusculas.
    expect(find.text('ANTECEDENTES'), findsOneWidget);
    expect(find.text('Hipertensión'), findsOneWidget);
    expect(find.text('Artrosis'), findsOneWidget);
  });

  testWidgets('el nombre y el estado siguen donde estaban', (tester) async {
    await montar(tester);

    expect(find.text('Elena Ramírez'), findsWidgets);
  });
}
