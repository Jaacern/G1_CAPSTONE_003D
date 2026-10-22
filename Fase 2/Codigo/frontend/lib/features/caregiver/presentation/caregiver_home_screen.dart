import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/common.dart';
import '../../auth/application/auth_controller.dart';
import '../../home/application/home_providers.dart';
import '../../medications/presentation/medications_screen.dart';
import '../../patients/application/patients_providers.dart';

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
    final user = ref.watch(currentUserProvider);
    final patient = ref.watch(selectedPatientProvider);
    final summary = ref.watch(todaySummaryProvider);
    final firstName =
        (user?.fullName ?? '').trim().split(RegExp(r'\s+')).first;

    if (patient == null) {
      return const EmptyView(
        icon: Icons.person_search_rounded,
        title: 'Sin paciente asignado',
        subtitle: 'Cuando te asignen un paciente, lo verás aquí.',
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(firstName.isEmpty ? 'Hoy' : 'Hola, $firstName'),
      ),
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
                                    fontSize: 16,
                                    fontWeight: FontWeight.w700)),
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
