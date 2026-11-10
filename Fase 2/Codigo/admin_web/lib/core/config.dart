/// Base de la API. Con valor vacío se usa el mismo origen que sirve el panel,
/// que es el caso de producción (la API entrega el build en /admin).
///
/// Para desarrollo:
///   flutter run -d chrome --dart-define=API_BASE_URL=http://localhost:8000
const String kApiBaseUrl = String.fromEnvironment('API_BASE_URL');
