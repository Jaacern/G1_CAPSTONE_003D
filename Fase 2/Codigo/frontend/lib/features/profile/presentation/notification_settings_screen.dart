import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/notifications/push_service.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/common.dart';
import '../application/profile_providers.dart';
import '../data/profile_repository.dart';
import '../domain/models.dart';

/// Preferencias de notificaciones: un switch por tipo de alerta del backend,
/// con guardado inmediato (PUT). Las alertas críticas (caída y SOS) están
/// bloqueadas y no pueden desactivarse (RF-50).
class NotificationSettingsScreen extends ConsumerStatefulWidget {
  const NotificationSettingsScreen({super.key});

  @override
  ConsumerState<NotificationSettingsScreen> createState() =>
      _NotificationSettingsScreenState();
}

class _NotificationSettingsScreenState
    extends ConsumerState<NotificationSettingsScreen> {
  NotificationSettings? _settings;
  bool _saving = false;

  Future<void> _toggle(AlertType type, bool enabled) async {
    final previous = _settings;
    final next = (previous ?? const NotificationSettings())
        .copyWithToggled(type, enabled);
    setState(() {
      _settings = next;
      _saving = true;
    });
    try {
      final saved = await ref
          .read(profileRepositoryProvider)
          .updateNotificationSettings(next);
      if (mounted) setState(() => _settings = saved);
    } catch (e) {
      setState(() => _settings = previous);
      if (mounted) showAppSnackBar(context, e.toString(), error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(notificationSettingsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Alertas y notificaciones')),
      body: async.when(
        loading: () => const LoadingView(),
        error: (e, _) => ErrorView(
          message: e.toString(),
          onRetry: () => ref.invalidate(notificationSettingsProvider),
        ),
        data: (loaded) {
          final s = _settings ??= loaded;
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(4, 4, 4, 10),
                child: Text(
                  'Elige por qué tipo de evento quieres recibir notificaciones push.',
                  style: TextStyle(color: AppColors.textSecondary),
                ),
              ),
              AppCard(
                padding: EdgeInsets.zero,
                child: Column(
                  children: [
                    for (var i = 0; i < s.items.length; i++) ...[
                      if (i != 0) const Divider(height: 1),
                      _AlertSwitchTile(
                        setting: s.items[i],
                        saving: _saving,
                        onChanged: (v) => _toggle(s.items[i].alertType, v),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 20),
              const _PushTokenCard(),
            ],
          );
        },
      ),
    );
  }
}

class _AlertSwitchTile extends StatelessWidget {
  const _AlertSwitchTile({
    required this.setting,
    required this.saving,
    required this.onChanged,
  });

  final NotificationSetting setting;
  final bool saving;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final subtitle = setting.isLocked
        ? '${setting.alertType.description} · No se puede desactivar.'
        : setting.alertType.description;
    return SwitchListTile(
      title: Row(
        children: [
          Flexible(
            child: Text(setting.alertType.label,
                style: const TextStyle(fontWeight: FontWeight.w600)),
          ),
          if (setting.isLocked) ...[
            const SizedBox(width: 6),
            const Icon(Icons.lock_rounded,
                size: 14, color: AppColors.textSecondary),
          ],
        ],
      ),
      subtitle: Text(subtitle,
          style:
              const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
      value: setting.pushEnabled,
      activeColor: AppColors.primary,
      // Bloqueadas o guardando → deshabilitadas.
      onChanged: (setting.isLocked || saving) ? null : onChanged,
    );
  }
}

class _PushTokenCard extends StatelessWidget {
  const _PushTokenCard();

  @override
  Widget build(BuildContext context) {
    final token = PushService.instance.fcmToken;
    final platform = kIsWeb
        ? 'Este navegador'
        : defaultTargetPlatform == TargetPlatform.iOS
            ? 'iOS'
            : defaultTargetPlatform == TargetPlatform.android
                ? 'Android'
                : 'Este dispositivo';
    final registered = token != null && token.isNotEmpty;
    return AppCard(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            registered ? Icons.cloud_done_rounded : Icons.cloud_off_rounded,
            color: registered ? AppColors.statusOk : AppColors.textSecondary,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Notificaciones push ($platform)',
                    style: const TextStyle(fontWeight: FontWeight.w700)),
                const SizedBox(height: 4),
                Text(
                  registered
                      ? 'Dispositivo registrado para recibir push.'
                      : 'Sin token de push. Las notificaciones remotas '
                          'podrían no llegar en este dispositivo.',
                  style: const TextStyle(
                      fontSize: 12, color: AppColors.textSecondary),
                ),
                if (registered) ...[
                  const SizedBox(height: 6),
                  Text(
                    'Token: ${token.substring(0, token.length.clamp(0, 18))}…',
                    style: const TextStyle(
                        fontSize: 11,
                        color: AppColors.textSecondary,
                        fontFamily: 'monospace'),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
