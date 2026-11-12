import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/app_config.dart';
import '../../../core/network/api_client.dart';
import '../../../core/offline/cache_de_lectura.dart';
import '../domain/models.dart';

/// Una página de alertas tal como la devuelve 9.1: los ítems de esa página,
/// cuántas alertas hay en total y cuántas siguen activas.
class AlertsPage {
  const AlertsPage({
    required this.items,
    required this.total,
    required this.unreadCount,
    required this.page,
    required this.pageSize,
  });

  final List<Alert> items;

  /// Alertas que cumplen el filtro, en todas las páginas.
  final int total;

  /// Alertas activas del usuario (el backend las cuenta aparte del filtro).
  final int unreadCount;

  final int page;
  final int pageSize;

  bool get hasMore => page * pageSize < total;

  static const vacio =
      AlertsPage(items: [], total: 0, unreadCount: 0, page: 1, pageSize: 20);
}

abstract class AlertsRepository {
  /// Lista las alertas del usuario. Si [activeOnly] es true solo devuelve las
  /// activas; [patientId] filtra por paciente. El backend devuelve 20 alertas
  /// por página, así que se pide de a una y [AlertsPage.hasMore] dice si falta.
  Future<AlertsPage> listAlerts({
    String? patientId,
    bool activeOnly = false,
    int page = 1,
    int pageSize = 20,
  });

  /// Marca una alerta como reconocida (acknowledged).
  Future<void> acknowledge(String alertId);

  /// Resuelve una alerta, con nota opcional.
  Future<void> resolve(String alertId, {String? note});

  /// Envía una alerta SOS para el paciente indicado.
  Future<void> sendSos(String patientId,
      {double? lat, double? lng, String? note});
}

// ---------------------------------------------------------------------------
// HTTP
// ---------------------------------------------------------------------------
class AlertsRepositoryHttp implements AlertsRepository {
  AlertsRepositoryHttp(this._api, this._cache);
  final ApiClient _api;
  final CacheDeLectura _cache;

  @override
  Future<AlertsPage> listAlerts(
      {String? patientId,
      bool activeOnly = false,
      int page = 1,
      int pageSize = 20}) async {
    Future<Map<String, dynamic>> delServidor() =>
        _api.get<Map<String, dynamic>>(
          '/users/me/alerts',
          query: {
            'status': activeOnly ? 'active' : 'all',
            'page': page,
            'page_size': pageSize,
            if (patientId != null) 'patient_id': patientId,
          },
        );

    // Solo la primera pagina. Guardar las siguientes serviria de poco: sin
    // conexion nadie va a paginar un historial, y lo que importa es poder
    // ver las alertas activas del paciente que se esta viendo.
    final data = page != 1
        ? await delServidor()
        : await _cache.leer(
            'alertas_${patientId ?? 'todas'}_${activeOnly ? 'activas' : 'todas'}',
            delServidor,
          );
    final items = ((data['items'] ?? []) as List)
        .map((e) => Alert.fromJson(e as Map<String, dynamic>))
        .toList();
    return AlertsPage(
      items: items,
      total: (data['total'] as num?)?.toInt() ?? items.length,
      unreadCount: (data['unread_count'] as num?)?.toInt() ?? 0,
      page: page,
      pageSize: pageSize,
    );
  }

  @override
  Future<void> acknowledge(String alertId) =>
      _api.post<void>('/alerts/$alertId/acknowledge');

  @override
  Future<void> resolve(String alertId, {String? note}) => _api.post<void>(
        '/alerts/$alertId/resolve',
        data: {if (note != null && note.isNotEmpty) 'resolution_note': note},
      );

  @override
  Future<void> sendSos(String patientId,
      {double? lat, double? lng, String? note}) {
    // El backend (9.6) solo acepta una nota opcional. La ubicación se
    // conserva en la firma para la UI, pero no se envía al backend actual.
    final loc = (lat != null && lng != null) ? 'Ubicación: $lat, $lng' : null;
    final body = [
      if (note != null && note.trim().isNotEmpty) note.trim(),
      if (loc != null) loc,
    ].join(' · ');
    return _api.post<void>(
      '/patients/$patientId/sos',
      data: {if (body.isNotEmpty) 'note': body},
    );
  }
}

