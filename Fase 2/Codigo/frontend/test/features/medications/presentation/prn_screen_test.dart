// Medicamentos SOS: verlos, registrar su uso y respetar los limites.
//
// Un SOS no esta en la agenda de tomas. Si quien cuida no lo ve aparte y no
// anota cada uso, el medico no sabe cuantas veces se uso; y si la app no frena
// el maximo de 24 h, una crisis puede terminar en sobredosis.
import 'package:agecare_app/core/theme/app_theme.dart';
import 'package:agecare_app/features/medications/data/prn_repository.dart';
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
}
