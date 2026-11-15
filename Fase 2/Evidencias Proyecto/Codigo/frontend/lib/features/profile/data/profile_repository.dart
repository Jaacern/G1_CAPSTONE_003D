import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/app_config.dart';
import '../../../core/network/api_client.dart';
import '../domain/models.dart';

abstract class ProfileRepository {
  /// Actualiza el perfil. El backend (3.8) acepta el nombre en cuatro partes,
  /// teléfono, avatar e idioma (full_name es generado y no editable).
  Future<void> updateProfile({
    String? firstName,
    String? secondName,
    String? lastName,
    String? secondLastName,
    String? phone,
    String? avatarUrl,
    String? locale,
  });
  Future<NotificationSettings> getNotificationSettings();
  Future<NotificationSettings> updateNotificationSettings(
      NotificationSettings settings);

  /// Registra el dispositivo para push (3.9). platform ∈ {ios, android, web}.
  /// Devuelve el id que el backend le dio al aparato, que es el que hay que
  /// mandar al cerrar sesión para que deje de recibir avisos (RF-04).
  Future<String?> registerDevice(String pushToken, String platform,
      {String? appVersion});

  /// Le confirma al backend que un aviso llegó al teléfono (`delivered`) o
  /// que la persona lo abrió (`opened`). El id viene dentro de la propia
  /// notificación. Con esto el backend mide cuánto tardó en llegar (RNF-05).
  Future<void> ackDelivery(String deliveryId, {required bool opened});
}

// ---------------------------------------------------------------------------
// HTTP
// ---------------------------------------------------------------------------
class ProfileRepositoryHttp implements ProfileRepository {
  ProfileRepositoryHttp(this._api);
  final ApiClient _api;

  @override
  Future<void> updateProfile({
    String? firstName,
    String? secondName,
    String? lastName,
    String? secondLastName,
    String? phone,
    String? avatarUrl,
    String? locale,
  }) =>
      _api.patch<void>('/users/me', data: {
        if (firstName != null) 'first_name': firstName,
        // "" quita el segundo nombre o apellido; null no lo toca.
        if (secondName != null) 'second_name': secondName,
        if (lastName != null) 'last_name': lastName,
        if (secondLastName != null) 'second_last_name': secondLastName,
        if (phone != null) 'phone': phone,
        if (avatarUrl != null) 'avatar_url': avatarUrl,
        if (locale != null) 'locale': locale,
      });

  @override
  Future<NotificationSettings> getNotificationSettings() async {
    final data = await _api
        .get<Map<String, dynamic>>('/users/me/notification-settings');
    return NotificationSettings.fromJson(data);
  }

  @override
  Future<NotificationSettings> updateNotificationSettings(
      NotificationSettings settings) async {
    // El PUT devuelve el conjunto completo actualizado.
    final data = await _api.put<Map<String, dynamic>>(
        '/users/me/notification-settings',
        data: settings.toJson());
    return NotificationSettings.fromJson(data);
  }

  @override
  Future<String?> registerDevice(String pushToken, String platform,
      {String? appVersion}) async {
    final data =
        await _api.post<Map<String, dynamic>>('/users/me/devices', data: {
      'push_token': pushToken,
      'platform': platform,
      if (appVersion != null) 'app_version': appVersion,
    });
    return data['device_id'] as String?;
  }

  @override
  Future<void> ackDelivery(String deliveryId, {required bool opened}) =>
      _api.post<void>('/users/me/deliveries/$deliveryId/ack',
          data: {'event': opened ? 'opened' : 'delivered'});
}

// ---------------------------------------------------------------------------
// Mock
// ---------------------------------------------------------------------------
class ProfileRepositoryMock implements ProfileRepository {
  NotificationSettings _settings = NotificationSettings(
    items: [
      for (final t in AlertType.values)
        NotificationSetting(
          alertType: t,
          pushEnabled: true,
          // Caída y SOS quedan bloqueadas, igual que en el backend.
          isLocked: t == AlertType.fall || t == AlertType.sos,
        ),
    ],
  );

  @override
  Future<void> updateProfile({
    String? firstName,
    String? secondName,
    String? lastName,
    String? secondLastName,
    String? phone,
    String? avatarUrl,
    String? locale,
  }) async {
    await Future.delayed(const Duration(milliseconds: 350));
  }

  @override
  Future<NotificationSettings> getNotificationSettings() async {
    await Future.delayed(const Duration(milliseconds: 250));
    return _settings;
  }

  @override
  Future<NotificationSettings> updateNotificationSettings(
      NotificationSettings settings) async {
    await Future.delayed(const Duration(milliseconds: 250));
    _settings = settings;
    return _settings;
  }

  @override
  Future<String?> registerDevice(String pushToken, String platform,
      {String? appVersion}) async {
    await Future.delayed(const Duration(milliseconds: 200));
    return 'mock-device';
  }

  @override
  Future<void> ackDelivery(String deliveryId, {required bool opened}) async {}
}

final profileRepositoryProvider = Provider<ProfileRepository>((ref) {
  if (AppConfig.useMocks) return ProfileRepositoryMock();
  return ProfileRepositoryHttp(ref.watch(apiClientProvider));
});
