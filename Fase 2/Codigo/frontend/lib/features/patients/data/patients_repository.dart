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
}

// ---------------------------------------------------------------------------
// HTTP
// ---------------------------------------------------------------------------
class PatientsRepositoryHttp implements PatientsRepository {
  PatientsRepositoryHttp(this._api);
  final ApiClient _api;

  @override
  Future<List<PatientCard>> listMyPatients() async {
    // /patients trae el rol, pero su wellbeing_status viene fijo en "ok".
    // /users/me/dashboard sí calcula el semáforo real (vitals, dosis, alertas).
    // Se combinan por patient_id: rol de /patients + semáforo del dashboard.
    final data = await _api.get<Map<String, dynamic>>('/patients');
    final base = ((data['items'] ?? []) as List)
        .map((e) => PatientCard.fromJson(e as Map<String, dynamic>))
        .toList();

    Map<String, Map<String, dynamic>> board = {};
    try {
      final dash = await _api.get<Map<String, dynamic>>('/users/me/dashboard');
      for (final e in (dash['items'] ?? []) as List) {
        final m = e as Map<String, dynamic>;
        board[m['patient_id'] as String] = m;
      }
    } catch (_) {
      // Si el dashboard falla, se muestran los pacientes sin semáforo calculado.
    }

    return [
      for (final p in base)
        board[p.patientId] == null
            ? p
            : PatientCard(
                patientId: p.patientId,
                fullName: p.fullName,
                photoUrl: p.photoUrl,
                role: p.role,
                wellbeingStatus: WellbeingStatus.fromApi(
                    (board[p.patientId]!['wellbeing_status'] ?? 'ok') as String),
                activeAlertsCount:
                    (board[p.patientId]!['active_alerts_count'] ?? 0) as int,
                topReason: board[p.patientId]!['top_reason'] == null
                    ? null
                    : humanizeReason(
                        board[p.patientId]!['top_reason'] as String),
              ),
    ];
  }

  @override
  Future<Patient> getPatient(String patientId) async {
    final data = await _api.get<Map<String, dynamic>>('/patients/$patientId');
    return Patient.fromJson(data);
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
}

final patientsRepositoryProvider = Provider<PatientsRepository>((ref) {
  if (AppConfig.useMocks) return PatientsRepositoryMock();
  return PatientsRepositoryHttp(ref.watch(apiClientProvider));
});
