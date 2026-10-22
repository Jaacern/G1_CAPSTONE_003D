import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'token_storage.dart';

/// Implementación nativa (iOS/Android): almacenamiento seguro en
/// Keychain / Keystore mediante flutter_secure_storage.
class TokenStorageImpl implements TokenStorageBackend {
  static const _kAccess = 'agecare_access_token';
  static const _kRefresh = 'agecare_refresh_token';

  final _storage = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  @override
  Future<String?> get accessToken => _storage.read(key: _kAccess);

  @override
  Future<String?> get refreshToken => _storage.read(key: _kRefresh);

  @override
  Future<void> save({required String access, required String refresh}) async {
    await _storage.write(key: _kAccess, value: access);
    await _storage.write(key: _kRefresh, value: refresh);
  }

  @override
  Future<bool> get hasSession async => (await refreshToken) != null;

  @override
  Future<void> clear() async {
    await _storage.delete(key: _kAccess);
    await _storage.delete(key: _kRefresh);
  }
}

TokenStorageBackend createTokenStorage() => TokenStorageImpl();
