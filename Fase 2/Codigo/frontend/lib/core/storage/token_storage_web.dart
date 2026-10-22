import 'package:web/web.dart' as web;

import 'token_storage.dart';

/// Implementación web: usa localStorage del navegador.
///
/// flutter_secure_storage en web depende de Web Crypto/IndexedDB y falla en
/// Safari iOS (sobre todo en modo privado), cortando el flujo de login. En
/// web no hay un almacén "seguro" real del lado del cliente, así que usar
/// localStorage es el estándar práctico para una SPA de este tipo.
class TokenStorageImpl implements TokenStorageBackend {
  static const _kAccess = 'agecare_access_token';
  static const _kRefresh = 'agecare_refresh_token';

  @override
  Future<String?> get accessToken async =>
      web.window.localStorage.getItem(_kAccess);

  @override
  Future<String?> get refreshToken async =>
      web.window.localStorage.getItem(_kRefresh);

  @override
  Future<void> save({required String access, required String refresh}) async {
    web.window.localStorage.setItem(_kAccess, access);
    web.window.localStorage.setItem(_kRefresh, refresh);
  }

  @override
  Future<bool> get hasSession async => (await refreshToken) != null;

  @override
  Future<void> clear() async {
    web.window.localStorage.removeItem(_kAccess);
    web.window.localStorage.removeItem(_kRefresh);
  }
}

TokenStorageBackend createTokenStorage() => TokenStorageImpl();
