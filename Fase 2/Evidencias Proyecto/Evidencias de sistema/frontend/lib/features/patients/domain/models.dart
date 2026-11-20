import '../../../core/theme/app_theme.dart';
import '../../auth/domain/models.dart';

class WearableStatus {
  const WearableStatus({
    this.wearableId,
    this.lastSyncAt,
    this.batteryPct,
    this.isStale = false,
  });

  final String? wearableId;
  final DateTime? lastSyncAt;
  final int? batteryPct;
  final bool isStale;

  bool get isLinked => wearableId != null;

  factory WearableStatus.fromJson(Map<String, dynamic> json) => WearableStatus(
        wearableId: json['wearable_id'] as String?,
        lastSyncAt: json['last_sync_at'] != null
            ? DateTime.parse(json['last_sync_at'] as String)
            : null,
        batteryPct: json['battery_pct'] as int?,
        isStale: (json['is_stale'] ?? false) as bool,
      );
}

/// Miembro del equipo de cuidado (con su profesión clínica real).
class CareMember {
  const CareMember({
    required this.userId,
    required this.fullName,
    required this.email,
    required this.role,
    this.profession,
    this.relationship,
    this.isOwner = false,
  });

  final String userId;
  final String fullName;
  final String email;
  final String role; // permiso: family/caregiver/doctor/elder
  final String? profession; // rol clínico real
  final String? relationship; // parentesco (hijo, hija, conyuge...)
  final bool isOwner;

  /// Etiqueta legible del rol en el equipo: prioriza la profesión clínica.
  String get label {
    if (profession != null) return professionLabel(profession!);
    return switch (role) {
      'family' => 'Familiar',
      'caregiver' => 'Cuidador(a)',
      'doctor' => 'Médico',
      'elder' => 'Adulto mayor',
      _ => role,
    };
  }

  factory CareMember.fromJson(Map<String, dynamic> j) => CareMember(
        userId: j['user_id'] as String,
        fullName: j['full_name'] as String,
        email: j['email'] as String,
        role: j['role'] as String,
        profession: j['profession'] as String?,
        relationship: j['relationship'] as String?,
        isOwner: (j['is_owner'] ?? false) as bool,
      );
}

/// Etiqueta legible del parentesco de un familiar con el paciente.
String relationshipLabel(String code) => switch (code) {
      'hijo' => 'Hijo',
      'hija' => 'Hija',
      'conyuge' => 'Cónyuge',
      'hermano' => 'Hermano',
      'hermana' => 'Hermana',
      'nieto' => 'Nieto',
      'nieta' => 'Nieta',
      'sobrino' => 'Sobrino',
      'sobrina' => 'Sobrina',
      'yerno' => 'Yerno',
      'nuera' => 'Nuera',
      'cuidador' => 'Cuidador(a)',
      'otro' => 'Otro',
      _ => code,
    };

/// Etiqueta legible de una profesión del equipo de salud.
String professionLabel(String code) => switch (code) {
      'medico_general' => 'Médico general',
      'medico_especialista' => 'Médico especialista',
      'kinesiologo' => 'Kinesiólogo(a)',
      'enfermera' => 'Enfermero(a)',
      'podologa' => 'Podólogo(a)',
      'nutricionista' => 'Nutricionista',
      'fonoaudiologo' => 'Fonoaudiólogo(a)',
      'terapeuta_ocupacional' => 'Terapeuta ocupacional',
      'psicologo' => 'Psicólogo(a)',
      'trabajador_social' => 'Trabajador(a) social',
      'cuidadora' => 'Cuidador(a)',
      'familiar' => 'Familiar',
      _ => code,
    };

/// Condición médica con su sistema clínico y etiqueta legible.
class ConditionDetail {
  const ConditionDetail(
      {required this.condition, required this.system, required this.label});
  final String condition;
  final String system;
  final String label;

  /// La ficha del paciente manda `condition`; el catálogo
  /// (GET /conditions/catalog) manda `code`. Antes solo se leía `condition`,
  /// el catálogo reventaba en el cast y la pantalla decía "No se pudo cargar
  /// el catálogo" con el backend real (en modo prueba no pasaba porque el
  /// mock no pasa por aquí).
  factory ConditionDetail.fromJson(Map<String, dynamic> j) {
    final codigo = (j['condition'] ?? j['code']) as String;
    return ConditionDetail(
      condition: codigo,
      system: (j['system'] ?? 'otras') as String,
      label: (j['label'] ?? codigo) as String,
    );
  }
}

