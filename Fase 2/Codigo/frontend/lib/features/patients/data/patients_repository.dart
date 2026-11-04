import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/app_config.dart';
import '../../../core/network/api_client.dart';
import '../../../core/theme/app_theme.dart';
import '../../auth/domain/models.dart';
import '../../home/domain/models.dart' show humanizeReason;
import '../domain/models.dart';

abstract class PatientsRepository {
  Future<List<PatientCard>> listMyPatients();
  Future<Patient> getPatient(String patientId);
  Future<Patient> createPatient(NewPatient data);
  Future<Invitation> invite({
    required String patientId,
    required RoleType role,
    String? email,
  });
  /// Valida el token de invitación y vincula al usuario actual al círculo
  /// de cuidado del paciente. Devuelve la tarjeta del paciente ya vinculado.
  Future<PatientCard> acceptInvitation(String token);
  Future<WearableStatus> wearableStatus(String patientId);

  /// Actualiza la lista de enfermedades del paciente (descubrir una nueva o
  /// dar de baja una que remitió). Solo el familiar administrador.
  Future<Patient> updateConditions(String patientId, List<String> conditions);

  /// Actualiza campos del perfil clínico (domicilio, estado civil, previsión,
  /// nivel de riesgo cardiovascular). Solo el familiar administrador.
  Future<Patient> updateProfile(String patientId, Map<String, dynamic> fields);

  /// Registra una medición antropométrica (peso/altura). Devuelve el paciente
  /// con la medición nueva como la más reciente.
  Future<Patient> addMeasurement(String patientId,
      {double? weightKg, double? heightCm});

  /// Catálogo de patologías agrupables por sistema (para el selector).
  Future<List<ConditionDetail>> conditionCatalog();

  /// Catálogo de alérgenos (para el selector de alergias).
  Future<List<AllergenCatalogItem>> allergenCatalog();

  /// Registra una alergia descubierta (al diagnosticar, por test, o por una
  /// reacción en tratamiento). Devuelve la lista vigente de alergias.
  Future<List<AllergyDetail>> addAllergy(String patientId, AllergyDetail allergy);

  /// Da de baja una alergia (baja lógica). Devuelve la lista vigente.
  Future<List<AllergyDetail>> removeAllergy(String patientId, String substance);

  /// Catálogo de vacunas (para el selector de inmunizaciones).
  Future<List<VaccineCatalogItem>> vaccineCatalog();

  /// Registra una vacuna (aplicada o programada). Devuelve el carnet vigente.
  Future<List<Immunization>> addImmunization(
      String patientId, Immunization immunization);

  /// Da de baja la última dosis de una vacuna. Devuelve el carnet vigente.
  Future<List<Immunization>> removeImmunization(
      String patientId, String vaccine);

  /// Contactos de emergencia del paciente (del grupo, rotativos).
  Future<List<EmergencyContact>> emergencyContacts(String patientId);

  /// Agrega un contacto eligiendo un miembro del grupo. Solo el administrador.
  Future<List<EmergencyContact>> addEmergencyContact(
      String patientId, {required String memberUserId, String? notes});

  /// Activa/desactiva un contacto (rotación). Sin orden/prioridad.
  Future<List<EmergencyContact>> updateEmergencyContact(
      String patientId, String contactId, {required bool isActive});

  /// Da de baja un contacto de emergencia.
  Future<List<EmergencyContact>> removeEmergencyContact(
      String patientId, String contactId);

  /// Equipo de cuidado del paciente (miembros vivos con su profesión).
  Future<List<CareMember>> listMembers(String patientId);
}

// ---------------------------------------------------------------------------
// HTTP
// ---------------------------------------------------------------------------
class PatientsRepositoryHttp implements PatientsRepository {
  PatientsRepositoryHttp(this._api);
  final ApiClient _api;

