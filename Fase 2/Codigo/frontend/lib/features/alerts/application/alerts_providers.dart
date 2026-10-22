import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/alerts_repository.dart';
import '../domain/models.dart';

/// Todas las alertas del usuario (activas y ya atendidas).
/// autoDispose: se recarga al volver a entrar al centro de alertas.
final activeAlertsProvider = FutureProvider.autoDispose<List<Alert>>((ref) {
  return ref.watch(alertsRepositoryProvider).listAlerts();
});

/// Número de alertas actualmente activas (para el badge del tab/inicio).
final alertsCountProvider = Provider.autoDispose<int>((ref) {
  final alerts = ref.watch(activeAlertsProvider);
  return alerts.maybeWhen(
    data: (list) => list.where((a) => a.isActive).length,
    orElse: () => 0,
  );
});

/// Refresca las listas de alertas tras una acción (acknowledge/resolve/SOS).
void refreshAlerts(Ref ref) => ref.invalidate(activeAlertsProvider);

/// Variante para usar desde widgets con [WidgetRef].
void refreshAlertsFromWidget(WidgetRef ref) => ref.invalidate(activeAlertsProvider);

/// Hora relativa en español ("hace 5 min", "hace 2 h", "hace 3 días").
String alertTimeAgo(DateTime when) {
  final d = DateTime.now().difference(when.toLocal());
  if (d.inSeconds < 60) return 'hace instantes';
  if (d.inMinutes < 60) return 'hace ${d.inMinutes} min';
  if (d.inHours < 24) return 'hace ${d.inHours} h';
  if (d.inDays == 1) return 'ayer';
  return 'hace ${d.inDays} días';
}
