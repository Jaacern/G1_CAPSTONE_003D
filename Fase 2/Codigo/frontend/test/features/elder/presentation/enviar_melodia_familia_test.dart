// Mandar una melodia al chat de la familia desde Mis melodias (RF-67).
import 'package:agecare_app/core/speech/speech_service.dart';
import 'package:agecare_app/core/theme/app_theme.dart';
import 'package:agecare_app/features/auth/application/auth_controller.dart';
import 'package:agecare_app/features/auth/domain/models.dart';
import 'package:agecare_app/features/comms/data/chat_repository.dart';
import 'package:agecare_app/features/comms/domain/models.dart';
import 'package:agecare_app/features/elder/presentation/elder_melodies_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

void main() {
  setUpAll(() => initializeDateFormatting('es'));

  final melodia = Melodia(
    id: 'm-1',
    title: 'Melodía del lunes',
    durationSeconds: 65,
    audioUrl: 'http://localhost:8000/api/v1/files/0b7c2f4e-1111-4222-8333-444455556666',
    createdAt: DateTime(2026, 11, 9, 10, 30),
  );

  Future<_ChatQueAnota> montar(WidgetTester tester) async {
    final chat = _ChatQueAnota();
    await tester.binding.setSurfaceSize(const Size(400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(ProviderScope(
      overrides: [
        speechServiceProvider.overrideWithValue(_VozMuda()),
        melodiasProvider.overrideWith((ref) async => [melodia]),
        chatRepositoryProvider.overrideWithValue(chat),
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
        home: const ElderMelodiesScreen(),
      ),
    ));
    await tester.pump();
    await tester.pump();
    return chat;
  }

  testWidgets('pregunta antes de mandar y "No" no manda nada',
      (tester) async {
    final chat = await montar(tester);

    await tester.tap(find.byTooltip('Mandar a mi familia'));
    await tester.pumpAndSettle();
    expect(find.text('¿Se la mandamos a tu familia?'), findsOneWidget);

    await tester.tap(find.text('No'));
    await tester.pumpAndSettle();
    expect(chat.enviados, isEmpty);
  });

  testWidgets('la manda al chat como nota de voz con su titulo',
      (tester) async {
    final chat = await montar(tester);

    await tester.tap(find.byTooltip('Mandar a mi familia'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mandar'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();

    expect(chat.enviados, hasLength(1));
    final (paciente, tipo, texto, archivo) = chat.enviados.single;
    expect(paciente, 'p-elena');
    expect(tipo, MessageType.voice);
    expect(texto, '🎵 Melodía del lunes');
    expect(archivo, melodia.audioUrl); // el mismo archivo, sin volver a subirlo
    expect(find.text('Le mandaste "Melodía del lunes" a tu familia.'),
        findsOneWidget);
  });
}

/// Chat de demostracion que anota lo que se manda.
class _ChatQueAnota extends ChatRepositoryMock {
  final enviados = <(String, MessageType, String?, String?)>[];

  @override
  Future<ChatMessage> sendMessage(
    String patientId, {
    required MessageType type,
    String? text,
    String? mediaUrl,
  }) {
    enviados.add((patientId, type, text, mediaUrl));
    return super.sendMessage(patientId,
        type: type, text: text, mediaUrl: mediaUrl);
  }
}

/// Voz que no suena: aqui solo se prueba lo que se manda.
class _VozMuda implements SpeechService {
  @override
  Stream<void> get onPlaybackComplete => const Stream.empty();

  @override
  Future<void> stopPlayback() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
