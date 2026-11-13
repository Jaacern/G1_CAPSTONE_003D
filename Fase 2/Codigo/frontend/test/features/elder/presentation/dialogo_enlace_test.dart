// El dialogo que muestra el enlace de una melodia para copiarlo (RF-67).
import 'package:agecare_app/core/theme/app_theme.dart';
import 'package:agecare_app/features/elder/presentation/elder_melodies_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

void main() {
  setUpAll(() => initializeDateFormatting('es'));

  final enlace = EnlaceDeEscucha(
    shareId: 's-1',
    url: 'http://localhost:8000/api/v1/music/shared/abc',
    expiresAt: DateTime(2026, 11, 15, 19),
  );

  /// Abre el dialogo desde un boton y guarda lo que devuelve al cerrarse.
  Future<List<String?>> abrir(WidgetTester tester) async {
    final resultados = <String?>[];
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light(),
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () async {
              resultados.add(await showDialog<String>(
                context: context,
                builder: (_) => DialogoEnlaceDeEscucha(
                    titulo: 'Melodía del lunes', enlace: enlace),
              ));
            },
            child: const Text('abrir'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('abrir'));
    await tester.pumpAndSettle();
    return resultados;
  }

  testWidgets('muestra el enlace y hasta cuando funciona', (tester) async {
    await abrir(tester);

    expect(find.text('Enlace para escuchar'), findsOneWidget);
    expect(find.text(enlace.url), findsOneWidget);
    expect(find.textContaining('15 de noviembre'), findsOneWidget);
    expect(find.textContaining('Melodía del lunes'), findsOneWidget);
  });

  testWidgets('copiar deja el enlace en el portapapeles', (tester) async {
    String? copiado;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copiado = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));

    final resultados = await abrir(tester);
    await tester.tap(find.text('Copiar enlace'));
    await tester.pumpAndSettle();

    expect(copiado, enlace.url);
    expect(resultados, ['copiado']);
    expect(find.text('Enlace para escuchar'), findsNothing);
  });

  testWidgets('cerrar no copia nada', (tester) async {
    final resultados = await abrir(tester);
    await tester.tap(find.text('Cerrar'));
    await tester.pumpAndSettle();

    expect(resultados, [null]);
  });
}
