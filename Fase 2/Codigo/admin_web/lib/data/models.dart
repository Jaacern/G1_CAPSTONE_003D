import '../core/format.dart';

Map<String, dynamic> _m(Object? v) => Map<String, dynamic>.from(v as Map);
List<Map<String, dynamic>> _l(Object? v) =>
    (v as List? ?? const []).map(_m).toList();
num? _n(Object? v) => v == null ? null : num.parse(v.toString());

// ── Usuarios ────────────────────────────────────────────────────────────
class UserRow {
  UserRow(Map<String, dynamic> j)
      : userId = j['user_id'] as String,
        email = j['email'] as String,
        fullName = j['full_name'] as String,
        accountType = j['account_type'] as String,
        status = j['status'] as String,
        planCode = j['plan_code'] as String,
        planName = j['plan_name'] as String,
        isStaff = j['is_staff'] as bool,
        createdAt = parseDate(j['created_at'])!;

  final String userId, email, fullName, accountType, status, planCode, planName;
  final bool isStaff;
  final DateTime createdAt;
}

class UsersResult {
  UsersResult(Map<String, dynamic> j)
      : items = _l(j['items']).map(UserRow.new).toList(),
        total = j['total'] as int,
        limit = j['limit'] as int,
        offset = j['offset'] as int;

  final List<UserRow> items;
  final int total, limit, offset;
}

class SubscriptionEntry {
  SubscriptionEntry(Map<String, dynamic> j)
      : planCode = j['plan_code'] as String,
        planName = j['plan_name'] as String,
        status = j['status'] as String,
        startedAt = parseDate(j['started_at'])!,
        periodEnd = parseDate(j['current_period_end']),
        cancelledAt = parseDate(j['cancelled_at']),
        grantedBy = j['granted_by_name'] as String?,
        reason = j['change_reason'] as String?,
        source = j['source'] as String,
        cancelRequestedAt = parseDate(j['cancel_requested_at']);

  final String planCode, planName, status, source;
  final DateTime startedAt;
  final DateTime? periodEnd, cancelledAt, cancelRequestedAt;
  final String? grantedBy, reason;

  bool get isCourtesy => source == 'admin';
}

class PaymentEntry {
  PaymentEntry(Map<String, dynamic> j)
      : type = j['type'] as String,
        status = j['status'] as String,
        amount = _n(j['amount']),
        currency = j['currency'] as String?,
        planName = j['plan_name'] as String,
        providerRef = j['provider_ref'] as String?,
        failureReason = j['failure_reason'] as String?,
        occurredAt = parseDate(j['occurred_at'])!;

  final String type, status, planName;
  final num? amount;
  final String? currency, providerRef, failureReason;
  final DateTime occurredAt;

  /// Las referencias SIM- vienen del proveedor simulado, no de una pasarela.
  bool get isSimulated => providerRef?.startsWith('SIM-') ?? false;
}

class AuditEntry {
  AuditEntry(Map<String, dynamic> j)
      : action = j['action'] as String,
        actorName = j['actor_name'] as String,
        targetName = j['target_name'] as String?,
        detail = _m(j['detail']),
        createdAt = parseDate(j['created_at'])!;

  final String action, actorName;
  final String? targetName;
  final Map<String, dynamic> detail;
  final DateTime createdAt;

  /// Una línea legible con lo que pasó.
  String get summary {
    final motivo = detail['reason'];
    switch (action) {
      case 'plan_assigned':
        final base = '${detail['from']} → ${detail['to']}';
        return motivo == null ? base : '$base · $motivo';
      case 'user_deactivated':
        return motivo == null ? '' : '$motivo';
      default:
        return '';
    }
  }
}

class UserDetail {
  UserDetail(Map<String, dynamic> j)
      : userId = j['user_id'] as String,
        email = j['email'] as String,
        fullName = j['full_name'] as String,
        phone = j['phone'] as String?,
        accountType = j['account_type'] as String,
        status = j['status'] as String,
        isStaff = j['is_staff'] as bool,
        createdAt = parseDate(j['created_at'])!,
        deactivatedAt = parseDate(j['deactivated_at']),
        deactivatedReason = j['deactivated_reason'] as String?,
        deactivatedBy = j['deactivated_by_name'] as String?,
        patients = j['pacientes'] as int,
        lastSession = parseDate(j['ultima_sesion']),
        planCode = j['plan_code'] as String,
        planName = j['plan_name'] as String,
        planEnds = parseDate(j['plan_vence']),
        subscriptions = _l(j['suscripciones']).map(SubscriptionEntry.new).toList(),
        payments = _l(j['pagos']).map(PaymentEntry.new).toList(),
        audit = _l(j['auditoria']).map(AuditEntry.new).toList();

  final String userId, email, fullName, accountType, status, planCode, planName;
  final String? phone, deactivatedReason, deactivatedBy;
  final bool isStaff;
  final DateTime createdAt;
  final DateTime? deactivatedAt, lastSession, planEnds;
  final int patients;
  final List<SubscriptionEntry> subscriptions;
  final List<PaymentEntry> payments;
  final List<AuditEntry> audit;
}

// ── Resumen ─────────────────────────────────────────────────────────────
class PlanShare {
  PlanShare(Map<String, dynamic> j)
      : code = j['plan_code'] as String,
        name = j['plan_name'] as String,
        tier = j['tier'] as int,
        source = j['source'] as String,
        users = j['usuarios'] as int;
  final String code, name, source;
  final int users, tier;

