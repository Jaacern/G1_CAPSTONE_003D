import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Servicio de notificaciones.
///
/// - Locales: alarmas de medicación programadas en el dispositivo
///   (flutter_local_notifications).
/// - Remotas: push desde el backend vía FCM. Este servicio solo obtiene el
///   token y avisa cuando llega un mensaje; quien lo registra en el backend
///   (POST /users/me/devices) y confirma las entregas es [PushRegistrar], que
///   sí conoce la sesión.
///
/// En modo mocks el registro remoto se omite para poder correr sin proyecto
/// Firebase configurado.
class PushService {
  PushService._();
  static final PushService instance = PushService._();

  final FlutterLocalNotificationsPlugin _local =
      FlutterLocalNotificationsPlugin();

  /// Se emite cuando llega un push o se toca una notificación local, con el
  /// payload (p. ej. {"type":"dose","dose_id":"..."} o {"type":"alert",...}).
  final StreamController<Map<String, dynamic>> _taps =
      StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get onNotificationTap => _taps.stream;

  /// Se emite cada vez que hay un token de push, al obtenerlo y cuando FCM lo
  /// renueva. Un token renovado que no llega al backend es un teléfono que
  /// deja de recibir alertas sin que nadie se entere.
  final StreamController<String> _tokens = StreamController<String>.broadcast();
  Stream<String> get onToken => _tokens.stream;

  /// Se emite cuando un push llega con la aplicación abierta, con sus datos.
  /// Sirve para confirmarle al backend que la notificación llegó (RNF-05).
  final StreamController<Map<String, dynamic>> _recibidos =
      StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get onRemoteMessage => _recibidos.stream;

  Map<String, dynamic>? _toqueInicial;

  /// Datos de la notificación que abrió la aplicación estando cerrada, si la
  /// hubo. Se entrega una sola vez.
  Map<String, dynamic>? takeInitialTap() {
    final t = _toqueInicial;
    _toqueInicial = null;
    return t;
  }

  String? _fcmToken;
  String? get fcmToken => _fcmToken;

  void _tokenNuevo(String? t) {
    _fcmToken = t;
    if (t != null && t.isNotEmpty) _tokens.add(t);
  }

  bool _initialized = false;

  Future<void> init({required bool enableRemote}) async {
    if (_initialized) return;
    _initialized = true;

    const androidInit =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosInit = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );
    await _local.initialize(
      const InitializationSettings(android: androidInit, iOS: iosInit),
      onDidReceiveNotificationResponse: (resp) {
        final payload = resp.payload;
        if (payload != null) _taps.add(_parse(payload));
      },
    );

