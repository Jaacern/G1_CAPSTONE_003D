import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:meta/meta.dart';

import '../config/app_config.dart';
import '../storage/token_storage.dart';

/// Error de la API con el formato estándar del backend (sección 2.4 de la
/// Especificación de Endpoints): { error: { code, message, details, request_id } }.
class ApiException implements Exception {
  ApiException({
    required this.statusCode,
    required this.code,
    required this.message,
    this.fieldErrors = const {},
  });

  final int statusCode;
  final String code;
  final String message;

  /// Detalle por campo de un 422 (`error.details`): campo → motivo. La clave
  /// es la ruta que devuelve el backend sin el prefijo `body.`, por ejemplo
  /// `rut` o `emergency_contact.phone`.
  final Map<String, String> fieldErrors;

  /// El motivo concreto si el backend lo dio; si no, el mensaje general.
  /// Sirve para no dejar a la persona con "Hay datos inválidos" sin saber cuál.
  String get detailedMessage =>
      fieldErrors.isEmpty ? message : fieldErrors.values.first;

  factory ApiException.fromDio(DioException e) {
    final data = e.response?.data;
    if (data is Map && data['error'] is Map) {
      final err = data['error'] as Map;
      final fields = <String, String>{};
      final details = err['details'];
      if (details is List) {
        for (final d in details) {
          if (d is Map && d['field'] != null) {
            final field =
                d['field'].toString().replaceFirst(RegExp(r'^body\.'), '');
            // Pydantic antepone "Value error, " a los ValueError propios.
            final msg = (d['message'] ?? '')
                .toString()
                .replaceFirst(RegExp(r'^Value error, '), '');
            if (msg.isNotEmpty) fields[field] = msg;
          }
        }
      }
      return ApiException(
        statusCode: e.response?.statusCode ?? 0,
        code: (err['code'] ?? 'UNKNOWN').toString(),
        message: (err['message'] ?? 'Ocurrió un error inesperado.').toString(),
        fieldErrors: fields,
      );
    }
    if (e.type == DioExceptionType.connectionTimeout ||
        e.type == DioExceptionType.connectionError) {
      return ApiException(
        statusCode: 0,
        code: 'NETWORK_ERROR',
        message: 'Sin conexión. Revisa tu internet e intenta de nuevo.',
      );
    }
    return ApiException(
      statusCode: e.response?.statusCode ?? 0,
      code: 'UNKNOWN',
      message: 'Algo salió mal. Intenta más tarde.',
    );
  }

  /// Las pantallas muestran el error con `toString()` dentro de un aviso. El
  /// estado y el código quedan disponibles como campos para el registro, pero
  /// no viajan en la cadena: a la cuidadora le sirve el mensaje del backend,
  /// que ya viene en español, y no un `409 SHIFT_ALREADY_OPEN`.
  @override
  String toString() => message;
}

/// Cliente HTTP con renovación automática del access token.
class ApiClient {
  /// [dio] y [refreshDio] solo existen para reemplazar el cliente HTTP real
  /// por uno falso en los tests (ver test/core/network/api_client_test.dart).
  /// En la app nunca se pasan: se arman con la configuración normal.
  ApiClient(
    this._tokens, {
    @visibleForTesting Dio? dio,
    @visibleForTesting Dio? refreshDio,
  }) : _refreshDio = refreshDio ??
            Dio(BaseOptions(
              baseUrl: AppConfig.apiBaseUrl + AppConfig.apiVersion,
              // Cabeceras del service token de Cloudflare Access (vacías si no
              // está configurado). Sin ellas, Access responde 403 antes de
              // llegar al backend.
              headers: {...AppConfig.cfAccessHeaders},
            )) {
    _dio = dio ??
        Dio(BaseOptions(
          baseUrl: AppConfig.apiBaseUrl + AppConfig.apiVersion,
          connectTimeout: const Duration(seconds: 10),
          receiveTimeout: const Duration(seconds: 20),
          headers: {
            'Content-Type': 'application/json',
            ...AppConfig.cfAccessHeaders,
          },
        ));

    _dio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) async {
        final token = await _tokens.accessToken;
        if (token != null && !_isPublicPath(options.path)) {
          options.headers['Authorization'] = 'Bearer $token';
        }
        handler.next(options);
      },
      onError: (error, handler) async {
        // 401 -> intenta refresh una vez y reintenta la petición original.
        if (error.response?.statusCode == 401 &&
            !_isPublicPath(error.requestOptions.path) &&
            error.requestOptions.extra['retried'] != true) {
          final refreshed = await _tryRefresh();
          if (refreshed) {
            final opts = error.requestOptions..extra['retried'] = true;
            opts.headers['Authorization'] = 'Bearer ${await _tokens.accessToken}';
            try {
              final response = await _dio.fetch(opts);
              return handler.resolve(response);
            } catch (_) {/* cae al handler.next */}
          } else {
            await _tokens.clear();
            onSessionExpired?.call();
          }
        }
        handler.next(error);
      },
    ));
  }

  final TokenStorage _tokens;
  late final Dio _dio;
  final Dio _refreshDio;

  /// Callback para que la capa de auth reaccione al vencimiento de sesión.
  void Function()? onSessionExpired;

  bool _isPublicPath(String path) =>
      path.startsWith('/auth/') || path == '/health';

  Future<bool> _tryRefresh() async {
    final refresh = await _tokens.refreshToken;
    if (refresh == null) return false;
    try {
      final res = await _refreshDio.post('/auth/refresh', data: {'refresh_token': refresh});
      await _tokens.save(
        access: res.data['access_token'] as String,
        refresh: res.data['refresh_token'] as String,
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<T> get<T>(String path, {Map<String, dynamic>? query}) =>
      _wrap(() => _dio.get<T>(path, queryParameters: query));

  /// Descarga binaria (PDF, imágenes) con el token ya inyectado por el
  /// interceptor. Devuelve los bytes crudos de la respuesta.
  Future<List<int>> getBytes(String path, {Map<String, dynamic>? query}) async {
    try {
      final res = await _dio.get<List<int>>(
        path,
        queryParameters: query,
        options: Options(responseType: ResponseType.bytes),
      );
      return res.data ?? const <int>[];
    } on DioException catch (e) {
      throw ApiException.fromDio(e);
    }
  }

  /// [query] va en la URL. Hace falta porque no toda la API recibe los datos
  /// en el cuerpo: el registro de una creación musical, por ejemplo, declara
  /// sus campos como parámetros de consulta.
  Future<T> post<T>(String path, {Object? data, Map<String, dynamic>? query}) =>
      _wrap(() => _dio.post<T>(path, data: data, queryParameters: query));

  Future<T> patch<T>(String path, {Object? data}) =>
      _wrap(() => _dio.patch<T>(path, data: data));

  Future<T> put<T>(String path, {Object? data}) =>
      _wrap(() => _dio.put<T>(path, data: data));

  Future<T> delete<T>(String path) => _wrap(() => _dio.delete<T>(path));

  Future<T> _wrap<T>(Future<Response<T>> Function() call) async {
    try {
      final res = await call();
      return res.data as T;
    } on DioException catch (e) {
      throw ApiException.fromDio(e);
    }
  }
}

final tokenStorageProvider = Provider<TokenStorage>((ref) => TokenStorage());

final apiClientProvider = Provider<ApiClient>((ref) {
  return ApiClient(ref.watch(tokenStorageProvider));
});
