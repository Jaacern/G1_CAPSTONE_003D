// Medicamentos SOS: verlos, registrar su uso y respetar los limites.
//
// Un SOS no esta en la agenda de tomas. Si quien cuida no lo ve aparte y no
// anota cada uso, el medico no sabe cuantas veces se uso; y si la app no frena
// el maximo de 24 h, una crisis puede terminar en sobredosis.
import 'package:agecare_app/core/theme/app_theme.dart';
import 'package:agecare_app/features/medications/data/prn_repository.dart';
import 'package:agecare_app/features/medications/presentation/prn_banner.dart';
import 'package:agecare_app/features/medications/presentation/prn_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> esperar(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
  }

  Future<void> montar(WidgetTester tester,
      {List<DateTime>? usos, double ancho = 400, Widget? pantalla}) async {
    await tester.binding.setSurfaceSize(Size(ancho, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(ProviderScope(
      overrides: [
        prnRepositoryProvider
            .overrideWithValue(PrnRepositoryMock(usosPrevios: usos)),
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
        home: pantalla ?? const PrnScreen(patientId: 'p-elena'),
      ),
    ));
    await esperar(tester);
  }

  Future<void> registrar(WidgetTester tester, String motivo) async {
    await tester.tap(find.text('Registrar uso'));
    await esperar(tester);
    await tester.enterText(find.byType(TextField), motivo);
    await tester.pump();
    await tester.tap(find.text('Registrar'));
    await esperar(tester);
  }

  testWidgets('lista el SOS indicado con su dosis e intervalo', (tester) async {
    await montar(tester);

    expect(find.text('Bromuro de ipratropio'), findsOneWidget);
    expect(find.text('2 puff · cada 6 h'), findsOneWidget);
    expect(find.text('Aún no se ha usado.'), findsOneWidget);
  });

  testWidgets('registrar un uso lo deja en el historial', (tester) async {
    await montar(tester);
    await registrar(tester, 'Tos persistente');

    expect(find.textContaining('Tos persistente'), findsOneWidget);
    expect(find.text('Aún no se ha usado.'), findsNothing);
  });

  testWidgets('un uso antes del intervalo pide confirmacion', (tester) async {
    await montar(tester);
    await registrar(tester, 'Tos persistente');
    await registrar(tester, 'Le falta el aire');

    expect(find.text('Registrar igual'), findsOneWidget);
    await tester.tap(find.text('Registrar igual'));
    await esperar(tester);

    expect(find.textContaining('Le falta el aire'), findsOneWidget);
    expect(find.byTooltip('Antes del intervalo'), findsOneWidget);
  });

  testWidgets('al llegar al maximo del dia no deja registrar otro',
      (tester) async {
    // Seis usos de 2 puff en 24 h = 12, el maximo del ipratropio.
    await montar(tester, usos: [
    for (final h in [7, 10, 13, 16, 19, 22])
      DateTime.now().subtract(Duration(hours: h)),
  ]);

    expect(find.textContaining('consulta al médico'), findsOneWidget);
    final boton = tester.widget<ButtonStyleButton>(find.ancestor(
        of: find.text('Registrar uso'),
        matching: find.byWidgetPredicate((w) => w is ButtonStyleButton)));
    expect(boton.onPressed, isNull);
  });

  testWidgets('la pantalla SOS con el maximo alcanzado cabe en 320 dp',
      (tester) async {
    await montar(tester, ancho: 320, usos: [
    for (final h in [7, 10, 13, 16, 19, 22])
      DateTime.now().subtract(Duration(hours: h)),
  ]);

    expect(find.text('Bromuro de ipratropio'), findsOneWidget);
  });

  testWidgets('el aviso de SOS aparece solo si el paciente tiene alguno',
      (tester) async {
    await montar(tester,
        pantalla: const Scaffold(
            body: Column(children: [
          PrnBanner(patientId: 'p-elena'),
          PrnBanner(patientId: 'p-jose'),
        ])));

    expect(find.text('Medicamentos SOS disponibles'), findsOneWidget);
    expect(find.text('Bromuro de ipratropio'), findsOneWidget);
  });
}
