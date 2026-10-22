import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/common.dart';
import '../../auth/application/auth_controller.dart';
import '../application/caregiver_providers.dart';
import '../data/caregiver_repository.dart';
import '../domain/models.dart';

/// Pantalla "Hoy" de la cuidadora: turno, resumen del paciente,
/// tareas pendientes y accesos rápidos a la bitácora.
class CaregiverTodayScreen extends ConsumerWidget {
  const CaregiverTodayScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final todayAsync = ref.watch(caregiverTodayProvider);
    final user = ref.watch(currentUserProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text('Hola${user != null ? ', ${user.fullName.split(' ').first}' : ''}'),
      ),
      body: todayAsync.when(
        loading: () => const LoadingView(),
        error: (e, _) => ErrorView(
          message: e.toString(),
          onRetry: () => ref.invalidate(caregiverTodayProvider),
        ),
        data: (today) => RefreshIndicator(
          onRefresh: () async => ref.invalidate(caregiverTodayProvider),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
            children: [
              _ShiftCard(today: today),
              const SizedBox(height: 16),
              _PatientSummary(today: today),
              const SizedBox(height: 16),
              _QuickActions(patientId: today.patientId),
              const SizedBox(height: 20),
              Text('Tareas de hoy',
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              if (today.pendingTasks.isEmpty)
                const AppCard(
                  child: Row(
                    children: [
                      Icon(Icons.check_circle_rounded,
                          color: AppColors.statusOk),
                      SizedBox(width: 12),
                      Expanded(
                        child: Text('¡Todas las tareas están completadas!'),
                      ),
                    ],
                  ),
                )
              else
                for (final task in today.pendingTasks)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: _TaskTile(task: task),
                  ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ShiftCard extends StatelessWidget {
  const _ShiftCard({required this.today});

  final CaregiverToday today;

  @override
  Widget build(BuildContext context) {
    final status = today.shiftStatus;
    final entering = !status.isCheckedIn;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(status.icon, color: status.color),
              const SizedBox(width: 8),
              Text(status.label,
                  style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 16,
                      color: status.color)),
              const Spacer(),
              Text(DateFormat('EEEE d MMM', 'es').format(DateTime.now()),
                  style: const TextStyle(color: AppColors.textSecondary)),
            ],
          ),
          const SizedBox(height: 14),
          SizedBox(
            height: 60,
            child: FilledButton.icon(
              onPressed: () =>
                  context.push('/cg/checkin?patient=${today.patientId}'),
              style: FilledButton.styleFrom(
                backgroundColor:
                    entering ? AppColors.statusOk : AppColors.primary,
                textStyle:
                    const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
              ),
              icon: Icon(
                  entering ? Icons.login_rounded : Icons.logout_rounded,
                  size: 26),
              label: Text(entering ? 'Check-in' : 'Check-out'),
            ),
          ),
        ],
      ),
    );
  }
}

class _PatientSummary extends StatelessWidget {
  const _PatientSummary({required this.today});

  final CaregiverToday today;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              InitialsAvatar(name: today.patientName, radius: 24),
              const SizedBox(width: 12),
              Expanded(
                child: Text(today.patientName,
                    style: const TextStyle(
                        fontSize: 17, fontWeight: FontWeight.w700)),
              ),
              WellbeingChip(status: today.wellbeingStatus),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              _Metric(
                  icon: Icons.checklist_rounded,
                  value: '${today.pendingTasks.length}',
                  label: 'Pendientes'),
              _Metric(
                  icon: Icons.notes_rounded,
                  value: '${today.observationsCount}',
                  label: 'Observaciones'),
              if (today.adherencePct != null)
                _Metric(
                    icon: Icons.medication_rounded,
                    value: '${today.adherencePct!.round()}%',
                    label: 'Adherencia'),
              if (today.alertsCount > 0)
                _Metric(
                    icon: Icons.warning_rounded,
                    value: '${today.alertsCount}',
                    label: 'Alertas',
                    color: AppColors.statusAttention),
            ],
          ),
        ],
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({
    required this.icon,
    required this.value,
    required this.label,
    this.color = AppColors.primary,
  });

  final IconData icon;
  final String value;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        children: [
          Icon(icon, color: color, size: 22),
          const SizedBox(height: 4),
          Text(value,
              style:
                  const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          Text(label,
              textAlign: TextAlign.center,
              style: const TextStyle(
                  fontSize: 11, color: AppColors.textSecondary)),
        ],
      ),
    );
  }
}

class _QuickActions extends StatelessWidget {
  const _QuickActions({required this.patientId});

  final String patientId;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        _ActionButton(
          icon: Icons.edit_note_rounded,
          label: 'Observación',
          color: AppColors.primary,
          onTap: () => context.push('/cg/observation?patient=$patientId'),
        ),
        const SizedBox(width: 10),
        _ActionButton(
          icon: Icons.report_gmailerrorred_rounded,
          label: 'Incidente',
          color: AppColors.statusAttention,
          onTap: () => context.push('/cg/incident?patient=$patientId'),
        ),
        const SizedBox(width: 10),
        _ActionButton(
          icon: Icons.swap_horiz_rounded,
          label: 'Relevo',
          color: AppColors.secondary,
          onTap: () => context.push('/cg/handover?patient=$patientId'),
        ),
      ],
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
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
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 16),
          decoration: BoxDecoration(
            color: color.withOpacity(.10),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            children: [
              Icon(icon, color: color, size: 28),
              const SizedBox(height: 6),
              Text(label,
                  style: TextStyle(
                      color: color,
                      fontWeight: FontWeight.w700,
                      fontSize: 12)),
            ],
          ),
        ),
      ),
    );
  }
}

class _TaskTile extends ConsumerStatefulWidget {
  const _TaskTile({required this.task});

  final CareTask task;

  @override
  ConsumerState<_TaskTile> createState() => _TaskTileState();
}

class _TaskTileState extends ConsumerState<_TaskTile> {
  bool _busy = false;

  Future<void> _advance() async {
    // Ciclo pendiente -> en curso -> completada.
    final next = switch (widget.task.status) {
      TaskStatus.pending => TaskStatus.inProgress,
      TaskStatus.inProgress => TaskStatus.done,
      TaskStatus.done => TaskStatus.pending,
    };
    setState(() => _busy = true);
    try {
      await ref
          .read(caregiverRepositoryProvider)
          .setTaskStatus(widget.task.id, next);
      ref.invalidate(caregiverTodayProvider);
      ref.invalidate(patientTasksProvider);
    } catch (e) {
      if (mounted) showAppSnackBar(context, e.toString(), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final task = widget.task;
    return AppCard(
      onTap: _busy ? null : _advance,
      child: Row(
        children: [
          _busy
              ? const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Icon(
                  task.status == TaskStatus.done
                      ? Icons.check_circle_rounded
                      : task.status == TaskStatus.inProgress
                          ? Icons.timelapse_rounded
                          : Icons.radio_button_unchecked_rounded,
                  color: task.status.color,
                ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(task.title,
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text('${task.timeLabel} · ${task.status.label}',
                    style: TextStyle(
                        fontSize: 12, color: task.status.color)),
              ],
            ),
          ),
          const Icon(Icons.chevron_right_rounded,
              color: AppColors.textSecondary),
        ],
      ),
    );
  }
}