/// Etiqueta legible de un sistema clínico.
String systemLabel(String code) => switch (code) {
      'cardiovascular' => 'Cardiovascular',
      'respiratorio' => 'Respiratorio',
      'geriatrico' => 'Síndromes geriátricos',
      'metabolico' => 'Metabólico / endocrino',
      'osteomuscular' => 'Osteomuscular',
      'neuropsiquiatrico' => 'Neuropsiquiátrico',
      'sensorial' => 'Sensorial',
      _ => 'Otras',
    };

/// Alergia/intolerancia del paciente con severidad, reacción y cómo se supo.
class AllergyDetail {
  const AllergyDetail({
    required this.substance,
    required this.label,
    required this.category,
    required this.severity,
    this.reaction,
    this.source,
    this.notedOn,
  });

  final String substance;
  final String label;
  final String category; // medicamento|alimento|ambiental|otra
  final String severity; // leve|moderada|severa|anafilaxia
  final String? reaction;
  final String? source; // reportada|test|reaccion_tratamiento
  final DateTime? notedOn;

  /// Las severas saltan primero y con color fuerte.
  bool get esGrave => severity == 'severa' || severity == 'anafilaxia';

  factory AllergyDetail.fromJson(Map<String, dynamic> j) => AllergyDetail(
        substance: j['substance'] as String,
        label: (j['label'] ?? j['substance']) as String,
        category: (j['category'] ?? 'otra') as String,
        severity: (j['severity'] ?? 'moderada') as String,
        reaction: j['reaction'] as String?,
        source: j['source'] as String?,
        notedOn: j['noted_on'] != null
            ? DateTime.tryParse(j['noted_on'] as String)
            : null,
      );
}

/// Un alérgeno del catálogo (GET /allergens/catalog) para el selector.
class AllergenCatalogItem {
  const AllergenCatalogItem(
      {required this.code, required this.label, required this.category});
  final String code;
  final String label;
  final String category;

  factory AllergenCatalogItem.fromJson(Map<String, dynamic> j) =>
      AllergenCatalogItem(
        code: j['code'] as String,
        label: j['label'] as String,
        category: (j['category'] ?? 'otra') as String,
      );
}

/// Último médico que atendió al paciente (derivado del tratamiento más reciente
/// mientras no exista el módulo de controles).
class LastSeenBy {
  const LastSeenBy({required this.name, this.specialty, this.date});
  final String name;
  final String? specialty;
  final DateTime? date;

  factory LastSeenBy.fromJson(Map<String, dynamic> j) => LastSeenBy(
        name: (j['name'] ?? '') as String,
        specialty: j['specialty'] as String?,
        date: j['date'] != null ? DateTime.tryParse(j['date'] as String) : null,
      );
}

/// Una vacuna del carnet del paciente (aplicada o programada).
class Immunization {
  const Immunization({
    required this.vaccine,
    required this.label,
    required this.kind,
    this.administeredOn,
    this.nextDueOn,
    this.doseNumber,
    this.exposureEvent,
    this.note,
  });

  final String vaccine;
  final String label;
  final String kind; // preventiva | post_exposicion
  final DateTime? administeredOn;
  final DateTime? nextDueOn;
  final int? doseNumber;
  final String? exposureEvent;
  final String? note;

  bool get esPostExposicion => kind == 'post_exposicion';

  /// La próxima dosis ya venció (recordatorio en rojo).
  bool get vencida => nextDueOn != null && nextDueOn!.isBefore(DateTime.now());

  factory Immunization.fromJson(Map<String, dynamic> j) => Immunization(
        vaccine: j['vaccine'] as String,
        label: (j['label'] ?? j['vaccine']) as String,
        kind: (j['kind'] ?? 'preventiva') as String,
        administeredOn: j['administered_on'] != null
            ? DateTime.tryParse(j['administered_on'] as String)
            : null,
        nextDueOn: j['next_due_on'] != null
            ? DateTime.tryParse(j['next_due_on'] as String)
            : null,
        doseNumber: j['dose_number'] as int?,
        exposureEvent: j['exposure_event'] as String?,
        note: j['note'] as String?,
      );
}

