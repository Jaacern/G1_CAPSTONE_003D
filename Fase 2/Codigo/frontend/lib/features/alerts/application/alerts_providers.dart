import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/alerts_repository.dart';
import '../domain/models.dart';

/// Lo que necesita la pantalla para pintar el centro de alertas.
class AlertsState {
  const AlertsState({
    required this.items,
    required this.total,
    required this.unreadCount,
    required this.hasMore,
    this.cargandoMas = false,
  });

  final List<Alert> items;

  /// Alertas que coinciden con el filtro, en todas las páginas.
  final int total;

  /// Alertas activas: las cuenta el backend, no las de esta página.
  final int unreadCount;

  final bool hasMore;
  final bool cargandoMas;

  AlertsState copyWith({bool? cargandoMas}) => AlertsState(
        items: items,
        total: total,
        unreadCount: unreadCount,
        hasMore: hasMore,
        cargandoMas: cargandoMas ?? this.cargandoMas,
      );
}

/// Centro de alertas paginado.
///
/// El endpoint 9.1 devuelve 20 alertas por página junto con el total. Antes la
/// app tomaba solo los ítems de la primera página y filtraba las activas en el
/// cliente: con más de 20 alertas entre todos los pacientes, el centro podía
/// quedarse vacío teniendo avisos sin atender, y no había forma de ver el resto.
class AlertsController extends AsyncNotifier<AlertsState> {
  static const pageSize = 20;

  @override
  Future<AlertsState> build() => _cargarPrimeraPagina();

  Future<AlertsState> _cargarPrimeraPagina() async {
    final pagina = await ref
        .watch(alertsRepositoryProvider)
        .listAlerts(activeOnly: true, page: 1, pageSize: pageSize);
    return _desde(pagina, pagina.items);
  }

  AlertsState _desde(AlertsPage pagina, List<Alert> items) => AlertsState(
        items: items,
        total: pagina.total,
        unreadCount: pagina.unreadCount,
        hasMore: items.length < pagina.total,
      );

  /// Añade la página siguiente a lo que ya está en pantalla.
  Future<void> cargarMas() async {
    final actual = state.value;
    if (actual == null || !actual.hasMore || actual.cargandoMas) return;

    state = AsyncData(actual.copyWith(cargandoMas: true));
    final pagina = await ref.read(alertsRepositoryProvider).listAlerts(
          activeOnly: true,
          page: actual.items.length ~/ pageSize + 1,
          pageSize: pageSize,
        );
    state = AsyncData(_desde(pagina, [...actual.items, ...pagina.items]));
  }

  Future<void> recargar() async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(_cargarPrimeraPagina);
  }
}

final alertsControllerProvider =
    AsyncNotifierProvider<AlertsController, AlertsState>(AlertsController.new);

/// Número de alertas activas (para el badge del tab/inicio).
///
/// Se lee el `unread_count` del backend: contar solo lo ya cargado en pantalla
/// topea en 20 y baja si se atendió alguna de esa página.
final alertsCountProvider = Provider.autoDispose<int>((ref) {
  return ref.watch(alertsControllerProvider).value?.unreadCount ?? 0;
});

/// Refresca el centro de alertas tras una acción (acknowledge/resolve/SOS).
void refreshAlerts(Ref ref) =>
    ref.read(alertsControllerProvider.notifier).recargar();

/// Variante para usar desde widgets con [WidgetRef].
void refreshAlertsFromWidget(WidgetRef ref) =>
    ref.read(alertsControllerProvider.notifier).recargar();

/// Alerta por su id. El backend no tiene GET /alerts/{id}, así que primero se
/// busca en lo que la pantalla ya cargó y, si no está, se recorren las páginas
/// (por ejemplo al abrir un aviso desde una notificación).
final alertByIdProvider =
    FutureProvider.autoDispose.family<Alert?, String>((ref, alertId) async {
  for (final a in ref.read(alertsControllerProvider).value?.items ?? const []) {
    if (a.id == alertId) return a;
  }
  final repo = ref.read(alertsRepositoryProvider);
  for (var page = 1; page <= 10; page++) {
    final pagina = await repo.listAlerts(page: page, pageSize: 100);
    for (final a in pagina.items) {
      if (a.id == alertId) return a;
    }
    if (!pagina.hasMore) break;
  }
  return null;
});

/// Hora relativa en español ("hace 5 min", "hace 2 h", "hace 3 días").
String alertTimeAgo(DateTime when) {
  final d = DateTime.now().difference(when.toLocal());
  if (d.inSeconds < 60) return 'hace instantes';
  if (d.inMinutes < 60) return 'hace ${d.inMinutes} min';
  if (d.inHours < 24) return 'hace ${d.inHours} h';
  if (d.inDays == 1) return 'ayer';
  return 'hace ${d.inDays} días';
}
