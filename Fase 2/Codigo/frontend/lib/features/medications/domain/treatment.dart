/// Modelo de tratamiento e indicaciones (Hito 3).
///
/// Un tratamiento es el conjunto de indicaciones vigentes que el médico definió
/// en un momento dado. Cambiar el esquema crea una versión nueva; la anterior
/// queda como histórico. Nada se edita en el lugar.
library;

/// Una indicación dentro de un tratamiento.
class TreatmentItem {
  const TreatmentItem({
    required this.itemId,
    required this.name,
    required this.dose,
    required this.doseAmount,
    required this.doseUnit,
    required this.times,
    required this.daysOfWeek,
    required this.graceWindowMin,
    required this.action,
    this.instructions,
    this.continuesItemId,
    this.isPrn = false,
    this.scheduleLabel,
    this.drugCode,
    this.prnMinIntervalMin,
  });

  final String itemId;
  final String name;
  final String dose;           // presentación "100 mg"
  final double doseAmount;
  final String doseUnit;
  final List<String> times;    // ["08:00", "20:00"]
  final List<int> daysOfWeek;
  final int graceWindowMin;

  /// added | kept | changed | removed (respecto del tratamiento anterior).
  final String action;
  final String? instructions;
  final String? continuesItemId;
  final bool isPrn;              // SOS/condicional: no genera agenda
  final String? scheduleLabel;  // "con el desayuno", etiqueta de referencia

  /// Fármaco del catálogo del que viene (unidad y rango fijos), o null.
  final String? drugCode;

  /// Solo SOS: intervalo mínimo entre usos, en minutos.
  final int? prnMinIntervalMin;

  factory TreatmentItem.fromJson(Map<String, dynamic> j) => TreatmentItem(
        itemId: j['item_id'] as String,
        name: j['name'] as String,
        dose: (j['dose'] ?? '') as String,
        doseAmount: (j['dose_amount'] as num).toDouble(),
        doseUnit: j['dose_unit'] as String,
        times: ((j['times'] ?? []) as List).map((e) => e.toString()).toList(),
        daysOfWeek:
            ((j['days_of_week'] ?? []) as List).map((e) => e as int).toList(),
        graceWindowMin: (j['grace_window_min'] ?? 60) as int,
        action: (j['action'] ?? 'kept') as String,
        instructions: j['instructions'] as String?,
        continuesItemId: j['continues_item_id'] as String?,
        isPrn: (j['is_prn'] ?? false) as bool,
        scheduleLabel: j['schedule_label'] as String?,
        drugCode: j['drug_code'] as String?,
        prnMinIntervalMin: j['prn_min_interval_min'] as int?,
      );
}

/// Un tratamiento (vigente o histórico), de una especialidad.
class Treatment {
  const Treatment({
    required this.treatmentId,
    required this.status,
    required this.specialty,
    required this.effectiveFrom,
    required this.items,
    this.prescriberName,
    this.effectiveTo,
    this.reviewDate,
    this.note,
    this.supersedesId,
  });

  final String treatmentId;
  final String status;        // vigente | superseded | cancelled
  final String specialty;
  final String? prescriberName;
  final DateTime effectiveFrom;
  final DateTime? effectiveTo;

  /// Duración: null = permanente (crónico); con fecha = temporal (hasta cuándo).
  final DateTime? reviewDate;
  final String? note;
  final String? supersedesId;
  final List<TreatmentItem> items;

  bool get vigente => status == 'vigente';