/// Una vacuna del catálogo (GET /vaccines/catalog) para el selector.
class VaccineCatalogItem {
  const VaccineCatalogItem({
    required this.code,
    required this.label,
    required this.kindDefault,
    required this.isRecurrent,
    this.intervalMonths,
    this.targetGroup,
  });

  final String code;
  final String label;
  final String kindDefault;
  final bool isRecurrent;
  final int? intervalMonths;
  final String? targetGroup;

  factory VaccineCatalogItem.fromJson(Map<String, dynamic> j) =>
      VaccineCatalogItem(
        code: j['code'] as String,
        label: j['label'] as String,
        kindDefault: (j['kind_default'] ?? 'preventiva') as String,
        isRecurrent: (j['is_recurrent'] ?? false) as bool,
        intervalMonths: j['interval_months'] as int?,
        targetGroup: j['target_group'] as String?,
      );
}

String vaccineKindLabel(String code) => switch (code) {
      'preventiva' => 'Preventiva',
      'post_exposicion' => 'Post-exposición',
      _ => code,
    };

/// Un contacto de emergencia del paciente. Sale del grupo familiar (miembro) y
/// es rotativo (activo/inactivo). El orden define a quién se avisa primero.
class EmergencyContact {
  const EmergencyContact({
    required this.id,
    required this.name,
    required this.isActive,
    this.memberUserId,
    this.phone,
    this.avatarUrl,
    this.notes,
  });

  final String id;
  final String name;
  // Sin prioridad/orden: en un SOS se avisa a todos por igual. La lista existe
  // para que un médico de urgencias o paramédico sepa a quién llamar.
  final bool isActive;
  final String? memberUserId;
  final String? phone;
  final String? avatarUrl;
  final String? notes;

  factory EmergencyContact.fromJson(Map<String, dynamic> j) => EmergencyContact(
        id: j['id'] as String,
        name: (j['name'] ?? '') as String,
        isActive: (j['is_active'] ?? true) as bool,
        memberUserId: j['member_user_id'] as String?,
        phone: j['phone'] as String?,
        avatarUrl: j['avatar_url'] as String?,
        notes: j['notes'] as String?,
      );
}

String allergyCategoryLabel(String code) => switch (code) {
      'medicamento' => 'Medicamentos',
      'alimento' => 'Alimentos',
      'ambiental' => 'Ambientales',
      _ => 'Otras',
    };

String allergySeverityLabel(String code) => switch (code) {
      'leve' => 'Leve',
      'moderada' => 'Moderada',
      'severa' => 'Severa',
      'anafilaxia' => 'Anafilaxia',
      _ => code,
    };

String allergySourceLabel(String code) => switch (code) {
      'reportada' => 'Reportada',
      'test' => 'Test de alergias',
      'reaccion_tratamiento' => 'Reacción en tratamiento',
      _ => code,
    };

class PatientMeasurement {
  const PatientMeasurement(
      {this.weightKg, this.heightCm, this.bmi, required this.measuredAt});
  final double? weightKg;
  final double? heightCm;
  final double? bmi;
  final DateTime measuredAt;

  factory PatientMeasurement.fromJson(Map<String, dynamic> j) =>
      PatientMeasurement(
        weightKg: (j['weight_kg'] as num?)?.toDouble(),
        heightCm: (j['height_cm'] as num?)?.toDouble(),
        bmi: (j['bmi'] as num?)?.toDouble(),
        measuredAt: DateTime.parse(j['measured_at'] as String),
      );
}

class Patient {
  const Patient({
    required this.patientId,
    required this.fullName,
    this.firstName,
    this.secondName,
    this.lastName,
    this.secondLastName,
    required this.birthDate,
    this.sex,
    this.photoUrl,
    this.conditions = const [],
    this.conditionsDetail = const [],
    this.allergies = const [],
    this.immunizations = const [],
    this.wearable,
    this.rut,
    this.address,
    this.maritalStatus,
    this.insurance,
    this.rcvLevel,
    this.complexity,
    this.priority,
    this.lastSeenBy,
    this.latestMeasurement,
  });

