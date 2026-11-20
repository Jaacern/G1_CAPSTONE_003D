import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/app_config.dart';
import '../../../core/network/api_client.dart';
import '../domain/_prn.dart';

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

/// Mock en memoria con las mismas reglas que el backend: intervalo mínimo
/// (409, se puede confirmar) y máximo de 24 h (422, no se puede saltar).
/// Solo Elena tiene un SOS: bromuro de ipratropio 2 puff cada 6 h.
class PrnRepositoryMock implements PrnRepository {
  PrnRepositoryMock({List<DateTime>? usosPrevios}) {
    for (final t in usosPrevios ?? const <DateTime>[]) {
      _usos.add(PrnUse(
        useId: 'u-${_usos.length}',
        itemId: _item,
        name: _nombre,
        dose: '2 puff',
        administeredAt: t,
        reason: 'Crisis de disnea',
        loggedByName: 'Marisol Tapia',
      ));
    }
  }

  static const _item = 'ti-ipratropio';
  static const _nombre = 'Bromuro de ipratropio';
  static const _dosis = 2.0;
  static const _maximo = 12.0;
  static const _intervalo = 360;
  final List<PrnUse> _usos = [];

  PrnItem _estado(DateTime ahora) {
    final en24h = _usos
        .where((u) => ahora.difference(u.administeredAt).inHours < 24)
        .length;
    final ultimo = _usos.isEmpty
        ? null
        : _usos
            .map((u) => u.administeredAt)
            .reduce((a, b) => a.isAfter(b) ? a : b);
    return PrnItem(
      itemId: _item,
      name: _nombre,
      dose: '2 puff',
      doseAmount: _dosis,
      doseUnit: 'puff',
      specialty: 'broncopulmonar',
      instructions: 'En crisis de disnea',
      minIntervalMin: _intervalo,
      maxDaily: _maximo,
      lastUsedAt: ultimo,
      nextAllowedAt: ultimo?.add(const Duration(minutes: _intervalo)),
      usesLast24h: en24h,
      usedLast24h: en24h * _dosis,
    );
  }

  @override
  Future<List<PrnItem>> listPrn(String patientId) async {
    await Future.delayed(const Duration(milliseconds: 150));
    if (patientId != 'p-elena') return const [];
    return [_estado(DateTime.now())];
  }

  @override
  Future<PrnUse> registerUse(
    String patientId,
    String itemId, {
    required String reason,
    DateTime? administeredAt,
    bool confirmInterval = false,
  }) async {
    await Future.delayed(const Duration(milliseconds: 150));
    final ahora = DateTime.now();
    final cuando = administeredAt ?? ahora;
    final it = _estado(ahora);
    if (it.alcanzoMaximo) {
      throw ApiException(
          statusCode: 422,
          code: 'PRN_MAX_DAILY',
          message: 'Con este uso serían 14 puff en 24 h y el máximo es 12. '
              'No registres otra dosis: consulta al médico.');
    }
    final temprano = it.antesDeTiempo(cuando);
    if (temprano && !confirmInterval) {
      throw ApiException(
          statusCode: 409,
          code: 'PRN_TOO_SOON',
          message: 'Todavía no se cumplen las 6 h desde el último uso. '
              'Confirma solo si el médico lo autorizó.');
    }
    final uso = PrnUse(
      useId: 'u-${_usos.length}',
      itemId: itemId,
      name: it.name,
      dose: it.dose,
      administeredAt: cuando,
      reason: reason,
      loggedByName: 'Marisol Tapia',
      overrodeInterval: temprano,
    );
    _usos.add(uso);
    return uso;
  }

  @override
  Future<List<PrnUse>> listUses(String patientId, {int days = 7}) async {
    await Future.delayed(const Duration(milliseconds: 150));
    if (patientId != 'p-elena') return const [];
    return [..._usos]
      ..sort((a, b) => b.administeredAt.compareTo(a.administeredAt));
  }
}

final prnRepositoryProvider = Provider<PrnRepository>((ref) {
  if (AppConfig.useMocks) return PrnRepositoryMock();
  return PrnRepositoryHttp(ref.watch(apiClientProvider));
});
