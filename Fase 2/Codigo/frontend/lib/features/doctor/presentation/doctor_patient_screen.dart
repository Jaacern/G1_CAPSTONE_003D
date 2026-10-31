import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/common.dart';
import '../../caregiver/application/caregiver_providers.dart';
import '../../caregiver/domain/models.dart';
import '../../health/application/health_providers.dart';
import '../../health/domain/models.dart' as health;
import '../../medications/application/medications_providers.dart';
import '../../medications/domain/models.dart';
import '../../patients/application/patients_providers.dart';

/// Ficha clínica del paciente para el rol médico (solo lectura del historial +
/// recetar). Toda la información viene de endpoints existentes:
/// - GET /patients/{id}/vitals/latest      (signos vitales actuales)
/// - GET /patients/{id}/medications        (medicación activa)
/// - GET /patients/{id}/adherence          (adherencia de los últimos 7 días)
/// - GET /patients/{id}/observations       (notas del círculo de cuidado)
/// - POST /patients/{id}/medications       (recetar; el backend guarda
///   prescribed_by cuando el rol es doctor)
class DoctorPatientScreen extends ConsumerWidget {
  const DoctorPatientScreen({super.key, required this.patientId});

  final String patientId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final patient = ref.watch(selectedPatientProvider);
    final latestVitals = ref.watch(latestVitalsProvider);
    final medications = ref.watch(medicationsProvider);
    final adherence = ref.watch(adherenceProvider);
    final observations = ref.watch(observationsProvider);

    // Si entró por deep link sin tener el paciente seleccionado, cargamos el
    // detalle para mostrar al menos nombre y estado.
    final name = patient?.fullName ?? 'Paciente';

