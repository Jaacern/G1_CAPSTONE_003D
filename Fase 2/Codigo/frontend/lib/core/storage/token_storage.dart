// Selección de implementación por plataforma:
//  - móvil/escritorio -> token_storage_native.dart (flutter_secure_storage)
//  - web              -> token_storage_web.dart (localStorage)
import 'token_storage_native.dart'
    if (dart.library.js_interop) 'token_storage_web.dart';

/// Persistencia de tokens de sesión.
///
/// Delega en la implementación adecuada según la plataforma: en móvil usa
/// almacenamiento seguro (Keychain/Keystore vía flutter_secure_storage); en
/// web usa localStorage, porque flutter_secure_storage falla en Safari iOS y
/// deja el login sin avanzar.
///
/// Se mantiene como clase concreta instanciable con `TokenStorage()` para no
/// cambiar los usos existentes.
class TokenStorage {
  TokenStorage() : _impl = createTokenStorage();

  final TokenStorageBackend _impl;

  Future<String?> get accessToken => _impl.accessToken;
  Future<String?> get refreshToken => _impl.refreshToken;
  Future<void> save({required String access, required String refresh}) =>
      _impl.save(access: access, refresh: refresh);
  Future<bool> get hasSession => _impl.hasSession;
  Future<void> clear() => _impl.clear();
}

/// Contrato que implementan las variantes por plataforma.
abstract class TokenStorageBackend {
  Future<String?> get accessToken;
  Future<String?> get refreshToken;
  Future<void> save({required String access, required String refresh});
  Future<bool> get hasSession;
  Future<void> clear();
}