// ---------------------------------------------------------------------------
// Mock
// ---------------------------------------------------------------------------
class AlertsRepositoryMock implements AlertsRepository {
  AlertsRepositoryMock() {
    final now = DateTime.now();
    _alerts = [
      Alert(
        id: 'a-fall-1',
        patientId: 'p-elena',
        patientName: 'Elena Ramírez',
        type: AlertType.fall,
        severity: AlertSeverity.critical,
        title: 'Posible caída detectada',
        message:
            'El wearable detectó un impacto compatible con una caída en el domicilio. '
            'Confirma el estado de Elena lo antes posible.',
        createdAt: now.subtract(const Duration(minutes: 4)),
        status: AlertStatus.active,
        meta: const {'location': 'Domicilio', 'confidence': 0.88},
      ),
      Alert(
        id: 'a-hr-1',
        patientId: 'p-jose',
        patientName: 'José Ramírez',
        type: AlertType.vitalOutOfRange,
        severity: AlertSeverity.warning,
        title: 'Ritmo cardíaco elevado',
        message:
            'La frecuencia cardíaca de José superó las 120 ppm en reposo durante '
            'los últimos 15 minutos.',
        createdAt: now.subtract(const Duration(minutes: 26)),
        status: AlertStatus.active,
        meta: const {'vital': 'heart_rate', 'value': 124, 'unit': 'ppm'},
      ),
      Alert(
        id: 'a-med-1',
        patientId: 'p-elena',
        patientName: 'Elena Ramírez',
        type: AlertType.medicationMissed,
        severity: AlertSeverity.warning,
        title: 'Dosis omitida',
        message: 'No se confirmó la toma de Losartán 50 mg de las 08:00. '
            'Revisa si Elena tomó su medicación.',
        createdAt: now.subtract(const Duration(hours: 2, minutes: 10)),
        status: AlertStatus.acknowledged,
        acknowledgedBy: 'María (familiar)',
        meta: const {'medication': 'Losartán 50 mg', 'scheduled': '08:00'},
      ),
      Alert(
        id: 'a-wear-1',
        patientId: 'p-jose',
        patientName: 'José Ramírez',
        type: AlertType.wearableOffline,
        severity: AlertSeverity.info,
        title: 'Wearable sin conexión',
        message:
            'El reloj de José no sincroniza datos desde hace más de 3 horas. '
            'Puede estar sin batería o fuera de alcance.',
        createdAt: now.subtract(const Duration(hours: 3, minutes: 20)),
        status: AlertStatus.active,
        meta: const {'last_sync_hours': 3},
      ),
    ];
  }

  late final List<Alert> _alerts;

  @override
  Future<AlertsPage> listAlerts(
      {String? patientId,
      bool activeOnly = false,
      int page = 1,
      int pageSize = 20}) async {
    await Future.delayed(const Duration(milliseconds: 350));
    final filtradas = _alerts.where((a) {
      if (patientId != null && a.patientId != patientId) return false;
      if (activeOnly && !a.isActive) return false;
      return true;
    }).toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

    // El demo también pagina, para que 'Cargar más' se vea igual que con el
    // backend conectado.
    final desde = ((page - 1) * pageSize).clamp(0, filtradas.length);
    final hasta = (desde + pageSize).clamp(0, filtradas.length);
    return AlertsPage(
      items: filtradas.sublist(desde, hasta),
      total: filtradas.length,
      unreadCount: filtradas.where((a) => a.isActive).length,
      page: page,
      pageSize: pageSize,
    );
  }

  @override
  Future<void> acknowledge(String alertId) async {
    await Future.delayed(const Duration(milliseconds: 300));
    final i = _alerts.indexWhere((a) => a.id == alertId);
    if (i == -1) {
      throw ApiException(
          statusCode: 404,
          code: 'NOT_FOUND',
          message: 'La alerta ya no está disponible.');
    }
    _alerts[i] = _alerts[i].copyWith(
      status: AlertStatus.acknowledged,
      acknowledgedBy: 'Tú',
    );
  }

  @override
  Future<void> resolve(String alertId, {String? note}) async {
    await Future.delayed(const Duration(milliseconds: 300));
    final i = _alerts.indexWhere((a) => a.id == alertId);
    if (i == -1) {
      throw ApiException(
          statusCode: 404,
          code: 'NOT_FOUND',
          message: 'La alerta ya no está disponible.');
    }
    _alerts[i] = _alerts[i].copyWith(
      status: AlertStatus.resolved,
      resolvedAt: DateTime.now(),
    );
  }

  @override
  Future<void> sendSos(String patientId,
      {double? lat, double? lng, String? note}) async {
    await Future.delayed(const Duration(milliseconds: 500));
    _alerts.insert(
      0,
      Alert(
        id: 'a-sos-${DateTime.now().millisecondsSinceEpoch}',
        patientId: patientId,
        patientName: '',
        type: AlertType.sos,
        severity: AlertSeverity.critical,
        title: 'Alerta SOS enviada',
        message: note?.isNotEmpty == true
            ? note!
            : 'Se envió una alerta SOS manual a la red de cuidado.',
        createdAt: DateTime.now(),
        status: AlertStatus.active,
        meta: {if (lat != null) 'lat': lat, if (lng != null) 'lng': lng},
      ),
    );
  }
}

final alertsRepositoryProvider = Provider<AlertsRepository>((ref) {
  if (AppConfig.useMocks) return AlertsRepositoryMock();
  return AlertsRepositoryHttp(
      ref.watch(apiClientProvider), ref.watch(cacheDeLecturaProvider));
});
