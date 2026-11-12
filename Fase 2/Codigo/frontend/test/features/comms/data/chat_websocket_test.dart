// Prueba del chat en tiempo real (RF-54): ChatRepositoryHttp.connect con
// WebSocket y su red de seguridad por sondeo.
//
// No toca la red de verdad: el "backend" es un servidor local en el puerto
// que el sistema asigne, con un WebSocket de dart:io, y el historial HTTP es
// un HttpClientAdapter falso (el mismo truco de chat_sondeo_test.dart).
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:agecare_app/core/network/api_client.dart';
import 'package:agecare_app/core/storage/token_storage.dart';
import 'package:agecare_app/features/comms/data/chat_repository.dart';
import 'package:agecare_app/features/comms/domain/models.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:web_socket_channel/io.dart';

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

Map<String, dynamic> _mensaje(String id, String texto) => {
      'id': id,
      'patient_id': 'p-elena',
      'sender_id': 'u-$id',
      'sender_name': 'Marisol Tapia',
      'sender_role': 'caregiver',
      'type': 'text',
      'text': texto,
      'media_url': null,
      'created_at': '2026-11-01T18:00:00Z',
      'read_by': <String>[],
    };

/// GET /chat/messages falso. Responde la página que le pongan.
class _Historial implements HttpClientAdapter {
  List<Map<String, dynamic>> items = [];
  int pedidos = 0;

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    pedidos++;
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

/// Servidor WebSocket local. Anota la URL con que se conectaron y los sockets
/// abiertos para poder empujarles mensajes o cortarlos.
class _ServidorSocket {
  _ServidorSocket._(this._http);
  final HttpServer _http;
  final List<WebSocket> sockets = [];
  final List<Uri> urls = [];
  final List<String> recibido = [];
  bool rechazar = false;

  static Future<_ServidorSocket> iniciar() async {
    final http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final s = _ServidorSocket._(http);
    http.listen((req) async {
      s.urls.add(req.uri);
      if (s.rechazar) {
        req.response.statusCode = 403;
        await req.response.close();
        return;
      }
      final ws = await WebSocketTransformer.upgrade(req);
      s.sockets.add(ws);
      ws.listen((d) {
        s.recibido.add('$d');
        if (d == 'ping') ws.add('pong');
      }, onDone: () => s.sockets.remove(ws));
    });
    return s;
  }

