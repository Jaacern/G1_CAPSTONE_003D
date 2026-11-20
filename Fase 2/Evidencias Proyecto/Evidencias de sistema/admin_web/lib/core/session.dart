import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'api_client.dart';
import 'api_error.dart';

enum SessionStatus { checking, signedOut, signedIn }

class SessionState {
  const SessionState(this.status, {this.userName, this.notice});

  final SessionStatus status;
  final String? userName;

  /// Aviso para la pantalla de ingreso (p. ej. "tu sesión expiró").
  final String? notice;
}

final tokenStoreProvider = Provider<TokenStore>((ref) => TokenStore());

final apiClientProvider = Provider<ApiClient>((ref) {
  final client = ApiClient(ref.watch(tokenStoreProvider));
  client.onSessionExpired =
      () => ref.read(sessionProvider.notifier).expire();
  return client;
});

final sessionProvider =
    NotifierProvider<SessionController, SessionState>(SessionController.new);

class SessionController extends Notifier<SessionState> {
  @override
  SessionState build() {
    Future.microtask(_restaurar);
    return const SessionState(SessionStatus.checking);
  }

  ApiClient get _api => ref.read(apiClientProvider);
  TokenStore get _tokens => ref.read(tokenStoreProvider);

  /// Al abrir el panel: si hay sesión guardada y sigue valiendo, se entra.
  Future<void> _restaurar() async {
    if (await _tokens.refresh == null) {
      state = const SessionState(SessionStatus.signedOut);
      return;
    }
    try {
      final me = await _api.get('/api/v1/users/me') as Map;
      await _api.get('/api/v1/admin/audit', query: {'limit': 1});
      state = SessionState(
        SessionStatus.signedIn,
        userName: me['full_name']?.toString(),
      );
    } on ApiException catch (e) {
      if (e.isNetwork) {
        // No se pudo comprobar: se deja pasar al ingreso sin borrar tokens.
        state = SessionState(SessionStatus.signedOut, notice: e.message);
      } else {
        await _tokens.clear();
        state = SessionState(
          SessionStatus.signedOut,
          notice: e.code == 'STAFF_ONLY' ? e.message : null,
        );
      }
    }
  }

  /// Lanza [ApiException] si falla, para que el formulario lo muestre.
  Future<void> login(String email, String password) async {
    final data = await _api.post(
      '/api/v1/auth/login',
      body: {'email': email.trim(), 'password': password},
      auth: false,
    ) as Map;
    await _tokens.save(
      data['access_token'] as String,
      data['refresh_token'] as String,
    );
    try {
      // La cuenta puede existir pero no ser del personal: se comprueba aquí
      // y no al primer clic dentro del panel.
      await _api.get('/api/v1/admin/audit', query: {'limit': 1});
    } on ApiException {
      await _tokens.clear();
      rethrow;
    }
    state = SessionState(
      SessionStatus.signedIn,
      userName: (data['user'] as Map)['full_name']?.toString(),
    );
  }

  Future<void> logout() async {
    final refresh = await _tokens.refresh;
    if (refresh != null) {
      try {
        await _api.post('/api/v1/auth/logout', body: {'refresh_token': refresh});
      } on ApiException {
        // Cerrar sesión localmente igual: el servidor ya no es requisito.
      }
    }
    await _tokens.clear();
    state = const SessionState(SessionStatus.signedOut);
  }

  /// La API ya no acepta la sesión y no se pudo renovar.
  void expire() {
    if (state.status == SessionStatus.signedOut) return;
    _tokens.clear();
    state = const SessionState(
      SessionStatus.signedOut,
      notice: 'Tu sesión expiró. Vuelve a iniciar sesión.',
    );
  }
}
