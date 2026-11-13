import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:agecare_app/features/alerts/presentation/sos_button.dart';

import '../../../core/config/app_config.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/bloques.dart';
import '../../../core/widgets/common.dart';
import '../../../core/widgets/remote_file_image.dart';
import '../../alerts/application/alerts_providers.dart';
import '../../auth/application/auth_controller.dart';
import '../../caregiver/application/caregiver_providers.dart';
import '../../caregiver/domain/models.dart';
import '../../patients/application/patients_providers.dart';
import '../../patients/domain/models.dart';
import '../../shell/main_shell.dart' show ShellTabs;
import '../../shell/shell_providers.dart';
import '../application/home_providers.dart';
import '../domain/models.dart';

/// Pantalla "Hoy" del familiar, fiel al wireframe:
/// banda de alerta · tarjetas de pacientes (semáforo) · resumen de vitals ·
/// medicamentos de hoy · acceso al asistente (si está disponible).
class FamilyHomeScreen extends ConsumerWidget {
  const FamilyHomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final patientsAsync = ref.watch(myPatientsProvider);
    final selected = ref.watch(selectedPatientProvider);

    return Scaffold(
      floatingActionButton: selected != null ? const SosButton() : null,
      body: SafeArea(
        child: patientsAsync.when(
          loading: () => const LoadingView(),
          error: (e, _) => ErrorView(
            message: e.toString(),
            onRetry: () => ref.invalidate(myPatientsProvider),
          ),
          data: (patients) {
            if (patients.isEmpty) {
              return EmptyView(
                icon: Icons.people_alt_outlined,
                title: 'Aún no agregas a tu adulto mayor',
                subtitle:
                    'Crea el perfil de tu familiar para empezar a cuidar de su bienestar.',
                action: FilledButton.icon(
                  onPressed: () => context.push('/patients/create'),
                  icon: const Icon(Icons.add_rounded),
                  label: const Text('Agregar adulto mayor'),
                ),
              );
            }

            return RefreshIndicator(
              onRefresh: () async {
                ref.invalidate(myPatientsProvider);
                ref.invalidate(todaySummaryProvider);
                ref.invalidate(selectedPatientDetailProvider);
              },
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 96),
                children: [
                  const _Saludo(),
                  const _AlertBand(),
                  const _AccesosRapidos(),
                  const EncabezadoDeSeccion('Tus adultos mayores'),
                  for (final p in patients) _PatientSemCard(patient: p),
                  EncabezadoDeSeccion(
                      'Resumen de ${_firstName(selected?.fullName)}'),
                  const _VitalsSummaryCard(),
                  const SizedBox(height: 12),
                  const _MedsTodayCard(),
                  const SizedBox(height: 12),
                  const _LastObservationCard(),
                  if (AppConfig.hasComms) ...[
                    const SizedBox(height: 12),
                    _AiCta(
                      label:
                          'Preguntar al asistente sobre ${_firstName(selected?.fullName)}',
                      onTap: () =>
                          ref.read(shellTabIndexProvider.notifier).state =
                          ShellTabs.familia('Mensajes'),
                    ),
                  ],
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  static String _firstName(String? full) {
    if (full == null || full.trim().isEmpty) return 'tu adulto mayor';
    return full.trim().split(RegExp(r'\s+')).first;
  }
}

/// Saludo con el nombre de quien entro y su foto.
///
/// Es lo primero de la pantalla porque le dice a la persona que esta en su
/// cuenta y no en la de otro, que en un telefono compartido entre familiares
/// no es obvio.
class _Saludo extends ConsumerWidget {
  const _Saludo();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final usuario = ref.watch(currentUserProvider);
    final nombre = (usuario?.firstName.trim().isNotEmpty ?? false)
        ? usuario!.firstName.trim()
        : _primerNombre(usuario?.fullName);
    final esquema = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 4, 4),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Hola,',
                    style: AgeText.small
                        .copyWith(color: esquema.onSurfaceVariant)),
                Text(nombre,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AgeText.h2.copyWith(color: esquema.onSurface)),
              ],
            ),
          ),
          InkWell(
            onTap: () => context.push('/profile'),
            borderRadius: BorderRadius.circular(AgeRadius.full),
            child: InitialsAvatar(
                name: usuario?.fullName ?? '', 
                photoUrl: usuario?.avatarUrl,
                radius: 22),
          ),
        ],
      ),
    );
  }

  static String _primerNombre(String? completo) {
    if (completo == null || completo.trim().isEmpty) return 'hola';
    return completo.trim().split(RegExp(r'\s+')).first;
  }
}

