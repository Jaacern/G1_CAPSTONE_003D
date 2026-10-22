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

class Patient {
  const Patient({
    required this.patientId,
    required this.fullName,
    required this.birthDate,
    this.sex,
    this.photoUrl,
    this.conditions = const [],
    this.wearable,
  });

  final String patientId;
  final String fullName;
  final DateTime birthDate;
  final String? sex;
  final String? photoUrl;
  final List<String> conditions;
  final WearableStatus? wearable;

  int get age {
    final now = DateTime.now();
    var years = now.year - birthDate.year;
    if (now.month < birthDate.month ||
        (now.month == birthDate.month && now.day < birthDate.day)) {
      years--;
    }
    return years;
  }

  factory Patient.fromJson(Map<String, dynamic> json) => Patient(
        patientId: json['patient_id'] as String,
        fullName: json['full_name'] as String,
        birthDate: DateTime.parse(json['birth_date'] as String),
        sex: json['sex'] as String?,
        photoUrl: json['photo_url'] as String?,
        conditions:
            ((json['conditions'] ?? []) as List).map((e) => e.toString()).toList(),
        wearable: json['wearable'] != null
            ? WearableStatus.fromJson(json['wearable'] as Map<String, dynamic>)
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
    this.topReason,
  });

  final String patientId;
  final String fullName;
  final String? photoUrl;
  final RoleType role;
  final WellbeingStatus wellbeingStatus;
  final int activeAlertsCount;
  final String? topReason;

  factory PatientCard.fromJson(Map<String, dynamic> json) => PatientCard(
        patientId: json['patient_id'] as String,
        fullName: json['full_name'] as String,
        photoUrl: json['photo_url'] as String?,
        role: RoleType.fromApi((json['role'] ?? 'family') as String),
        wellbeingStatus:
            WellbeingStatus.fromApi((json['wellbeing_status'] ?? 'ok') as String),
        activeAlertsCount: (json['active_alerts_count'] ?? 0) as int,
        topReason: json['top_reason'] as String?,
      );
}

/// Solicitud de creación de paciente.
///
/// La UI captura un único campo "Nombre completo", pero el backend exige
/// `first_name` + `last_name` por separado (esquema 2FN). Al serializar se
/// divide el nombre: la primera palabra es el nombre y el resto el apellido.
class NewPatient {
  const NewPatient({
    required this.fullName,
    required this.birthDate,
    this.sex,
    this.conditions = const [],
  });

  final String fullName;
  final DateTime birthDate;
  final String? sex;
  final List<String> conditions;

  /// Divide el nombre completo en (first_name, last_name) para el backend.
  /// Si solo hay una palabra, se usa como nombre y el apellido queda igual
  /// (el backend exige ambos con min_length 1).
  (String, String) get _splitName {
    final parts =
        fullName.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return ('', '');
    if (parts.length == 1) return (parts.first, parts.first);
    return (parts.first, parts.sublist(1).join(' '));
  }

  Map<String, dynamic> toJson() {
    final (firstName, lastName) = _splitName;
    return {
      'first_name': firstName,
      'last_name': lastName,
      'birth_date':
          '${birthDate.year.toString().padLeft(4, '0')}-${birthDate.month.toString().padLeft(2, '0')}-${birthDate.day.toString().padLeft(2, '0')}',
      if (sex != null) 'sex': sex,
      if (conditions.isNotEmpty) 'conditions': conditions,
    };
  }
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
