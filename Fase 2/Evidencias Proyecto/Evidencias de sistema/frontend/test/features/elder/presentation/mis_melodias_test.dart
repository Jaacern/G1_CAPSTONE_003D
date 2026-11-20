// "Mis melodías": las creaciones guardadas del adulto mayor.
import 'package:agecare_app/core/speech/speech_service.dart';
import 'package:agecare_app/core/theme/app_theme.dart';
import 'package:agecare_app/features/elder/presentation/elder_melodies_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

void main() {
  setUpAll(() => initializeDateFormatting('es'));

  Future<void> montar(WidgetTester tester, List<Melodia> lista) async {
    await tester.binding.setSurfaceSize(const Size(400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(ProviderScope(
      overrides: [
        speechServiceProvider.overrideWithValue(_VozMuda()),
        melodiasProvider.overrideWith((ref) async => lista),
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
        home: const ElderMelodiesScreen(),
      ),
    ));
    await tester.pump();
    await tester.pump();
  }

  testWidgets('muestra cada melodia con su duracion', (tester) async {
    await montar(tester, [
      Melodia(
        id: 'm-1',
        title: 'Melodía del lunes',
        durationSeconds: 65,
        audioUrl: '/files/1',
        createdAt: DateTime(2026, 11, 9, 10, 30),
      ),
      Melodia(
        id: 'm-2',
        title: 'Melodía del martes',
        durationSeconds: 12,
        audioUrl: '/files/2',
        createdAt: DateTime(2026, 11, 10, 18, 5),
      ),
    ]);

    expect(find.text('Melodía del lunes'), findsOneWidget);
    expect(find.text('Melodía del martes'), findsOneWidget);
    expect(find.textContaining('1:05'), findsOneWidget);
    expect(find.textContaining('0:12'), findsOneWidget);
    expect(find.byIcon(Icons.play_arrow_rounded), findsNWidgets(2));
  });

  testWidgets('cada melodia se puede mandar a la familia (RF-67)',
      (tester) async {
    await montar(tester, [
      Melodia(
        id: 'm-1',
        title: 'Melodía del lunes',
        durationSeconds: 65,
        audioUrl: '/files/1',
        createdAt: DateTime(2026, 11, 9, 10, 30),
      ),
    ]);

    expect(find.byTooltip('Mandar a mi familia'), findsOneWidget);
  });

  testWidgets('sin melodias explica donde se graban', (tester) async {
    await montar(tester, const []);

    expect(find.text('Todavía no tienes melodías'), findsOneWidget);
    expect(find.textContaining('Director musical'), findsOneWidget);
  });
}

/// Voz que no suena: aqui solo se prueba lo que la pantalla muestra.
class _VozMuda implements SpeechService {
  @override
  Stream<void> get onPlaybackComplete => const Stream.empty();

  @override
  Future<void> stopPlayback() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
