import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/common.dart';
import '../../auth/application/auth_controller.dart';
import '../../patients/application/patients_providers.dart';
import '../../patients/domain/models.dart';

/// "Hoy" del médico: lista de pacientes asignados con su estado (semáforo y
/// alertas activas). Al tocar un paciente se selecciona y se abre su ficha
/// clínica (doctor_patient_screen).
///
/// Solo consume endpoints existentes: GET /patients devuelve los pacientes
/// donde el usuario es miembro, con cualquier rol (incluido doctor).
class DoctorHomeScreen extends ConsumerWidget {
  const DoctorHomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(currentUserProvider);
    final firstName =
        (user?.fullName ?? '').trim().split(RegExp(r'\s+')).first;
    final patientsAsync = ref.watch(myPatientsProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(firstName.isEmpty ? 'Mis pacientes' : 'Hola, $firstName'),
      ),
      body: patientsAsync.when(
        loading: () => const LoadingView(),
        error: (e, _) => ErrorView(message: e.toString()),
        data: (patients) {
          if (patients.isEmpty) {
            return const EmptyView(
              icon: Icons.medical_services_rounded,
              title: 'Sin pacientes asignados',
              subtitle:
                  'Cuando un familiar te invite a su círculo de cuidado con el '
                  'rol médico, verás a tus pacientes aquí.',
            );
          }
          final requierenAtencion = patients
              .where((p) => p.wellbeingStatus != WellbeingStatus.ok)
              .length;
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 8, left: 2),
                child: Text(
                  requierenAtencion > 0
                      ? '$requierenAtencion de ${patients.length} requieren atención · ordenados por prioridad'
                      : '${patients.length} paciente(s) · todo en orden',
                  style: const TextStyle(
                      fontSize: 13, color: AppColors.textSecondary),
                ),
              ),
              for (final p in patients)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: _DoctorPatientCard(patient: p),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _DoctorPatientCard extends ConsumerWidget {
  const _DoctorPatientCard({required this.patient});

  final PatientCard patient;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return AppCard(
      onTap: () {
        ref.read(selectedPatientProvider.notifier).select(patient);
        context.push('/doctor/patient?patient=${patient.patientId}');
      },
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
                // Nombre completo + edad: el médico interpreta los signos según
                // la edad (54 lpm no es lo mismo a los 50 que a los 90).
                Text(
                  patient.age != null
                      ? '${patient.fullName}, ${patient.age} años'
                      : patient.fullName,
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w700),
                ),
                if ((patient.rut ?? '').isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text('RUT ${patient.rut}',
                      style: const TextStyle(
                          fontSize: 12, color: AppColors.textSecondary)),
                ],
                if (patient.conditions.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      for (final c in patient.conditions)
                        _ConditionChip(label: _bonito(c)),
                    ],
                  ),
                ],
                if (patient.vitalsSummary.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      const Icon(Icons.favorite_rounded,
                          size: 13, color: AppColors.textSecondary),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          patient.vitalsSummary.map((v) => v.display).join('  ·  '),
                          style: const TextStyle(
                              fontSize: 12, color: AppColors.textSecondary),
                        ),
                      ),
                    ],
                  ),
                ],
                if ((patient.topReason ?? '').isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      const Icon(Icons.warning_amber_rounded,
                          size: 14, color: AppColors.statusAttention),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(patient.topReason!,
                            style: const TextStyle(
                                fontSize: 13,
                                color: AppColors.statusAttention)),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              WellbeingChip(status: patient.wellbeingStatus),
              if (patient.activeAlertsCount > 0) ...[
                const SizedBox(height: 6),
                Text(
                  '${patient.activeAlertsCount} alerta(s)',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: AppColors.statusAttention,
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(width: 4),
          const Icon(Icons.chevron_right_rounded,
              color: AppColors.textSecondary),
        ],
      ),
    );
  }
}

/// Chip compacto de enfermedad para la tarjeta del médico.
class _ConditionChip extends StatelessWidget {
  const _ConditionChip({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: AppColors.primary.withValues(alpha: .10),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(
          label,
          style: const TextStyle(
              fontSize: 11, color: AppColors.primary, fontWeight: FontWeight.w600),
        ),
      );
}

/// Convierte el código de enfermedad del backend ("diabetes_tipo_2") en una
/// etiqueta legible ("Diabetes tipo 2"). Es presentación: el dato crudo sigue
/// siendo el del expediente.
String _bonito(String codigo) {
  final limpio = codigo.replaceAll('_', ' ').trim();
  if (limpio.isEmpty) return codigo;
  return limpio[0].toUpperCase() + limpio.substring(1);
}
