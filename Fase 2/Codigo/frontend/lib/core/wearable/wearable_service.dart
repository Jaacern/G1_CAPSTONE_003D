import 'package:flutter_riverpod/flutter_riverpod.dart';
// Se importa con prefijo `spike` porque el SDK exporta un símbolo `Provider`
// que colisiona con el `Provider` de Riverpod.
import 'package:spike_flutter_sdk/spike_flutter_sdk.dart' as spike;
import 'package:url_launcher/url_launcher.dart';

import '../config/app_config.dart';
import '../network/api_client.dart';

/// Credenciales de Spike emitidas por el backend para un end-user (paciente).
///
/// Contrato con el backend (POST /patients/{id}/wearable):
///   { "application_id": 1234, "signature": "<jwt>", "end_user_id": "p-elena",
///     "connection_id": "..." (opcional) }
class SpikeCredentials {
  const SpikeCredentials({
    required this.applicationId,
    required this.signature,
    required this.endUserId,
    this.connectionId,
  });

  final int applicationId;
  final String signature;
  final String endUserId;
  final String? connectionId;

  factory SpikeCredentials.fromJson(Map<String, dynamic> json) => SpikeCredentials(
        applicationId: (json['application_id'] as num).toInt(),
        signature: json['signature'] as String,
        endUserId: json['end_user_id'] as String,
        connectionId: json['connection_id'] as String?,
      );
}

/// Servicio de wearables sobre el Spike SDK v3.
///
/// Flujo (plan v1, Spike real):
///  1. La app pide credenciales firmadas al backend (POST /patients/{id}/wearable).
///  2. Crea una conexión Spike (SpikeSDKV3.createConnection).
///  3. Solicita permisos de HealthKit / Health Connect y dispara un backfill;
///     Spike entrega los datos estandarizados al backend (webhook -> ingesta
///     batch en /patients/{id}/vitals/batch), donde se calcula el semáforo.
///  4. Habilita background delivery para sincronización continua.
///
/// Los proveedores de terceros (Garmin, Whoop, ...) se conectan por OAuth con
/// getIntegrationInitUrl + navegador del sistema.
class WearableService {
  WearableService(this._api);

  final ApiClient _api;
  spike.SpikeConnectionV3? _connection;

  static bool _sdkInitialized = false;

  /// Métricas de salud relevantes para AgeCare (adulto mayor).
  static const _statTypes = <spike.StatisticsType>[
    spike.StatisticsType.heartrate,
    spike.StatisticsType.heartrateResting,
    spike.StatisticsType.steps,
    spike.StatisticsType.sleepDurationTotal,
  ];

  static Future<void> _ensureSdk() async {
    if (_sdkInitialized) return;
    spike.SpikeSDKV3.init();
    await spike.SpikeSDKV3.setLogCallback(
      callback: (level, message) {
        // ignore: avoid_print
        print('SpikeSDK[${level.toJson()}]: $message');
      },
    );
    _sdkInitialized = true;
  }

  /// Vincula el wearable del paciente: crea la conexión Spike y pide permisos.
  Future<void> linkPatient(String patientId) async {
    await _ensureSdk();
    final creds = await _fetchCredentials(patientId);

    final connection = await spike.SpikeSDKV3.createConnection(
      applicationId: creds.applicationId,
      signature: creds.signature,
      endUserId: creds.endUserId,
      desiredConnectionId: creds.connectionId,
    );
    _connection = connection;

    // Permisos + backfill de 30 días. En iOS usa HealthKit, en Android Health
    // Connect. Spike decide según la plataforma; llamamos ambos de forma segura.
    try {
      await connection.requestPermissionsFromHealthKitAndBackfill(
        statisticTypes: _statTypes,
        days: 30,
      );
    } catch (_) {/* no iOS/HealthKit: ignora */}
    try {
      await connection.requestPermissionsFromHealthConnectAndBackfill(
        statisticTypes: _statTypes,
        days: 30,
      );
    } catch (_) {/* no Android/Health Connect: ignora */}

    // Sincronización continua en segundo plano.
    try {
      await connection.enableBackgroundDelivery(statisticTypes: _statTypes);
    } catch (_) {/* opcional */}
  }

  /// Conecta un proveedor de terceros (Garmin, Whoop, ...) por OAuth.
  Future<void> connectProvider(String patientId, spike.Provider provider) async {
    await _ensureSdk();
    final connection = _connection ?? await _openConnection(patientId);
    final url = await connection.getIntegrationInitUrl(provider: provider);
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  /// Lee estadísticas recientes directamente del SDK (para vista inmediata).
  /// La fuente de verdad sigue siendo el backend; esto es un complemento.
  Future<List<spike.Statistic>> recentStatistics(
    String patientId, {
    int days = 7,
  }) async {
    await _ensureSdk();
    final connection = _connection ?? await _openConnection(patientId);
    final now = DateTime.now();
    return connection.getStatistics(
      ofTypes: _statTypes,
      from: now.subtract(Duration(days: days)),
      to: now,
      interval: spike.StatisticsInterval.day,
    );
  }

  Future<spike.SpikeConnectionV3> _openConnection(String patientId) async {
    final creds = await _fetchCredentials(patientId);
    final connection = await spike.SpikeSDKV3.createConnection(
      applicationId: creds.applicationId,
      signature: creds.signature,
      endUserId: creds.endUserId,
      desiredConnectionId: creds.connectionId,
    );
    _connection = connection;
    return connection;
  }

  Future<SpikeCredentials> _fetchCredentials(String patientId) async {
    // Modo demo: credenciales ficticias para no romper el flujo sin backend.
    if (AppConfig.useMocks) {
      return SpikeCredentials(
        applicationId: AppConfig.spikeAppId == 0 ? 1 : AppConfig.spikeAppId,
        signature: 'mock-signature',
        endUserId: patientId,
      );
    }
    final data = await _api.post<Map<String, dynamic>>(
      '/patients/$patientId/wearable',
      data: {'platform': 'spike'},
    );
    return SpikeCredentials.fromJson(data);
  }

  Future<void> dispose() async {
    try {
      await _connection?.close();
    } catch (_) {}
    _connection = null;
  }
}

final wearableServiceProvider = Provider<WearableService>((ref) {
  final service = WearableService(ref.watch(apiClientProvider));
  ref.onDispose(service.dispose);
  return service;
});