  @override
  Future<List<PatientCard>> listMyPatients() async {
    // /patients ya calcula el semáforo real y trae edad, enfermedades, RUT y
    // el mini-resumen de vitales. Antes se combinaba con /users/me/dashboard y
    // al reconstruir la tarjeta se perdían esos campos nuevos; ya no hace falta.
    final data = await _api.get<Map<String, dynamic>>('/patients');
    return ((data['items'] ?? []) as List)
        .map((e) => PatientCard.fromJson(e as Map<String, dynamic>))
        .map((p) => p.topReason == null
            ? p
            : p.withHumanizedReason(humanizeReason(p.topReason!)))
        .toList();
  }

  @override
  Future<Patient> getPatient(String patientId) async {
    final data = await _api.get<Map<String, dynamic>>('/patients/$patientId');
    return Patient.fromJson(data);
  }

  @override
  Future<Patient> updateConditions(
      String patientId, List<String> conditions) async {
    final data = await _api.patch<Map<String, dynamic>>(
      '/patients/$patientId',
      data: {'conditions': conditions},
    );
    return Patient.fromJson(data);
  }

  @override
  Future<Patient> updateProfile(
      String patientId, Map<String, dynamic> fields) async {
    final data = await _api.patch<Map<String, dynamic>>(
      '/patients/$patientId',
      data: fields,
    );
    return Patient.fromJson(data);
  }

  @override
  Future<Patient> addMeasurement(String patientId,
      {double? weightKg, double? heightCm}) async {
    await _api.post<Map<String, dynamic>>(
      '/patients/$patientId/measurements',
      data: {
        if (weightKg != null) 'weight_kg': weightKg,
        if (heightCm != null) 'height_cm': heightCm,
      },
    );
    return getPatient(patientId);
  }

