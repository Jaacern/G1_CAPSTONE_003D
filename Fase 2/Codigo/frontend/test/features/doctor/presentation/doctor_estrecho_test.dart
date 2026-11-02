import 'package:agecare_app/core/theme/app_theme.dart';
import 'package:agecare_app/features/auth/application/auth_controller.dart';
import 'package:agecare_app/features/auth/domain/models.dart';
import 'package:agecare_app/features/caregiver/data/caregiver_repository.dart';
import 'package:agecare_app/features/doctor/presentation/doctor_home_screen.dart';
import 'package:agecare_app/features/doctor/presentation/doctor_patient_screen.dart';
import 'package:agecare_app/features/health/data/vitals_repository.dart';
import 'package:agecare_app/features/medications/data/medications_repository.dart';
import 'package:agecare_app/features/patients/data/patients_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

/// Las dos pantallas del rol médico en un teléfono de 320 dp. La ficha del
/// paciente es la que más filas comprimidas tiene: signo vital + unidad +
/// ícono de alerta en la misma línea, y receta con dos botones a la derecha.
void main() {
  setUpAll(() => initializeDateFormatting('es'));

  Future<void> montar(WidgetTester tester, Widget screen) async {
    await tester.binding.setSurfaceSize(const Size(320, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(ProviderScope(
      overrides: [
        patientsRepositoryProvider
            .overrideWithValue(PatientsRepositoryMock()),
        vitalsRepositoryProvider.overrideWithValue(VitalsRepositoryMock()),
        medicationsRepositoryProvider
            .overrideWithValue(MedicationsRepositoryMock()),
        caregiverRepositoryProvider
            .overrideWithValue(CaregiverRepositoryMock()),
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
        home: screen,
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('la lista de pacientes del médico cabe en 320 dp',
      (tester) async {
    await montar(tester, const DoctorHomeScreen());

    expect(find.text('Elena Ramírez'), findsOneWidget);
  });

  testWidgets('la ficha clínica del médico cabe en 320 dp', (tester) async {
    await montar(tester, const DoctorPatientScreen(patientId: 'p-elena'));

    expect(find.text('Ritmo cardíaco'), findsOneWidget);
  });
}
