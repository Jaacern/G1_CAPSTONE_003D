import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_theme.dart';
import '../../core/widgets/aviso_sin_conexion.dart';
import '../auth/application/auth_controller.dart';
import '../auth/domain/models.dart';
import '../alerts/application/alerts_providers.dart';
import '../patients/application/patients_providers.dart';
import '../patients/presentation/patient_profile_screen.dart';
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
/// - familiar:        Hoy · Salud · Ficha · Mensajes · Tienda · Más
///                    (Mensajes = Comunicación, Tienda = Marketplace)
/// - cuidadora:       Hoy · Salud · Ficha · Mensajes · Más
/// - adulto mayor:    experiencia de mosaico a pantalla completa
/// - médico:          Hoy (mis pacientes) · Salud · Más
///
/// Las alertas no ocupan una pestaña: van en la campana de la barra
/// superior, con el número de activas, a la vista desde cualquier pestaña.
class MainShell extends ConsumerWidget {
  const MainShell({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(currentUserProvider);
    final role = user?.primaryRole ?? RoleType.family;

    // Personal de AgeCare: no cuida ni es familia de nadie. Sin esto veía la
    // app de la familia, con "Agregar adulto mayor" incluido.
    if (user != null && user.isStaff) {
      return const _CuentaDePersonal();
    }

    if (role == RoleType.elder) {
      return const ElderHomeScreen();
    }

    // Médico sin habilitación vigente: el backend le niega todo acceso
    // clínico, así que mostrarle la app del médico solo daría errores.
    if (user != null && user.isUnverifiedDoctor) {
      return const _MedicoSinHabilitacion();
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
    // Alertas queda fuera a proposito. El centro trae su propio filtro, que
    // ademas ofrece "Todos", cosa que este desplegable no puede hacer porque
    // el paciente seleccionado no admite nulo. Dejar los dos significaba dos
    // selectores en la misma pantalla diciendo cosas distintas.
    final showPatientSelector = role == RoleType.doctor
        ? tab.label == 'Salud'
        : (tab.label == 'Hoy' || tab.label == 'Salud' || tab.label == 'Ficha');

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            _ShellTitleBar(title: tab.full ?? tab.label),
            // Arriba de todo y en el contenedor y no en cada pantalla: el
            // aviso vale para cualquier pestaña y mientras hay conexion no
            // ocupa alto (RF-80).
            const AvisoSinConexion(),
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

  // 🏠 Hoy · ❤️ Salud · 📋 Ficha · 💬 Comunicación · 🛍️ Marketplace · ☰ Más
  //
  // La pestaña de Alertas dejó su lugar a la Ficha del adulto mayor (con la
  // hoja de emergencia): las alertas ya están en la campana de arriba, y la
  // ficha es lo que la familia necesita a mano en una urgencia.
  // Los índices que el inicio usa para saltar viven en [ShellTabs].
  static const familyTabs = <ShellTab>[
    ShellTab('Hoy', '🏠', FamilyHomeScreen()),
    ShellTab('Salud', '❤️', HealthScreen()),
    ShellTab('Ficha', '📋', FichaTab(), full: 'Ficha del adulto mayor'),
    ShellTab('Mensajes', '💬', CommsScreen(), full: 'Comunicación'),
    ShellTab('Tienda', '🛍️', MarketplaceScreen(), full: 'Marketplace'),
    ShellTab('Más', '☰', MoreScreen()),
  ];

  // Barra de la cuidadora:
  // 🏠 Hoy (resumen + dosis) · ❤️ Salud · 📋 Ficha · 💬 Mensajes · ☰ Más
  // La Ficha es la de cada adulto mayor a su cargo, con la hoja de
  // emergencia; las alertas van en la campana de arriba.
  // Mensajes reutiliza el hub de Comunicación del familiar: la cuidadora
  // conversa con la familia por el mismo chat de equipo (/patients/{id}/chat).
  static const caregiverTabs = <ShellTab>[
    ShellTab('Hoy', '🏠', CaregiverHomeScreen()),
    ShellTab('Salud', '❤️', HealthScreen()),
    ShellTab('Ficha', '📋', FichaTab(), full: 'Ficha del adulto mayor'),
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

/// Pantalla para una cuenta del personal de AgeCare que entra a la app móvil.
class _CuentaDePersonal extends ConsumerWidget {
  const _CuentaDePersonal();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.admin_panel_settings_outlined,
                      size: 56, color: AppColors.primary),
                  const SizedBox(height: 16),
                  const Text('Esta cuenta es del personal de AgeCare',
                      textAlign: TextAlign.center,
                      style:
                          TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
                  const SizedBox(height: 10),
                  const Text(
                    'Los usuarios, planes y habilitaciones se administran desde '
                    'el panel web. En la app, los adultos mayores los crea la '
                    'familia y la cuidadora o el médico entran por invitación.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: AppColors.textSecondary),
                  ),
                  const SizedBox(height: 24),
                  OutlinedButton.icon(
                    onPressed: () =>
                        ref.read(authControllerProvider.notifier).logout(),
                    icon: const Icon(Icons.logout_rounded),
                    label: const Text('Cerrar sesión'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Pantalla para un médico cuya habilitación no está vigente.
class _MedicoSinHabilitacion extends ConsumerWidget {
  const _MedicoSinHabilitacion();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.verified_user_outlined,
                      size: 56, color: AppColors.primary),
                  const SizedBox(height: 16),
                  const Text('Tu cuenta de médico no está habilitada',
                      textAlign: TextAlign.center,
                      style:
                          TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
                  const SizedBox(height: 10),
                  const Text(
                    'Para proteger a los pacientes, solo un médico con registro '
                    'profesional verificado por AgeCare puede ver fichas e indicar '
                    'tratamientos. Escribe al equipo de AgeCare para revisar tu habilitación.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: AppColors.textSecondary),
                  ),
                  const SizedBox(height: 24),
                  OutlinedButton.icon(
                    onPressed: () => ref
                        .read(authControllerProvider.notifier)
                        .refreshProfile(),
                    icon: const Icon(Icons.refresh_rounded),
                    label: const Text('Volver a comprobar'),
                  ),
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: () =>
                        ref.read(authControllerProvider.notifier).logout(),
                    child: const Text('Cerrar sesión'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
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
            const AlertsBell(),
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


/// Índices de las pestañas a las que el inicio familiar salta. Se leen de la
/// lista para que reordenar la barra no rompa los atajos.
abstract final class ShellTabs {
  static int familia(String label) =>
      MainShell.familyTabs.indexWhere((t) => t.label == label);
}

/// Ficha del adulto mayor elegido, como pestaña.
class FichaTab extends ConsumerWidget {
  const FichaTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = ref.watch(selectedPatientProvider);
    if (p == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('Elige a un adulto mayor para ver su ficha.',
              textAlign: TextAlign.center),
        ),
      );
    }
    return PatientProfileScreen(
        key: ValueKey('ficha-${p.patientId}'),
        patientId: p.patientId,
        embedded: true);
  }
}

/// Campana de alertas de la barra superior, con el número de activas.
///
/// Antes las alertas eran una pestaña más de la barra inferior. Arriba a la
/// derecha están a la vista desde cualquier pestaña, que es lo que importa
/// con una caída o un SOS.
class AlertsBell extends ConsumerWidget {
  const AlertsBell({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Sin filtro, el total del backend; con el centro filtrado por un adulto
    // mayor, la suma de sus tarjetas, para que la campana cuente todas.
    final filtro = ref.watch(filtroPacienteAlertasProvider);
    final centro = ref.watch(alertsControllerProvider).valueOrNull;
    final tarjetas = ref.watch(myPatientsProvider).valueOrNull ?? const [];
    final activas = (filtro == null && centro != null)
        ? centro.unreadCount
        : tarjetas.fold<int>(0, (a, p) => a + p.activeAlertsCount);
    final etiqueta = activas == 0
        ? 'Alertas, sin alertas activas'
        : 'Alertas, $activas activa${activas == 1 ? '' : 's'}';

    return Tooltip(
      message: 'Alertas',
      child: Semantics(
        button: true,
        label: etiqueta,
        excludeSemantics: true,
        child: IconButton(
          key: const Key('alertsBell'),
          onPressed: () {
            refreshAlertsFromWidget(ref);
            context.push('/alerts');
          },
          icon: Badge(
            isLabelVisible: activas > 0,
            backgroundColor: AppColors.critical,
            label: Text(activas > 99 ? '99+' : '$activas'),
            child: Icon(
              activas > 0
                  ? Icons.notifications_active_rounded
                  : Icons.notifications_none_rounded,
              color: activas > 0 ? AppColors.critical : AppColors.textPrimary,
            ),
          ),
        ),
      ),
    );
  }
}
