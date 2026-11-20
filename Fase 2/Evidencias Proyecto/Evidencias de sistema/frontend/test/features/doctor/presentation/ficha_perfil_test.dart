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

import '../tratamiento_fijo.dart';

void main() {
  setUpAll(() => initializeDateFormatting('es'));

  Future<void> montar(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(ProviderScope(
      overrides: [
        patientsRepositoryProvider.overrideWithValue(PatientsRepositoryMock()),
        tratamientoFijoOverride,
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
    // cinco pestanas) al Resumen.
    expect(find.text('Antecedentes'), findsOneWidget);
    expect(find.text('Hipertensión'), findsOneWidget);
    expect(find.text('Artrosis'), findsOneWidget);
  });

  testWidgets('el nombre y el estado siguen donde estaban', (tester) async {
    await montar(tester);

    expect(find.text('Elena Ramírez'), findsWidgets);
  });

  testWidgets('la franja fija muestra el estado, no la edad ni el sexo',
      (tester) async {
    await montar(tester);

    // Antes era una línea suelta "82 años · Femenino" que no se entendía.
    expect(find.text('Estado'), findsOneWidget);
    expect(find.text('Sin alertas activas'), findsOneWidget);
    expect(find.textContaining(' · Femenino'), findsNothing);
  });

  testWidgets('edad y sexo están en Datos del paciente', (tester) async {
    await montar(tester);

    final datos = tester.getTopLeft(find.text('Datos del paciente')).dy;
    expect(tester.getTopLeft(find.text('Edad')).dy, greaterThan(datos));
    expect(tester.getTopLeft(find.text('Femenino')).dy, greaterThan(datos));
  });

  testWidgets('el perfil completo es un botón con texto en la barra',
      (tester) async {
    await montar(tester);

    final boton = find.widgetWithText(FilledButton, 'Perfil completo');
    expect(boton, findsOneWidget);
    // Arriba, en la barra de título.
    expect(tester.getTopLeft(boton).dy, lessThan(80));
  });

  testWidgets('el resumen va de lo urgente al contexto', (tester) async {
    await montar(tester);

    double y(String t) => tester.getTopLeft(find.text(t)).dy;
    final orden = [
      'Alergias',
      'Signos vitales actuales',
      'Antecedentes',
      'Tratamiento vigente',
      'Adherencia (últimos 7 días)',
      'Contacto de emergencia',
      'Datos del paciente',
    ];
    for (var i = 1; i < orden.length; i++) {
      expect(y(orden[i]), greaterThan(y(orden[i - 1])),
          reason: '${orden[i]} debería ir después de ${orden[i - 1]}');
    }
  });

  testWidgets('el resumen trae la alergia con su gravedad y reacción',
      (tester) async {
    await montar(tester);

    expect(find.text('Alergias'), findsOneWidget);
    expect(find.text('Penicilina · Severa'), findsOneWidget);
    expect(find.text('Reacción: Urticaria generalizada'), findsOneWidget);
  });

  testWidgets('el resumen trae el tratamiento vigente', (tester) async {
    await montar(tester);

    expect(find.text('Tratamiento vigente'), findsOneWidget);
    expect(find.text('Cardiología'), findsOneWidget);
    expect(find.textContaining('Losartán'), findsOneWidget);
    expect(find.textContaining('08:00, 20:00'), findsOneWidget);
    expect(find.textContaining('SOS, solo si se necesita'), findsOneWidget);
  });

  testWidgets('el resumen trae los niveles de riesgo y los datos del paciente',
      (tester) async {
    await montar(tester);

    expect(find.text('Complejidad: Alta'), findsOneWidget);
    expect(find.text('Prioridad: Media'), findsOneWidget);
    expect(find.text('Riesgo CV: Alto'), findsOneWidget);
    expect(find.text('Datos del paciente'), findsOneWidget);
    expect(find.text('5.123.456-1'), findsOneWidget);
    expect(find.text('Fonasa'), findsOneWidget);
    expect(find.text('Los Aromos 1234, La Florida'), findsOneWidget);
    expect(find.text('64,5 kg · IMC 25,8'), findsOneWidget);
    expect(find.textContaining('Dra. Carolina Soto · Medicina general'),
        findsOneWidget);
  });
}
