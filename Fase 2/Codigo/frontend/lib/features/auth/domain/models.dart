/// Modelos de autenticación (alineados con la Especificación de Endpoints v1).

enum RoleType {
  family('family', 'Familiar'),
  caregiver('caregiver', 'Cuidadora'),
  doctor('doctor', 'Médico'),
  elder('elder', 'Adulto mayor');

  const RoleType(this.apiValue, this.label);
  final String apiValue;
  final String label;

  static RoleType fromApi(String v) =>
      RoleType.values.firstWhere((r) => r.apiValue == v, orElse: () => RoleType.family);
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
    this.phone,
    this.avatarUrl,
    this.locale = 'es',
    this.memberships = const [],
  });

  final String userId;
  final String fullName;
  final String email;
  final String? phone;
  final String? avatarUrl;
  final String locale;
  final List<Membership> memberships;

  /// Rol principal del usuario (el de su primera membresía).
  /// Determina qué vista de la app se muestra.
  RoleType get primaryRole =>
      memberships.isEmpty ? RoleType.family : memberships.first.role;

  factory User.fromJson(Map<String, dynamic> json) => User(
        userId: json['user_id'] as String,
        fullName: json['full_name'] as String,
        email: json['email'] as String,
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
        email: email,
        phone: phone,
        avatarUrl: avatarUrl,
        locale: locale,
        memberships: memberships ?? this.memberships,
      );
}

class AuthSession {
  const AuthSession({required this.user, required this.accessToken, required this.refreshToken});

  final User user;
  final String accessToken;
  final String refreshToken;
}
