import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/api_client.dart';
import '../core/session.dart';
import 'models.dart';

const _base = '/api/v1/admin';

final adminRepositoryProvider = Provider<AdminRepository>(
  (ref) => AdminRepository(ref.watch(apiClientProvider)),
);

class AdminRepository {
  AdminRepository(this._api);
  final ApiClient _api;

  // ── Resumen y actividad ──
  Future<Summary> summary() async =>
      Summary(Map<String, dynamic>.from(await _api.get('$_base/summary') as Map));

  Future<List<AuditEntry>> audit({int limit = 100}) async {
    final r = await _api.get('$_base/audit', query: {'limit': limit}) as Map;
    return (r['items'] as List)
        .map((e) => AuditEntry(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  // ── Usuarios ──
  Future<UsersResult> users({
    String? q,
    String status = 'all',
    String? plan,
    String? accountType,
    int limit = 25,
    int offset = 0,
  }) async {
    final r = await _api.get('$_base/users', query: {
      if (q != null && q.trim().isNotEmpty) 'q': q.trim(),
      'status': status,
      'plan': ?plan,
      'account_type': ?accountType,
      'limit': limit,
      'offset': offset,
    });
    return UsersResult(Map<String, dynamic>.from(r as Map));
  }

  Future<UserDetail> user(String id) async => UserDetail(
        Map<String, dynamic>.from(await _api.get('$_base/users/$id') as Map),
      );

  Future<UserDetail> assignPlan(
    String id, {
    required String planCode,
    DateTime? validUntil,
    required String reason,
  }) async =>
      UserDetail(Map<String, dynamic>.from(await _api.post(
        '$_base/users/$id/plan',
        body: {
          'plan_code': planCode,
          if (validUntil != null) 'valid_until': validUntil.toUtc().toIso8601String(),
          'reason': reason,
        },
      ) as Map));

  Future<UserDetail> deactivate(String id, String reason) async =>
      UserDetail(Map<String, dynamic>.from(await _api.post(
        '$_base/users/$id/deactivate',
        body: {'reason': reason},
      ) as Map));

  Future<UserDetail> reactivate(String id) async => UserDetail(
        Map<String, dynamic>.from(
            await _api.post('$_base/users/$id/reactivate') as Map),
      );

  // ── Planes ──
  Future<List<PlanItem>> plans() async {
    final r = await _api.get('$_base/plans') as Map;
    return (r['items'] as List)
        .map((e) => PlanItem(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  Future<PlanDetail> planDetail(String id) async => PlanDetail(
        Map<String, dynamic>.from(await _api.get('$_base/plans/$id') as Map),
      );

  Future<void> createPlan({
    required String code,
    required String name,
    String? description,
    required int tier,
  }) =>
      _api.post('$_base/plans', body: {
        'code': code,
        'name': name,
        if (description != null && description.isNotEmpty) 'description': description,
        'tier': tier,
      });

  Future<void> editPlan(
    String id, {
    required String name,
    String? description,
    required int tier,
    required bool isPublic,
  }) =>
      _api.patch('$_base/plans/$id', body: {
        'name': name,
        'description': description,
        'tier': tier,
        'is_public': isPublic,
      });

  Future<void> publishPlan(String id) => _api.post('$_base/plans/$id/publish');
  Future<void> archivePlan(String id) => _api.post('$_base/plans/$id/archive');

  Future<void> setFeature(String planId, String code, bool included) =>
      _api.put('$_base/plans/$planId/features/$code',
          body: {'is_included': included});

  /// [value] nulo = sin tope. Cero = no incluido.
  Future<void> setLimit(String planId, String key, int? value) =>
      _api.put('$_base/plans/$planId/limits/$key', body: {'value': value});

  Future<void> clearLimit(String planId, String key) =>
      _api.delete('$_base/plans/$planId/limits/$key');

  Future<void> newPrice(
    String planId, {
    required String period,
    required num amount,
    required String currency,
  }) =>
      _api.post('$_base/plans/$planId/prices', body: {
        'period': period,
        'amount': amount,
        'currency': currency,
      });

  // ── Catálogo ──
  Future<List<CatalogFeature>> catalogFeatures() async {
    final r = await _api.get('$_base/features') as Map;
    return (r['items'] as List)
        .map((e) => CatalogFeature(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  Future<List<CatalogLimit>> catalogLimits() async {
    final r = await _api.get('$_base/limit-keys') as Map;
    return (r['items'] as List)
        .map((e) => CatalogLimit(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  Future<void> createFeature({
    required String code,
    required String label,
    required String description,
    required String module,
    required bool isCore,
  }) =>
      _api.post('$_base/features', body: {
        'code': code,
        'label': label,
        'description': description,
        'module': module,
        'is_core': isCore,
      });

  Future<void> createLimit({
    required String key,
    required String label,
    required String description,
    required String unit,
  }) =>
      _api.post('$_base/limit-keys', body: {
        'key': key,
        'label': label,
        'description': description,
        'unit': unit,
      });

  // ── Médicos ──
  Future<List<DoctorItem>> doctors() async {
    final r = await _api.get('$_base/doctors') as Map;
    return (r['items'] as List)
        .map((e) => DoctorItem(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  Future<Enrollment> enrollDoctor({
    required String email,
    required String license,
    String? specialty,
  }) async =>
      Enrollment(Map<String, dynamic>.from(await _api.post(
        '$_base/doctors/enrollments',
        body: {
          'email': email,
          'license_number': license,
          if (specialty != null && specialty.isNotEmpty) 'specialty': specialty,
        },
      ) as Map));

  Future<void> revokeDoctor(String userId, String reason) =>
      _api.post('$_base/doctors/$userId/revoke', body: {'reason': reason});
}
