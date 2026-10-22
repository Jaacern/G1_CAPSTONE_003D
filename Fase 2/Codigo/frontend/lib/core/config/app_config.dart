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

  /// Application ID de Spike API (https://docs.spikeapi.com).
  static const int spikeAppId = int.fromEnvironment('SPIKE_APP_ID', defaultValue: 0);

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
  // El backend actual implementa los módulos 3 (auth), 4 (pacientes),
  // 5 (vitals/semáforo), 6 (medicamentos/adherencia) y 9 (alertas/SOS).
  //
  // Los siguientes módulos NO tienen endpoints en el backend todavía. Mientras
  // tanto, en modo backend real (useMocks=false) se muestran como
  // "Próximamente"; en modo demo (useMocks=true) siguen disponibles con datos
  // simulados en memoria para poder enseñar el flujo completo.
  //
  // La regla es simple: un módulo sin backend solo está habilitado si estamos
  // en modo mocks. Así la app nunca llama a endpoints inexistentes.

  /// Comunicación: chat de familia + asistente IA. Sin backend aún.
  static bool get hasComms => useMocks;

  /// Marketplace de cuidadoras y artículos. Sin backend aún.
  static bool get hasMarketplace => useMocks;

  /// Documentos clínicos del paciente (recetas, estudios). Sin backend aún.
  static bool get hasDocuments => useMocks;

  /// OCR / escaneo de recetas para crear medicamentos. Sin backend aún.
  static bool get hasPrescriptionScan => useMocks;

  /// Fotos de familia y feed de contenido del adulto mayor. Sin backend aún.
  static bool get hasElderContent => useMocks;

  /// Bitácora de la cuidadora: tareas, observaciones, incidentes, entrega de
  /// turno, check-in y reportes (/caregiver/*). Sin backend aún.
  static bool get hasCaregiverLog => useMocks;
}
