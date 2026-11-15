/// Historial del paciente: eventos de una sola línea de tiempo
/// (GET /patients/{id}/timeline).
library;

enum TimelineKind {
  observation('observation', 'Bitácora'),
  incident('incident', 'Incidente'),
  handover('handover', 'Relevo'),
  dose('dose', 'Dosis'),
  prn('prn', 'SOS'),
  alert('alert', 'Alerta'),
  treatment('treatment', 'Tratamiento'),
  vital('vital', 'Signo vital'),
  unknown('', 'Evento');

  const TimelineKind(this.apiValue, this.label);
  final String apiValue;
  final String label;

  static TimelineKind fromApi(String v) => TimelineKind.values
      .firstWhere((k) => k.apiValue == v, orElse: () => TimelineKind.unknown);
}

/// Filtros del historial, agrupando tipos que se leen juntos.
enum TimelineFilter {
  todo('Todo', []),
  vitales('Signos vitales', [TimelineKind.vital]),
  medicacion('Medicación',
      [TimelineKind.dose, TimelineKind.prn, TimelineKind.treatment]),
  bitacora('Bitácora',
      [TimelineKind.observation, TimelineKind.handover, TimelineKind.incident]),
  alertas('Alertas', [TimelineKind.alert, TimelineKind.incident]);

  const TimelineFilter(this.label, this.kinds);
  final String label;

  /// Vacío = todos los tipos.
  final List<TimelineKind> kinds;
}

class TimelineEvent {
  const TimelineEvent({
    required this.id,
    required this.kind,
    required this.ts,
    required this.title,
    this.subtype,
    this.severity,
    this.detail,
    this.author,
    this.value,
    this.valueSecondary,
    this.unit,
  });

  final String id;
  final TimelineKind kind;
  final DateTime ts;
  final String title;
  final String? subtype;
  final String? severity;
  final String? detail;
  final String? author;
  final double? value;
  final double? valueSecondary;
  final String? unit;

  /// Algo que el médico tiene que notar: dosis omitida, evento adverso,
  /// signo fuera de rango, alerta o incidente grave.
  bool get esImportante =>
      severity == 'warning' || severity == 'critical' || severity == 'high';

  bool get esCritico => severity == 'critical';

  /// Valor del signo vital listo para leer: "148/92 mmHg", "36,8 °C".
  String? get valorLegible {
    if (value == null) return null;
    String n(double v, {int dec = 0}) =>
        v.toStringAsFixed(dec).replaceAll('.', ',');
    final dec = subtype == 'temperature' ? 1 : 0;
    final txt = valueSecondary != null
        ? '${n(value!)}/${n(valueSecondary!)}'
        : n(value!, dec: dec);
    return (unit ?? '').isEmpty ? txt : '$txt $unit';
  }

  /// Estado de una dosis en palabras.
  String? get estadoDosis => switch (subtype) {
        'taken' => 'Tomada',
        'skipped' => 'No se dio',
        'missed' => 'Omitida',
        'adverse' => 'Con problema',
        'postponed' => 'Pospuesta',
        _ => null,
      };

  factory TimelineEvent.fromJson(Map<String, dynamic> j) => TimelineEvent(
        id: j['id'] as String,
        kind: TimelineKind.fromApi((j['kind'] ?? '') as String),
        ts: DateTime.parse(j['ts'] as String),
        title: (j['title'] ?? '') as String,
        subtype: j['subtype'] as String?,
        severity: j['severity'] as String?,
        detail: j['detail'] as String?,
        author: j['author'] as String?,
        value: (j['value'] as num?)?.toDouble(),
        valueSecondary: (j['value_secondary'] as num?)?.toDouble(),
        unit: j['unit'] as String?,
      );
}

class TimelinePage {
  const TimelinePage({required this.items, this.nextCursor});
  final List<TimelineEvent> items;

  /// null = no hay más páginas.
  final String? nextCursor;
}
