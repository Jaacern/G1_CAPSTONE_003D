import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/session.dart';
import 'widgets.dart';

class _Destino {
  const _Destino(this.path, this.label, this.icon);
  final String path;
  final String label;
  final IconData icon;
}

const _destinos = [
  _Destino('/', 'Resumen', Icons.space_dashboard_outlined),
  _Destino('/usuarios', 'Usuarios', Icons.people_outline),
  _Destino('/planes', 'Planes', Icons.workspace_premium_outlined),
  _Destino('/catalogo', 'Catálogo', Icons.tune),
  _Destino('/medicos', 'Médicos', Icons.medical_services_outlined),
  _Destino('/actividad', 'Actividad', Icons.history),
];

int _indiceDe(String ubicacion) {
  if (ubicacion == '/') return 0;
  final i = _destinos.indexWhere((d) => d.path != '/' && ubicacion.startsWith(d.path));
  return i < 0 ? 0 : i;
}

/// Marco común: menú lateral en pantallas anchas, cajón en las angostas.
class AppShell extends ConsumerWidget {
  const AppShell({super.key, required this.location, required this.child});

  final String location;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider);
    final indice = _indiceDe(location);
    final ancho = MediaQuery.sizeOf(context).width >= 900;

    Future<void> salir() async {
      final ok = await confirm(
        context,
        title: 'Cerrar sesión',
        message: '¿Salir del panel?',
        confirmLabel: 'Salir',
      );
      if (ok) await ref.read(sessionProvider.notifier).logout();
    }

    final usuario = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Center(
        child: Text(session.userName ?? '', overflow: TextOverflow.ellipsis),
      ),
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('AgeCare · Administración'),
        actions: [
          if (ancho) usuario,
          IconButton(
            tooltip: 'Cerrar sesión',
            onPressed: salir,
            icon: const Icon(Icons.logout),
          ),
        ],
      ),
      drawer: ancho
          ? null
          : Drawer(
              child: SafeArea(
                child: ListView(
                  children: [
                    for (var i = 0; i < _destinos.length; i++)
                      ListTile(
                        leading: Icon(_destinos[i].icon),
                        title: Text(_destinos[i].label),
                        selected: i == indice,
                        onTap: () {
                          Navigator.pop(context);
                          context.go(_destinos[i].path);
                        },
                      ),
                  ],
                ),
              ),
            ),
      body: Row(
        children: [
          if (ancho)
            NavigationRail(
              selectedIndex: indice,
              labelType: NavigationRailLabelType.all,
              onDestinationSelected: (i) => context.go(_destinos[i].path),
              destinations: [
                for (final d in _destinos)
                  NavigationRailDestination(icon: Icon(d.icon), label: Text(d.label)),
              ],
            ),
          if (ancho) const VerticalDivider(width: 1),
          Expanded(child: child),
        ],
      ),
    );
  }
}
