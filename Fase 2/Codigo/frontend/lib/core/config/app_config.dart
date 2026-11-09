/// Configuración de entorno de la app.
///
/// Se controla con --dart-define en tiempo de compilación:
///   flutter run --dart-define=USE_MOCKS=true
///   flutter run --dart-define=API_BASE_URL=https://api-dev.agecare.app --dart-define=USE_MOCKS=false
///   flutter run --dart-define=SPIKE_APP_ID=1000
class AppConfig {
  AppConfig._();

  /// true = repositorios en memoria con datos demo (no requiere backend).
  static const bool useMocks =
      bool.fromEnvironment('USE_MOCKS', defaultValue: true);

  static const String apiBaseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'https://api-dev.agecare.app',
  );

  /// Service token de Cloudflare Access. Necesario cuando el backend está
  /// detrás de Cloudflare Access (p. ej. el despliegue en srv01). Si quedan
  /// vacíos, no se envían las cabeceras (backend sin Access / local).
  /// Se pasan por --dart-define para no quemar el secreto en el repo:
  ///   --dart-define=CF_ACCESS_CLIENT_ID=xxxxx.access
  ///   --dart-define=CF_ACCESS_CLIENT_SECRET=xxxxx
  static const String cfAccessClientId =
      String.fromEnvironment('CF_ACCESS_CLIENT_ID', defaultValue: '');
  static const String cfAccessClientSecret =
      String.fromEnvironment('CF_ACCESS_CLIENT_SECRET', defaultValue: '');

  /// Mapa de cabeceras de Access, vacío si no está configurado el token.
  static Map<String, String> get cfAccessHeaders =>
      (cfAccessClientId.isNotEmpty && cfAccessClientSecret.isNotEmpty)
          ? {
              'CF-Access-Client-Id': cfAccessClientId,
              'CF-Access-Client-Secret': cfAccessClientSecret,
            }
          : <String, String>{};

  /// Application ID de Spike API (https://docs.spikeapi.com).
  static const int spikeAppId =
      int.fromEnvironment('SPIKE_APP_ID', defaultValue: 0);

  /// true = usa el simulador de wearable en lugar del SDK de Spike.
  /// El simulador es la fuente por defecto mientras no haya SPIKE_APP_ID.
  static const bool useWearableSimulator = bool.fromEnvironment(
    'USE_WEARABLE_SIMULATOR',
    defaultValue: true,
  );

  static const String appName = 'AgeCare';
  static const String apiVersion = '/api/v1';

  // --------------------------------------------------------------------------
  // Capacidades del backend (feature flags)
  // --------------------------------------------------------------------------
  // Un módulo queda en false solo si el backend todavía no lo tiene. En ese
  // caso, con useMocks=false la pantalla muestra "Próximamente" en vez de
  // llamar a un endpoint inexistente, y con useMocks=true sigue disponible
  // con datos simulados para poder enseñar el flujo completo.

  /// Comunicación: chat del círculo + asistente IA.
  static bool get hasComms => true;

  /// Marketplace: cuidadoras, ayudas técnicas y ofertas de trabajo.
  static bool get hasMarketplace => true;

  /// Documentos clínicos del paciente (recetas, estudios).
  static bool get hasDocuments => true;

  /// OCR / escaneo de recetas para proponer indicaciones.
  ///
  /// El servidor puede tener el motor apagado (OCR_PROVIDER=none), y en ese
  /// caso responde 503 con OCR_NOT_CONFIGURED. Eso lo avisa la pantalla
  /// cuando pasa; no se puede saber desde aquí antes de preguntar.
  static bool get hasPrescriptionScan => true;

  /// Fotos de familia y feed de contenido del adulto mayor.
  static bool get hasElderContent => true;

  /// Bitácora de la cuidadora: tareas, observaciones, incidentes, entrega de
  /// turno, check-in y reportes.
  static bool get hasCaregiverLog => true;
}
