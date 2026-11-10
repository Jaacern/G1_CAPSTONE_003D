import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'api_error.dart';
import 'config.dart';

/// Guarda el par de tokens. El de acceso también vive en memoria para no
/// leer el almacenamiento en cada petición.
class TokenStore {
  TokenStore([FlutterSecureStorage? storage])
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;
  static const _kAccess = 'admin_access';
  static const _kRefresh = 'admin_refresh';

  String? _access;
  String? _refresh;
  bool _loaded = false;

  Future<void> _load() async {
    if (_loaded) return;
    try {
      _access = await _storage.read(key: _kAccess);
      _refresh = await _storage.read(key: _kRefresh);
    } catch (_) {
      // Almacenamiento no disponible (modo privado, etc.): se trabaja en memoria.
    }
    _loaded = true;
  }

  Future<String?> get access async {
    await _load();
    return _access;
  }

  Future<String?> get refresh async {
    await _load();
    return _refresh;
  }

  Future<void> save(String access, String refresh) async {
    _access = access;
    _refresh = refresh;
    _loaded = true;
    try {
      await _storage.write(key: _kAccess, value: access);
      await _storage.write(key: _kRefresh, value: refresh);
    } catch (_) {}
  }

  Future<void> clear() async {
    _access = null;
    _refresh = null;
    _loaded = true;
    try {
      await _storage.delete(key: _kAccess);
      await _storage.delete(key: _kRefresh);
    } catch (_) {}
  }
}

/// Cliente de la API del panel.
///
/// - Agrega el token a cada petición.
/// - Ante un 401 renueva la sesión una sola vez (aunque fallen varias
///   peticiones a la vez) y reintenta.
/// - Si no se puede renovar, avisa con [onSessionExpired].
/// - Siempre lanza [ApiException], nunca DioException.
class ApiClient {
  ApiClient(this.tokens, {Dio? dio})
      : _dio = dio ??
            Dio(
              BaseOptions(
                baseUrl: kApiBaseUrl.isEmpty ? Uri.base.origin : kApiBaseUrl,
                connectTimeout: const Duration(seconds: 15),
                receiveTimeout: const Duration(seconds: 30),
                headers: {'Accept': 'application/json'},
              ),
            );

  final Dio _dio;
  final TokenStore tokens;
  void Function()? onSessionExpired;
  Future<bool>? _refreshing;

  Future<dynamic> get(String path, {Map<String, dynamic>? query}) =>
      _request('GET', path, query: query);

  Future<dynamic> post(String path, {Object? body, bool auth = true}) =>
      _request('POST', path, body: body, auth: auth);

  Future<dynamic> put(String path, {Object? body}) =>
      _request('PUT', path, body: body);

  Future<dynamic> patch(String path, {Object? body}) =>
      _request('PATCH', path, body: body);

  Future<dynamic> delete(String path) => _request('DELETE', path);

  Future<Response<dynamic>> _once(
    String method,
    String path, {
    Object? body,
    Map<String, dynamic>? query,
    required bool auth,
  }) async {
    final headers = <String, dynamic>{};
    if (auth) {
      final t = await tokens.access;
      if (t != null) headers['Authorization'] = 'Bearer $t';
    }
    return _dio.request<dynamic>(
      path,
      data: body,
      queryParameters: query,
      options: Options(method: method, headers: headers),
    );
  }

  Future<dynamic> _request(
    String method,
    String path, {
    Object? body,
    Map<String, dynamic>? query,
    bool auth = true,
  }) async {
    try {
      final r = await _once(method, path, body: body, query: query, auth: auth);
      return r.data;
    } on DioException catch (e) {
      if (!auth || e.response?.statusCode != 401) throw ApiException.from(e);

      bool renovado;
      try {
        renovado = await _renovar();
      } on DioException catch (e2) {
        throw ApiException.from(e2); // sin red: no se cierra la sesión
      }
      if (!renovado) {
        onSessionExpired?.call();
        throw ApiException(
          message: 'Tu sesión expiró. Vuelve a iniciar sesión.',
          code: 'UNAUTHORIZED',
          status: 401,
        );
      }
      try {
        final r = await _once(method, path, body: body, query: query, auth: true);
        return r.data;
      } on DioException catch (e3) {
        if (e3.response?.statusCode == 401) onSessionExpired?.call();
        throw ApiException.from(e3);
      }
    }
  }

  Future<bool> _renovar() =>
      _refreshing ??= _hacerRenovar().whenComplete(() => _refreshing = null);

  /// true si se obtuvo un par nuevo; false si el servidor rechazó el refresh.
  /// Lanza DioException si no hubo respuesta (red caída).
  Future<bool> _hacerRenovar() async {
    final refresh = await tokens.refresh;
    if (refresh == null) return false;
    try {
      final r = await _dio.post<dynamic>(
        '/api/v1/auth/refresh',
        data: {'refresh_token': refresh},
      );
      final data = r.data as Map;
      await tokens.save(
        data['access_token'] as String,
        data['refresh_token'] as String,
      );
      return true;
    } on DioException catch (e) {
      if (e.response == null) rethrow;
      await tokens.clear();
      return false;
    }
  }
}
