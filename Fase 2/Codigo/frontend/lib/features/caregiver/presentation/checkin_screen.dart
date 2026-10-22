import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/config/app_config.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/common.dart';
import '../application/caregiver_providers.dart';
import '../data/caregiver_repository.dart';
import '../domain/models.dart';

/// Confirmación de check-in / check-out del turno.
class CheckinScreen extends ConsumerStatefulWidget {
  const CheckinScreen({super.key, required this.patientId});

  final String patientId;

  @override
  ConsumerState<CheckinScreen> createState() => _CheckinScreenState();
}

class _CheckinScreenState extends ConsumerState<CheckinScreen> {
  bool _saving = false;

  Future<void> _submit(ShiftStatus current) async {
    setState(() => _saving = true);
    final type = current.nextCheckinType;
    try {
      await ref
          .read(caregiverRepositoryProvider)
          .checkin(widget.patientId, type: type);
      ref.invalidate(caregiverTodayProvider);
      if (mounted) {
        showAppSnackBar(
          context,
          type == 'in' ? 'Turno iniciado. ¡Buen trabajo!' : 'Turno finalizado.',
        );
        context.pop();
      }
    } catch (e) {
      if (mounted) showAppSnackBar(context, e.toString(), error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!AppConfig.hasCaregiverLog) {
      return Scaffold(
        appBar: AppBar(title: const Text('Check-in')),
        body: const ComingSoonView(
          icon: Icons.how_to_reg_rounded,
          title: 'Check-in de turno',
          subtitle: 'La bitácora de la cuidadora estará disponible pronto.',
        ),
      );
    }
    final todayAsync = ref.watch(caregiverTodayProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Registro de turno')),
      body: todayAsync.when(
        loading: () => const LoadingView(),
        error: (e, _) => ErrorView(
          message: e.toString(),
          onRetry: () => ref.invalidate(caregiverTodayProvider),
        ),
        data: (today) {
          final current = today.shiftStatus;
          final entering = !current.isCheckedIn;
          return Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                AppCard(
                  child: Column(
                    children: [
                      Icon(current.icon, size: 48, color: current.color),
                      const SizedBox(height: 12),
                      Text(
                        'Estado actual: ${current.label}',
                        style: const TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Paciente: ${today.patientName}',
                        style: const TextStyle(color: AppColors.textSecondary),
                      ),
                    ],
                  ),
                ),
                const Spacer(),
                Text(
                  entering
                      ? '¿Comenzar tu turno ahora?'
                      : '¿Finalizar tu turno ahora?',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 24),
                SizedBox(
                  height: 72,
                  child: FilledButton.icon(
                    onPressed: _saving ? null : () => _submit(current),
                    style: FilledButton.styleFrom(
                      backgroundColor:
                          entering ? AppColors.statusOk : AppColors.primary,
                      textStyle: const TextStyle(
                          fontSize: 20, fontWeight: FontWeight.w700),
                    ),
                    icon: _saving
                        ? const SizedBox(
                            height: 24,
                            width: 24,
                            child: CircularProgressIndicator(
                                strokeWidth: 2.5, color: Colors.white),
                          )
                        : Icon(entering
                            ? Icons.login_rounded
                            : Icons.logout_rounded),
                    label: Text(entering ? 'Check-in' : 'Check-out'),
                  ),
                ),
                const SizedBox(height: 32),
              ],
            ),
          );
        },
      ),
    );
  }
}