/// Accesos a las cuatro pantallas a las que mas se entra desde aqui.
///
/// Son atajos a lo que ya existe, no pantallas nuevas: entrar a la salud del
/// paciente desde el tablero son hoy dos toques, uno para cambiar de pestaña
/// y otro para encontrar lo que se buscaba.
class _AccesosRapidos extends ConsumerWidget {
  const _AccesosRapidos();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    void aPestana(String etiqueta) =>
        ref.read(shellTabIndexProvider.notifier).state =
            ShellTabs.familia(etiqueta);

    return Padding(
      padding: const EdgeInsets.only(top: 18),
      // Cada mosaico se reparte el ancho por igual, para que entren los
      // cuatro tambien en una pantalla angosta.
      child: Row(
        children: [
          Expanded(
            child: MosaicoDeAcceso(
              icono: Icons.favorite_rounded,
              etiqueta: 'Salud',
              color: AgeColors.teal600,
              alPresionar: () => aPestana('Salud'),
            ),
          ),
          Expanded(
            child: MosaicoDeAcceso(
              icono: Icons.assignment_ind_rounded,
              etiqueta: 'Ficha',
              color: AgeColors.coral500,
              alPresionar: () => aPestana('Ficha'),
            ),
          ),
          Expanded(
            child: MosaicoDeAcceso(
              icono: Icons.folder_rounded,
              etiqueta: 'Documentos',
              color: AgeColors.gold500,
              alPresionar: () => context.push('/documents'),
            ),
          ),
          if (AppConfig.hasComms)
            Expanded(
              child: MosaicoDeAcceso(
                icono: Icons.forum_rounded,
                etiqueta: 'Mensajes',
                color: AgeColors.navy500,
                alPresionar: () => aPestana('Mensajes'),
              ),
            ),
        ],
      ),
    );
  }
}

/// Banda de alerta del paciente seleccionado (si tiene alertas activas).
class _AlertBand extends ConsumerWidget {
  const _AlertBand();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final summaryAsync = ref.watch(todaySummaryProvider);
    return summaryAsync.maybeWhen(
      data: (summary) {
        if (summary == null || summary.activeAlerts.isEmpty) {
          return const SizedBox.shrink();
        }
        final alert = summary.activeAlerts.first;
        final critical = alert.isCritical;
        final bg = critical
            ? AppColors.statusAttention.withValues(alpha: .10)
            : AppColors.statusWarning.withValues(alpha: .12);
        final border = critical
            ? AppColors.statusAttention.withValues(alpha: .35)
            : AppColors.statusWarning.withValues(alpha: .4);
        return Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: () => context.push('/alerts'),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: bg,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: border),
              ),
              child: Row(
                children: [
                  Icon(critical ? Icons.sos_rounded : Icons.error_rounded,
                      color: critical
                          ? AppColors.statusAttention
                          : AppColors.statusWarning),
                  const SizedBox(width: 11),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(alert.title,
                            style: const TextStyle(
                                fontWeight: FontWeight.w700, fontSize: 13)),
                        if (alert.detail != null)
                          Text(alert.detail!,
                              style: const TextStyle(
                                  fontSize: 12,
                                  color: AppColors.textSecondary)),
                      ],
                    ),
                  ),
                  const Icon(Icons.chevron_right_rounded,
                      color: AppColors.textSecondary),
                ],
              ),
            ),
          ),
        );
      },
      orElse: () => const SizedBox.shrink(),
    );
  }
}

/// Tarjeta de paciente estilo "semáforo" del wireframe.
class _PatientSemCard extends ConsumerWidget {
  const _PatientSemCard({required this.patient});
  final PatientCard patient;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(selectedPatientProvider);
    final isSelected = selected?.patientId == patient.patientId;
    final status = patient.wellbeingStatus;

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: AppCard(
        onTap: () {
          ref.read(selectedPatientProvider.notifier).select(patient);
          ref.read(shellTabIndexProvider.notifier).state =
              ShellTabs.familia('Salud');
        },
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 4,
                  height: 40,
                  decoration: BoxDecoration(
                    color: status.color,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
                const SizedBox(width: 11),
                InitialsAvatar(
                    name: patient.fullName,
                    photoUrl: patient.photoUrl,
                    radius: 20),
                const SizedBox(width: 11),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(patient.fullName,
                          style: const TextStyle(
                              fontWeight: FontWeight.w700, fontSize: 15)),
                      Text(
                        patient.topReason ??
                            (isSelected
                                ? 'Seleccionado'
                                : patient.role.label),
                        style: const TextStyle(
                            fontSize: 11, color: AppColors.textSecondary),
                      ),
                    ],
                  ),
                ),
                WellbeingChip(status: status),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Tarjeta "Resumen de vitals" del paciente seleccionado.
