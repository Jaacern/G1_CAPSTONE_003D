import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/common.dart';
import '../../patients/application/patients_providers.dart';
import '../data/medications_repository.dart';
import '../domain/models.dart';
import 'dose_actions.dart';

/// Carga la dosis (de las de hoy del paciente seleccionado) por su id.
final _doseByIdProvider =
    FutureProvider.autoDispose.family<Dose?, String>((ref, doseId) async {
  final patient = ref.watch(selectedPatientProvider);
  if (patient == null) return null;
  final doses = await ref
      .watch(medicationsRepositoryProvider)
      .listDoses(patient.patientId, date: DateTime.now());
  for (final d in doses) {
    if (d.id == doseId) return d;
  }
  return null;
});

/// Pantalla a la que se llega desde la alarma de medicación (ticket AGE-403).
/// Diseño accesible: botones grandes de "Confirmar toma" / "Posponer" /
/// "No la tomé".
class DoseConfirmScreen extends ConsumerWidget {
  const DoseConfirmScreen({super.key, required this.doseId});

  final String doseId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dose = ref.watch(_doseByIdProvider(doseId));

    return Scaffold(
      appBar: AppBar(title: const Text('Recordatorio')),
      body: dose.when(
        loading: () => const LoadingView(),
        error: (e, _) => ErrorView(
            message: e.toString(),
            onRetry: () => ref.invalidate(_doseByIdProvider(doseId))),
        data: (d) {
          if (d == null) {
            return const EmptyView(
                icon: Icons.medication_rounded,
                title: 'Dosis no encontrada',
                subtitle: 'Puede que ya la hayas registrado.');
          }
          return _DoseConfirmBody(dose: d);
        },
      ),
    );
  }
}

class _DoseConfirmBody extends ConsumerStatefulWidget {
  const _DoseConfirmBody({required this.dose});
  final Dose dose;

  @override
  ConsumerState<_DoseConfirmBody> createState() => _DoseConfirmBodyState();
}

class _DoseConfirmBodyState extends ConsumerState<_DoseConfirmBody> {
  bool _busy = false;

  Future<void> _log(DoseStatus status) async {
    setState(() => _busy = true);
    final registrado = await registrarDosis(
        context: context, ref: ref, dose: widget.dose, status: status);
    if (!mounted) return;
    setState(() => _busy = false);
    if (registrado) context.pop();
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.dose;
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Spacer(),
          Center(
            child: Container(
              width: 96,
              height: 96,
              decoration: BoxDecoration(
                color: AppColors.primary.withValues(alpha: .1),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.medication_rounded,
                  size: 52, color: AppColors.primary),
            ),
          ),
          const SizedBox(height: 24),
          const Text('Hora de tu medicamento',
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 18,
                  color: AppColors.textSecondary,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          Text(d.medicationName,
              textAlign: TextAlign.center,
              style:
                  const TextStyle(fontSize: 30, fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          Text(
            '${d.dose != null ? '${d.dose} ${d.unit ?? ''} · '.trim() : ''}${d.timeLabel}',
            textAlign: TextAlign.center,
            style:
                const TextStyle(fontSize: 20, color: AppColors.textSecondary),
          ),
          const Spacer(),
          FilledButton.icon(
            onPressed: _busy ? null : () => _log(DoseStatus.taken),
            icon: const Icon(Icons.check_rounded, size: 28),
            label: const Text('Confirmar toma',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.statusOk,
              minimumSize: const Size.fromHeight(72),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _busy ? null : () => _log(DoseStatus.postponed),
                  icon: const Icon(Icons.schedule_rounded, size: 26),
                  label: const Text('Posponer',
                      style:
                          TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(64),
                    foregroundColor: AppColors.textPrimary,
                    side:
                        const BorderSide(color: AppColors.divider, width: 1.5),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _busy ? null : () => _log(DoseStatus.missed),
                  icon: const Icon(Icons.close_rounded, size: 26),
                  label: const Text('No la tomé',
                      style:
                          TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(64),
                    foregroundColor: AppColors.statusAttention,
                    side: const BorderSide(
                        color: AppColors.statusAttention, width: 1.5),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}
