import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/auth/application/auth_controller.dart';
import '../../features/profile/data/profile_repository.dart';
import '../config/app_config.dart';
import 'push_device_id.dart';
import 'push_service.dart';

/// Une el push del teléfono con la sesión del usuario.
///
/// [PushService] consigue el token y recibe los mensajes, pero no sabe quién
/// inició sesión. El backend guarda a qué usuario pertenece cada token. Esta
/// clase es el puente, y sin ella el token nunca salía del teléfono: la
/// aplicación lo obtenía, lo mostraba en la pantalla de notificaciones y
/// nadie se lo mandaba al servidor, así que ninguna alerta podía llegar.
///
/// Hace tres cosas:
///
/// 1. Registra el token cuando hay sesión, y lo vuelve a registrar si FCM lo
///    renueva o si entra otra persona en el mismo teléfono.
/// 2. Guarda el id que el backend le dio al aparato, para mandarlo al cerrar
///    sesión y que este teléfono deje de recibir los avisos de quien salió
///    (RF-04).
/// 3. Le confirma al backend cuando una notificación llega y cuando la
///    abren, que es lo que permite medir si llegó a tiempo (RNF-05).
///
/// Nada de esto puede romper la aplicación. Un fallo al registrar el token o
/// al confirmar una entrega se traga y se reintenta en la próxima ocasión:
/// que el push no funcione no es razón para que alguien no pueda entrar.
class PushRegistrar {
  PushRegistrar({
    required ProfileRepository repo,
    required String platform,
    required Stream<String> tokens,
    required String? Function() currentToken,
    required Stream<Map<String, dynamic>> received,
    required Stream<Map<String, dynamic>> taps,
    void Function(String? deviceId)? onDeviceId,
  })  : _repo = repo,
        _platform = platform,
        _currentToken = currentToken,
        _onDeviceId = onDeviceId {
    _subs = [
      tokens.listen((_) => _sincronizar()),
      received.listen((d) => _confirmar(d, opened: false)),
      taps.listen((d) => _confirmar(d, opened: true)),
    ];
  }

  final ProfileRepository _repo;
  final String _platform;
  final String? Function() _currentToken;
  final void Function(String? deviceId)? _onDeviceId;
  late final List<StreamSubscription<dynamic>> _subs;

  String? _usuario;
  String? _registrado; // "usuario|token" de lo último que aceptó el backend
  String? _deviceId;
  bool _ocupado = false;
  bool _pendiente = false;

  /// Id del aparato en el backend, o null si todavía no se registró.
  String? get deviceId => _deviceId;

  /// Hay sesión de [userId]: registra el token si ya se tiene.
  Future<void> onSignedIn(String userId) {
    _usuario = userId;
    return _sincronizar();
  }

  /// Se cerró la sesión. El backend ya apagó el aparato con el id que se le
  /// mandó en el logout; aquí solo se olvida, para que la próxima persona
  /// que entre registre el suyo.
  void onSignedOut() {
    _usuario = null;
    _registrado = null;
    _deviceId = null;
    _onDeviceId?.call(null);
  }

  Future<void> _sincronizar() async {
    // Si llega un token nuevo mientras se está registrando el anterior, se
    // anota y se repite al terminar, en vez de cruzar dos llamadas.
    if (_ocupado) {
      _pendiente = true;
      return;
    }
    _ocupado = true;
    try {
      do {
        _pendiente = false;
        final usuario = _usuario;
        final token = _currentToken();
        if (usuario == null || token == null || token.isEmpty) continue;
        final clave = '$usuario|$token';
        if (clave == _registrado) continue;
        try {
          final id = await _repo.registerDevice(token, _platform);
          // Pudo cerrarse la sesión mientras respondía el servidor.
          if (_usuario != usuario) continue;
          _deviceId = id;
          _registrado = clave;
          _onDeviceId?.call(id);
        } catch (_) {
          // Sin red o servidor caído: queda sin registrar y se reintenta la
          // próxima vez que haya sesión o token.
        }
      } while (_pendiente);
    } finally {
      _ocupado = false;
    }
  }

  /// Confirma al backend la notificación que abrió la aplicación estando
  /// cerrada. Las demás se confirman solas, por los streams.
  Future<void> confirmOpened(Map<String, dynamic> datos) =>
      _confirmar(datos, opened: true);

  Future<void> _confirmar(Map<String, dynamic> datos,
      {required bool opened}) async {
    final id = datos['delivery_id']?.toString();
    if (id == null || id.isEmpty || _usuario == null) return;
    try {
      await _repo.ackDelivery(id, opened: opened);
    } catch (_) {
      // La confirmación es para medir, no para funcionar: si no sale, la
      // notificación igual llegó.
    }
  }

  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
  }
}

String _plataforma() {
  if (kIsWeb) return 'web';
  return defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android';
}

/// El registrador de la aplicación, conectado a [PushService] y a la sesión.
///
/// Hay que leerlo una vez para que exista (lo hace el widget raíz). Desde ahí
/// sigue los cambios de sesión por su cuenta.
final pushRegistrarProvider = Provider<PushRegistrar?>((ref) {
  // En modo demo no hay backend al que registrar nada.
  if (AppConfig.useMocks) return null;

  final push = PushService.instance;
  final aparato = ref.watch(pushDeviceIdProvider);
  final registrar = PushRegistrar(
    repo: ref.watch(profileRepositoryProvider),
    platform: _plataforma(),
    tokens: push.onToken,
    currentToken: () => push.fcmToken,
    received: push.onRemoteMessage,
    taps: push.onNotificationTap,
    onDeviceId: (id) => aparato.value = id,
  );
  ref.onDispose(registrar.dispose);

  void seguir(AuthState estado) {
    if (estado is Authenticated) {
      registrar.onSignedIn(estado.user.userId).then((_) {
        // Si la aplicación se abrió tocando una notificación, se confirma
        // ahora que ya hay sesión para hacerlo.
        final inicial = push.takeInitialTap();
        if (inicial != null) registrar.confirmOpened(inicial);
      });
    } else if (estado is Unauthenticated) {
      registrar.onSignedOut();
    }
  }

  ref.listen<AuthState>(authControllerProvider, (_, nuevo) => seguir(nuevo),
      fireImmediately: true);
  return registrar;
});
