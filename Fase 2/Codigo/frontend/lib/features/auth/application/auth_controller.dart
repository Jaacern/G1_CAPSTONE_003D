import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../data/auth_repository.dart';
import '../domain/models.dart';

/// Estado global de autenticación.
sealed class AuthState {
  const AuthState();
}

class AuthLoading extends AuthState {
  const AuthLoading();
}

class Unauthenticated extends AuthState {
  const Unauthenticated();
}

class Authenticated extends AuthState {
  const Authenticated(this.user);
  final User user;
}

class AuthController extends Notifier<AuthState> {
  @override
  AuthState build() {
    _restoreSession();
    return const AuthLoading();
  }

  AuthRepository get _repo => ref.read(authRepositoryProvider);

  Future<void> _restoreSession() async {
    // Tiempo mínimo para que la animación del splash se aprecie completa,
    // incluso si la restauración de sesión resuelve de inmediato.
    final minSplash = Future<void>.delayed(const Duration(milliseconds: 1600));

    final tokens = ref.read(tokenStorageProvider);
    AuthState resolved = const Unauthenticated();
    if (await tokens.hasSession) {
      try {
        final user = await _repo.me();
        resolved = Authenticated(user);
      } catch (_) {
        await tokens.clear();
      }
    }

    await minSplash;
    state = resolved;
  }

  Future<void> login(String email, String password) async {
    final session = await _repo.login(email: email, password: password);
    await ref
        .read(tokenStorageProvider)
        .save(access: session.accessToken, refresh: session.refreshToken);
    state = Authenticated(session.user);
  }

  Future<void> register({
    required String firstName,
    required String lastName,
    required String email,
    required String password,
    String? phone,
    String? invitationToken,
  }) async {
    final session = await _repo.register(
      firstName: firstName,
      lastName: lastName,
      email: email,
      password: password,
      phone: phone,
      invitationToken: invitationToken,
    );
    await ref
        .read(tokenStorageProvider)
        .save(access: session.accessToken, refresh: session.refreshToken);
    // Tras registro con invitación las membresías llegan en /users/me.
    final user =
        invitationToken != null ? await _repo.me() : session.user;
    state = Authenticated(user);
  }

  Future<void> recoverPassword(String email) => _repo.requestPasswordRecovery(email);

  /// Refresca el perfil (ej. tras crear un paciente o aceptar invitación).
  Future<void> refreshProfile() async {
    if (state is! Authenticated) return;
    state = Authenticated(await _repo.me());
  }

  Future<void> logout() async {
    final tokens = ref.read(tokenStorageProvider);
    final refresh = await tokens.refreshToken;
    if (refresh != null) {
      try {
        await _repo.logout(refresh);
      } catch (_) {/* best effort */}
    }
    await tokens.clear();
    state = const Unauthenticated();
  }

  void onSessionExpired() => state = const Unauthenticated();
}

final authControllerProvider =
    NotifierProvider<AuthController, AuthState>(AuthController.new);

/// Usuario actual (null si no hay sesión).
final currentUserProvider = Provider<User?>((ref) {
  final state = ref.watch(authControllerProvider);
  return state is Authenticated ? state.user : null;
});
