// El asistente se puede usar dictando la pregunta (RF-64), sin escribir.
import 'package:agecare_app/core/theme/app_theme.dart';
import 'package:agecare_app/features/comms/presentation/assistant_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> montar(WidgetTester tester, {double ancho = 400}) async {
    await tester.binding.setSurfaceSize(Size(ancho, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(
        theme: AppTheme.light(),
        home: const AssistantScreen(patientId: 'p-elena'),
      ),
    ));
    await tester.pump();
  }

  testWidgets('el cuadro de la pregunta tiene el boton de dictar',
      (tester) async {
    await montar(tester);

    expect(find.text('Escribe tu pregunta…'), findsOneWidget);
    expect(find.byTooltip('Dictar con la voz'), findsOneWidget);
  });

  testWidgets('el boton de dictar cabe en 320 dp', (tester) async {
    await montar(tester, ancho: 320);

    // Un RenderFlex que no entra revienta la prueba por si solo.
    expect(find.byTooltip('Dictar con la voz'), findsOneWidget);
  });
}