  final String patientId;
  final String fullName;

  /// Las cuatro partes del nombre como se identifica a una persona en Chile:
  /// primer nombre, segundo nombre, primer apellido y segundo apellido.
  /// Las segundas son opcionales. Pueden faltar en datos de demostración que
  /// solo traen [fullName].
  final String? firstName;
  final String? secondName;
  final String? lastName;
  final String? secondLastName;
  final DateTime birthDate;
  final String? sex;
  final String? photoUrl;
  final List<String> conditions;
  final List<ConditionDetail> conditionsDetail;
  final List<AllergyDetail> allergies;
  final List<Immunization> immunizations;
  final WearableStatus? wearable;
  // Perfil clínico ampliado (Fase 2).
  final String? rut;
  final String? address;
  final String? maritalStatus;
  final String? insurance;
  final String? rcvLevel;
  final String? complexity; // baja|moderada|alta (Fase 6)
  final String? priority; // baja|media|alta (Fase 6)
  final LastSeenBy? lastSeenBy;
  final PatientMeasurement? latestMeasurement;

  int get age {
    final now = DateTime.now();
    var years = now.year - birthDate.year;
    if (now.month < birthDate.month ||
        (now.month == birthDate.month && now.day < birthDate.day)) {
      years--;
    }
    return years;
  }

  /// Copia con cambios. Los demás campos se conservan tal cual: armar un
  /// Patient a mano en cada edición iba perdiendo alergias y niveles.
  Patient copyWith({
    String? fullName,
    String? firstName,
    String? Function()? secondName,
    String? lastName,
    String? Function()? secondLastName,
    String? address,
    String? maritalStatus,
    String? insurance,
    String? rcvLevel,
    String? complexity,
    String? priority,
    List<String>? conditions,
    PatientMeasurement? latestMeasurement,
  }) =>
      Patient(
        patientId: patientId,
        fullName: fullName ?? this.fullName,
        firstName: firstName ?? this.firstName,
        secondName: secondName != null ? secondName() : this.secondName,
        lastName: lastName ?? this.lastName,
        secondLastName:
            secondLastName != null ? secondLastName() : this.secondLastName,
        birthDate: birthDate,
        sex: sex,
        photoUrl: photoUrl,
        conditions: conditions ?? this.conditions,
        conditionsDetail: conditionsDetail,
        allergies: allergies,
        immunizations: immunizations,
        wearable: wearable,
        rut: rut,
        address: address ?? this.address,
        maritalStatus: maritalStatus ?? this.maritalStatus,
        insurance: insurance ?? this.insurance,
        rcvLevel: rcvLevel ?? this.rcvLevel,
        complexity: complexity ?? this.complexity,
        priority: priority ?? this.priority,
        lastSeenBy: lastSeenBy,
        latestMeasurement: latestMeasurement ?? this.latestMeasurement,
      );

  /// Nombres (primer y segundo nombre) y apellidos, para mostrarlos por
  /// separado. Sin las partes, se cae al nombre completo.
  String get givenNames => [firstName, secondName]
      .where((s) => s != null && s.trim().isNotEmpty)
      .join(' ');
  String get surnames => [lastName, secondLastName]
      .where((s) => s != null && s.trim().isNotEmpty)
      .join(' ');

  /// Las condiciones con nombre legible. El backend guarda códigos
  /// (`hipertension`) y manda la etiqueta aparte en `conditions_detail`.
  List<String> get conditionLabels => conditionsDetail.isNotEmpty
      ? conditionsDetail.map((c) => c.label).toList()
      : conditions;

