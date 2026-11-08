import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
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
/// - familiar:        Hoy · Salud · Mensajes · Tienda · Más
///                    (Mensajes = Comunicación, Tienda = Marketplace)
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
      RoleType.caregiver => caregiverTabs,
      RoleType.doctor => doctorTabs,
      _ => familyTabs,
    };
    final index = ref.watch(shellTabIndexProvider);
    final safeIndex = index.clamp(0, tabs.length - 1);
    final tab = tabs[safeIndex];
    // El contexto de paciente se ofrece donde se lee información de un
    // paciente concreto. El médico elige paciente desde su lista de "Hoy",
    // así que allí no necesita desplegable; la cuidadora además lo usa en
    // Alertas para ver solo los avisos del paciente seleccionado.
    final showPatientSelector = role == RoleType.doctor
        ? tab.label == 'Salud'
        : (tab.label == 'Hoy' ||
            tab.label == 'Salud' ||
            tab.label == 'Alertas');

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            _ShellTitleBar(title: tab.full ?? tab.label),
            if (showPatientSelector) const PatientSelectorBar(),
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
              icon: _EmojiTab(
                  emoji: tabs[i].emoji,
                  active: i == safeIndex,
                  nombre: tabs[i].full ?? tabs[i].label),
              label: tabs[i].label,
            ),
        ],
      ),
    );
  }

  // Orden, emojis y etiquetas fieles al wireframe Suite/Familiar v1:
  // 🏠 Hoy · ❤️ Salud · 💬 Comunicación · 🛍️ Marketplace · 🔔 Alertas · ☰ Más
  //
  // Seis destinos en 360 dp dan ~60 dp por etiqueta; "Mensajes" (8 caracteres)
  // es el más largo y aún cabe. Alertas va al final, antes de Más, para no
  // mover los índices que el inicio familiar usa para saltar a Salud/Mensajes.
  // El familiar ve las alertas en modo lectura: sin reconocer ni resolver.
  static const familyTabs = <ShellTab>[
    ShellTab('Hoy', '🏠', FamilyHomeScreen()),
    ShellTab('Salud', '❤️', HealthScreen()),
    ShellTab('Mensajes', '💬', CommsScreen(), full: 'Comunicación'),
    ShellTab('Tienda', '🛍️', MarketplaceScreen(), full: 'Marketplace'),
    ShellTab('Alertas', '🔔', AlertsScreen(embedded: true)),
    ShellTab('Más', '☰', MoreScreen()),
  ];

  // Barra de la cuidadora: solo pestañas con backend real.
  // 🏠 Hoy (resumen + dosis) · ❤️ Salud · 🔔 Alertas · 💬 Mensajes · ☰ Más
  // Mensajes reutiliza el hub de Comunicación del familiar: la cuidadora
  // conversa con la familia por el mismo chat de equipo (/patients/{id}/chat).
  static const caregiverTabs = <ShellTab>[
    ShellTab('Hoy', '🏠', CaregiverHomeScreen()),
    ShellTab('Salud', '❤️', HealthScreen()),
    ShellTab('Alertas', '🔔', AlertsScreen(embedded: true)),
    ShellTab('Mensajes', '💬', CommsScreen(), full: 'Comunicación'),
    ShellTab('Más', '☰', MoreScreen()),
  ];

  // Barra del médico: lectura del historial + recetas desde la ficha del
  // paciente. Todos los GET del backend aceptan cualquier miembro (incluido
  // doctor) y POST /medications acepta el rol doctor.
  // 🏠 Hoy (mis pacientes) · ❤️ Salud · ☰ Más
  static const doctorTabs = <ShellTab>[
    ShellTab('Hoy', '🏠', DoctorHomeScreen()),
    ShellTab('Salud', '❤️', HealthScreen()),
    ShellTab('Más', '☰', MoreScreen()),
  ];
}

/// Barra superior de [MainShell]: muestra el título de la pestaña activa en
/// lugar del nombre del paciente. El contexto de paciente vive ahora en el
/// desplegable ([PatientSelectorBar]) que va debajo, solo en Hoy y Salud.
class _ShellTitleBar extends StatelessWidget {
  const _ShellTitleBar({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.surface,
      child: Container(
        height: 52,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        alignment: Alignment.centerLeft,
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: AppColors.divider)),
        ),
        child: Row(
          children: [
            const Icon(Icons.health_and_safety_rounded,
                size: 22, color: AppColors.primary),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                title,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 19,
                  letterSpacing: -0.3,
                  color: AppColors.textPrimary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Pestaña de la barra inferior. Las listas de cada rol son públicas para que
/// los tests midan las etiquetas reales en vez de copiarlas.
class ShellTab {
  const ShellTab(this.label, this.emoji, this.screen, {this.full});

  final String label;
  final String emoji;
  final Widget screen;

  /// Nombre completo, para el tooltip y el lector de pantalla cuando [label]
  /// se acorta porque no entra en la barra.
  final String? full;
}

/// Emoji de pestaña. Se atenúa levemente cuando no está activa para que la
/// seleccionada destaque, imitando el wireframe. El lector de pantalla recibe
/// el nombre en vez del emoji, que de otra forma se announce como "casa".
class _EmojiTab extends StatelessWidget {
  const _EmojiTab(
      {required this.emoji, required this.active, required this.nombre});

  final String emoji;
  final bool active;
  final String nombre;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: nombre,
      child: Semantics(
        label: nombre,
        excludeSemantics: true,
        child: Opacity(
          opacity: active ? 1 : 0.55,
          child: Text(emoji, style: const TextStyle(fontSize: 22)),
        ),
      ),
    );
  }
}
