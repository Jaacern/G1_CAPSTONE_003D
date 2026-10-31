import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/application/auth_controller.dart';
import '../auth/domain/models.dart';
import '../alerts/presentation/alerts_screen.dart';
import '../caregiver/presentation/caregiver_home_screen.dart';
import '../comms/presentation/comms_screen.dart';
import '../doctor/presentation/doctor_home_screen.dart';
import '../elder/presentation/elder_home_screen.dart';
import '../health/presentation/health_screen.dart';
import '../home/presentation/family_home_screen.dart';
import '../marketplace/presentation/marketplace_screen.dart';
import 'more_screen.dart';
import 'patient_selector_bar.dart';
import 'shell_providers.dart';

/// Contenedor principal con navegación inferior según el rol del usuario.
/// Las pestañas se limitan a lo que el backend soporta hoy:
/// - familiar:        Hoy · Salud · Comunicación · Marketplace · Más
/// - cuidadora:       Hoy · Salud · Alertas · Más
/// - adulto mayor:    experiencia de mosaico a pantalla completa
/// - médico:          Hoy (mis pacientes) · Salud · Más
class MainShell extends ConsumerWidget {
  const MainShell({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(currentUserProvider);
    final role = user?.primaryRole ?? RoleType.family;

    if (role == RoleType.elder) {
      return const ElderHomeScreen();
    }

    final tabs = switch (role) {
      RoleType.caregiver => _caregiverTabs,
      RoleType.doctor => _doctorTabs,
      _ => _familyTabs,
    };
    final index = ref.watch(shellTabIndexProvider);
    final safeIndex = index.clamp(0, tabs.length - 1);

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            const PatientSelectorBar(),
            Expanded(
              child: IndexedStack(
                index: safeIndex,
                children: [for (final t in tabs) t.screen],
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: safeIndex,
        onDestinationSelected: (i) =>
            ref.read(shellTabIndexProvider.notifier).state = i,
        destinations: [
          for (var i = 0; i < tabs.length; i++)
            NavigationDestination(
              // Emojis fieles al wireframe (🏠 ❤️ 💬 🛍️ ☰). Semantics mantiene
              // la accesibilidad con el nombre de la pestaña.
              icon: _EmojiTab(emoji: tabs[i].emoji, active: i == safeIndex),
              label: tabs[i].label,
            ),
        ],
      ),
    );
  }

  // Orden, emojis y etiquetas fieles al wireframe Suite/Familiar v1:
  // 🏠 Hoy · ❤️ Salud · 💬 Comunicación · 🛍️ Marketplace · ☰ Más
  static const _familyTabs = <_Tab>[
    _Tab('Hoy', '🏠', FamilyHomeScreen()),
    _Tab('Salud', '❤️', HealthScreen()),
    _Tab('Comunicación', '💬', CommsScreen()),
    _Tab('Marketplace', '🛍️', MarketplaceScreen()),
    _Tab('Más', '☰', MoreScreen()),
  ];

  // Barra de la cuidadora: solo pestañas con backend real.
  // 🏠 Hoy (resumen + dosis) · ❤️ Salud · 🔔 Alertas · ☰ Más
  static const _caregiverTabs = <_Tab>[
    _Tab('Hoy', '🏠', CaregiverHomeScreen()),
    _Tab('Salud', '❤️', HealthScreen()),
    _Tab('Alertas', '🔔', AlertsScreen()),
    _Tab('Más', '☰', MoreScreen()),
  ];

  // Barra del médico: lectura del historial + recetas desde la ficha del
  // paciente. Todos los GET del backend aceptan cualquier miembro (incluido
  // doctor) y POST /medications acepta el rol doctor.
  // 🏠 Hoy (mis pacientes) · ❤️ Salud · ☰ Más
  static const _doctorTabs = <_Tab>[
    _Tab('Hoy', '🏠', DoctorHomeScreen()),
    _Tab('Salud', '❤️', HealthScreen()),
    _Tab('Más', '☰', MoreScreen()),
  ];
}

class _Tab {
  const _Tab(this.label, this.emoji, this.screen);
  final String label;
  final String emoji;
  final Widget screen;
}

/// Emoji de pestaña. Se atenúa levemente cuando no está activa para que la
/// seleccionada destaque, imitando el wireframe.
class _EmojiTab extends StatelessWidget {
  const _EmojiTab({required this.emoji, required this.active});
  final String emoji;
  final bool active;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: active ? 1 : 0.55,
      child: Text(emoji, style: const TextStyle(fontSize: 22)),
    );
  }
}