  factory Patient.fromJson(Map<String, dynamic> json) => Patient(
        patientId: json['patient_id'] as String,
        fullName: json['full_name'] as String,
        firstName: json['first_name'] as String?,
        secondName: json['second_name'] as String?,
        lastName: json['last_name'] as String?,
        secondLastName: json['second_last_name'] as String?,
        birthDate: DateTime.parse(json['birth_date'] as String),
        sex: json['sex'] as String?,
        photoUrl: json['photo_url'] as String?,
        conditions: ((json['conditions'] ?? []) as List)
            .map((e) => e.toString())
            .toList(),
        conditionsDetail: ((json['conditions_detail'] ?? []) as List)
            .map((e) => ConditionDetail.fromJson(e as Map<String, dynamic>))
            .toList(),
        allergies: ((json['allergies'] ?? []) as List)
            .map((e) => AllergyDetail.fromJson(e as Map<String, dynamic>))
            .toList(),
        immunizations: ((json['immunizations'] ?? []) as List)
            .map((e) => Immunization.fromJson(e as Map<String, dynamic>))
            .toList(),
        wearable: json['wearable'] != null
            ? WearableStatus.fromJson(json['wearable'] as Map<String, dynamic>)
            : null,
        rut: json['rut'] as String?,
        address: json['address'] as String?,
        maritalStatus: json['marital_status'] as String?,
        insurance: json['insurance'] as String?,
        rcvLevel: json['rcv_level'] as String?,
        complexity: json['complexity'] as String?,
        priority: json['priority'] as String?,
        lastSeenBy: json['last_seen_by'] != null
            ? LastSeenBy.fromJson(json['last_seen_by'] as Map<String, dynamic>)
            : null,
        latestMeasurement: json['latest_measurement'] != null
            ? PatientMeasurement.fromJson(
                json['latest_measurement'] as Map<String, dynamic>)
            : null,
      );
}

/// Tarjeta de paciente para el selector y el tablero multi-paciente.
class PatientCard {
  const PatientCard({
    required this.patientId,
    required this.fullName,
    this.photoUrl,
    required this.role,
    required this.wellbeingStatus,
    this.activeAlertsCount = 0,
    this.criticalAlertsCount = 0,
    this.topReason,
    this.age,
    this.conditions = const [],
    this.rut,
    this.vitalsSummary = const [],
    this.sex,
    this.address,
    this.conditionsLabels = const [],
    this.allergies = const [],
    this.complexity,
    this.priority,
    this.insurance,
  });

  final String patientId;
  final String fullName;
  final String? photoUrl;
  final RoleType role;
  final WellbeingStatus wellbeingStatus;
  final int activeAlertsCount;
  final int criticalAlertsCount;
  final String? topReason;

  /// Edad y enfermedades: contexto clínico para la vista del médico (triage).
  final int? age;
  final List<String> conditions;

  /// RUT (desempata dos pacientes de igual nombre) y mini-resumen de vitales.
  final String? rut;
  final List<VitalMini> vitalsSummary;

  /// Sexo y domicilio: junto al RUT, separan a dos pacientes con el mismo
  /// nombre ("Juanito Pérez" de Maipú vs. el de La Florida).
  final String? sex;
  final String? address;

  /// Contexto clínico de un vistazo: enfermedades con nombre legible,
  /// alergias (graves primero), complejidad, prioridad y previsión.
  final List<String> conditionsLabels;
  final List<AllergyMini> allergies;
  final String? complexity;
  final String? priority;
  final String? insurance;

  /// Copia con el motivo ya humanizado (el backend manda un código técnico).
  PatientCard withHumanizedReason(String reason) => PatientCard(
        patientId: patientId,
        fullName: fullName,
        photoUrl: photoUrl,
        role: role,
        wellbeingStatus: wellbeingStatus,
        activeAlertsCount: activeAlertsCount,
        criticalAlertsCount: criticalAlertsCount,
        topReason: reason,
        age: age,
        conditions: conditions,
        rut: rut,
        vitalsSummary: vitalsSummary,
        sex: sex,
        address: address,
        conditionsLabels: conditionsLabels,
        allergies: allergies,
        complexity: complexity,
        priority: priority,
        insurance: insurance,
      );

