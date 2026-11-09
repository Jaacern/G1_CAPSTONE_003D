import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';

/// Estado de una dosis (alineado con la API).
///
/// [skipped] es solo de lectura: el backend la usa en su historial pero
/// 6.6 no admite recibirla, así que al registrar se traduce a [missed].
enum DoseStatus {
  pending('pending', 'Pendiente', AppColors.textSecondary),
  taken('taken', 'Tomada', AppColors.statusOk),
  postponed('postponed', 'Pospuesta', AppColors.statusWarning),
  skipped('skipped', 'Omitida', AppColors.statusWarning),
  missed('missed', 'No tomada', AppColors.statusAttention);

  const DoseStatus(this.apiValue, this.label, this.color);

  final String apiValue;
  final String label;
  final Color color;

  static DoseStatus fromApi(String value) => DoseStatus.values.firstWhere(
        (s) => s.apiValue == value,
        orElse: () => DoseStatus.pending,
      );
}

/// Medicamento del plan del paciente.
// ---------------------------------------------------------------------------
// Unidades de dosis
//
// Son exactamente las diez que acepta el backend (ck_medications_dose_unit en
// 301_medications.sql). Si se agrega una aca sin agregarla alla, el guardado
// falla con un error de restriccion que no le dice nada util al usuario.
//
// Se separan por como se leen. Las de medida no cambian con la cantidad; las
// que se cuentan se pluralizan, porque "2 comprimido" no lo dice nadie.
// ---------------------------------------------------------------------------

/// Unidades de medida: la cantidad no las modifica.
const unidadesDeMedida = <String>['mg', 'g', 'mcg', 'ml', 'UI'];

/// Unidades que se cuentan: la cantidad las pluraliza.
const unidadesDeCantidad = <String>[
  'comprimido',
  'cápsula',
  'gotas',
  'puff',
  'parche',
];

/// Todas las unidades validas, en el orden en que se ofrecen.
const unidadesDeDosis = <String>[...unidadesDeMedida, ...unidadesDeCantidad];

/// Singular y plural de las unidades que se cuentan. 'gotas' llega en plural
/// desde el backend porque ese es el valor que admite la restriccion, pero
/// una sola gota se lee "1 gota".
const _singularPlural = <String, List<String>>{
  'comprimido': ['comprimido', 'comprimidos'],
  'cápsula': ['cápsula', 'cápsulas'],
  'gotas': ['gota', 'gotas'],
  'puff': ['puff', 'puff'],
  'parche': ['parche', 'parches'],
};

/// La dosis como la leeria una persona: "2 comprimidos", "10 gotas", "50 mg".
///
/// El backend devuelve dose_amount como decimal, asi que sin esto la pantalla
/// mostraba "50.0 mg". Se saca el decimal cuando no aporta y se concuerda el
/// numero con la unidad.
String etiquetaDeDosis(String cantidad, String unidad) {
  final limpia = cantidad.trim();
  if (limpia.isEmpty) return unidad;
  final n = double.tryParse(limpia.replaceAll(',', '.'));
  final numero = n == null
      ? limpia
      : (n == n.roundToDouble()
          ? n.round().toString()
          : n.toString().replaceAll('.', ','));
  final par = _singularPlural[unidad];
  if (par == null) return '$numero $unidad';
  return '$numero ${n == 1 ? par.first : par.last}';
}

/// Quita el prefijo "Forma: X." que una version anterior escribia dentro de
/// las instrucciones para guardar un dato que la tabla no tenia. Los
/// medicamentos creados en esa epoca lo siguen trayendo, y sin esto aparece
/// en pantalla como si el usuario lo hubiera escrito, y se vuelve a duplicar
/// cada vez que alguien edita y guarda.
String? sinPrefijoDeForma(String? instrucciones) {
  if (instrucciones == null) return null;
  var s = instrucciones.trim();
  final conPunto = RegExp(r'^Forma:\s*[^.]*\.\s*', caseSensitive: false);
  while (conPunto.hasMatch(s)) {
    s = s.replaceFirst(conPunto, '').trim();
  }
  // Un "Forma: jarabe" sin nada detras deja el campo vacio, no un resto.
  if (RegExp(r'^Forma:\s*\S*$', caseSensitive: false).hasMatch(s)) return null;
  return s.isEmpty ? null : s;
}

class Medication {
  const Medication({
    required this.id,
    required this.name,
    required this.dose,
    required this.unit,
    this.schedule = const [],
    this.instructions,
    this.active = true,
    required this.startDate,
    this.endDate,
  });

  final String id;
  final String name;

  /// Cantidad por toma (p. ej. "50", "1").
  final String dose;

  /// Unidad de la dosis (p. ej. "mg", "ml", "comprimido").
  final String unit;

