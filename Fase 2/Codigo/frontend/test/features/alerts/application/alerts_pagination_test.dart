// El backend 9.1 pagina de a 20 alertas. Estas pruebas cubren que el centro de
// alertas alcance la página siguiente y que el contador use el total del
// servidor, no lo que ya se ve en pantalla.
import 'package:agecare_app/core/theme/app_theme.dart';
import 'package:agecare_app/features/alerts/application/alerts_providers.dart';
import 'package:agecare_app/features/alerts/data/alerts_repository.dart';
import 'package:agecare_app/features/alerts/domain/models.dart';
import 'package:agecare_app/features/alerts/presentation/alerts_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

Alert _alerta(int i) => Alert(
      id: 'a-$i',
      patientId: 'p-elena',
      patientName: 'Elena Ramírez',
      type: AlertType.vitalOutOfRange,
      severity: AlertSeverity.warning,
      title: 'Ritmo cardíaco elevado',
      message: 'La FC superó el máximo configurado.',
      createdAt: DateTime.now().subtract(Duration(minutes: i)),
      status: AlertStatus.active,
    );

/// Repo que pagina de verdad, para contar las llamadas que hace la pantalla.
class _RepoFake implements AlertsRepository {
  _RepoFake(this.alertas, {this.activas});

  final List<Alert> alertas;

  /// Cuántas dice el servidor que están activas; por defecto, todas.
  final int? activas;

  int peticiones = 0;

  @override
  Future<AlertsPage> listAlerts(
      {String? patientId,
      bool activeOnly = false,
      int page = 1,
      int pageSize = 20}) async {
    peticiones++;
    final desde = ((page - 1) * pageSize).clamp(0, alertas.length);
    final hasta = (desde + pageSize).clamp(0, alertas.length);
    return AlertsPage(
      items: alertas.sublist(desde, hasta),
      total: alertas.length,
      unreadCount: activas ?? alertas.length,
      page: page,
      pageSize: pageSize,
    );
  }

  @override
  Future<void> acknowledge(String alertId) async {}

  @override
  Future<void> resolve(String alertId, {String? note}) async {}

  @override
  Future<void> sendSos(String patientId,
      {double? lat, double? lng, String? note}) async {}
}

ProviderContainer _contenedor(AlertsRepository repo) =>
    ProviderContainer(overrides: [
      alertsRepositoryProvider.overrideWithValue(repo),
    ]);

void main() {
  final veinticinco = List.generate(25, _alerta);

  test('arranca con la primera página y avisa que faltan alertas', () async {
    final repo = _RepoFake(veinticinco);
    final container = _contenedor(repo);
    addTearDown(container.dispose);

    final state = await container.read(alertsControllerProvider.future);

    expect(state.items.length, 20);
    expect(state.hasMore, isTrue);
    expect(state.total, 25);
    expect(repo.peticiones, 1);
  });

  test('cargar más suma la página siguiente en vez de reemplazarla', () async {
    final repo = _RepoFake(veinticinco);
    final container = _contenedor(repo);
    addTearDown(container.dispose);
    await container.read(alertsControllerProvider.future);

    await container.read(alertsControllerProvider.notifier).cargarMas();

    final state = container.read(alertsControllerProvider).value!;
    expect(state.items.length, 25);
    expect(state.hasMore, isFalse);
    expect(repo.peticiones, 2);
  });

  test('el contador lee las activas del servidor, no de la página cargada',
      () async {
    // 25 alertas en dos páginas, pero el servidor dice que solo 3 siguen
    // activas: el badge no puede decir 20.
    final container = _contenedor(_RepoFake(veinticinco, activas: 3));
    addTearDown(container.dispose);
    await container.read(alertsControllerProvider.future);

    expect(container.read(alertsCountProvider), 3);
  });

  testWidgets('la lista ofrece cargar las alertas que faltan', (tester) async {
    final repo = _RepoFake(veinticinco);
    await tester.pumpWidget(ProviderScope(
      overrides: [alertsRepositoryProvider.overrideWithValue(repo)],
      child: MaterialApp(
          theme: AppTheme.light(), home: const Scaffold(body: AlertsScreen())),
    ));
    await tester.pumpAndSettle();

    // La lista es un ListView: el botón está bajo las 20 tarjetas y hay que
    // desplazar hasta él, igual que haría la cuidadora.
    expect(find.text('(20)'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Cargar 5 alertas más'), 300,
        scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Cargar 5 alertas más'));
    await tester.pumpAndSettle();

    expect(find.text('Cargar 5 alertas más'), findsNothing);
    expect(repo.peticiones, 2);

    await tester.scrollUntilVisible(find.text('(25)'), -300,
        scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    expect(find.text('(25)'), findsOneWidget);
  });
}
