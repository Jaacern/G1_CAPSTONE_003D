// El boton para escribir dictando (RF-64). Aqui no hay reconocimiento de voz:
// se prueba lo que se ve, que es lo que la persona usa para empezar.
import 'package:agecare_app/core/speech/boton_dictado.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> montar(WidgetTester tester, {bool enabled = true}) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: TextField(
          controller: TextEditingController(text: 'Hola'),
          decoration: InputDecoration(
            suffixIcon: BotonDictado(
              controller: TextEditingController(),
              enabled: enabled,
            ),
          ),
        ),
      ),
    ));
  }

  testWidgets('se ve dentro del cuadro de texto con su ayuda',
      (tester) async {
    await montar(tester);

    expect(find.byTooltip('Dictar con la voz'), findsOneWidget);
    expect(find.byIcon(Icons.keyboard_voice_rounded), findsOneWidget);
  });

  testWidgets('desactivado no se puede tocar (por ejemplo, mientras envia)',
      (tester) async {
    await montar(tester, enabled: false);

    final boton = tester.widget<IconButton>(find.byType(IconButton));
    expect(boton.onPressed, isNull);
  });

  testWidgets('salir sin haber dictado no falla', (tester) async {
    await montar(tester);

    // Al cerrar la pantalla el boton se desarma. Si nunca se uso, no hay
    // reconocimiento que cancelar.
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });
}
