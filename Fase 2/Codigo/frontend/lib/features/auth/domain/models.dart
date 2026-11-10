/// Modelos de autenticación (alineados con la Especificación de Endpoints v1).
library;

import 'dart:ui' show Color;

import '../../../core/theme/app_theme.dart';

enum RoleType {
  family('family', 'Familiar'),
  caregiver('caregiver', 'Cuidadora'),
  doctor('doctor', 'Médico'),
  elder('elder', 'Adulto mayor');

  const RoleType(this.apiValue, this.label);
  final String apiValue;
  final String label;

  /// Acento de rol (guía AgeCare, sección 4.5). Para avatares, etiquetas de
  /// nombre y tarjetas de rol. Nunca para estados ni acciones.
  Color get accentFg => switch (this) {
        RoleType.family => AgeRoleAccent.familyFg,
        RoleType.caregiver => AgeRoleAccent.caregiverFg,
        RoleType.doctor => AgeRoleAccent.doctorFg,
        RoleType.elder => AgeRoleAccent.elderFg,
      };

  Color get accentBg => switch (this) {
        RoleType.family => AgeRoleAccent.familyBg,
        RoleType.caregiver => AgeRoleAccent.caregiverBg,
        RoleType.doctor => AgeRoleAccent.doctorBg,
        RoleType.elder => AgeRoleAccent.elderBg,
      };

  static RoleType fromApi(String v) => RoleType.values
      .firstWhere((r) => r.apiValue == v, orElse: () => RoleType.family);
}

class Membership {
  const Membership({
    required this.patientId,
    required this.patientName,
    required this.role,
  });

  final String patientId;
  final String patientName;
  final RoleType role;

  factory Membership.fromJson(Map<String, dynamic> json) => Membership(
        patientId: json['patient_id'] as String,
        patientName: json['patient_name'] as String,
        role: RoleType.fromApi(json['role'] as String),
      );
}

class User {
  const User({
    required this.userId,
    required this.fullName,
    required this.email,
    required this.accountType,
    this.firstName = '',
    this.secondName,
    this.lastName = '',
    this.secondLastName,
    this.rut,
    this.doctorVerified = false,
    this.phone,
    this.avatarUrl,
    this.locale = 'es',
    this.memberships = const [],
  });

  final String userId;
  final String fullName;

  /// Nombre en cuatro partes. [fullName] es la unión que arma el servidor.
  final String firstName;
  final String? secondName;
  final String lastName;
  final String? secondLastName;

  /// "12.345.678-5". Lo registra la cuidadora; el familiar no lo necesita.
  final String? rut;
  final String email;
  final String? phone;
  final String? avatarUrl;
  final String locale;

  /// Qué es la persona para la plataforma (`users.account_type`). Lo elige
  /// al registrarse y no depende de tener pacientes: una cuidadora recién
  /// registrada sigue siendo cuidadora aunque nadie la haya invitado aún.
  final RoleType accountType;

  /// Solo aplica a médicos: habilitación vigente del personal de AgeCare.
  final bool doctorVerified;
  final List<Membership> memberships;

  /// Rol con el que se arma la vista. Es el tipo de cuenta, no la primera
  /// membresía: antes, sin membresías se asumía "familiar" y una cuidadora o
  /// un médico recién registrados veían la app de la familia.
  RoleType get primaryRole => accountType;

  /// Médico cuya cuenta no está (o dejó de estar) habilitada.
  bool get isUnverifiedDoctor =>
      accountType == RoleType.doctor && !doctorVerified;

  factory User.fromJson(Map<String, dynamic> json) => User(
        userId: json['user_id'] as String,
        fullName: json['full_name'] as String,
        firstName: (json['first_name'] ?? '') as String,
        secondName: json['second_name'] as String?,
        lastName: (json['last_name'] ?? '') as String,
        secondLastName: json['second_last_name'] as String?,
        rut: json['rut'] as String?,
        email: json['email'] as String,
        accountType: RoleType.fromApi((json['account_type'] ?? '') as String),
        doctorVerified: (json['doctor_verified'] ?? false) as bool,
        phone: json['phone'] as String?,
        avatarUrl: json['avatar_url'] as String?,
        locale: (json['locale'] ?? 'es') as String,
        memberships: ((json['memberships'] ?? []) as List)
            .map((m) => Membership.fromJson(m as Map<String, dynamic>))
            .toList(),
      );

  User copyWith({List<Membership>? memberships}) => User(
        userId: userId,
        fullName: fullName,
        firstName: firstName,
        secondName: secondName,
        lastName: lastName,
        secondLastName: secondLastName,
        rut: rut,
        email: email,
        accountType: accountType,
        doctorVerified: doctorVerified,
        phone: phone,
        avatarUrl: avatarUrl,
        locale: locale,
        memberships: memberships ?? this.memberships,
      );
}

/// Tipos de cuenta que una persona puede elegir al registrarse. El adulto
/// mayor no se registra solo (su cuenta la vincula la familia) y el médico
/// necesita el código de habilitación que emite el personal de AgeCare.
const selfRegistrableAccountTypes = [
  RoleType.family,
  RoleType.caregiver,
  RoleType.doctor,
];

class AuthSession {
  const AuthSession(
      {required this.user,
      required this.accessToken,
      required this.refreshToken});

  final User user;
  final String accessToken;
  final String refreshToken;
}

/// Lo que devuelve el registro: solo la sesión. El usuario se pide después a
/// `/users/me`, porque su tipo de cuenta, la habilitación del médico y sus
/// membresías las decide el servidor, no lo que se escribió en el formulario.
class AuthTokens {
  const AuthTokens({required this.accessToken, required this.refreshToken});

  final String accessToken;
  final String refreshToken;
}
