import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/common.dart';
import '../../health/application/health_providers.dart';
import '../../health/domain/models.dart' as health;
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
    final patientsAsync = ref.watch(myPatientsProvider);

    return Scaffold(
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
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
            children: [
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
                    if ((patient.topReason ?? '').isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(patient.topReason!,
                          style: const TextStyle(
                              fontSize: 13, color: AppColors.textSecondary)),
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
          // Los numeros, en la misma tarjeta. El semaforo dice que algo pasa;
          // esto dice que. Sin ello hay que entrar a la ficha de cada
          // paciente, mirar, salir y entrar al siguiente para comparar.
          _VitalesEnLinea(patientId: patient.patientId),
        ],
      ),
    );
  }
}

/// Los ultimos valores del paciente, en una linea dentro de su tarjeta.
///
/// El semaforo de la tarjeta dice que algo pasa, pero no que. Con esto el
/// medico compara a sus pacientes de un vistazo en vez de entrar a una ficha,
/// mirar, salir y entrar a la siguiente.
///
/// Mientras cargan no se dibuja nada en lugar de un indicador: son varias
/// tarjetas pidiendo a la vez y la lista entera quedaria parpadeando. Si la
/// peticion falla tampoco se muestra error, porque el dato de aqui es un
/// extra y la ficha ya informa el fallo con su propio reintento.
class _VitalesEnLinea extends ConsumerWidget {
  const _VitalesEnLinea({required this.patientId});

  final String patientId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final vitales = ref.watch(vitalesDePacienteProvider(patientId));
    final conDatos =
        vitales.valueOrNull?.where((v) => v.hasData).toList() ?? const [];
    if (conDatos.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Wrap(
        spacing: 14,
        runSpacing: 6,
        children: [
          for (final v in conDatos) _ValorSuelto(vital: v),
        ],
      ),
    );
  }
}

class _ValorSuelto extends StatelessWidget {
  const _ValorSuelto({required this.vital});

  final health.LatestVital vital;

  @override
  Widget build(BuildContext context) {
    final fuera = !vital.inRange;
    final color = fuera ? AppColors.statusAttention : AppColors.textPrimary;
    return Semantics(
      label: '${vital.type.label}: ${_numero(vital.value)} '
          '${vital.type.unit}${fuera ? ', fuera de rango' : ''}',
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(vital.type.icon,
              size: 15,
              color: fuera ? AppColors.statusAttention : AppColors.primary),
          const SizedBox(width: 4),
          Text(
            '${_numero(vital.value)} ${vital.type.unit}',
            style: TextStyle(
              fontSize: 13,
              fontWeight: fuera ? FontWeight.w800 : FontWeight.w600,
              color: color,
            ),
          ),
          if (fuera) ...[
            const SizedBox(width: 3),
            const Icon(Icons.error_rounded,
                size: 14, color: AppColors.statusAttention),
          ],
        ],
      ),
    );
  }

  /// La temperatura necesita su decimal; el resto no.
  static String _numero(double v) =>
      v == v.roundToDouble() ? v.round().toString() : v.toStringAsFixed(1);
}
