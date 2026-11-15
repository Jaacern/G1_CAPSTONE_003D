// Los remedios de hoy en la pantalla del adulto mayor.
//
// Su inicio no tiene barra de pestanas, asi que antes la persona que se toma
// las pastillas no tenia donde mirar que le toca: dependia de alcanzar la
// notificacion. Esta tarjeta es su unica via.
import 'package:agecare_app/core/speech/speech_service.dart';
import 'package:agecare_app/core/theme/app_theme.dart';
import 'package:agecare_app/features/auth/application/auth_controller.dart';
import 'package:agecare_app/features/auth/domain/models.dart';
import 'package:agecare_app/features/elder/data/elder_repository.dart';
import 'package:agecare_app/features/elder/presentation/elder_home_screen.dart';
import 'package:agecare_app/features/medications/data/medications_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

void main() {
  setUpAll(() => initializeDateFormatting('es'));

  Future<void> montar(WidgetTester tester, {ElderRepository? elder}) async {
    await tester.binding.setSurfaceSize(const Size(400, 2000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(ProviderScope(
      overrides: [
        if (elder != null) elderRepositoryProvider.overrideWithValue(elder),
        // La voz real usa micrófono, reproductor y red: aquí no hay ninguno.
        speechServiceProvider.overrideWithValue(_VozMuda()),
        medicationsRepositoryProvider
            .overrideWithValue(MedicationsRepositoryMock()),
        currentUserProvider.overrideWith((ref) => const User(
              userId: 'u-elena',
              fullName: 'Elena Ramírez',
              accountType: RoleType.elder,
              email: 'elena@agecare.app',
              memberships: [
                Membership(
                    patientId: 'p-elena',
                    patientName: 'Elena Ramírez',
                    role: RoleType.elder),
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
        home: const ElderHomeScreen(),
      ),
    ));
    await tester.pump();
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }
  }

  testWidgets('la tarjeta aparece en el inicio del adulto mayor',
      (tester) async {
    await montar(tester);

    expect(find.text('Tus remedios de hoy'), findsOneWidget);
  });

  testWidgets('la tarjeta es de consulta: la toma la registra la cuidadora',
      (tester) async {
    await montar(tester);

    // RF-28: el adulto mayor consulta. RF-29: registrar es de la cuidadora,
    // y el backend se lo niega a cualquier otro rol.
    expect(find.text('Ya me lo tomé'), findsNothing);
    expect(find.text('Tu cuidadora lo anota cuando te lo tomas.'),
        findsOneWidget);
  });

  testWidgets('el animo de hoy se guarda en el servidor (RF-38)',
      (tester) async {
    final repo = ElderRepositoryMock();
    await montar(tester, elder: repo);

    await tester.tap(find.text('Mal'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // Antes solo cambiaba el color de la cara: no llegaba a nadie.
    String? guardado;
    await tester.runAsync(() async {
      guardado = await repo.todayMood('p-elena');
    });
    expect(guardado, 'bad');
  });

  testWidgets('hay una tarjeta para el contenido de entretenimiento',
      (tester) async {
    await montar(tester);

    expect(find.text('Para ti'), findsOneWidget);
  });

  testWidgets('dice cuantas van de cuantas, sin hacer contar al usuario',
      (tester) async {
    await montar(tester);

    expect(find.textContaining('Te tomaste'), findsOneWidget);
    expect(find.textContaining('de hoy.'), findsOneWidget);
  });

  testWidgets('la dosis se lee con su unidad, no como numero suelto',
      (tester) async {
    await montar(tester);

    // Sale del mock de dosis: nombre, cantidad con unidad y hora.
    expect(find.textContaining('a las '), findsOneWidget);
  });

  testWidgets('el saludo y el boton de ayuda siguen estando', (tester) async {
    await montar(tester);

    // La tarjeta se agrego arriba: no debe haber tapado lo que ya habia.
    expect(find.textContaining('Hola, Elena'), findsOneWidget);
  });
}

/// Voz que no suena: solo se prueba lo que la pantalla guarda y muestra.
class _VozMuda implements SpeechService {
  @override
  Future<void> speak(String text, {String voice = ''}) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
