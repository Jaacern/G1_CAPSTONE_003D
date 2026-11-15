// Prueba del interceptor de ApiClient (AGE-105, criterio "el interceptor
// renueva el token"). No hay backend real todavia, asi que se simula un
// servidor falso con un HttpClientAdapter propio: nada de esto toca la red.
import 'dart:typed_data';

import 'package:agecare_app/core/network/api_client.dart';
import 'package:agecare_app/core/storage/token_storage.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// Reemplaza el almacenamiento seguro real (que necesita un dispositivo)
/// por variables en memoria, para poder probar sin un emulador.
class _FakeTokenStorage extends TokenStorage {
  String? access;
  String? refresh;
  bool cleared = false;

  @override
  Future<String?> get accessToken async => access;

  @override
  Future<String?> get refreshToken async => refresh;

  @override
  Future<void> save({required String access, required String refresh}) async {
    this.access = access;
    this.refresh = refresh;
  }

  @override
  Future<void> clear() async {
    cleared = true;
    access = null;
    refresh = null;
  }
}

ResponseBody _json(int statusCode, String body) => ResponseBody.fromString(
      body,
      statusCode,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );

/// Servidor falso: registra cada petición que le llega y responde según
/// guiones fijos, sin usar la red de verdad.
class _ScriptedAdapter implements HttpClientAdapter {
  final List<String> paths = [];
  final List<String?> authHeaders = [];

  /// Si es true, /auth/refresh responde 401 (refresh token también vencido).
  bool refreshFails = false;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    paths.add(options.path);
    authHeaders.add(options.headers['Authorization'] as String?);

    if (options.path == '/auth/refresh') {
      if (refreshFails) {
        return _json(
            401, '{"error":{"code":"INVALID_REFRESH","message":"vencido"}}');
      }
      return _json(
          200, '{"access_token":"new-access","refresh_token":"new-refresh"}');
    }

    if (options.path == '/patients/me') {
      if (options.headers['Authorization'] == 'Bearer new-access') {
        return _json(200, '{"id":"p1","name":"Elena"}');
      }
      return _json(
          401, '{"error":{"code":"TOKEN_EXPIRED","message":"expirado"}}');
    }

    if (options.path == '/auth/login') {
      // Ruta publica: no deberia llegar con Authorization.
      return _json(200, '{"ok":true}');
    }

    return _json(
        404, '{"error":{"code":"NOT_FOUND","message":"no encontrado"}}');
  }

  @override
  void close({bool force = false}) {}
}

Dio _dioWith(_ScriptedAdapter adapter) =>
    Dio(BaseOptions(baseUrl: 'https://fake.test/api/v1'))
      ..httpClientAdapter = adapter;

void main() {
  test('agrega el token guardado en rutas privadas, y lo omite en publicas',
      () async {
    final tokens = _FakeTokenStorage()
      ..access = 'new-access'
      ..refresh = 'r1';
    final adapter = _ScriptedAdapter();
    final client = ApiClient(tokens,
        dio: _dioWith(adapter), refreshDio: _dioWith(adapter));

    await client.get<Map<String, dynamic>>('/patients/me');
    expect(adapter.authHeaders.last, 'Bearer new-access');

    await client.post<Map<String, dynamic>>('/auth/login', data: {});
    expect(adapter.authHeaders.last, isNull);
  });

  test('ante un 401 pide refresh solo y reintenta la peticion original',
      () async {
    final tokens = _FakeTokenStorage()
      ..access = 'old-access'
      ..refresh = 'valid-refresh';
    final adapter = _ScriptedAdapter();
    final client = ApiClient(tokens,
        dio: _dioWith(adapter), refreshDio: _dioWith(adapter));

    final result = await client.get<Map<String, dynamic>>('/patients/me');

    // 1) la primera llamada con el token viejo -> 401
    // 2) refresh automatico en /auth/refresh
    // 3) reintento con el token nuevo -> 200
    expect(adapter.paths, ['/patients/me', '/auth/refresh', '/patients/me']);
    expect(adapter.authHeaders[0], 'Bearer old-access');
    expect(adapter.authHeaders[2], 'Bearer new-access');
    expect(result['name'], 'Elena');

    // Los tokens nuevos quedaron guardados para la proxima peticion.
    expect(tokens.access, 'new-access');
    expect(tokens.refresh, 'new-refresh');
  });

  test('si el refresh tambien falla, limpia la sesion y avisa', () async {
    final tokens = _FakeTokenStorage()
      ..access = 'old-access'
      ..refresh = 'expired-refresh';
    final adapter = _ScriptedAdapter()..refreshFails = true;
    final client = ApiClient(tokens,
        dio: _dioWith(adapter), refreshDio: _dioWith(adapter));

    var sessionExpiredCalled = false;
    client.onSessionExpired = () => sessionExpiredCalled = true;

    await expectLater(
      client.get<Map<String, dynamic>>('/patients/me'),
      throwsA(isA<ApiException>()),
    );

    expect(sessionExpiredCalled, isTrue);
    expect(tokens.cleared, isTrue);
    expect(tokens.access, isNull);
  });

  group('ApiException', () {
    test('lee el mensaje del sobre de error del backend', () {
      final error = ApiException.fromDio(DioException(
        requestOptions: RequestOptions(path: '/x'),
        response: Response(
          statusCode: 409,
          requestOptions: RequestOptions(path: '/x'),
          data: const {
            'error': {
              'code': 'SHIFT_ALREADY_OPEN',
              'message': 'Ya tienes un turno abierto con otro paciente.',
              'details': null,
              'request_id': 'r-1',
            }
          },
        ),
      ));

      expect(error.statusCode, 409);
      expect(error.code, 'SHIFT_ALREADY_OPEN');
      expect(error.message, 'Ya tienes un turno abierto con otro paciente.');
    });

    // Las pantallas interpolan el error directo en un aviso; si toString
    // sumara el estado y el código, ese detalle técnico se leería en pantalla.
    test('se muestra con el mensaje, sin el código de la API', () {
      final error = ApiException(
          statusCode: 404, code: 'NOT_FOUND', message: 'La tarea no existe.');

      expect(error.toString(), 'La tarea no existe.');
    });

    test('un fallo sin sobre de error usa el mensaje genérico', () {
      final error = ApiException.fromDio(DioException(
        requestOptions: RequestOptions(path: '/x'),
        type: DioExceptionType.connectionError,
      ));

      expect(error.code, 'NETWORK_ERROR');
      expect(error.toString(), isNot(contains('Instance of')));
      expect(error.toString(), isNotEmpty);
    });
  });
}
