// Prueba del sondeo de mensajes nuevos (ChatRepositoryHttp.connect).
//
// El chat del equipo de cuidado se mostraba "en tiempo real" mediante un
// WebSocket a /ws/patients/{id}/chat, pero el backend no registra ninguna ruta
// ws: el handshake fallaba y nunca llegaba un mensaje. Ahora se sondea
// GET /patients/{id}/chat/messages. Nada de esto toca la red: el servidor falso
// es un HttpClientAdapter, el mismo truco de api_client_test.dart.
import 'dart:convert';
import 'dart:typed_data';

import 'package:agecare_app/core/network/api_client.dart';
import 'package:agecare_app/core/storage/token_storage.dart';
import 'package:agecare_app/features/comms/data/chat_repository.dart';
import 'package:agecare_app/features/comms/domain/models.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// El almacenamiento seguro real necesita un dispositivo; acá son variables.
class _FakeTokenStorage extends TokenStorage {
  @override
  Future<String?> get accessToken async => 'token-de-prueba';

  @override
  Future<String?> get refreshToken async => null;

  @override
  Future<void> save({required String access, required String refresh}) async {}

  @override
  Future<void> clear() async {}
}

/// Un mensaje con la forma exacta de `MessageOut` del backend.
Map<String, dynamic> _mensaje(String id, String hora, String texto) => {
      'id': id,
      'patient_id': 'p-elena',
      'sender_id': 'u-$id',
      'sender_name': 'Marisol Tapia',
      'sender_role': 'caregiver',
      'type': 'text',
      'text': texto,
      'media_url': null,
      'created_at': '2026-11-01T$hora:00Z',
      'read_by': <String>[],
    };

/// Servidor falso del chat: responde la página que le pongan en `items`
/// (orden descendente, como el backend) y anota las rutas que le pidieron.
class _ServidorDelChat implements HttpClientAdapter {
  _ServidorDelChat(this.items);

  /// La página que devuelve el próximo GET. Se puede mutar entre sondeos.
  List<Map<String, dynamic>> items;

  final List<String> rutas = [];

  /// Los query params del último GET, para comprobar cómo se serializa `before`.
  Map<String, dynamic> ultimoQuery = const {};

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    rutas.add(options.path);
    ultimoQuery = options.queryParameters;
    return ResponseBody.fromString(
      jsonEncode({'items': items}),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  late _ServidorDelChat servidor;
  late ChatRepositoryHttp repo;

  setUp(() {
    servidor = _ServidorDelChat([
      // El backend entrega del más nuevo al más viejo.
      _mensaje('m-3', '18:00', 'Ya merendó'),
      _mensaje('m-2', '17:00', 'Siesta tranquila'),
      _mensaje('m-1', '16:00', 'Almuerció bien'),
    ]);
    final dio = Dio()..httpClientAdapter = servidor;
    repo = ChatRepositoryHttp(
      ApiClient(_FakeTokenStorage(), dio: dio),
      sondeoCada: const Duration(milliseconds: 30),
    );
  });

  Future<List<ChatMessage>> escuchar(int n) =>
      repo.connect('p-elena').take(n).toList();

  test('el primer sondeo entrega el historial en orden cronológico', () async {
    final recibidos = await escuchar(3);

    expect(recibidos.map((m) => m.id).toList(), ['m-1', 'm-2', 'm-3']);
  });

  test('cada sondeo aporta solo los mensajes que faltaban', () async {
    final recibidos = <String>[];
    final sub = repo.connect('p-elena').listen((m) => recibidos.add(m.id));
    await Future.delayed(const Duration(milliseconds: 80));
    expect(recibidos, ['m-1', 'm-2', 'm-3']);

    // Llega un mensaje nuevo y el backend lo pone al principio de la página.
    servidor.items = [
      _mensaje('m-4', '19:00', 'A la cama'),
      ...servidor.items,
    ];
    await Future.delayed(const Duration(milliseconds: 80));

    // El sondeo vuelve a traer m-1..m-3, pero no los re-emite.
    expect(recibidos, ['m-1', 'm-2', 'm-3', 'm-4']);
    await sub.cancel();
  });

  test('el chat pregunta por el endpoint que si existe', () async {
    await escuchar(3);

    // Ninguna ruta ws: el backend no registra ninguna, así que pedirla era el
    // fallo original.
    expect(servidor.rutas, contains('/patients/p-elena/chat/messages'));
    expect(servidor.rutas.any((r) => r.contains('/ws/')), isFalse);
  });

  test('before viaja como fecha ISO-8601 en UTC, no como id de mensaje',
      () async {
    // El backend declara `before: datetime | None`, así que un id de mensaje
    // (o una fecha local con espacios) devolvería 422 y la paginación no
    // cargaría nunca la página anterior.
    await repo.fetchMessages(
      'p-elena',
      before: DateTime.utc(2026, 11, 1, 17, 30),
    );

    expect(servidor.ultimoQuery['before'], '2026-11-01T17:30:00.000Z');
    expect(servidor.ultimoQuery['limit'], 50);
  });
}