  /// Horarios de toma en formato 'HH:mm' (o descripciones de frecuencia).
  final List<String> schedule;

  final String? instructions;
  final bool active;
  final DateTime startDate;
  final DateTime? endDate;

  /// Texto legible del horario para mostrar en la UI.
  String get scheduleLabel =>
      schedule.isEmpty ? 'Sin horario definido' : schedule.join(' · ');

  /// Texto legible de la dosis (p. ej. "50 mg", "2 comprimidos").
  String get doseLabel => etiquetaDeDosis(dose, unit);

  Medication copyWith({
    String? name,
    String? dose,
    String? unit,
    List<String>? schedule,
    String? instructions,
    bool? active,
    DateTime? startDate,
    DateTime? endDate,
  }) =>
      Medication(
        id: id,
        name: name ?? this.name,
        dose: dose ?? this.dose,
        unit: unit ?? this.unit,
        schedule: schedule ?? this.schedule,
        instructions: instructions ?? this.instructions,
        active: active ?? this.active,
        startDate: startDate ?? this.startDate,
        endDate: endDate ?? this.endDate,
      );

  factory Medication.fromJson(Map<String, dynamic> json) => Medication(
        id: (json['id'] ?? json['medication_id']).toString(),
        name: json['name'] as String,
        // Backend: dose_amount (num) + dose_unit. Fallback a dose/unit (mock).
        dose: (json['dose_amount'] ?? json['dose'] ?? '').toString(),
        unit: (json['dose_unit'] ?? json['unit'] ?? '').toString(),
        // Backend: times (["HH:MM"]). Fallback a schedule (mock).
        schedule: ((json['times'] ?? json['schedule'] ?? []) as List)
            .map((e) => e.toString())
            .toList(),
        instructions: sinPrefijoDeForma(json['instructions'] as String?),
        // Backend: is_active. Fallback a active (mock).
        active: (json['is_active'] ?? json['active'] ?? true) as bool,
        startDate: json['start_date'] != null
            ? DateTime.parse(json['start_date'] as String)
            : DateTime.now(),
        endDate: json['end_date'] != null
            ? DateTime.parse(json['end_date'] as String)
            : null,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'dose': dose,
        'unit': unit,
        'schedule': schedule,
        if (instructions != null) 'instructions': instructions,
        'active': active,
        'start_date': _dateOnly(startDate),
        if (endDate != null) 'end_date': _dateOnly(endDate!),
      };
}

/// Dosis programada (una toma concreta en una fecha/hora).
class Dose {
  const Dose({
    required this.id,
    required this.medicationId,
    required this.medicationName,
    required this.scheduledAt,
    this.status = DoseStatus.pending,
    this.loggedAt,
    this.dose,
    this.unit,
  });

  final String id;
  final String medicationId;
  final String medicationName;
  final DateTime scheduledAt;
  final DoseStatus status;
  final DateTime? loggedAt;

  /// Cantidad y unidad para mostrar en la confirmación (opcional).
  final String? dose;
  final String? unit;

  String get timeLabel =>
      '${scheduledAt.hour.toString().padLeft(2, '0')}:${scheduledAt.minute.toString().padLeft(2, '0')}';

  Dose copyWith({DoseStatus? status, DateTime? loggedAt}) => Dose(
        id: id,
        medicationId: medicationId,
        medicationName: medicationName,
        scheduledAt: scheduledAt,
        status: status ?? this.status,
        loggedAt: loggedAt ?? this.loggedAt,
        dose: dose,
        unit: unit,
      );

  factory Dose.fromJson(Map<String, dynamic> json) => Dose(
        id: (json['id'] ?? json['dose_id']).toString(),
        medicationId: (json['medication_id'] ?? '').toString(),
        medicationName: (json['medication_name'] ?? '') as String,
        scheduledAt: DateTime.parse(json['scheduled_at'] as String),
        status: DoseStatus.fromApi((json['status'] ?? 'pending') as String),
        loggedAt: json['logged_at'] != null
            ? DateTime.parse(json['logged_at'] as String)
            : null,
        dose: json['dose']?.toString(),
        unit: json['unit']?.toString(),
      );
}

/// Solicitud de creación de un medicamento.
class NewMedication {
  const NewMedication({
    required this.name,
    required this.dose,
    required this.unit,
    this.schedule = const [],
    this.instructions,
    required this.startDate,
    this.endDate,
  });

  final String name;
  final String dose;
  final String unit;
  final List<String> schedule;
  final String? instructions;
  final DateTime startDate;
  final DateTime? endDate;

