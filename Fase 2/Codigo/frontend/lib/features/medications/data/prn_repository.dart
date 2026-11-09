import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../domain/prn.dart';

/// Indicaciones SOS del paciente y el registro de cada uso.
abstract class PrnRepository {
  Future<List<PrnItem>> listPrn(String patientId);

  /// Registra que se dio una dosis SOS. [confirmInterval] va en true solo
  /// después de que el backend avisó (409) que aún no se cumple el intervalo.
  Future<PrnUse> registerUse(
    String patientId,
    String itemId, {
    required String reason,
    DateTime? administeredAt,
    bool confirmInterval = false,
  });

  Future<List<PrnUse>> listUses(String patientId, {int days = 7});
}

class PrnRepositoryHttp implements PrnRepository {
  PrnRepositoryHttp(this._api);
  final ApiClient _api;

  @override
  Future<List<PrnItem>> listPrn(String patientId) async {
    final data = await _api.get<List<dynamic>>('/patients/$patientId/prn');
    return data
        .map((e) => PrnItem.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  @override
  Future<PrnUse> registerUse(
    String patientId,
    String itemId, {
    required String reason,
    DateTime? administeredAt,
    bool confirmInterval = false,
  }) async {
    final data = await _api.post<Map<String, dynamic>>(
      '/patients/$patientId/prn/$itemId/uses',
      data: {
        'reason': reason,
        if (administeredAt != null)
          'administered_at': administeredAt.toUtc().toIso8601String(),
        if (confirmInterval) 'confirm_interval': true,
      },
    );
    return PrnUse.fromJson(data);
  }

  @override
  Future<List<PrnUse>> listUses(String patientId, {int days = 7}) async {
    final data = await _api.get<List<dynamic>>(
        '/patients/$patientId/prn/uses',
        query: {'days': days});
    return data
        .map((e) => PrnUse.fromJson(e as Map<String, dynamic>))
        .toList();
  }
}

final prnRepositoryProvider = Provider<PrnRepository>(
  (ref) => PrnRepositoryHttp(ref.watch(apiClientProvider)),
);