  factory Treatment.fromJson(Map<String, dynamic> j) => Treatment(
        treatmentId: j['treatment_id'] as String,
        status: j['status'] as String,
        specialty: (j['specialty'] ?? 'general') as String,
        prescriberName: j['prescriber_name'] as String?,
        effectiveFrom: DateTime.parse(j['effective_from'] as String),
        effectiveTo: j['effective_to'] != null
            ? DateTime.parse(j['effective_to'] as String)
            : null,
        reviewDate: j['review_date'] != null
            ? DateTime.parse(j['review_date'] as String)
            : null,
        note: j['note'] as String?,
        supersedesId: j['supersedes_id'] as String?,
        items: ((j['items'] ?? []) as List)
            .map((e) => TreatmentItem.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

/// Un grupo de tratamientos de una especialidad: el vigente + su historial.
class SpecialtyGroup {
  const SpecialtyGroup({
    required this.specialty,
    this.current,
    this.history = const [],
  });

  final String specialty;
  final Treatment? current;
  final List<Treatment> history;

  factory SpecialtyGroup.fromJson(Map<String, dynamic> j) => SpecialtyGroup(
        specialty: (j['specialty'] ?? 'general') as String,
        current: j['current'] != null
            ? Treatment.fromJson(j['current'] as Map<String, dynamic>)
            : null,
        history: ((j['history'] ?? []) as List)
            .map((e) => Treatment.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

/// Respuesta de GET /treatments: tratamientos agrupados por especialidad.
class TreatmentBundle {
  const TreatmentBundle({
    this.current,
    this.history = const [],
    this.bySpecialty = const [],
  });
  final Treatment? current;
  final List<Treatment> history;
  final List<SpecialtyGroup> bySpecialty;

  /// Especialidades que tienen un tratamiento vigente.
  List<SpecialtyGroup> get vigentes =>
      bySpecialty.where((g) => g.current != null).toList();

  factory TreatmentBundle.fromJson(Map<String, dynamic> j) => TreatmentBundle(
        current: j['current'] != null
            ? Treatment.fromJson(j['current'] as Map<String, dynamic>)
            : null,
        history: ((j['history'] ?? []) as List)
            .map((e) => Treatment.fromJson(e as Map<String, dynamic>))
            .toList(),
        bySpecialty: ((j['by_specialty'] ?? []) as List)
            .map((e) => SpecialtyGroup.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

/// Etiqueta legible de una especialidad ("cardiologia" → "Cardiología").
String specialtyLabel(String code) {
  const mapa = {
    'general': 'Medicina general',
    'cardiologia': 'Cardiología',
    'traumatologia': 'Traumatología',
    'neurologia': 'Neurología',
    'geriatria': 'Geriatría',
    'endocrinologia': 'Endocrinología',
    'psiquiatria': 'Psiquiatría',
    'nefrologia': 'Nefrología',
    'broncopulmonar': 'Broncopulmonar',
  };
  if (mapa.containsKey(code)) return mapa[code]!;
  if (code.isEmpty) return 'Medicina general';
  return code[0].toUpperCase() + code.substring(1);
}

/// Catálogo sugerido de especialidades para el selector (texto libre permitido).
const kEspecialidades = <String>[
  'general',
  'cardiologia',
  'traumatologia',
  'neurologia',
  'geriatria',
  'endocrinologia',
  'psiquiatria',
  'nefrologia',
  'broncopulmonar',
];

/// Un fármaco del catálogo (GET /drugs/catalog). La unidad y el rango de dosis
/// vienen del servidor: el médico no teclea la unidad, se hereda del fármaco.
/// Es la base de la seguridad de dosis (evita "loperamida en kg").
class DrugCatalogItem {
  const DrugCatalogItem({
    required this.code,
    required this.activeIngredient,
    required this.label,
    required this.form,
    required this.route,
    required this.unit,
    required this.doseMin,
    required this.doseMax,
    this.maxDaily,
  });

  final String code;
  final String activeIngredient;
  final String label;
  final String form;   // comprimido, aerosol, ampolla...
  final String route;  // oral, inhalatoria, subcutanea...
  final String unit;   // mg, mcg, puff, UI... (ÚNICA permitida)
  final double doseMin;
  final double doseMax;
  final double? maxDaily;

  /// Rango legible para mostrar bajo el campo de dosis ("12.5 – 100 mg").
  String get rangoLegible => '${_n(doseMin)} – ${_n(doseMax)} $unit';

  static String _n(double v) =>
      v == v.roundToDouble() ? v.toInt().toString() : v.toString();

  factory DrugCatalogItem.fromJson(Map<String, dynamic> j) => DrugCatalogItem(
        code: j['code'] as String,
        activeIngredient: (j['active_ingredient'] ?? '') as String,
        label: j['label'] as String,
        form: (j['form'] ?? '') as String,
        route: (j['route'] ?? '') as String,
        unit: j['unit'] as String,
        doseMin: (j['dose_min'] as num).toDouble(),
        doseMax: (j['dose_max'] as num).toDouble(),
        maxDaily: j['max_daily'] != null
            ? (j['max_daily'] as num).toDouble()
            : null,
      );
}

/// Borrador editable de una indicación para armar un nuevo tratamiento.
/// [removed] marca que el fármaco sale del esquema (no se envía como item).
class TreatmentItemDraft {
  TreatmentItemDraft({
    required this.name,
    required this.doseAmount,
    required this.doseUnit,
    required this.times,
    this.drugCode,
    this.instructions,
    this.continuesItemId,
    this.removed = false,
    this.isPrn = false,
    this.scheduleLabel,
  });

  String name;
  double doseAmount;
  String doseUnit;
  List<String> times;
  String? drugCode;        // code del catálogo si se eligió uno (si no, libre)
  String? instructions;
  String? continuesItemId;
  bool removed;
  bool isPrn;
  String? scheduleLabel;

  /// Crea el borrador a partir de una indicación vigente (para precargar).
  factory TreatmentItemDraft.fromItem(TreatmentItem it) => TreatmentItemDraft(
        name: it.name,
        doseAmount: it.doseAmount,
        doseUnit: it.doseUnit,
        times: List<String>.from(it.times),
        instructions: it.instructions,
        continuesItemId: it.itemId,
        isPrn: it.isPrn,
        scheduleLabel: it.scheduleLabel,
      );

  Map<String, dynamic> toJson() => {
        'name': name,
        'dose_amount': doseAmount,
        'dose_unit': doseUnit,
        'times': times,
        'is_prn': isPrn,
        if (drugCode != null) 'drug_code': drugCode,
        if (instructions != null && instructions!.trim().isNotEmpty)
          'instructions': instructions,
        if (scheduleLabel != null && scheduleLabel!.trim().isNotEmpty)
          'schedule_label': scheduleLabel,
        if (continuesItemId != null) 'continues_item_id': continuesItemId,
      };
}
