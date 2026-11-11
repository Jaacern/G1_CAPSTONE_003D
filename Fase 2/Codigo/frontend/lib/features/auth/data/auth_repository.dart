import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/app_config.dart';
import '../../../core/network/api_client.dart';
import '../domain/models.dart';

/// Contrato del repositorio de autenticación.
abstract class AuthRepository {
  Future<AuthSession> login({required String email, required String password});

  /// [accountType] es obligatorio salvo con [invitationToken] (la invitación
  /// ya define el rol). Para médico hace falta [doctorEnrollmentToken], el
  /// código que entrega el personal de AgeCare tras verificar el registro.
  Future<AuthTokens> register({
    required String firstName,
    String? secondName,
    required String lastName,
    String? secondLastName,
    String? rut,
    required String email,
    required String password,
    RoleType? accountType,
    String? doctorEnrollmentToken,
    String? phone,
    String? invitationToken,
  });

  Future<void> requestPasswordRecovery(String email);

  Future<User> me();

  /// [deviceId] es el id del aparato registrado para push. Si se manda, el
  /// backend deja de enviarle avisos a este teléfono (RF-04).
  Future<void> logout(String refreshToken, {String? deviceId});
}

// ---------------------------------------------------------------------------
// Implementación HTTP (contra la Especificación de Endpoints v1)
// ---------------------------------------------------------------------------
class AuthRepositoryHttp implements AuthRepository {
  AuthRepositoryHttp(this._api);
  final ApiClient _api;

