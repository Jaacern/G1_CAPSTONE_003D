import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'core/session.dart';
import 'features/auth/login_page.dart';
import 'features/dashboard/dashboard_page.dart';
import 'features/doctors/doctors_page.dart';
import 'features/plans/catalog_page.dart';
import 'features/plans/plan_detail_page.dart';
import 'features/plans/plans_page.dart';
import 'features/users/activity_page.dart';
import 'features/users/user_detail_page.dart';
import 'features/users/users_page.dart';
import 'shared/app_shell.dart';

/// Avisa a go_router cuando cambia la sesión para que reevalúe `redirect`.
class _SessionRefresh extends ChangeNotifier {
  void ping() => notifyListeners();
}

final routerProvider = Provider<GoRouter>((ref) {
  final refresh = _SessionRefresh();
  ref.listen(sessionProvider, (_, _) => refresh.ping());
  ref.onDispose(refresh.dispose);

  return GoRouter(
    refreshListenable: refresh,
    redirect: (context, state) {
      final status = ref.read(sessionProvider).status;
      final loc = state.matchedLocation;
      switch (status) {
        case SessionStatus.checking:
          return loc == '/cargando' ? null : '/cargando';
        case SessionStatus.signedOut:
          return loc == '/login' ? null : '/login';
        case SessionStatus.signedIn:
          return (loc == '/login' || loc == '/cargando') ? '/' : null;
      }
    },
    routes: [
      GoRoute(
        path: '/cargando',
        builder: (_, _) =>
            const Scaffold(body: Center(child: CircularProgressIndicator())),
      ),
      GoRoute(path: '/login', builder: (_, _) => const LoginPage()),
      ShellRoute(
        builder: (context, state, child) =>
            AppShell(location: state.matchedLocation, child: child),
        routes: [
          GoRoute(path: '/', builder: (_, _) => const DashboardPage()),
          GoRoute(path: '/usuarios', builder: (_, _) => const UsersPage()),
          GoRoute(
            path: '/usuarios/:id',
            builder: (_, s) => UserDetailPage(userId: s.pathParameters['id']!),
          ),
          GoRoute(path: '/planes', builder: (_, _) => const PlansPage()),
          GoRoute(
            path: '/planes/:id',
            builder: (_, s) => PlanDetailPage(planId: s.pathParameters['id']!),
          ),
          GoRoute(path: '/catalogo', builder: (_, _) => const CatalogPage()),
          GoRoute(path: '/medicos', builder: (_, _) => const DoctorsPage()),
          GoRoute(path: '/actividad', builder: (_, _) => const ActivityPage()),
        ],
      ),
    ],
    errorBuilder: (context, state) => Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Esta página no existe.'),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: () => context.go('/'),
              child: const Text('Ir al resumen'),
            ),
          ],
        ),
      ),
    ),
  );
});
