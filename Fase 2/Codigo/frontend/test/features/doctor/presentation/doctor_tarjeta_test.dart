// La tarjeta del paciente en la lista del medico.
//
// Se lee de un vistazo: quien es, como esta y sus vitales, con el que esta
// fuera de rango marcado. El RUT, el domicilio y los antecedentes viven en la
// ficha; aqui competirian con lo que importa para decidir a quien abrir
// primero.
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
        home: const DoctorHomeScreen(),
      ),
    ));
    await tester.pump();
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }
  }

  testWidgets('la tarjeta dice solo edad y sexo', (tester) async {
    await montar(tester);

    expect(find.text('78 años · Femenino'), findsOneWidget);
    expect(find.text('81 años · Masculino'), findsOneWidget);
  });

  testWidgets('RUT, domicilio y antecedentes quedan para la ficha',
      (tester) async {
    await montar(tester);

    expect(find.textContaining('RUT'), findsNothing);
    expect(find.text('Los Aromos 1234, La Florida'), findsNothing);
    expect(find.textContaining('Alergias:'), findsNothing);
    expect(find.textContaining('Crónico:'), findsNothing);
    expect(find.textContaining('Prioridad'), findsNothing);
    expect(find.textContaining('Complejidad'), findsNothing);
  });

  testWidgets('se ven todos los vitales y el fuera de rango lleva su nombre',
      (tester) async {
    await montar(tester);

    // Elena, en rango: valores sobrios, sin nombre.
    expect(find.text('97 %'), findsOneWidget);
    expect(find.text('74 bpm'), findsNWidgets(2));
    expect(find.text('36.7 °C'), findsNWidgets(2));
    // Jose, oxigeno bajo el minimo: con su nombre, para no adivinar que mide.
    expect(find.textContaining('91 %'), findsOneWidget);
    expect(find.textContaining('Oxígeno'), findsOneWidget);
    // Y no hay un segundo aviso de "todo en rango" repitiendo al semaforo.
    expect(find.text('Vitales en rango'), findsNothing);
  });

  testWidgets('la tarjeta dice cuando fue la ultima lectura', (tester) async {
    await montar(tester);

    expect(find.textContaining('Última lectura'), findsNWidgets(2));
  });

  testWidgets('el numero de alertas no se repite en la tarjeta',
      (tester) async {
    await montar(tester);

    // La campana de la barra superior ya lo muestra.
    expect(find.textContaining('alertas activas'), findsNothing);
    expect(find.textContaining('alerta activa'), findsNothing);
  });

  testWidgets('con todos los datos la tarjeta cabe en 320 dp', (tester) async {
    await montar(tester, ancho: 320);

    expect(find.text('Elena Ramírez'), findsOneWidget);
    expect(find.textContaining('91 %'), findsOneWidget);
  });
}
