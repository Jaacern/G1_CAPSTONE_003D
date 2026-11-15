import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/profile_repository.dart';
import '../domain/models.dart';

/// Preferencias de notificaciones del usuario actual.
final notificationSettingsProvider =
    FutureProvider.autoDispose<NotificationSettings>(
  (ref) => ref.watch(profileRepositoryProvider).getNotificationSettings(),
);
