import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/common.dart';
import '../../alerts/presentation/sos_button.dart';
import '../../home/application/home_providers.dart';
import '../../medications/presentation/medications_screen.dart';
import '../../medications/presentation/prn_banner.dart';
import '../../patients/application/patients_providers.dart';
import '../application/caregiver_providers.dart';

/// "Hoy" de la cuidadora, construido solo con endpoints que el backend soporta:
/// resumen del día del paciente (summary/today) y la gestión de dosis del día
/// (MedicationsBody: adherencia, dosis de hoy con registro de toma, y plan).
///
/// La cuidadora tiene permiso para registrar/editar medicamentos y dosis, a
/// diferencia del familiar. Esta pantalla es su centro operativo real.
class CaregiverHomeScreen extends ConsumerWidget {
  const CaregiverHomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final patient = ref.watch(selectedPatientProvider);
    final summary = ref.watch(todaySummaryProvider);

    if (patient == null) {
      // Sin paciente es justo cuando más le sirve publicarse: así la
      // encuentran las familias que buscan cuidadora.
      return EmptyView(
        icon: Icons.person_search_rounded,
        title: 'Sin adulto mayor asignado',
        subtitle: 'Cuando una familia te invite, verás aquí a su familiar. '
            'Publica tu perfil para que las familias te encuentren.',
        action: FilledButton.icon(
          onPressed: () => context.push('/cg/profile'),
          icon: const Icon(Icons.badge_outlined),
          label: const Text('Mi perfil profesional'),
        ),
      );
    }

    return Scaffold(
      // La cuidadora es, junto con el adulto mayor, quien la API autoriza a
      // disparar un SOS, y era la única que no tenía el botón a mano.
      floatingActionButton: const SosButton(),
      body: Column(
        children: [
          // Tarjeta de estado del paciente (semáforo + motivo), de summary/today.
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: summary.when(
              loading: () => const AppCard(
                child: SizedBox(height: 70, child: LoadingView()),
              ),
              error: (_, __) => const SizedBox.shrink(),
              data: (s) {
                if (s == null) return const SizedBox.shrink();
                return AppCard(
                  child: Row(
                    children: [
                      InitialsAvatar(name: patient.fullName, radius: 22),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(patient.fullName,
                                style: const TextStyle(
                                    fontSize: 16, fontWeight: FontWeight.w700)),
                            if ((s.topReason ?? '').isNotEmpty) ...[
                              const SizedBox(height: 2),
                              Text(s.topReason!,
                                  style: const TextStyle(
                                      fontSize: 13,
                                      color: AppColors.textSecondary)),
                            ],
                          ],
                        ),
                      ),
                      WellbeingChip(status: s.wellbeingStatus),
                    ],
                  ),
                );
              },
            ),
          ),
          // Lo primero que lee quien llega al turno: lo que dejo la anterior
          // (RF-70).
          const _UltimoRelevo(),
          // Accesos a su propio trabajo. Las cuatro pantallas que hay detras
          // existian sin ruta ni boton, asi que una cuidadora no podia marcar
          // una tarea, hacer su check-in, dejar una observacion, reportar un
          // incidente, hacer el relevo ni ver sus reportes. Solo registrar
          // dosis, que es lo que esta pantalla ya mostraba.
          const _AccesosDeTurno(),
          // Los SOS no estan en la agenda: si no se avisan aqui, la cuidadora
          // no sabe que existen hasta la crisis.
          PrnBanner(patientId: patient.patientId),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text('Medicación de hoy',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
            ),
          ),
          // Dosis del día + plan, con permiso de registro/edición de la cuidadora.
          const Expanded(child: MedicationsBody()),
        ],
      ),
    );
  }
}

/// Accesos al trabajo de la cuidadora desde su pantalla de inicio.
///
/// Su turno, sus tareas, la bitacora y los reportes vivian en pantallas que
/// nadie instanciaba y que no tenian ruta: existian, compilaban, hasta habia
/// una prueba que medía que cupieran en 320 dp, y ninguna cuidadora podia
/// abrirlas. Los botones del check-in, la observacion, el incidente y el
/// relevo estaban dentro de una de ellas, asi que se cayeron todos juntos.
///
/// Van arriba de la medicacion y no en el menu Mas porque son lo que hace
/// durante el turno, no una configuracion que se toca una vez.
///
/// Se agregan aqui en vez de reemplazar esta pantalla por la del turno,
/// que seria lo mas directo, porque esa no muestra la medicacion y no existe
/// una ruta de medicamentos suelta: cambiarla le quitaria el registro de
/// dosis, que es su tarea de todos los dias.
class _AccesosDeTurno extends StatelessWidget {
  const _AccesosDeTurno();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Row(
        children: [
          _Acceso(
            icon: Icons.schedule_rounded,
            label: 'Mi turno',
            color: AppColors.primary,
            onTap: () => context.push('/cg/today'),
          ),
          const SizedBox(width: 10),
          _Acceso(
            icon: Icons.checklist_rounded,
            label: 'Tareas',
            color: AppColors.secondary,
            onTap: () => context.push('/cg/tasks'),
          ),
          const SizedBox(width: 10),
          _Acceso(
            icon: Icons.menu_book_rounded,
            label: 'Bitácora',
            color: AppColors.accent,
            onTap: () => context.push('/cg/log'),
          ),
          const SizedBox(width: 10),
          _Acceso(
            icon: Icons.bar_chart_rounded,
            label: 'Reportes',
            color: AppColors.textSecondary,
            onTap: () => context.push('/cg/reports'),
          ),
        ],
      ),
    );
  }
}

class _Acceso extends StatelessWidget {
  const _Acceso({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: InkWell(
        borderRadius: BorderRadius.circular(AgeRadius.xl),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
          decoration: BoxDecoration(
            color: color.withValues(alpha: .10),
            borderRadius: BorderRadius.circular(AgeRadius.xl),
          ),
          child: Column(
            children: [
              Icon(icon, color: color, size: 24),
              const SizedBox(height: 6),
              Text(
                label,
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    color: color, fontWeight: FontWeight.w700, fontSize: 11),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Ultima nota de relevo del paciente que se esta viendo (RF-70).
///
/// La cuidadora que llega al turno tiene que saber primero que dejo dicho la
/// anterior: si durmio mal, si no quiso almorzar. Antes eso estaba solo en
/// la pantalla de relevo, a la que habia que entrar a buscarlo.
///
/// Usa las mismas notas que esa pantalla (GET .../handover-notes), que ya
/// deja constancia de la lectura del expediente. Mientras carga, si falla o
/// si todavia no hay notas no ocupa lugar: la medicacion de abajo es lo
/// urgente y no tiene que saltar de posicion.
class _UltimoRelevo extends ConsumerWidget {
  const _UltimoRelevo();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final patient = ref.watch(selectedPatientProvider);
    final notas = ref.watch(handoverNotesProvider).valueOrNull;
    if (patient == null || notas == null || notas.isEmpty) {
      return const SizedBox.shrink();
    }
    final ultima = notas.first;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: AppCard(
        onTap: () =>
            context.push('/cg/handover?patient=${patient.patientId}'),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.swap_horiz_rounded,
                    size: 18, color: AppColors.primary),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Último relevo · ${ultima.authorName}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w700),
                  ),
                ),
                Text(
                  DateFormat('d MMM · HH:mm', 'es').format(ultima.createdAt),
                  style: const TextStyle(
                      fontSize: 12, color: AppColors.textSecondary),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              ultima.text,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13.5),
            ),
          ],
        ),
      ),
    );
  }
}
