import 'package:dio/dio.dart';

/// Error de la API ya traducido a algo que se le puede mostrar a una persona.
///
/// La API responde `{error: {code, message, details, request_id}}`. Aquí se
/// aplana: `message` siempre es legible, `code` sirve para decidir qué hacer
/// y `fields` trae los errores por campo (HTTP 422).
class ApiException implements Exception {
  ApiException({
    required this.message,
    this.code,
    this.status,
    this.fields = const {},
    this.requestId,
  });

  final String message;
  final String? code;
  final int? status;
  final Map<String, String> fields;
  final String? requestId;

  bool get isNetwork => code == 'NETWORK';

  /// Mensaje para mostrar: suma el detalle por campo si lo hay.
  String get display {
    if (fields.isEmpty) return message;
    final detalle = fields.entries.map((e) => '${e.key}: ${e.value}').join(' · ');
    return '$message ($detalle)';
  }

  static ApiException from(Object error) {
    if (error is ApiException) return error;
    if (error is DioException) return _fromDio(error);
    return ApiException(
      message: 'Ocurrió un error inesperado. Intenta de nuevo.',
      code: 'UNKNOWN',
    );
  }

  static ApiException _fromDio(DioException e) {
    final res = e.response;
    final data = res?.data;

    if (data is Map && data['error'] is Map) {
      final err = data['error'] as Map;
      final fields = <String, String>{};
      final details = err['details'];
      if (details is List) {
        for (final d in details) {
          if (d is Map && d['field'] != null) {
            final nombre = d['field'].toString().split('.').last;
            fields[nombre] = (d['message'] ?? '').toString();
          }
        }
      }
      return ApiException(
        message: (err['message'] ?? 'Ocurrió un error.').toString(),
        code: err['code']?.toString(),
        status: res?.statusCode,
        fields: fields,
        requestId: err['request_id']?.toString(),
      );
    }

    if (res == null) {
      final timeout = e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.receiveTimeout ||
          e.type == DioExceptionType.sendTimeout;
      return ApiException(
        message: timeout
            ? 'El servidor tardó demasiado en responder. Intenta de nuevo.'
            : 'No hay conexión con el servidor. Revisa tu red e intenta de nuevo.',
        code: 'NETWORK',
      );
    }

    return ApiException(
      message: 'El servidor respondió con un error (${res.statusCode}).',
      code: 'HTTP_${res.statusCode}',
      status: res.statusCode,
    );
  }

  @override
  String toString() => display;
}