    return Scaffold(
      appBar: AppBar(title: Text(name)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 100),
        children: [
          if (patient != null)
            AppCard(
              child: Row(
                children: [
                  InitialsAvatar(
                    name: patient.fullName,
                    photoUrl: patient.photoUrl,
                    radius: 24,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(patient.fullName,
                            style: const TextStyle(
                                fontSize: 16, fontWeight: FontWeight.w700)),
                        if ((patient.topReason ?? '').isNotEmpty) ...[
                          const SizedBox(height: 2),
                          Text(patient.topReason!,
                              style: const TextStyle(
                                  fontSize: 13,
                                  color: AppColors.textSecondary)),
                        ],
                      ],
                    ),
                  ),
                  WellbeingChip(status: patient.wellbeingStatus),
                ],
              ),
            ),
          const _SectionLabel('Signos vitales actuales'),
          latestVitals.when(
            loading: () => const AppCard(
              child: SizedBox(height: 70, child: LoadingView()),
            ),
            error: (e, _) =>
                AppCard(child: Text('No se pudieron cargar: $e')),
            data: (vitals) {
              final withData = vitals.where((v) => v.hasData).toList();
              if (withData.isEmpty) {
                return const AppCard(
                  child: Text(
                    'Aún no hay lecturas del wearable para este paciente.',
                    style: TextStyle(color: AppColors.textSecondary),
                  ),
                );
              }
              return AppCard(
                padding: EdgeInsets.zero,
                child: Column(
                  children: [
                    for (var i = 0; i < withData.length; i++) ...[
                      if (i != 0) const Divider(height: 1),
                      _VitalTile(vital: withData[i]),
                    ],
                  ],
                ),
              );
            },
          ),
          const _SectionLabel('Medicación activa'),
          medications.when(
            loading: () => const AppCard(
              child: SizedBox(height: 70, child: LoadingView()),
            ),
            error: (e, _) =>
                AppCard(child: Text('No se pudo cargar: $e')),
            data: (meds) {
              final active = meds.where((m) => m.active).toList();
              if (active.isEmpty) {
                return const AppCard(
                  child: Text(
                    'No hay medicación activa.',
                    style: TextStyle(color: AppColors.textSecondary),
                  ),
                );
              }
              return AppCard(
                padding: EdgeInsets.zero,
                child: Column(
                  children: [
                    for (var i = 0; i < active.length; i++) ...[
                      if (i != 0) const Divider(height: 1),
                      _MedicationTile(
                          medication: active[i], patientId: patientId),
                    ],
                  ],
                ),
              );
            },
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: () =>
                context.push('/meds/plan?patient=$patientId'),
            icon: const Icon(Icons.add_rounded),
            label: const Text('Recetar medicamento'),
          ),
          const _SectionLabel('Adherencia (últimos 7 días)'),
          adherence.when(
            loading: () => const AppCard(
              child: SizedBox(height: 70, child: LoadingView()),
            ),
            error: (e, _) =>
                AppCard(child: Text('No se pudo cargar: $e')),
            data: (adh) {
              if (adh == null) return const SizedBox.shrink();
              return AppCard(
                child: Row(
                  children: [
                    Text('${adh.pct.round()}%',
                        style: const TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.w800,
                          color: AppColors.primary,
                        )),
                    const SizedBox(width: 16),
                    const Expanded(
                      child: Text(
                        'de las dosis registradas en la semana',
                        style:
                            TextStyle(color: AppColors.textSecondary),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
          const _SectionLabel('Notas del círculo de cuidado'),
          observations.when(
            loading: () => const AppCard(
              child: SizedBox(height: 70, child: LoadingView()),
            ),
            error: (e, _) =>
                AppCard(child: Text('No se pudieron cargar: $e')),
            data: (notes) {
              if (notes.isEmpty) {
                return const AppCard(
                  child: Text(
                    'Aún no hay observaciones registradas.',
                    style: TextStyle(color: AppColors.textSecondary),
                  ),
                );
              }
              final recent = notes.take(5).toList();
              return AppCard(
                padding: EdgeInsets.zero,
                child: Column(
                  children: [
                    for (var i = 0; i < recent.length; i++) ...[
                      if (i != 0) const Divider(height: 1),
                      _ObservationTile(observation: recent[i]),
                    ],
                  ],
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 22, 4, 10),
        child: Text(
          text.toUpperCase(),
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: AppColors.textSecondary,
            letterSpacing: .5,
          ),
        ),
      );
}

class _VitalTile extends StatelessWidget {
  const _VitalTile({required this.vital});

  final health.LatestVital vital;

  @override
  Widget build(BuildContext context) {
    final color =
        vital.inRange ? AppColors.textPrimary : AppColors.statusAttention;
    final type = vital.type;
    return ListTile(
      leading: Icon(type.icon, color: AppColors.primary),
      title: Text(type.label),
      subtitle: Text(_timeAgo(vital.measuredAt)),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '${vital.value.round()} ${type.unit}',
            style: TextStyle(
                fontSize: 16, fontWeight: FontWeight.w700, color: color),
          ),
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

class _MedicationTile extends StatelessWidget {
  const _MedicationTile({required this.medication, required this.patientId});

  final Medication medication;
  final String patientId;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const Icon(Icons.medication_rounded, color: AppColors.primary),
      title: Text(medication.name),
      subtitle: Text(
        '${medication.dose} ${medication.unit} · ${medication.form} · '
        '${medication.schedule.join(', ')}',
        style: const TextStyle(
            fontSize: 12, color: AppColors.textSecondary),
      ),
      trailing: IconButton(
        tooltip: 'Editar receta',
        icon: const Icon(Icons.edit_outlined,
            color: AppColors.textSecondary),
        onPressed: () => context.push(
            '/meds/plan?patient=$patientId&medication=${medication.id}'),
      ),
    );
  }
}

class _ObservationTile extends StatelessWidget {
  const _ObservationTile({required this.observation});

  final Observation observation;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text(observation.text,
          maxLines: 3, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        '${observation.authorName} · ${_timeAgo(observation.createdAt)}',
        style: const TextStyle(
            fontSize: 12, color: AppColors.textSecondary),
      ),
    );
  }
}

String _timeAgo(DateTime dt) {
  final diff = DateTime.now().difference(dt);
  if (diff.inMinutes < 1) return 'ahora';
  if (diff.inMinutes < 60) return 'hace ${diff.inMinutes} min';
  if (diff.inHours < 24) return 'hace ${diff.inHours} h';
  if (diff.inDays == 1) return 'ayer';
  return 'hace ${diff.inDays} días';
}
