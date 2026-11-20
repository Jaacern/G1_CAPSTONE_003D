/// Indicaciones SOS ("solo si se necesita") y el registro de cada uso.
///
/// Un SOS no genera dosis en la agenda: se da cuando el paciente lo necesita
/// (bromuro de ipratropio en una crisis de disnea). Por eso quien cuida tiene
/// que verlo aparte y anotar cada vez que lo da, con la hora y el motivo; si
/// no, el médico no sabe cuántas veces se usó.
library;

class PrnItem {
  const PrnItem({
    required this.itemId,
    required this.name,
    required this.dose,
    required this.doseAmount,
    required this.doseUnit,
    required this.specialty,
    this.instructions,
    this.scheduleLabel,
    this.minIntervalMin,
    this.maxDaily,
    this.lastUsedAt,
    this.nextAllowedAt,
    this.usesLast24h = 0,
    this.usedLast24h = 0,
  });

  final String itemId;
  final String name;
  final String dose; // "2 puff"
  final double doseAmount;
  final String doseUnit;
  final String specialty;
  final String? instructions;
  final String? scheduleLabel;
  final int? minIntervalMin;
  final double? maxDaily; // máximo de 24 h del catálogo, en doseUnit
  final DateTime? lastUsedAt;
  final DateTime? nextAllowedAt;
  final int usesLast24h;
  final double usedLast24h; // cantidad dada en 24 h

  /// Una dosis más pasaría el máximo de 24 h: no se puede dar sin el médico.
  bool get alcanzoMaximo =>
      maxDaily != null && usedLast24h + doseAmount > maxDaily!;

  /// Todavía no se cumple el intervalo mínimo desde el último uso.
  bool antesDeTiempo(DateTime ahora) =>
      nextAllowedAt != null && ahora.isBefore(nextAllowedAt!);

  /// "cada 6 h", "cada 90 min" o null si no hay intervalo indicado.
  String? get intervaloLegible =>
      minIntervalMin == null ? null : intervaloTexto(minIntervalMin!);

  factory PrnItem.fromJson(Map<String, dynamic> j) => PrnItem(
        itemId: j['item_id'] as String,
        name: j['name'] as String,
        dose: (j['dose'] ?? '') as String,
        doseAmount: (j['dose_amount'] as num).toDouble(),
        doseUnit: (j['dose_unit'] ?? '') as String,
        specialty: (j['specialty'] ?? 'general') as String,
        instructions: j['instructions'] as String?,
        scheduleLabel: j['schedule_label'] as String?,
        minIntervalMin: j['min_interval_min'] as int?,
        maxDaily: (j['max_daily'] as num?)?.toDouble(),
        lastUsedAt: _fecha(j['last_used_at']),
        nextAllowedAt: _fecha(j['next_allowed_at']),
        usesLast24h: (j['uses_last_24h'] ?? 0) as int,
        usedLast24h: ((j['used_last_24h'] ?? 0) as num).toDouble(),
      );
}

/// Un uso registrado de un SOS.
class PrnUse {
  const PrnUse({
    required this.useId,
    required this.itemId,
    required this.name,
    required this.dose,
    required this.administeredAt,
    required this.reason,
    this.loggedByName,
    this.overrodeInterval = false,
  });

  final String useId;
  final String itemId;
  final String name;
  final String dose;
  final DateTime administeredAt;
  final String reason;
  final String? loggedByName;

  /// Se dio antes de cumplirse el intervalo, tras confirmarlo.
  final bool overrodeInterval;

  factory PrnUse.fromJson(Map<String, dynamic> j) => PrnUse(
        useId: j['use_id'] as String,
        itemId: j['item_id'] as String,
        name: j['name'] as String,
        dose: (j['dose'] ?? '') as String,
        administeredAt: _fecha(j['administered_at']) ?? DateTime.now(),
        reason: (j['reason'] ?? '') as String,
        loggedByName: j['logged_by_name'] as String?,
        overrodeInterval: (j['overrode_interval'] ?? false) as bool,
      );
}

/// "cada 6 h" o "cada 90 min".
String intervaloTexto(int minutos) =>
    minutos % 60 == 0 ? 'cada ${minutos ~/ 60} h' : 'cada $minutos min';

DateTime? _fecha(Object? v) =>
    v == null ? null : DateTime.tryParse(v as String)?.toLocal();