  @override
  Future<AuthSession> login(
      {required String email, required String password}) async {
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
  Future<AuthTokens> register({
    required String firstName,
    String? secondName,
    required String lastName,
    String? secondLastName,
    String? rut,
    required String email,
    required String password,
    RoleType? accountType,
    String? doctorEnrollmentToken,
    String? phone,
    String? invitationToken,
  }) async {
    // RegisterIn exige first_name y last_name por separado (no full_name) y
    // el tipo de cuenta. El backend normaliza y valida los nombres.
    final data = await _api.post<Map<String, dynamic>>('/auth/register', data: {
      'first_name': firstName,
      if (secondName != null && secondName.isNotEmpty) 'second_name': secondName,
      'last_name': lastName,
      if (secondLastName != null && secondLastName.isNotEmpty)
        'second_last_name': secondLastName,
      if (rut != null && rut.isNotEmpty) 'rut': rut,
      'email': email,
      'password': password,
      if (accountType != null) 'account_type': accountType.apiValue,
      if (doctorEnrollmentToken != null && doctorEnrollmentToken.isNotEmpty)
        'doctor_enrollment_token': doctorEnrollmentToken,
      if (phone != null && phone.isNotEmpty) 'phone': phone,
      if (invitationToken != null) 'invitation_token': invitationToken,
      'locale': 'es',
    });
    // El usuario no se arma aquí con lo que escribió la persona: lo decide el
    // servidor (tipo de cuenta, habilitación, membresías) y se lee con me().
    return AuthTokens(
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
  Future<void> logout(String refreshToken, {String? deviceId}) =>
      _api.post<void>('/auth/logout', data: {
        'refresh_token': refreshToken,
        if (deviceId != null) 'device_id': deviceId,
      });
}

// ---------------------------------------------------------------------------
// Implementación Mock (demo sin backend)
// ---------------------------------------------------------------------------
class AuthRepositoryMock implements AuthRepository {
  static const demoEmail = 'demo@agecare.app';
  static const demoDoctorEmail = 'doctor@agecare.app';
  static const demoCaregiverEmail = 'cuidadora@agecare.app';
  // En producción el adulto mayor no usa contraseña (911_elder_account.sql):
  // autentica el dispositivo vinculado. Solo en modo demo se expone esta
  // cuenta para poder revisar su vista desde el navegador.
  static const demoElderEmail = 'adultomayor@agecare.app';
  static const demoPassword = 'agecare123';

  User? _currentUser;

  static const _demoUser = User(
    userId: 'u-demo-1',
    fullName: 'María José González Pérez',
    firstName: 'María',
    secondName: 'José',
    lastName: 'González',
    secondLastName: 'Pérez',
    email: demoEmail,
    accountType: RoleType.family,
    memberships: [
      Membership(
          patientId: 'p-elena', patientName: 'Elena', role: RoleType.family),
      Membership(
          patientId: 'p-jose', patientName: 'José', role: RoleType.family),
    ],
  );

  static const _demoDoctor = User(
    userId: 'u-demo-doctor',
    fullName: 'Dra. Carolina Soto',
    firstName: 'Carolina',
    lastName: 'Soto',
    email: demoDoctorEmail,
    accountType: RoleType.doctor,
    doctorVerified: true,
    memberships: [
      Membership(
          patientId: 'p-elena',
          patientName: 'Elena Ramírez',
          role: RoleType.doctor),
      Membership(
          patientId: 'p-jose',
          patientName: 'José Ramírez',
          role: RoleType.doctor),
    ],
  );

  static const _demoCaregiver = User(
    userId: 'u-demo-caregiver',
    fullName: 'Rosa Millán Díaz',
    firstName: 'Rosa',
    lastName: 'Millán',
    secondLastName: 'Díaz',
    rut: '15.234.567-4',
    email: demoCaregiverEmail,
    accountType: RoleType.caregiver,
    memberships: [
      Membership(
          patientId: 'p-elena',
          patientName: 'Elena Ramírez',
          role: RoleType.caregiver),
      Membership(
          patientId: 'p-jose',
          patientName: 'José Ramírez',
          role: RoleType.caregiver),
    ],
  );

  // Solo demo: el adulto mayor es paciente de sí mismo. Permite revisar la
  // vista del rol elder sin un dispositivo vinculado.
  static const _demoElder = User(
    userId: 'u-demo-elder',
    fullName: 'Elena Ramírez',
    firstName: 'Elena',
    lastName: 'Ramírez',
    email: demoElderEmail,
    accountType: RoleType.elder,
    memberships: [
      Membership(
          patientId: 'p-elena',
          patientName: 'Elena Ramírez',
          role: RoleType.elder),
    ],
  );

  @override
  Future<AuthSession> login(
      {required String email, required String password}) async {
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
      demoCaregiverEmail => _demoCaregiver,
      demoElderEmail => _demoElder,
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
    return AuthSession(
        user: user, accessToken: 'mock-access', refreshToken: 'mock-refresh');
  }

  /// Código de habilitación de médico que acepta el modo demo. En el backend
  /// real lo emite el personal de AgeCare desde el panel de administración.
  static const demoDoctorEnrollmentCode = 'MEDICO-DEMO';

  @override
  Future<AuthTokens> register({
    required String firstName,
    String? secondName,
    required String lastName,
    String? secondLastName,
    String? rut,
    required String email,
    required String password,
    RoleType? accountType,
    String? doctorEnrollmentToken,
    String? phone,
    String? invitationToken,
  }) async {
    await Future.delayed(const Duration(milliseconds: 400));
    const conocidos = {
      demoEmail,
      demoDoctorEmail,
      demoCaregiverEmail,
      demoElderEmail,
    };
    if (conocidos.contains(email.toLowerCase())) {
      throw ApiException(
        statusCode: 409,
        code: 'EMAIL_ALREADY_EXISTS',
        message: 'Ya existe una cuenta con este correo electrónico.',
      );
    }
    // Mismas reglas que POST /auth/register.
    if (accountType == null && invitationToken == null) {
      throw ApiException(
        statusCode: 422,
        code: 'VALIDATION_ERROR',
        message: 'Indica si te registras como familiar, cuidador(a) o médico.',
      );
    }
    if (accountType == RoleType.elder) {
      throw ApiException(
        statusCode: 422,
        code: 'VALIDATION_ERROR',
        message: 'La cuenta del adulto mayor la vincula su familia.',
      );
    }
    // La cuidadora entra a casas ajenas: sin RUT ni teléfono no hay cuenta.
    if (accountType == RoleType.caregiver &&
        (rut == null || rut.isEmpty || phone == null || phone.isEmpty)) {
      throw ApiException(
        statusCode: 422,
        code: 'VALIDATION_ERROR',
        message: 'Hay datos inválidos en la solicitud.',
        fieldErrors: {
          if (rut == null || rut.isEmpty)
            'rut': 'El RUT es obligatorio para cuidadores(as).',
          if (phone == null || phone.isEmpty)
            'phone': 'El teléfono es obligatorio para cuidadores(as).',
        },
      );
    }
    final esMedico = accountType == RoleType.doctor;
    if (esMedico && doctorEnrollmentToken != demoDoctorEnrollmentCode) {
      throw ApiException(
        statusCode: 403,
        code: doctorEnrollmentToken == null || doctorEnrollmentToken.isEmpty
            ? 'DOCTOR_ENROLLMENT_REQUIRED'
            : 'INVALID_DOCTOR_ENROLLMENT',
        message: doctorEnrollmentToken == null || doctorEnrollmentToken.isEmpty
            ? 'Las cuentas de médico las habilita el equipo de AgeCare.'
            : 'El código de habilitación no existe, ya fue usado, venció o no corresponde a este correo.',
      );
    }
    _currentUser = User(
      userId: 'u-new',
      fullName: [firstName, secondName, lastName, secondLastName]
          .where((p) => p != null && p.isNotEmpty)
          .join(' '),
      firstName: firstName,
      secondName: secondName,
      lastName: lastName,
      secondLastName: secondLastName,
      rut: rut,
      email: email,
      accountType: accountType ?? RoleType.family,
      doctorVerified: esMedico,
      phone: phone,
    );
    return const AuthTokens(
        accessToken: 'mock-access', refreshToken: 'mock-refresh');
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
  Future<void> logout(String refreshToken, {String? deviceId}) async {
    _currentUser = null;
  }
}

final authRepositoryProvider = Provider<AuthRepository>((ref) {
  if (AppConfig.useMocks) return AuthRepositoryMock();
  return AuthRepositoryHttp(ref.watch(apiClientProvider));
});