  factory PatientCard.fromJson(Map<String, dynamic> json) => PatientCard(
        patientId: json['patient_id'] as String,
        fullName: json['full_name'] as String,
        photoUrl: json['photo_url'] as String?,
        role: RoleType.fromApi((json['role'] ?? 'family') as String),
        wellbeingStatus: WellbeingStatus.fromApi(
            (json['wellbeing_status'] ?? 'ok') as String),
        activeAlertsCount: (json['active_alerts_count'] ?? 0) as int,
        criticalAlertsCount: (json['critical_alerts_count'] ?? 0) as int,
        topReason: json['top_reason'] as String?,
        age: json['age'] as int?,
        conditions: ((json['conditions'] ?? const []) as List)
            .map((e) => e.toString())
            .toList(),
        rut: json['rut'] as String?,
        vitalsSummary: ((json['vitals_summary'] ?? const []) as List)
            .map((e) => VitalMini.fromJson(e as Map<String, dynamic>))
            .toList(),
        sex: json['sex'] as String?,
        address: json['address'] as String?,
        conditionsLabels: ((json['conditions_labels'] ?? const []) as List)
            .map((e) => e.toString())
            .toList(),
        allergies: ((json['allergies'] ?? const []) as List)
            .map((e) => AllergyMini.fromJson(e as Map<String, dynamic>))
            .toList(),
        complexity: json['complexity'] as String?,
        priority: json['priority'] as String?,
        insurance: json['insurance'] as String?,
      );
}

/// Lectura reciente de un signo vital, para el mini-resumen de la tarjeta.
class VitalMini {
  const VitalMini({
    required this.type,
    required this.value,
    required this.unit,
    this.valueSecondary,
    this.measuredAt,
  });
  final String type;
  final double value;
  final String unit;

  /// Diastólica, solo para presión arterial.
  final double? valueSecondary;

  /// Cuándo se tomó: el médico tiene que saber si el dato es de hace 5 minutos
  /// o de hace 3 días antes de usarlo.
  final DateTime? measuredAt;

  /// Etiqueta corta legible del tipo.
  String get label => switch (type) {
        'heart_rate' => 'FC',
        'spo2' => 'SpO₂',
        'blood_pressure' => 'PA',
        _ => type,
      };

  String get display {
    final v = value == value.roundToDouble()
        ? value.toInt().toString()
        : value.toStringAsFixed(1);
    return '$label $v$unit';
  }

  factory VitalMini.fromJson(Map<String, dynamic> j) => VitalMini(
        type: j['type'] as String,
        value: (j['value'] as num).toDouble(),
        unit: (j['unit'] ?? '') as String,
        valueSecondary: (j['value_secondary'] as num?)?.toDouble(),
        measuredAt: j['measured_at'] != null
            ? DateTime.tryParse(j['measured_at'] as String)
            : null,
      );
}

/// Alergia resumida para la tarjeta de la lista (etiqueta + severidad).
class AllergyMini {
  const AllergyMini({required this.label, required this.severity});
  final String label;
  final String severity; // leve|moderada|severa|anafilaxia

  bool get esGrave => severity == 'severa' || severity == 'anafilaxia';

  factory AllergyMini.fromJson(Map<String, dynamic> j) => AllergyMini(
        label: (j['label'] ?? '') as String,
        severity: (j['severity'] ?? 'moderada') as String,
      );
}

/// Contacto de emergencia que se declara al crear el paciente. Es un
/// contacto libre (nombre + teléfono) porque el círculo de cuidado aún no
/// existe; después se pueden sumar miembros del grupo como contactos.
class NewEmergencyContact {
  const NewEmergencyContact({
    required this.firstName,
    required this.lastName,
    required this.relationship,
    required this.phone,
  });

  final String firstName;
  final String lastName;
  final String relationship;

  /// En E.164 (+56912345678).
  final String phone;

  Map<String, dynamic> toJson() => {
        'first_name': firstName.trim(),
        'last_name': lastName.trim(),
        'relationship': relationship.trim(),
        'phone': phone,
      };
}

/// Alergia conocida al crear el paciente.
class NewAllergy {
  const NewAllergy({
    required this.substance,
    required this.category,
    this.severity = 'moderada',
  });

  final String substance; // code del catálogo o texto libre
  final String category; // medicamento|alimento|ambiental|otra
  final String severity; // leve|moderada|severa|anafilaxia

  Map<String, dynamic> toJson() =>
      {'substance': substance, 'category': category, 'severity': severity};
}

