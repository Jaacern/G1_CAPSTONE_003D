import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';

/// Descarga de reportes PDF del paciente (Fase 6).
///
/// El backend genera el PDF al vuelo con autorización Bearer, así que no es una
/// URL pública: se piden los bytes con el token y la capa de presentación
/// decide cómo abrirlos/compartirlos según la plataforma.
class ReportsRepository {
  ReportsRepository(this._api);
  final ApiClient _api;

  /// Hoja de emergencia (1 página) para mostrar a un paramédico / doctor de
  /// turno: identidad, alergias, tratamientos, signos vitales, contactos.
  Future<Uint8List> emergencySheet(String patientId) async {
    final bytes = await _api.getBytes(
      '/patients/$patientId/report',
      query: {'type': 'emergency'},
    );
    return Uint8List.fromList(bytes);
  }

  /// Signos vitales alrededor de un incidente (±[windowHours] horas).
  Future<Uint8List> vitalsAroundIncident(
    String patientId, {
    DateTime? incidentAt,
    int windowHours = 1,
  }) async {
    final bytes = await _api.getBytes(
      '/patients/$patientId/report',
      query: {
        'type': 'vitals_incident',
        if (incidentAt != null) 'incident_at': incidentAt.toIso8601String(),
        'window_hours': windowHours,
      },
    );
    return Uint8List.fromList(bytes);
  }
}

final reportsRepositoryProvider = Provider<ReportsRepository>(
  (ref) => ReportsRepository(ref.watch(apiClientProvider)),
);
