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
import '../../medications/data/medications_repository.dart';
import '../../medications/domain/models.dart';
import '../../patients/application/patients_providers.dart';
import '../../patients/domain/models.dart';

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
    // Edad, sexo y enfermedades. Van aparte porque el listado de pacientes no
    // los trae, solo el detalle.
    final detalle = ref.watch(selectedPatientDetailProvider);

    // Si entró por deep link sin tener el paciente seleccionado, cargamos el
    // detalle para mostrar al menos nombre y estado.
    final name = patient?.fullName ?? 'Paciente';

    return Scaffold(
      appBar: AppBar(title: Text(name)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 100),
        children: [
          if (patient != null)
            _Cabecera(patient: patient, detalle: detalle.valueOrNull),
          const _SectionLabel('Signos vitales actuales'),
          latestVitals.when(
            loading: () => const AppCard(
              child: SizedBox(height: 70, child: LoadingView()),
            ),
            error: (_, __) => AppCard(
              child: ErrorView(
                message: 'No se pudieron cargar las constantes.',
                onRetry: () => ref.invalidate(latestVitalsProvider),
              ),
            ),
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
            error: (_, __) => AppCard(
              child: ErrorView(
                message: 'No se pudo cargar la medicación.',
                onRetry: () => ref.invalidate(medicationsProvider),
              ),
            ),
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
                          medication: active[i],
                          patientId: patientId,
                          onDiscontinue: () => _discontinuarReceta(
                              context, ref, patientId, active[i])),
                    ],
                  ],
                ),
              );
            },
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: () => context.push('/meds/plan?patient=$patientId'),
            icon: const Icon(Icons.add_rounded),
            label: const Text('Recetar medicamento'),
          ),
          const _SectionLabel('Adherencia (últimos 7 días)'),
          adherence.when(
            loading: () => const AppCard(
              child: SizedBox(height: 70, child: LoadingView()),
            ),
            error: (_, __) => AppCard(
              child: ErrorView(
                message: 'No se pudo calcular la adherencia.',
                onRetry: () => ref.invalidate(adherenceProvider),
              ),
            ),
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
                        style: TextStyle(color: AppColors.textSecondary),
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
            error: (_, __) => AppCard(
              child: ErrorView(
                message: 'No se pudieron cargar las observaciones.',
                onRetry: () => ref.invalidate(observationsProvider),
              ),
            ),
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

/// Saca una medicación del plan del paciente. El backend responde 204 y deja
/// la receta con discontinued_at, conservando las dosis ya registradas.
Future<void> _discontinuarReceta(BuildContext context, WidgetRef ref,
    String patientId, Medication medication) async {
  final confirmar = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text('¿Discontinuar ${medication.name}?'),
      content: const Text(
        'Deja de estar activa en el plan del paciente. '
        'Las dosis ya registradas se conservan.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: AppColors.critical),
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: const Text('Discontinuar'),
        ),
      ],
    ),
  );
  if (confirmar != true) return;
  try {
    await ref
        .read(medicationsRepositoryProvider)
        .deleteMedication(patientId, medication.id);
    ref.invalidate(medicationsProvider);
    // Las dosis de hoy se generan desde la medicación activa: al salir una del
    // plan, su dosis pendiente ya no debe aparecer en el día.
    ref.invalidate(todayDosesProvider);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${medication.name} salió del plan.')),
      );
    }
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No se pudo discontinuar la receta.')),
      );
    }
  }
}

class _MedicationTile extends StatelessWidget {
  const _MedicationTile(
      {required this.medication,
      required this.patientId,
      required this.onDiscontinue});

  final Medication medication;
  final String patientId;
  final VoidCallback onDiscontinue;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const Icon(Icons.medication_rounded, color: AppColors.primary),
      title: Text(medication.name),
      subtitle: Text(
        // doseLabel ya concuerda el numero con la unidad ("2 comprimidos")
        // y no deja el punto colgando cuando falta un dato.
        '${medication.doseLabel} · ${medication.schedule.join(', ')}',
        style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: 'Editar receta',
            icon:
                const Icon(Icons.edit_outlined, color: AppColors.textSecondary),
            onPressed: () => context.push(
                '/meds/plan?patient=$patientId&medication=${medication.id}'),
          ),
          IconButton(
            tooltip: 'Discontinuar receta',
            icon: const Icon(Icons.delete_outline_rounded,
                color: AppColors.critical),
            onPressed: onDiscontinue,
          ),
        ],
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
      title:
          Text(observation.text, maxLines: 3, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        '${observation.authorName} · ${_timeAgo(observation.createdAt)}',
        style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
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

/// Cabecera de la ficha: quien es el paciente antes de mirar un solo numero.
///
/// La edad no es un adorno. Cincuenta y cuatro latidos por minuto son
/// bradicardia en alguien de cincuenta y pueden ser normales en alguien de
/// noventa, asi que una ficha que muestra el pulso sin la edad obliga al
/// profesional a pedir el dato por otro lado antes de decidir. Lo mismo con
/// las enfermedades de base: la misma presion se lee distinto en un paciente
/// hipertenso que en uno que no lo es.
///
/// El dato estaba en la base desde el principio (patients.birth_date y la
/// tabla patient_conditions) y el modelo del front ya calculaba la edad. Solo
/// no se dibujaba.
///
/// [detalle] llega nulo mientras carga o si la peticion falla. En ese caso se
/// muestra lo que ya trae el listado, nombre y estado, en vez de dejar la
/// cabecera en blanco o poner un indicador que empuje el resto de la ficha
/// hacia abajo cuando llegue.
class _Cabecera extends StatelessWidget {
  const _Cabecera({required this.patient, required this.detalle});

  final PatientCard patient;
  final Patient? detalle;

  @override
  Widget build(BuildContext context) {
    final edadYSexo = <String>[
      if (detalle != null) '${detalle!.age} años',
      if (detalle?.sex != null) _sexo(detalle!.sex!),
    ].join(' · ');

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
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
                    if (edadYSexo.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(edadYSexo,
                          style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: AppColors.textPrimary)),
                    ],
                    if ((patient.topReason ?? '').isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(patient.topReason!,
                          style: const TextStyle(
                              fontSize: 13, color: AppColors.textSecondary)),
                    ],
                  ],
                ),
              ),
              WellbeingChip(status: patient.wellbeingStatus),
            ],
          ),
          if (detalle != null && detalle!.conditions.isNotEmpty) ...[
            const SizedBox(height: 12),
            const Divider(height: 1),
            const SizedBox(height: 12),
            const Text('Antecedentes',
                style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.4,
                    color: AppColors.textSecondary)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final c in detalle!.conditions) _Antecedente(texto: c),
              ],
            ),
          ],
        ],
      ),
    );
  }

  /// El backend guarda una sola letra (ck_patients_sex admite M, F u O), pero
  /// los datos de prueba traian la palabra completa. Se mira la inicial para
  /// que ninguna de las dos formas termine mostrando "Otro".
  static String _sexo(String s) {
    if (s.isEmpty) return 'Otro';
    return switch (s[0].toUpperCase()) {
      'M' => 'Masculino',
      'F' => 'Femenino',
      _ => 'Otro',
    };
  }
}

class _Antecedente extends StatelessWidget {
  const _Antecedente({required this.texto});

  final String texto;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: AppColors.surfaceAlt,
        borderRadius: BorderRadius.circular(AgeRadius.full),
        border: Border.all(color: AppColors.divider),
      ),
      child: Text(
        texto,
        style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: AppColors.textPrimary),
      ),
    );
  }
}