  /// Serializa al contrato del backend (módulo 6):
  /// - `dose` (texto UI) -> `dose_amount` (float) + `dose_unit`
  /// - `schedule` (["HH:mm"]) -> `times`
  /// - `days_of_week`: todos los días (el backend asume todos si se omite,
  ///   pero lo enviamos explícito para que el plan sea claro)
  /// - `grace_window_min`: ventana de gracia por defecto (60 min)
  ///
  /// La unidad ya dice la presentación, asi que no hay un campo de forma
  /// aparte. Antes habia uno que la tabla no tenia y que se guardaba como
  /// prefijo de las instrucciones, de donde se perdia del formulario y se
  /// duplicaba en cada edicion.
  Map<String, dynamic> toJson() {
    final doseAmount = double.tryParse(dose.replaceAll(',', '.')) ?? 0;
    final limpias = instructions?.trim() ?? '';
    return {
      'name': name,
      'dose_amount': doseAmount,
      'dose_unit': unit,
      'times': schedule,
      'days_of_week': const [1, 2, 3, 4, 5, 6, 7],
      'grace_window_min': 60,
      if (limpias.isNotEmpty) 'instructions': limpias,
      'start_date': _dateOnly(startDate),
      if (endDate != null) 'end_date': _dateOnly(endDate!),
    };
  }
}

/// Un punto de adherencia por día.
class AdherencePoint {
  const AdherencePoint({required this.date, required this.pct});

  final DateTime date;
  final double pct;

  /// El backend (daily[]) entrega conteos {taken, missed, pending} por día,
  /// no un porcentaje; aquí lo calculamos: taken / (taken + missed).
  /// Mantiene fallback a 'pct' por compat con el mock.
  factory AdherencePoint.fromJson(Map<String, dynamic> json) {
    double pct;
    if (json['pct'] != null) {
      pct = (json['pct'] as num).toDouble();
    } else {
      final taken = (json['taken'] ?? 0) as int;
      final missed = (json['missed'] ?? 0) as int;
      final total = taken + missed;
      pct = total > 0 ? (taken / total) * 100 : 100;
    }
    return AdherencePoint(
      date: DateTime.parse(json['date'] as String),
      pct: pct,
    );
  }
}

/// Adherencia por medicamento.
class MedicationAdherence {
  const MedicationAdherence({
    required this.medicationId,
    required this.medicationName,
    required this.pct,
  });

  final String medicationId;
  final String medicationName;
  final double pct;

  factory MedicationAdherence.fromJson(Map<String, dynamic> json) =>
      MedicationAdherence(
        medicationId: (json['medication_id'] ?? '').toString(),
        // Backend: 'name'. Fallback a medication_name (mock).
        medicationName:
            (json['name'] ?? json['medication_name'] ?? '') as String,
        // Backend: adherence_pct. Fallback a pct (mock).
        pct: ((json['adherence_pct'] ?? json['pct']) as num).toDouble(),
      );
}

/// Resumen de adherencia del paciente en un rango.
class Adherence {
  const Adherence({
    required this.pct,
    this.byDay = const [],
    this.byMedication = const [],
  });

  final double pct;
  final List<AdherencePoint> byDay;
  final List<MedicationAdherence> byMedication;

  factory Adherence.fromJson(Map<String, dynamic> json) => Adherence(
        pct: (json['adherence_pct'] as num).toDouble(),
        // Backend: 'daily'. Fallback a by_day (mock).
        byDay: ((json['daily'] ?? json['by_day'] ?? []) as List)
            .map((e) => AdherencePoint.fromJson(e as Map<String, dynamic>))
            .toList(),
        byMedication: ((json['by_medication'] ?? []) as List)
            .map((e) => MedicationAdherence.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

/// Borrador de medicación sugerido por el OCR de una receta.
class PrescriptionDraft {
  const PrescriptionDraft({this.medications = const []});

  final List<NewMedication> medications;

  factory PrescriptionDraft.fromJson(Map<String, dynamic> json) =>
      PrescriptionDraft(
        medications: ((json['medications'] ?? []) as List)
            .map((e) => _newMedFromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

// ---------------------------------------------------------------------------
// Helpers privados
// ---------------------------------------------------------------------------
String _dateOnly(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

NewMedication _newMedFromJson(Map<String, dynamic> json) => NewMedication(
      name: (json['name'] ?? '') as String,
      dose: (json['dose'] ?? '').toString(),
      unit: (json['unit'] ?? '').toString(),
      schedule:
          ((json['schedule'] ?? []) as List).map((e) => e.toString()).toList(),
      instructions: json['instructions'] as String?,
      startDate: json['start_date'] != null
          ? DateTime.parse(json['start_date'] as String)
          : DateTime.now(),
      endDate: json['end_date'] != null
          ? DateTime.parse(json['end_date'] as String)
          : null,
    );
