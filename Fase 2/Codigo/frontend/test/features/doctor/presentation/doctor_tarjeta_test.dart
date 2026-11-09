// La tarjeta del paciente en la lista del medico.
//
// Con dos "Ramirez" en la lista, el nombre solo no alcanza para saber a quien
// se mira. La tarjeta trae lo que lo identifica (edad, sexo, RUT, domicilio),
// lo que no se puede pasar por alto (alergias, enfermedades cronicas) y cuando
// fue la ultima lectura de sus vitales.
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

  Future<void> montar(WidgetTester tester, {double ancho = 400}) async {
    await tester.binding.setSurfaceSize(Size(ancho, 1600));
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
    await tester.pump();
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }
  }

  testWidgets('la tarjeta dice edad, sexo y RUT para no confundir homonimos',
      (tester) async {
    await montar(tester);

    expect(find.text('78 años · Femenino · RUT 5.123.456-K'), findsOneWidget);
    expect(find.text('81 años · Masculino'), findsOneWidget);
  });

  testWidgets('la tarjeta muestra el domicilio', (tester) async {
    await montar(tester);

    expect(find.text('Los Aromos 1234, La Florida'), findsOneWidget);
    expect(find.text('Pasaje Los Olmos 55, Maipú'), findsOneWidget);
  });

  testWidgets('una alergia grave se ve en rojo', (tester) async {
    await montar(tester);

    final texto = tester.widget<Text>(find.text('Alergias: Penicilina'));
    expect(texto.style?.color, AppColors.critical);
  });

  testWidgets('las enfermedades cronicas salen con su nombre', (tester) async {
    await montar(tester);

    expect(find.text('Crónico: Hipertensión arterial (HTA) · Artrosis'),
        findsOneWidget);
    expect(find.text('Crónico: Diabetes mellitus tipo 2 (DM2)'), findsOneWidget);
  });

  testWidgets('prioridad y complejidad salen como etiquetas', (tester) async {
    await montar(tester);

    expect(find.text('Prioridad baja'), findsOneWidget);
    expect(find.text('Complejidad alta'), findsOneWidget);
  });

  testWidgets('sin datos clinicos no aparecen lineas vacias', (tester) async {
    await montar(tester);

    // Jose no tiene alergias ni prioridad: solo la tarjeta de Elena las trae.
    expect(find.textContaining('Alergias:'), findsOneWidget);
    expect(find.textContaining('Prioridad'), findsOneWidget);
  });

  testWidgets('la tarjeta dice cuando fue la ultima lectura', (tester) async {
    await montar(tester);

    expect(find.textContaining('Última lectura'), findsNWidgets(2));
  });

  testWidgets('con todos los datos la tarjeta cabe en 320 dp', (tester) async {
    await montar(tester, ancho: 320);

    expect(find.text('Elena Ramírez'), findsOneWidget);
    expect(find.text('Alergias: Penicilina'), findsOneWidget);
  });
}
