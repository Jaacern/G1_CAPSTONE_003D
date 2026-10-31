import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/app_config.dart';
import '../../../core/network/api_client.dart';
import '../domain/models.dart';

/// Contrato del repositorio de autenticación.
abstract class AuthRepository {
  Future<AuthSession> login({required String email, required String password});

  Future<AuthSession> register({
    required String firstName,
    required String lastName,
    required String email,
    required String password,
    String? phone,
    String? invitationToken,
  });

  Future<void> requestPasswordRecovery(String email);

  Future<User> me();

  Future<void> logout(String refreshToken);
}

// ---------------------------------------------------------------------------
// Implementación HTTP (contra la Especificación de Endpoints v1)
// ---------------------------------------------------------------------------
class AuthRepositoryHttp implements AuthRepository {
  AuthRepositoryHttp(this._api);
  final ApiClient _api;

  @override
  Future<AuthSession> login({required String email, required String password}) async {
    final data = await _api.post<Map<String, dynamic>>('/auth/login',
        data: {'email': email, 'password': password});
    final user = User.fromJson({
      ...data['user'] as Map<String, dynamic>,
      'memberships': data['memberships'],
    });
    return AuthSession(
      user: user,
      accessToken: data['access_token'] as String,
      refreshToken: data['refresh_token'] as String,
    );
  }

  @override
  Future<AuthSession> register({
    required String firstName,
    required String lastName,
    required String email,
    required String password,
    String? phone,
    String? invitationToken,
  }) async {
    // RegisterIn exige first_name y last_name por separado (no full_name).
    final data = await _api.post<Map<String, dynamic>>('/auth/register', data: {
      'first_name': firstName,
      'last_name': lastName,
      'email': email,
      'password': password,
      if (phone != null && phone.isNotEmpty) 'phone': phone,
      if (invitationToken != null) 'invitation_token': invitationToken,
      'locale': 'es',
    });
    return AuthSession(
      user: User(
        userId: data['user_id'] as String,
        fullName: '$firstName $lastName',
        email: email,
        // Las membresías no vienen en RegisterOut; llegan en /users/me.
        memberships: const [],
      ),
      accessToken: data['access_token'] as String,
      refreshToken: data['refresh_token'] as String,
    );
  }

  @override
  Future<void> requestPasswordRecovery(String email) =>
      _api.post<void>('/auth/password/recovery', data: {'email': email});

  @override
  Future<User> me() async {
    final data = await _api.get<Map<String, dynamic>>('/users/me');
    return User.fromJson(data);
  }

  @override
  Future<void> logout(String refreshToken) =>
      _api.post<void>('/auth/logout', data: {'refresh_token': refreshToken});
}

// ---------------------------------------------------------------------------
// Implementación Mock (demo sin backend)
// ---------------------------------------------------------------------------
class AuthRepositoryMock implements AuthRepository {
  static const demoEmail = 'demo@agecare.app';
  static const demoDoctorEmail = 'doctor@agecare.app';
  static const demoPassword = 'agecare123';

  User? _currentUser;

  static final _demoUser = User(
    userId: 'u-demo-1',
    fullName: 'María González',
    email: demoEmail,
    memberships: const [
      Membership(patientId: 'p-elena', patientName: 'Elena', role: RoleType.family),
      Membership(patientId: 'p-jose', patientName: 'José', role: RoleType.family),
    ],
  );

  static final _demoDoctor = User(
    userId: 'u-demo-doctor',
    fullName: 'Dra. Carolina Soto',
    email: demoDoctorEmail,
    memberships: const [
      Membership(patientId: 'p-elena', patientName: 'Elena Ramírez', role: RoleType.doctor),
      Membership(patientId: 'p-jose', patientName: 'José Ramírez', role: RoleType.doctor),
    ],
  );

  @override
  Future<AuthSession> login({required String email, required String password}) async {
    await Future.delayed(const Duration(milliseconds: 400));
    if (password != demoPassword) {
      throw ApiException(
        statusCode: 401,
        code: 'INVALID_CREDENTIALS',
        message: 'Correo o contraseña incorrectos.',
      );
    }
    final user = switch (email.toLowerCase()) {
      demoEmail => _demoUser,
      demoDoctorEmail => _demoDoctor,
      _ => null,
    };
    if (user == null) {
      throw ApiException(
        statusCode: 401,
        code: 'INVALID_CREDENTIALS',
        message: 'Correo o contraseña incorrectos.',
      );
    }
    _currentUser = user;
    return AuthSession(user: user, accessToken: 'mock-access', refreshToken: 'mock-refresh');
  }

  @override
  Future<AuthSession> register({
    required String firstName,
    required String lastName,
    required String email,
    required String password,
    String? phone,
    String? invitationToken,
  }) async {
    await Future.delayed(const Duration(milliseconds: 400));
    if (email.toLowerCase() == demoEmail) {
      throw ApiException(
        statusCode: 409,
        code: 'EMAIL_ALREADY_EXISTS',
        message: 'Ya existe una cuenta con este correo electrónico.',
      );
    }
    _currentUser = User(
      userId: 'u-new',
      fullName: '$firstName $lastName',
      email: email,
      phone: phone,
    );
    return AuthSession(
        user: _currentUser!, accessToken: 'mock-access', refreshToken: 'mock-refresh');
  }

  @override
  Future<void> requestPasswordRecovery(String email) async {
    await Future.delayed(const Duration(milliseconds: 300));
  }

  @override
  Future<User> me() async {
    await Future.delayed(const Duration(milliseconds: 200));
    return _currentUser ?? _demoUser;
  }

  @override
  Future<void> logout(String refreshToken) async {
    _currentUser = null;
  }
}

final authRepositoryProvider = Provider<AuthRepository>((ref) {
  if (AppConfig.useMocks) return AuthRepositoryMock();
  return AuthRepositoryHttp(ref.watch(apiClientProvider));
});
