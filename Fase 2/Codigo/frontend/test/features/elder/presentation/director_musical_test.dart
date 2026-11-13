// El Director Musical del adulto mayor: tocar notas, grabarlas y guardarlas
// sin microfono (RF-65, RNF-20).
import 'package:agecare_app/core/audio/tone_service.dart';
import 'package:agecare_app/core/theme/app_theme.dart';
import 'package:agecare_app/features/auth/application/auth_controller.dart';
import 'package:agecare_app/features/auth/domain/models.dart';
import 'package:agecare_app/features/elder/presentation/elder_music_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

void main() {
  setUpAll(() => initializeDateFormatting('es'));

  Future<_TonoMudo> montar(WidgetTester tester, {double ancho = 400}) async {
    final tono = _TonoMudo();
    await tester.binding.setSurfaceSize(Size(ancho, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(ProviderScope(
      overrides: [
        toneServiceProvider.overrideWithValue(tono),
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
        home: const ElderMusicScreen(),
      ),
    ));
    await tester.pump();
    return tono;
  }

  /// Deja terminar el contador de segundos de la grabacion.
  Future<void> esperarContador(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 2));
  }

  testWidgets('se dibuja entera en un telefono de 320 dp', (tester) async {
    await montar(tester, ancho: 320);

    // Antes los botones con ancho infinito dentro de una fila rompian el
    // dibujo de toda la pantalla.
    expect(find.text('Grabar'), findsOneWidget);
    expect(find.text('Mis melodías'), findsOneWidget);
    expect(find.text('Do'), findsOneWidget);
  });

  testWidgets('tocar una nota la hace sonar', (tester) async {
    final tono = await montar(tester);

    await tester.tap(find.text('La'));
    await tester.pump(const Duration(milliseconds: 200));

    expect(tono.tocadas, [440.0]);
  });

  testWidgets('guardar sin haber tocado notas lo explica', (tester) async {
    await montar(tester);

    await tester.tap(find.text('Grabar'));
    await tester.pump();
    await tester.tap(find.text('Guardar'));
    await tester.pump();

    expect(find.textContaining('No tocaste ninguna nota'), findsOneWidget);
    await esperarContador(tester);
  });
}

/// Tonos que no suenan: anota lo que se toco.
class _TonoMudo extends ToneService {
  final tocadas = <double>[];

  @override
  Future<void> play(double frequency,
      {int durationMs = 600, double volume = 0.9}) async {
    tocadas.add(frequency);
  }
}