  int get puerto => _http.port;
  Uri get base => Uri.parse('http://127.0.0.1:$puerto');
  Future<void> cerrar() => _http.close(force: true);
}

Future<void> _esperar(bool Function() cond, {int ms = 3000}) async {
  final fin = DateTime.now().add(Duration(milliseconds: ms));
  while (!cond() && DateTime.now().isBefore(fin)) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  late _Historial historial;
  late _ServidorSocket servidor;

  ChatRepositoryHttp crear({Duration? reintento}) => ChatRepositoryHttp(
        ApiClient(_FakeTokenStorage(), dio: Dio()..httpClientAdapter = historial),
        tokens: _FakeTokenStorage(),
        sondeoCada: const Duration(milliseconds: 40),
        sondeoConSocket: const Duration(seconds: 30),
        pingCada: const Duration(milliseconds: 60),
        esperaMinimaReintento: reintento ?? const Duration(milliseconds: 50),
        abrirSocket: (uri) => IOWebSocketChannel.connect(
            uri.replace(host: '127.0.0.1', port: servidor.puerto, scheme: 'ws')),
      );

  setUp(() async {
    historial = _Historial();
    servidor = await _ServidorSocket.iniciar();
  });

  tearDown(() => servidor.cerrar());

  test('la URL del socket usa ws/wss, la ruta del chat y el token', () {
    final u = ChatRepositoryHttp.uriSocket(
        'https://api.agecare.app', 'p-1', 'abc.def');
    expect(u.scheme, 'wss');
    expect(u.path, '/api/v1/patients/p-1/chat/ws');
    expect(u.queryParameters['token'], 'abc.def');

    final local = ChatRepositoryHttp.uriSocket(
        'http://localhost:8000/', 'p-1', 't');
    expect(local.scheme, 'ws');
    expect(local.path, '/api/v1/patients/p-1/chat/ws');
  });

  test('un mensaje empujado por el socket llega sin esperar un sondeo',
      () async {
    final repo = crear();
    final recibidos = <String>[];
    final sub = repo.connect('p-elena').listen((m) => recibidos.add(m.id));

    await _esperar(() => servidor.sockets.isNotEmpty);
    expect(servidor.sockets, isNotEmpty, reason: 'el cliente debía conectar');
    expect(servidor.urls.single.queryParameters['token'], 'token-de-prueba');

    // El historial sigue vacío: si llega, llegó por el socket.
    servidor.sockets.single.add(jsonEncode(_mensaje('m-9', 'Hola por socket')));
    await _esperar(() => recibidos.contains('m-9'));
    expect(recibidos, ['m-9']);
    await sub.cancel();
  });

  test('un mensaje que llega por socket y por historial se muestra una vez',
      () async {
    final repo = crear();
    final recibidos = <String>[];
    final sub = repo.connect('p-elena').listen((m) => recibidos.add(m.id));
    await _esperar(() => servidor.sockets.isNotEmpty);

    final m = _mensaje('m-1', 'Doble vía');
    servidor.sockets.single.add(jsonEncode(m));
    await _esperar(() => recibidos.isNotEmpty);
    historial.items = [m]; // y ahora también aparece en el sondeo
    await Future<void>.delayed(const Duration(milliseconds: 150));

    expect(recibidos, ['m-1']);
    await sub.cancel();
  });

  test('manda ping y el servidor responde pong sin romper el stream',
      () async {
    final repo = crear();
    final sub = repo.connect('p-elena').listen((_) {});
    await _esperar(() => servidor.recibido.contains('ping'));
    expect(servidor.recibido, contains('ping'));
    await sub.cancel();
  });

  test('si el servidor rechaza el socket, el chat sigue por sondeo', () async {
    servidor.rechazar = true;
    historial.items = [_mensaje('m-1', 'Por sondeo')];
    final repo = crear();
    final recibidos = <String>[];
    final sub = repo.connect('p-elena').listen((m) => recibidos.add(m.id));

    await _esperar(() => recibidos.isNotEmpty);
    expect(recibidos, ['m-1']);
    expect(servidor.sockets, isEmpty);
    await sub.cancel();
  });

  test('si el socket se cae, se reconecta solo', () async {
    final repo = crear();
    final sub = repo.connect('p-elena').listen((_) {});
    await _esperar(() => servidor.sockets.isNotEmpty);
    final primero = servidor.sockets.single;

    await primero.close();
    await _esperar(
        () => servidor.sockets.isNotEmpty && servidor.sockets.single != primero);

    expect(servidor.urls.length, greaterThanOrEqualTo(2));
    expect(servidor.sockets, isNotEmpty);
    await sub.cancel();
  });

  test('un mensaje ilegible por el socket no tumba la conexión', () async {
    final repo = crear();
    final recibidos = <String>[];
    final sub = repo.connect('p-elena').listen((m) => recibidos.add(m.id));
    await _esperar(() => servidor.sockets.isNotEmpty);

    servidor.sockets.single.add('esto no es json');
    servidor.sockets.single.add(jsonEncode(_mensaje('m-2', 'Sigue vivo')));
    await _esperar(() => recibidos.contains('m-2'));

    expect(recibidos, ['m-2']);
    await sub.cancel();
  });

  test('al cancelar se cierra el socket y no se reabre', () async {
    final repo = crear();
    final sub = repo.connect('p-elena').listen((_) {});
    await _esperar(() => servidor.sockets.isNotEmpty);
    await sub.cancel();

    await _esperar(() => servidor.sockets.isEmpty);
    final conexiones = servidor.urls.length;
    await Future<void>.delayed(const Duration(milliseconds: 300));

    expect(servidor.sockets, isEmpty);
    expect(servidor.urls.length, conexiones);
  });

  test('tipo de mensaje del socket es el mismo que el del historial', () async {
    final repo = crear();
    final recibidos = <ChatMessage>[];
    final sub = repo.connect('p-elena').listen(recibidos.add);
    await _esperar(() => servidor.sockets.isNotEmpty);
    servidor.sockets.single.add(jsonEncode(_mensaje('m-3', 'Texto')));
    await _esperar(() => recibidos.isNotEmpty);

    expect(recibidos.single.type, MessageType.text);
    expect(recibidos.single.text, 'Texto');
    await sub.cancel();
  });
}