class _VitalsSummaryCard extends ConsumerWidget {
  const _VitalsSummaryCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final summaryAsync = ref.watch(todaySummaryProvider);
    return summaryAsync.when(
      loading: () => const AppCard(
        child: SizedBox(height: 90, child: LoadingView()),
      ),
      error: (e, _) => AppCard(
        child: ErrorView(
          message: 'No se pudo cargar el resumen del día.',
          onRetry: () => ref.invalidate(todaySummaryProvider),
        ),
      ),
      data: (summary) {
        if (summary == null) return const SizedBox.shrink();
        return AppCard(
          onTap: () => ref.read(shellTabIndexProvider.notifier).state =
              ShellTabs.familia('Salud'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(
                children: [
                  // El título cede ancho antes que "Ver todo": sin Expanded,
                  // en una fila de 256 dp empujaba el enlace fuera de pantalla.
                  Expanded(
                    child: Text('Vitals del wearable',
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w700)),
                  ),
                  Text('Ver todo ›',
                      style: TextStyle(
                          fontSize: 12, color: AppColors.textSecondary)),
                ],
              ),
              const SizedBox(height: 12),
              if (summary.latestVitals.isEmpty)
                const Text('Aún no hay lecturas recientes.',
                    style: TextStyle(color: AppColors.textSecondary))
              else
                ...summary.latestVitals.map((v) => _VitalRow(vital: v)),
            ],
          ),
        );
      },
    );
  }
}

class _VitalRow extends StatelessWidget {
  const _VitalRow({required this.vital});
  final VitalReading vital;

  @override
  Widget build(BuildContext context) {
    final color =
        vital.inRange ? AppColors.textPrimary : AppColors.statusAttention;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Text(vital.emoji, style: const TextStyle(fontSize: 18)),
          const SizedBox(width: 12),
          Expanded(
            child: Text(vital.label,
                style: const TextStyle(color: AppColors.textSecondary)),
          ),
          Text(vital.display,
              style: TextStyle(
                  fontSize: 16, fontWeight: FontWeight.w700, color: color)),
          if (!vital.inRange) ...[
            const SizedBox(width: 6),
            const Icon(Icons.error_rounded,
                size: 18, color: AppColors.statusAttention),
          ],
        ],
      ),
    );
  }
}

/// Tarjeta "Medicamentos de hoy" (conteo tomadas/pendientes/omitidas).
class _MedsTodayCard extends ConsumerWidget {
  const _MedsTodayCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final summaryAsync = ref.watch(todaySummaryProvider);
    return summaryAsync.maybeWhen(
      data: (summary) {
        if (summary == null) return const SizedBox.shrink();
        final m = summary.medicationsToday;
        final pct = m.adherencePct;
        final color = pct >= 80
            ? AppColors.statusOk
            : pct >= 50
                ? AppColors.statusWarning
                : AppColors.statusAttention;
        return AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Text('Medicamentos de hoy',
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w700)),
                  ),
                  if (m.pending > 0)
                    _Pill(
                      text:
                          '${m.pending} pendiente${m.pending == 1 ? '' : 's'}',
                      color: AppColors.statusWarning,
                    )
                  else if (m.missed > 0)
                    _Pill(
                      text: '${m.missed} omitida${m.missed == 1 ? '' : 's'}',
                      color: AppColors.statusAttention,
                    )
                  else
                    const _Pill(text: 'Al día', color: AppColors.statusOk),
                ],
              ),
              const SizedBox(height: 12),
              ClipRRect(
                borderRadius: BorderRadius.circular(999),
                child: LinearProgressIndicator(
                  value: (pct.clamp(0, 100)) / 100,
                  minHeight: 8,
                  backgroundColor: AppColors.divider,
                  valueColor: AlwaysStoppedAnimation<Color>(color),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '${m.taken} tomada(s) · ${m.missed} omitida(s) · ${m.pending} pendiente(s)',
                style: const TextStyle(
                    fontSize: 12, color: AppColors.textSecondary),
              ),
              const SizedBox(height: 6),
              const Text(
                  'El plan lo gestiona la cuidadora / médico · tú observas',
                  style:
                      TextStyle(fontSize: 11, color: AppColors.textSecondary)),
            ],
          ),
        );
      },
      orElse: () => const SizedBox.shrink(),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.text, required this.color});
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(text,
          style: TextStyle(
              fontSize: 11, fontWeight: FontWeight.w700, color: color)),
    );
  }
}