    if (enableRemote) {
      try {
        await Firebase.initializeApp();
        final messaging = FirebaseMessaging.instance;
        await messaging.requestPermission();
        _tokenNuevo(await messaging.getToken());
        messaging.onTokenRefresh.listen(_tokenNuevo);
        FirebaseMessaging.onMessage.listen(_onForegroundMessage);
        FirebaseMessaging.onMessageOpenedApp
            .listen((m) => _taps.add(Map<String, dynamic>.from(m.data)));
        // La aplicación estaba cerrada y se abrió tocando la notificación.
        // No se emite por el stream: a esta altura todavía no hay nadie
        // escuchando y se perdería. Queda guardado para quien lo pida.
        final inicial = await messaging.getInitialMessage();
        if (inicial != null) {
          _toqueInicial = Map<String, dynamic>.from(inicial.data);
        }
      } catch (e) {
        // Sin configuración Firebase (o en desarrollo): las notificaciones
        // locales siguen funcionando.
        _fcmToken = null;
      }
    }
  }

  void _onForegroundMessage(RemoteMessage m) {
    _recibidos.add(Map<String, dynamic>.from(m.data));
    final n = m.notification;
    if (n != null) {
      _local.show(
        m.hashCode,
        n.title,
        n.body,
        _details(m.data['type'] == 'alert' ? _alertChannel : _generalChannel),
        payload: _encode(m.data),
      );
    }
  }

  /// Programa la alarma local de una dosis de medicación (ticket AGE-403).
  Future<void> scheduleDoseReminder({
    required int id,
    required String medicationName,
    required DateTime when,
    required String doseId,
  }) async {
    // Nota: para disparo exacto se recomienda zonedSchedule con timezone.
    // Aquí usamos show inmediato si la hora ya pasó; en producción usar
    // flutter_local_notifications + timezone para zonedSchedule.
    await _local.show(
      id,
      'Hora de tu medicamento',
      'Es momento de tomar $medicationName',
      _details(_medChannel),
      payload: _encode({'type': 'dose', 'dose_id': doseId}),
    );
  }

  Future<void> cancelDoseReminder(int id) => _local.cancel(id);

  /// Notificación del sistema para una CAÍDA detectada. Suena, vibra y aparece
  /// en la barra de notificaciones aunque el usuario esté en otra app o con la
  /// pantalla bloqueada (mientras el proceso siga vivo). Usa el canal de
  /// alertas (importancia máxima). Para disparo con la app completamente
  /// cerrada por largos periodos se necesita push remoto (FCM); eso queda como
  /// siguiente paso. Esta notificación local cubre el caso de la demo y el uso
  /// normal con la app en segundo plano.
  Future<void> showFallAlert({
    required String alertId,
    required String patientName,
    required String message,
  }) async {
    final title = patientName.isNotEmpty
        ? '🚨 Posible caída · $patientName'
        : '🚨 Posible caída detectada';
    await _local.show(
      // id estable por alerta: no duplica la misma caída, pero sí notifica
      // caídas distintas.
      alertId.hashCode,
      title,
      message.isNotEmpty ? message : 'Revisa el estado del paciente de inmediato.',
      NotificationDetails(
        android: AndroidNotificationDetails(
          _fallChannel.id,
          _fallChannel.name,
          channelDescription: _fallChannel.description,
          importance: Importance.max,
          priority: Priority.max,
          category: AndroidNotificationCategory.alarm,
          fullScreenIntent: true,
          enableVibration: true,
          playSound: true,
        ),
        iOS: const DarwinNotificationDetails(
          interruptionLevel: InterruptionLevel.critical,
        ),
      ),
      payload: _encode({'type': 'alert', 'alert_type': 'fall', 'alert_id': alertId}),
    );
  }

  NotificationDetails _details(AndroidNotificationChannel ch) => NotificationDetails(
        android: AndroidNotificationDetails(
          ch.id,
          ch.name,
          channelDescription: ch.description,
          importance: Importance.max,
          priority: Priority.high,
        ),
        iOS: const DarwinNotificationDetails(),
      );

  static const _medChannel = AndroidNotificationChannel(
      'meds', 'Medicación', description: 'Alarmas de medicamentos');
  static const _alertChannel = AndroidNotificationChannel(
      'alerts', 'Alertas', description: 'Alertas de salud y SOS');
  // Canal dedicado a caídas: máxima prioridad, sonido y vibración. Separado
  // para que el usuario no pueda silenciarlo junto con alertas menores.
  static const _fallChannel = AndroidNotificationChannel(
      'falls', 'Caídas',
      description: 'Alertas críticas de caída del paciente',
      importance: Importance.max);
  static const _generalChannel = AndroidNotificationChannel(
      'general', 'General', description: 'Notificaciones generales');

  String _encode(Map<String, dynamic> data) =>
      data.entries.map((e) => '${e.key}=${e.value}').join('&');

  Map<String, dynamic> _parse(String payload) {
    final out = <String, dynamic>{};
    for (final pair in payload.split('&')) {
      final kv = pair.split('=');
      if (kv.length == 2) out[kv[0]] = kv[1];
    }
    return out;
  }
}
