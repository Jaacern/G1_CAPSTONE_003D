import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/app_config.dart';
import '../../../core/network/api_client.dart';

/// Código de vinculación generado por el backend para emparejar un Reloj
/// AgeCare con un paciente (RF-68). Se muestra en pantalla para dictarlo y
/// escribirlo en el reloj. Vence rápido y es de un solo uso.
class WatchLinkCode {
  const WatchLinkCode({required this.code, required this.expiresAt});

  final String code;
  final DateTime expiresAt;

  factory WatchLinkCode.fromJson(Map<String, dynamic> json) => WatchLinkCode(
        code: json['code'] as String,
        expiresAt: DateTime.parse(json['expires_at'] as String),
      );

  /// Segundos restantes hasta el vencimiento (nunca negativo).
  int get secondsLeft {
    final diff = expiresAt.difference(DateTime.now()).inSeconds;
    return diff < 0 ? 0 : diff;
  }
}

/// Servicio para el flujo de vinculación del Reloj AgeCare.
///
/// Contrato con el backend:
///   POST /patients/{id}/device-link-codes  -> { code, expires_at }
///
/// El reloj luego canjea ese código por su token con POST /devices/link, pero
/// eso ocurre en el propio reloj, no aquí.
class WatchLinkService {
  WatchLinkService(this._api);

  final ApiClient _api;

  /// Genera un código de vinculación para el paciente dado.
  Future<WatchLinkCode> createLinkCode(String patientId) async {
    // En modo demo no hay backend: devuelve un código ficticio para enseñar
    // la pantalla sin romper el flujo.
    if (AppConfig.useMocks) {
      return WatchLinkCode(
        code: '123456',
        expiresAt: DateTime.now().add(const Duration(minutes: 10)),
      );
    }
    final data = await _api.post<Map<String, dynamic>>(
      '/patients/$patientId/device-link-codes',
    );
    return WatchLinkCode.fromJson(data);
  }

  /// Consulta si el paciente tiene un Reloj AgeCare vinculado y vigente.
  Future<WatchStatus> getStatus(String patientId) async {
    if (AppConfig.useMocks) {
      return const WatchStatus(linked: false);
    }
    final data = await _api.get<Map<String, dynamic>>(
      '/patients/$patientId/watch/status',
    );
    return WatchStatus.fromJson(data);
  }

  /// Desvincula el reloj del paciente (para reasignarlo a otra persona).
  Future<void> unlink(String patientId) async {
    if (AppConfig.useMocks) return;
    await _api.delete<Map<String, dynamic>>('/patients/$patientId/watch');
  }
}

/// Estado de vinculación del Reloj AgeCare para un paciente.
class WatchStatus {
  const WatchStatus({
    required this.linked,
    this.deviceLabel,
    this.lastSeenAt,
    this.connected = false,
    this.batteryPct,
  });

  final bool linked;
  final String? deviceLabel;
  final DateTime? lastSeenAt;

  /// true = vinculado Y con actividad reciente (envía datos).
  /// false = vinculado pero "desconectado" (apagado/sin batería/fuera de rango).
  final bool connected;

  /// Nivel de batería del wearable (0–100), o null si no reportó.
  final int? batteryPct;

  /// Batería baja: 15% o menos (y conocida).
  bool get batteryLow => batteryPct != null && batteryPct! <= 15;

  factory WatchStatus.fromJson(Map<String, dynamic> json) => WatchStatus(
        linked: json['linked'] == true,
        deviceLabel: json['device_label'] as String?,
        lastSeenAt: json['last_seen_at'] != null
            ? DateTime.tryParse(json['last_seen_at'] as String)
            : null,
        connected: json['connected'] == true,
        batteryPct: json['battery_pct'] as int?,
      );
}

/// Estado del reloj del paciente seleccionado.
///
/// Se AUTO-REFRESCA cada 10s mientras algún widget lo observe: así el estado
/// (conectado/desconectado), la batería y la vinculación se mantienen frescos
/// solos, sin que el usuario tenga que tocar "recargar" ni arrastrar. Se
/// cancela solo cuando ningún widget lo usa (autoDispose + ref.onDispose).
final watchStatusProvider =
    FutureProvider.autoDispose.family<WatchStatus, String>((ref, patientId) {
  // Programa una re-consulta periódica mientras el provider esté vivo.
  final timer = Timer(const Duration(seconds: 10), () {
    ref.invalidateSelf();
  });
  ref.onDispose(timer.cancel);
  return ref.watch(watchLinkServiceProvider).getStatus(patientId);
});

final watchLinkServiceProvider = Provider<WatchLinkService>((ref) {
  return WatchLinkService(ref.watch(apiClientProvider));
});