  bool get isCourtesy => tier > 0 && source == 'admin';

  String get label => isCourtesy ? '$name (cortesía)' : name;
}

class MonthRow {
  MonthRow(Map<String, dynamic> j)
      : month = j['mes'] as String,
        signups = j['altas'] as int,
        drops = j['bajas'] as int;
  final String month;
  final int signups, drops;
}

class Summary {
  Summary(Map<String, dynamic> j)
      : total = j['usuarios_total'] as int,
        active = j['usuarios_activos'] as int,
        inactive = j['usuarios_inactivos'] as int,
        deleted = j['usuarios_eliminados'] as int,
        byType = _m(j['por_tipo']).map((k, v) => MapEntry(k, v as int)),
        byPlan = _l(j['por_plan']).map(PlanShare.new).toList(),
        conversionPct = _n(j['conversion_pct'])?.toDouble(),
        monthRevenue = _n(j['ingresos_mes']) ?? 0,
        currency = j['moneda'] as String,
        monthCharges = j['cobros_mes'] as int,
        byMonth = _l(j['por_mes']).map(MonthRow.new).toList();

  final int total, active, inactive, deleted;
  final Map<String, int> byType;
  final List<PlanShare> byPlan;
  final double? conversionPct;
  final num monthRevenue;
  final String currency;
  final int monthCharges;
  final List<MonthRow> byMonth;
}

// ── Planes ──────────────────────────────────────────────────────────────
class PlanItem {
  PlanItem(Map<String, dynamic> j)
      : id = j['id'] as String,
        code = j['code'] as String,
        name = j['name'] as String,
        description = j['description'] as String?,
        tier = j['tier'] as int,
        isPublic = j['is_public'] as bool,
        status = j['status'] as String,
        features = j['features_incluidas'] as int,
        limits = j['limites_fijados'] as int,
        price = _n(j['precio_vigente']),
        currency = j['moneda'] as String?,
        subscribers = j['suscripciones_activas'] as int;

  final String id, code, name, status;
  final String? description, currency;
  final int tier, features, limits, subscribers;
  final bool isPublic;
  final num? price;

  bool get isActive => status == 'active';
}

class PlanFeature {
  PlanFeature(Map<String, dynamic> j)
      : code = j['code'] as String,
        label = j['label'] as String,
        description = j['description'] as String,
        module = j['module'] as String,
        isCore = j['is_core'] as bool,
        included = j['is_included'] as bool;
  final String code, label, description, module;
  final bool isCore, included;
}

class PlanLimit {
  PlanLimit(Map<String, dynamic> j)
      : key = j['key'] as String,
        label = j['label'] as String,
        description = j['description'] as String,
        unit = j['unit'] as String,
        value = j['value'] as int?,
        isSet = j['fijado'] as bool;
  final String key, label, description, unit;
  final int? value;
  final bool isSet;
}

class PlanPrice {
  PlanPrice(Map<String, dynamic> j)
      : currency = j['currency'] as String,
        period = j['period'] as String,
        amount = _n(j['amount'])!,
        validFrom = parseDate(j['valid_from'])!,
        validTo = parseDate(j['valid_to']);
  final String currency, period;
  final num amount;
  final DateTime validFrom;
  final DateTime? validTo;
}

class PlanDetail {
  PlanDetail(Map<String, dynamic> j)
      : plan = PlanItem(_m(j['plan'])),
        features = _l(j['features']).map(PlanFeature.new).toList(),
        limits = _l(j['limites']).map(PlanLimit.new).toList(),
        prices = _l(j['precios']).map(PlanPrice.new).toList();
  final PlanItem plan;
  final List<PlanFeature> features;
  final List<PlanLimit> limits;
  final List<PlanPrice> prices;
}

// ── Catálogo ────────────────────────────────────────────────────────────
class CatalogFeature {
  CatalogFeature(Map<String, dynamic> j)
      : code = j['code'] as String,
        label = j['label'] as String,
        description = j['description'] as String,
        module = j['module'] as String,
        isCore = j['is_core'] as bool,
        plans = j['planes_que_la_incluyen'] as int;
  final String code, label, description, module;
  final bool isCore;
  final int plans;
}

class CatalogLimit {
  CatalogLimit(Map<String, dynamic> j)
      : key = j['key'] as String,
        label = j['label'] as String,
        description = j['description'] as String,
        unit = j['unit'] as String,
        plans = j['planes_que_lo_fijan'] as int;
  final String key, label, description, unit;
  final int plans;
}

// ── Médicos ─────────────────────────────────────────────────────────────
class DoctorItem {
  DoctorItem(Map<String, dynamic> j)
      : userId = j['user_id'] as String,
        fullName = j['full_name'] as String,
        email = j['email'] as String,
        license = j['license_number'] as String,
        specialty = j['specialty'] as String?,
        verifiedAt = parseDate(j['verified_at'])!,
        revokedAt = parseDate(j['revoked_at']);
  final String userId, fullName, email, license;
  final String? specialty;
  final DateTime verifiedAt;
  final DateTime? revokedAt;

  bool get revoked => revokedAt != null;
}

class Enrollment {
  Enrollment(Map<String, dynamic> j)
      : email = j['email'] as String,
        license = j['license_number'] as String,
        expiresAt = parseDate(j['expires_at'])!,
        token = j['enrollment_token'] as String;
  final String email, license, token;
  final DateTime expiresAt;
}
