import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/network/api_client.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/common.dart';
import '../application/alerts_providers.dart';
import '../data/alerts_repository.dart';
import '../domain/models.dart';

/// Centro de alertas: lista agrupada por severidad con acciones rápidas.
class AlertsScreen extends ConsumerWidget {
  const AlertsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final alertsAsync = ref.watch(activeAlertsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Centro de alertas')),
      body: RefreshIndicator(
        onRefresh: () async => ref.invalidate(activeAlertsProvider),
        child: alertsAsync.when(
          loading: () => const LoadingView(),
          error: (e, _) => ErrorView(
            message: e is ApiException ? e.message : 'No pudimos cargar las alertas.',
            onRetry: () => ref.invalidate(activeAlertsProvider),
          ),
          data: (alerts) {
            final active = alerts.where((a) => a.isActive).toList();
            if (active.isEmpty) {
              return ListView(
                children: const [
                  SizedBox(height: 80),
                  EmptyView(
                    icon: Icons.verified_rounded,
                    title: 'Todo en orden',
                    subtitle:
                        'No hay alertas activas. Te avisaremos si algo necesita tu atención.',
                  ),
                ],
              );
            }

            final groups = <AlertSeverity, List<Alert>>{};
            for (final a in active) {
              groups.putIfAbsent(a.severity, () => []).add(a);
            }
            const order = [
              AlertSeverity.critical,
              AlertSeverity.warning,
              AlertSeverity.info,
            ];

            return ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              children: [
                for (final sev in order)
                  if (groups[sev]?.isNotEmpty ?? false) ...[
                    _SeverityHeader(severity: sev, count: groups[sev]!.length),
                    const SizedBox(height: 8),
                    ...groups[sev]!.map((a) => Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: _AlertCard(alert: a),
                        )),
                    const SizedBox(height: 8),
                  ],
              ],
            );
          },
        ),
      ),
    );
  }
}

class _SeverityHeader extends StatelessWidget {
  const _SeverityHeader({required this.severity, required this.count});

  final AlertSeverity severity;
  final int count;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(color: severity.color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 8),
        Text(
          severity.label,
          style: TextStyle(
            fontWeight: FontWeight.w800,
            fontSize: 15,
            color: severity.color,
          ),
        ),
        const SizedBox(width: 6),
        Text('($count)',
            style: const TextStyle(color: AppColors.textSecondary, fontSize: 13)),
      ],
    );
  }
}

class _AlertCard extends ConsumerStatefulWidget {
  const _AlertCard({required this.alert});

  final Alert alert;

  @override
  ConsumerState<_AlertCard> createState() => _AlertCardState();
}

class _AlertCardState extends ConsumerState<_AlertCard> {
  bool _busy = false;

  Future<void> _run(Future<void> Function() action, String okMessage) async {
    setState(() => _busy = true);
    try {
      await action();
      ref.invalidate(activeAlertsProvider);
      if (mounted) showAppSnackBar(context, okMessage);
    } on ApiException catch (e) {
      if (mounted) showAppSnackBar(context, e.message, error: true);
    } catch (_) {
      if (mounted) {
        showAppSnackBar(context, 'No se pudo completar la acción.', error: true);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final a = widget.alert;
    final color = a.severity.color;
    final acknowledged = a.status == AlertStatus.acknowledged;
    final repo = ref.read(alertsRepositoryProvider);

    return AppCard(
      onTap: () => context.push('/alerts/${a.id}'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: color.withOpacity(.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(a.type.icon, color: color, size: 24),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(a.title,
                        style: const TextStyle(
                            fontWeight: FontWeight.w700, fontSize: 15)),
                    const SizedBox(height: 2),
                    if (a.patientName.isNotEmpty)
                      Text(a.patientName,
                          style: const TextStyle(
                              color: AppColors.textSecondary, fontSize: 13)),
                  ],
                ),
              ),
              Text(alertTimeAgo(a.createdAt),
                  style: const TextStyle(
                      color: AppColors.textSecondary, fontSize: 12)),
            ],
          ),
          const SizedBox(height: 10),
          Text(a.message,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: AppColors.textSecondary, fontSize: 13)),
          if (acknowledged) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                const Icon(Icons.check_rounded,
                    size: 16, color: AppColors.statusOk),
                const SizedBox(width: 4),
                Text('Reconocida${a.acknowledgedBy != null ? ' por ${a.acknowledgedBy}' : ''}',
                    style: const TextStyle(
                        color: AppColors.statusOk, fontSize: 12)),
              ],
            ),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              if (!acknowledged)
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _busy
                        ? null
                        : () => _run(() => repo.acknowledge(a.id),
                            'Alerta reconocida'),
                    icon: const Icon(Icons.done_rounded, size: 18),
                    label: const Text('Reconocer'),
                  ),
                ),
              if (!acknowledged) const SizedBox(width: 10),
              Expanded(
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: color,
                    minimumSize: const Size.fromHeight(44),
                  ),
                  onPressed: _busy
                      ? null
                      : () => _run(
                          () => repo.resolve(a.id), 'Alerta resuelta'),
                  icon: _busy
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white),
                        )
                      : const Icon(Icons.task_alt_rounded, size: 18),
                  label: const Text('Resolver'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