/// Tarjeta "Última observación" del wireframe.
///
/// Lee `GET /patients/{id}/observations` (logbook.py), que devuelve la bitácora
/// de la cuidadora del más nuevo al más viejo. El endpoint solo pide
/// pertenencia al paciente, sin lista de roles, así que la familia y el médico
/// pueden leerla; lo que no pueden es escribir.
class _LastObservationCard extends ConsumerWidget {
  const _LastObservationCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final obsAsync = ref.watch(observationsProvider);
    return obsAsync.when(
      // Mientras llega, nada: la pantalla ya se está llenando sola y un
      // spinner en cada tarjeta hace que el listado parpadee.
      loading: () => const SizedBox.shrink(),
      error: (e, _) => AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _ObservationHeader(),
            const SizedBox(height: 8),
            Text(
              'No pudimos cargar la bitácora. ${e.toString()}',
              style: const TextStyle(
                  fontSize: 13, color: AppColors.textSecondary, height: 1.4),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: () => ref.invalidate(observationsProvider),
                child: const Text('Reintentar'),
              ),
            ),
          ],
        ),
      ),
      data: (items) {
        if (items.isEmpty) {
          return const AppCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _ObservationHeader(),
                SizedBox(height: 8),
                Text(
                  'La cuidadora todavía no ha registrado una observación para '
                  'este adulto mayor.',
                  style: TextStyle(
                      fontSize: 13,
                      color: AppColors.textSecondary,
                      height: 1.4),
                ),
              ],
            ),
          );
        }
        final obs = items.first;
        final etiqueta = categoryLabel(obs.category);
        return AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Expanded(child: _ObservationHeader()),
                  Text(alertTimeAgo(obs.createdAt),
                      style: const TextStyle(
                          fontSize: 12, color: AppColors.textSecondary)),
                ],
              ),
              const SizedBox(height: 8),
              Text(obs.authorName.isEmpty ? 'Cuidadora' : obs.authorName,
                  style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: AppColors.primary)),
              const SizedBox(height: 4),
              Text(obs.text, style: const TextStyle(fontSize: 14, height: 1.4)),
              if (etiqueta.isNotEmpty) ...[
                const SizedBox(height: 10),
                Row(
                  children: [
                    Flexible(
                        child: _Pill(text: etiqueta, color: AppColors.primary)),
                  ],
                ),
              ],
              if (obs.mediaUrl != null && obs.mediaUrl!.isNotEmpty) ...[
                const SizedBox(height: 10),
                RemoteFileImage(
                  obs.mediaUrl!,
                  height: 150,
                  width: double.infinity,
                  borderRadius: BorderRadius.circular(12),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

/// Encabezado de la tarjeta, igual con o sin datos.
class _ObservationHeader extends StatelessWidget {
  const _ObservationHeader();

  @override
  Widget build(BuildContext context) {
    return const Row(
      children: [
        Text('👩‍⚕️ ', style: TextStyle(fontSize: 16)),
        Expanded(
          child: Text('Última observación',
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
        ),
      ],
    );
  }
}

class _AiCta extends StatelessWidget {
  const _AiCta({required this.label, required this.onTap});
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        decoration: BoxDecoration(
          color: AppColors.primary.withValues(alpha: .08),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.primary.withValues(alpha: .20)),
        ),
        child: Row(
          children: [
            const Icon(Icons.chat_bubble_outline_rounded,
                size: 20, color: AppColors.primary),
            const SizedBox(width: 10),
            Expanded(
              child: Text(label,
                  style: const TextStyle(
                      fontWeight: FontWeight.w600, color: AppColors.primary)),
            ),
          ],
        ),
      ),
    );
  }
}