  @override
  Future<List<AllergenCatalogItem>> allergenCatalog() async {
    final data = await _api.get<List<dynamic>>('/allergens/catalog');
    return data
        .map((e) => AllergenCatalogItem.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  @override
  Future<List<AllergyDetail>> addAllergy(
      String patientId, AllergyDetail allergy) async {
    final data = await _api.post<Map<String, dynamic>>(
      '/patients/$patientId/allergies',
      data: {
        'substance': allergy.substance,
        'category': allergy.category,
        'severity': allergy.severity,
        if (allergy.reaction != null && allergy.reaction!.trim().isNotEmpty)
          'reaction': allergy.reaction,
        'source': allergy.source ?? 'reportada',
      },
    );
    return ((data['allergies'] ?? []) as List)
        .map((e) => AllergyDetail.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  @override
  Future<List<AllergyDetail>> removeAllergy(
      String patientId, String substance) async {
    final data = await _api.delete<Map<String, dynamic>>(
      '/patients/$patientId/allergies/$substance',
    );
    return ((data['allergies'] ?? []) as List)
        .map((e) => AllergyDetail.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  @override
  Future<List<VaccineCatalogItem>> vaccineCatalog() async {
    final data = await _api.get<List<dynamic>>('/vaccines/catalog');
    return data
        .map((e) => VaccineCatalogItem.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  @override
  Future<List<Immunization>> addImmunization(
      String patientId, Immunization im) async {
    final data = await _api.post<Map<String, dynamic>>(
      '/patients/$patientId/immunizations',
      data: {
        'vaccine': im.vaccine,
        if (im.administeredOn != null)
          'administered_on': _soloFecha(im.administeredOn!),
        if (im.doseNumber != null) 'dose_number': im.doseNumber,
        if (im.exposureEvent != null && im.exposureEvent!.trim().isNotEmpty)
          'exposure_event': im.exposureEvent,
        if (im.note != null && im.note!.trim().isNotEmpty) 'note': im.note,
      },
    );
    return ((data['immunizations'] ?? []) as List)
        .map((e) => Immunization.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  @override
  Future<List<Immunization>> removeImmunization(
      String patientId, String vaccine) async {
    final data = await _api.delete<Map<String, dynamic>>(
      '/patients/$patientId/immunizations/$vaccine',
    );
    return ((data['immunizations'] ?? []) as List)
        .map((e) => Immunization.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  List<EmergencyContact> _parseContacts(Map<String, dynamic> data) =>
      ((data['contacts'] ?? []) as List)
          .map((e) => EmergencyContact.fromJson(e as Map<String, dynamic>))
          .toList();

  @override
  Future<List<EmergencyContact>> emergencyContacts(String patientId) async {
    final data = await _api
        .get<Map<String, dynamic>>('/patients/$patientId/emergency-contacts');
    return _parseContacts(data);
  }

  @override
  Future<List<EmergencyContact>> addEmergencyContact(
      String patientId, {required String memberUserId, String? notes}) async {
    final data = await _api.post<Map<String, dynamic>>(
      '/patients/$patientId/emergency-contacts',
      data: {
        'member_user_id': memberUserId,
        if (notes != null && notes.trim().isNotEmpty) 'notes': notes,
      },
    );
    return _parseContacts(data);
  }

  @override
  Future<List<EmergencyContact>> updateEmergencyContact(
      String patientId, String contactId, {required bool isActive}) async {
    final data = await _api.patch<Map<String, dynamic>>(
      '/patients/$patientId/emergency-contacts/$contactId',
      data: {'is_active': isActive},
    );
    return _parseContacts(data);
  }

  @override
  Future<List<EmergencyContact>> removeEmergencyContact(
      String patientId, String contactId) async {
    final data = await _api.delete<Map<String, dynamic>>(
      '/patients/$patientId/emergency-contacts/$contactId',
    );
    return _parseContacts(data);
  }

  static String _soloFecha(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  @override
  Future<List<ConditionDetail>> conditionCatalog() async {
    final data = await _api.get<List<dynamic>>('/conditions/catalog');
    return data
        .map((e) => ConditionDetail.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  @override
  Future<List<CareMember>> listMembers(String patientId) async {
    final data =
        await _api.get<Map<String, dynamic>>('/patients/$patientId/members');
    return ((data['members'] ?? []) as List)
        .map((e) => CareMember.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  @override
  Future<Patient> createPatient(NewPatient data) async {
    final res =
        await _api.post<Map<String, dynamic>>('/patients', data: data.toJson());
    return getPatient(res['patient_id'] as String);
  }

  @override
  Future<Invitation> invite(
      {required String patientId, required RoleType role, String? email}) async {
    final res = await _api.post<Map<String, dynamic>>(
      '/patients/$patientId/invitations',
      data: {'role': role.apiValue, if (email != null) 'email': email},
    );
    return Invitation.fromJson(res, fallbackRole: role);
  }

  @override
  Future<PatientCard> acceptInvitation(String token) async {
    // El backend responde {patient_id, role}; con eso construimos la tarjeta
    // consultando el detalle del paciente ya vinculado.
    final res = await _api.post<Map<String, dynamic>>(
      '/invitations/accept',
      data: {'token': token},
    );
    final patientId = res['patient_id'] as String;
    final role = RoleType.fromApi((res['role'] ?? 'family') as String);
    final patient = await getPatient(patientId);
    return PatientCard(
      patientId: patient.patientId,
      fullName: patient.fullName,
      photoUrl: patient.photoUrl,
      role: role,
      wellbeingStatus: WellbeingStatus.ok,
    );
  }

  @override
  Future<WearableStatus> wearableStatus(String patientId) async {
    final data =
        await _api.get<Map<String, dynamic>>('/patients/$patientId/wearable/status');
    return WearableStatus.fromJson(data);
  }
}

// ---------------------------------------------------------------------------
// Mock
// ---------------------------------------------------------------------------
class PatientsRepositoryMock implements PatientsRepository {
  final Map<String, Patient> _patients = {
    'p-elena': Patient(
      patientId: 'p-elena',
      fullName: 'Elena Ramírez',
      birthDate: DateTime(1948, 3, 12),
      sex: 'female',
      conditions: const ['Hipertensión', 'Artrosis'],
      wearable: WearableStatus(
        wearableId: 'w-1',
        lastSyncAt: DateTime.now().subtract(const Duration(minutes: 18)),
        batteryPct: 72,
      ),
    ),
    'p-jose': Patient(
      patientId: 'p-jose',
      fullName: 'José Ramírez',
      birthDate: DateTime(1945, 11, 2),
      sex: 'male',
      conditions: const ['Diabetes tipo 2'],
      wearable: WearableStatus(
        wearableId: 'w-2',
        lastSyncAt: DateTime.now().subtract(const Duration(hours: 3)),
        batteryPct: 15,
        isStale: true,
      ),
    ),
  };

  final List<PatientCard> _myPatients = [
    const PatientCard(
      patientId: 'p-elena',
      fullName: 'Elena Ramírez',
      role: RoleType.family,
      wellbeingStatus: WellbeingStatus.ok,
    ),
    const PatientCard(
      patientId: 'p-jose',
      fullName: 'José Ramírez',
      role: RoleType.family,
      wellbeingStatus: WellbeingStatus.warning,
      activeAlertsCount: 1,
      topReason: 'Wearable sin datos desde hace 3 h',
    ),
  ];

  /// Código de 6 dígitos -> invitación pendiente. Un código se usa una sola vez.
  final Map<String, ({String patientId, RoleType role, DateTime expiresAt})>
      _pendingInvitations = {};

  @override
  Future<List<PatientCard>> listMyPatients() async {
    await Future.delayed(const Duration(milliseconds: 350));
    return List.unmodifiable(_myPatients);
  }

  @override
  Future<Patient> getPatient(String patientId) async {
    await Future.delayed(const Duration(milliseconds: 250));
    final p = _patients[patientId];
    if (p == null) {
      throw ApiException(
          statusCode: 404,
          code: 'NOT_FOUND',
          message: 'El recurso solicitado no existe o no está disponible.');
    }
    return p;
  }

  @override
  Future<Patient> createPatient(NewPatient data) async {
    await Future.delayed(const Duration(milliseconds: 400));
    final id = 'p-${DateTime.now().millisecondsSinceEpoch}';
    final patient = Patient(
      patientId: id,
      fullName: data.fullName,
      birthDate: data.birthDate,
      sex: data.sex,
      conditions: data.conditions,
    );
    _patients[id] = patient;
    return patient;
  }

  @override
  Future<Invitation> invite(
      {required String patientId, required RoleType role, String? email}) async {
    await Future.delayed(const Duration(milliseconds: 300));
    final code = _generateUnusedCode();
    final expiresAt = DateTime.now().add(const Duration(hours: 48));
    _pendingInvitations[code] =
        (patientId: patientId, role: role, expiresAt: expiresAt);
    return Invitation(
      invitationId: 'i-$code',
      token: code,
      role: role,
      expiresAt: expiresAt,
    );
  }

  /// 6 dígitos (000000-999999, con ceros a la izquierda), sin choques con
  /// un código todavía pendiente.
  String _generateUnusedCode() {
    final random = Random();
    late String code;
    do {
      code = random.nextInt(1000000).toString().padLeft(6, '0');
    } while (_pendingInvitations.containsKey(code));
    return code;
  }

  @override
  Future<PatientCard> acceptInvitation(String code) async {
    await Future.delayed(const Duration(milliseconds: 300));
    final invitation = _pendingInvitations[code];
    if (invitation == null) {
      throw ApiException(
        statusCode: 404,
        code: 'INVALID_CODE',
        message: 'Ese código no es válido. Revísalo con quien te invitó.',
      );
    }
    if (DateTime.now().isAfter(invitation.expiresAt)) {
      _pendingInvitations.remove(code);
      throw ApiException(
        statusCode: 410,
        code: 'EXPIRED_CODE',
        message: 'Este código venció. Pide uno nuevo.',
      );
    }
    final patient = await getPatient(invitation.patientId);
    final card = PatientCard(
      patientId: patient.patientId,
      fullName: patient.fullName,
      role: invitation.role,
      wellbeingStatus: WellbeingStatus.ok,
    );
    _myPatients.removeWhere((c) => c.patientId == patient.patientId);
    _myPatients.add(card);
    _pendingInvitations.remove(code); // un solo uso
    return card;
  }

  @override
  Future<WearableStatus> wearableStatus(String patientId) async {
    final p = await getPatient(patientId);
    return p.wearable ?? const WearableStatus();
  }

  @override
  Future<Patient> updateConditions(
      String patientId, List<String> conditions) async {
    final p = _patients[patientId];
    if (p == null) throw StateError('paciente no encontrado');
    final actualizado = Patient(
      patientId: p.patientId,
      fullName: p.fullName,
      birthDate: p.birthDate,
      sex: p.sex,
      photoUrl: p.photoUrl,
      conditions: conditions,
      wearable: p.wearable,
    );
    _patients[patientId] = actualizado;
    return actualizado;
  }

  @override
  Future<Patient> updateProfile(
      String patientId, Map<String, dynamic> fields) async {
    final p = _patients[patientId];
    if (p == null) throw StateError('paciente no encontrado');
    final actualizado = Patient(
      patientId: p.patientId,
      fullName: p.fullName,
      birthDate: p.birthDate,
      sex: p.sex,
      photoUrl: p.photoUrl,
      conditions: p.conditions,
      wearable: p.wearable,
      rut: p.rut,
      address: fields['address'] as String? ?? p.address,
      maritalStatus: fields['marital_status'] as String? ?? p.maritalStatus,
      insurance: fields['insurance'] as String? ?? p.insurance,
      rcvLevel: fields['rcv_level'] as String? ?? p.rcvLevel,
      latestMeasurement: p.latestMeasurement,
    );
    _patients[patientId] = actualizado;
    return actualizado;
  }

  @override
  Future<Patient> addMeasurement(String patientId,
      {double? weightKg, double? heightCm}) async {
    final p = _patients[patientId];
    if (p == null) throw StateError('paciente no encontrado');
    double? bmi;
    if (weightKg != null && heightCm != null && heightCm > 0) {
      final m = heightCm / 100.0;
      bmi = double.parse((weightKg / (m * m)).toStringAsFixed(1));
    }
    final actualizado = Patient(
      patientId: p.patientId,
      fullName: p.fullName,
      birthDate: p.birthDate,
      sex: p.sex,
      photoUrl: p.photoUrl,
      conditions: p.conditions,
      wearable: p.wearable,
      rut: p.rut,
      address: p.address,
      maritalStatus: p.maritalStatus,
      insurance: p.insurance,
      rcvLevel: p.rcvLevel,
      latestMeasurement: PatientMeasurement(
          weightKg: weightKg,
          heightCm: heightCm,
          bmi: bmi,
          measuredAt: DateTime.now()),
    );
    _patients[patientId] = actualizado;
    return actualizado;
  }

  @override
  Future<List<ConditionDetail>> conditionCatalog() async => const [
        ConditionDetail(
            condition: 'hipertension',
            system: 'cardiovascular',
            label: 'Hipertensión arterial (HTA)'),
        ConditionDetail(
            condition: 'diabetes_tipo_2',
            system: 'metabolico',
            label: 'Diabetes mellitus tipo 2 (DM2)'),
        ConditionDetail(
            condition: 'epoc',
            system: 'respiratorio',
            label: 'Enfermedad pulmonar obstructiva crónica (EPOC)'),
        ConditionDetail(
            condition: 'artrosis_rodilla',
            system: 'osteomuscular',
            label: 'Artrosis de rodillas'),
      ];

  @override
  Future<List<AllergenCatalogItem>> allergenCatalog() async => const [
        AllergenCatalogItem(
            code: 'penicilina', label: 'Penicilina', category: 'medicamento'),
        AllergenCatalogItem(
            code: 'aines', label: 'AINEs (antiinflamatorios)', category: 'medicamento'),
        AllergenCatalogItem(
            code: 'mariscos', label: 'Mariscos', category: 'alimento'),
        AllergenCatalogItem(
            code: 'latex', label: 'Látex', category: 'ambiental'),
      ];

  final Map<String, List<AllergyDetail>> _allergies = {};

  @override
  Future<List<AllergyDetail>> addAllergy(
      String patientId, AllergyDetail allergy) async {
    await Future.delayed(const Duration(milliseconds: 150));
    final lista = _allergies.putIfAbsent(patientId, () => []);
    lista.removeWhere((a) => a.substance == allergy.substance);
    lista.add(allergy);
    return List.unmodifiable(lista);
  }

  @override
  Future<List<AllergyDetail>> removeAllergy(
      String patientId, String substance) async {
    await Future.delayed(const Duration(milliseconds: 150));
    final lista = _allergies.putIfAbsent(patientId, () => []);
    lista.removeWhere((a) => a.substance == substance);
    return List.unmodifiable(lista);
  }

  @override
  Future<List<VaccineCatalogItem>> vaccineCatalog() async => const [
        VaccineCatalogItem(
            code: 'influenza',
            label: 'Influenza (anual)',
            kindDefault: 'preventiva',
            isRecurrent: true,
            intervalMonths: 12),
        VaccineCatalogItem(
            code: 'neumococica_23',
            label: 'Neumocócica polisacárida 23v',
            kindDefault: 'preventiva',
            isRecurrent: false),
        VaccineCatalogItem(
            code: 'antirrabica',
            label: 'Antirrábica',
            kindDefault: 'post_exposicion',
            isRecurrent: false),
      ];

  final Map<String, List<Immunization>> _immunizations = {};

  @override
  Future<List<Immunization>> addImmunization(
      String patientId, Immunization im) async {
    await Future.delayed(const Duration(milliseconds: 150));
    final lista = _immunizations.putIfAbsent(patientId, () => []);
    lista.add(im);
    return List.unmodifiable(lista);
  }

  @override
  Future<List<Immunization>> removeImmunization(
      String patientId, String vaccine) async {
    await Future.delayed(const Duration(milliseconds: 150));
    final lista = _immunizations.putIfAbsent(patientId, () => []);
    final idx = lista.lastIndexWhere((v) => v.vaccine == vaccine);
    if (idx >= 0) lista.removeAt(idx);
    return List.unmodifiable(lista);
  }

  final Map<String, List<EmergencyContact>> _contacts = {};

  @override
  Future<List<EmergencyContact>> emergencyContacts(String patientId) async {
    await Future.delayed(const Duration(milliseconds: 150));
    return List.unmodifiable(_contacts[patientId] ?? const []);
  }

  @override
  Future<List<EmergencyContact>> addEmergencyContact(
      String patientId, {required String memberUserId, String? notes}) async {
    await Future.delayed(const Duration(milliseconds: 150));
    final lista = _contacts.putIfAbsent(patientId, () => []);
    lista.add(EmergencyContact(
      id: 'ec-${DateTime.now().millisecondsSinceEpoch}',
      name: 'Miembro $memberUserId',
      isActive: true,
      memberUserId: memberUserId,
      notes: notes,
    ));
    return List.unmodifiable(lista);
  }

  @override
  Future<List<EmergencyContact>> updateEmergencyContact(
      String patientId, String contactId, {required bool isActive}) async {
    await Future.delayed(const Duration(milliseconds: 150));
    final lista = _contacts.putIfAbsent(patientId, () => []);
    final i = lista.indexWhere((c) => c.id == contactId);
    if (i >= 0) {
      final c = lista[i];
      lista[i] = EmergencyContact(
        id: c.id,
        name: c.name,
        isActive: isActive,
        memberUserId: c.memberUserId,
        phone: c.phone,
        avatarUrl: c.avatarUrl,
        notes: c.notes,
      );
    }
    return List.unmodifiable(lista);
  }

  @override
  Future<List<EmergencyContact>> removeEmergencyContact(
      String patientId, String contactId) async {
    await Future.delayed(const Duration(milliseconds: 150));
    final lista = _contacts.putIfAbsent(patientId, () => []);
    lista.removeWhere((c) => c.id == contactId);
    return List.unmodifiable(lista);
  }

  @override
  Future<List<CareMember>> listMembers(String patientId) async => const [
        CareMember(
            userId: 'u1',
            fullName: 'Javier Cerna',
            email: 'ja.cernac@duocuc.cl',
            role: 'family',
            isOwner: true),
        CareMember(
            userId: 'u2',
            fullName: 'Rosa Medina',
            email: 'rosa@cuidados.cl',
            role: 'caregiver',
            profession: 'cuidadora'),
      ];
}

final patientsRepositoryProvider = Provider<PatientsRepository>((ref) {
  if (AppConfig.useMocks) return PatientsRepositoryMock();
  return PatientsRepositoryHttp(ref.watch(apiClientProvider));
});