/// Solicitud de creación de paciente (`POST /patients`).
///
/// Cada parte del nombre va en su propio campo, igual que en el backend
/// (first_name, second_name, last_name, second_last_name). Antes se pedía un
/// "nombre completo" y se partía por el primer espacio, lo que guardaba mal
/// a "María José Pérez" (apellido "José Pérez") y duplicaba nombres sueltos.
///
/// Obligatorios: nombre, apellido, RUT, nacimiento, sexo, domicilio y un
/// contacto de emergencia. Opcionales: segundo nombre y apellido,
/// condiciones, alergias, previsión. Una lista vacía de alergias NO viaja: el
/// backend la interpreta como "no informado", no como "sin alergias".
/// Cuenta con la que el adulto mayor entra a la app. La crea su familia al
/// crear el perfil (POST /patients, campo elder_account).
class NewElderAccount {
  const NewElderAccount({required this.email, required this.password});

  final String email;
  final String password;

  Map<String, dynamic> toJson() =>
      {'email': email.trim(), 'password': password};
}

class NewPatient {
  const NewPatient({
    required this.firstName,
    this.secondName,
    required this.lastName,
    this.secondLastName,
    required this.rut,
    required this.birthDate,
    required this.sex,
    required this.address,
    required this.emergencyContact,
    this.conditions = const [],
    this.allergies = const [],
    this.insurance,
    this.elderAccount,
  });

  final String firstName;
  final String? secondName;
  final String lastName;
  final String? secondLastName;
  final String rut;
  final DateTime birthDate;

  /// `female`, `male` u `other`. `patients.sex` es NOT NULL.
  final String sex;
  final String address;
  final NewEmergencyContact emergencyContact;
  final List<String> conditions;
  final List<NewAllergy> allergies;

  /// fonasa | isapre | particular | otra
  final String? insurance;

  /// Si viene, se crea también la cuenta del adulto mayor.
  final NewElderAccount? elderAccount;

  /// Nombre completo, igual a como lo arma la columna generada de la base.
  String get fullName => [firstName, secondName, lastName, secondLastName]
      .where((p) => p != null && p.trim().isNotEmpty)
      .map((p) => p!.trim())
      .join(' ');

  static String? _opcional(String? v) =>
      v == null || v.trim().isEmpty ? null : v.trim();

  Map<String, dynamic> toJson() => {
        'first_name': firstName.trim(),
        if (_opcional(secondName) != null) 'second_name': _opcional(secondName),
        'last_name': lastName.trim(),
        if (_opcional(secondLastName) != null)
          'second_last_name': _opcional(secondLastName),
        'rut': rut.trim(),
        'birth_date':
            '${birthDate.year.toString().padLeft(4, '0')}-${birthDate.month.toString().padLeft(2, '0')}-${birthDate.day.toString().padLeft(2, '0')}',
        'sex': sex,
        'address': address.trim(),
        'emergency_contact': emergencyContact.toJson(),
        if (conditions.isNotEmpty) 'conditions': conditions,
        if (allergies.isNotEmpty)
          'allergies': allergies.map((a) => a.toJson()).toList(),
        if (insurance != null) 'insurance': insurance,
        if (elderAccount != null) 'elder_account': elderAccount!.toJson(),
      };
}

/// Invitación al círculo de cuidado (AGE-205 / DAC05-7).
///
/// El backend emite un `token` (cadena larga) y una `invite_url` para
/// compartir; la invitación vence a los 7 días. La UI muestra el token como
/// texto a copiar/compartir.
class Invitation {
  const Invitation({
    required this.invitationId,
    required this.token,
    required this.role,
    required this.expiresAt,
    this.inviteUrl,
  });

  final String invitationId;
  final String token;
  final RoleType role;
  final DateTime expiresAt;
  final String? inviteUrl;

  Duration get timeLeft => expiresAt.difference(DateTime.now());
  bool get isExpired => timeLeft.isNegative;

  /// El backend (4.5) responde {invitation_id, token, invite_url, expires_at}
  /// sin el rol; por eso se puede pasar [fallbackRole] (el solicitado al invitar).
  factory Invitation.fromJson(Map<String, dynamic> json,
          {RoleType fallbackRole = RoleType.family}) =>
      Invitation(
        invitationId: json['invitation_id'] as String,
        token: json['token'] as String,
        role: json['role'] != null
            ? RoleType.fromApi(json['role'] as String)
            : fallbackRole,
        expiresAt: DateTime.parse(json['expires_at'] as String),
        inviteUrl: json['invite_url'] as String?,
      );
}
