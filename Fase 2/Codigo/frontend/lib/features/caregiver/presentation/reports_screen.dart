import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/config/app_config.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/common.dart';
import '../application/caregiver_providers.dart';
import '../domain/models.dart';

/// "Mi desempeño" de la cuidadora (RF-74), con el rango que permite su plan.
///
/// Los últimos 7 días son gratis. 30 y 90 días son Premium (RF-73): el
/// servidor los niega con 402 a un plan gratuito, y aquí se muestran con
/// candado y llevan a la suscripción en vez de fallar.
class CaregiverReportsScreen extends ConsumerStatefulWidget {
  const CaregiverReportsScreen({super.key});

  @override
  ConsumerState<CaregiverReportsScreen> createState() =>
      _CaregiverReportsScreenState();
}

class _CaregiverReportsScreenState
    extends ConsumerState<CaregiverReportsScreen> {
  int _days = 7;

  @override
  Widget build(BuildContext context) {
    if (!AppConfig.hasCaregiverLog) {
      return Scaffold(
        appBar: AppBar(title: const Text('Reportes')),
        body: const ComingSoonView(
          icon: Icons.insights_rounded,
          title: 'Reportes de cuidado',
          subtitle: 'La bitácora de la cuidadora estará disponible pronto.',
        ),
      );
    }
    final planAsync = ref.watch(caregiverPlanProvider);
    // Mientras se sabe el plan se asume gratuito: así nunca se pide un rango
    // que el servidor va a negar.
    final isFree = planAsync.valueOrNull?.tier.isFree ?? true;
    final dias = isFree ? 7 : _days;
    final reportAsync = ref.watch(caregiverReportProvider(dias));

    return Scaffold(
      appBar: AppBar(title: const Text('Mi desempeño')),
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(caregiverReportProvider(dias));
          ref.invalidate(caregiverPlanProvider);
        },
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
          children: [
            _SelectorRango(
              dias: dias,
              bloqueado: isFree,
              onElegir: (d) => setState(() => _days = d),
            ),
            const SizedBox(height: 12),
            reportAsync.when(
              loading: () =>
                  const SizedBox(height: 260, child: LoadingView()),
              error: (e, _) => ErrorView(
                message: e.toString(),
                onRetry: () => ref.invalidate(caregiverReportProvider(dias)),
              ),
              data: (report) => Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(report.period,
                      style: const TextStyle(color: AppColors.textSecondary)),
                  const SizedBox(height: 12),
                  _MetricsGrid(report: report),
                  const SizedBox(height: 20),
                  Text(
                      report.days > 30
                          ? 'Tareas completadas por semana'
                          : 'Tareas completadas por día',
                      style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 12),
                  AppCard(
                    child: SizedBox(
                      height: 200,
                      child: _TasksChart(points: report.weeklyTasks),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            if (isFree) _PremiumUpsell(),
          ],
        ),
      ),
    );
  }
}

/// 7 / 30 / 90 días. En el plan gratuito, 30 y 90 llevan candado y abren
/// la suscripción.
class _SelectorRango extends StatelessWidget {
  const _SelectorRango({
    required this.dias,
    required this.bloqueado,
    required this.onElegir,
  });

  final int dias;
  final bool bloqueado;
  final ValueChanged<int> onElegir;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      children: [
        for (final d in const [7, 30, 90])
          ChoiceChip(
            avatar: bloqueado && d > 7
                ? const Icon(Icons.lock_outline_rounded, size: 16)
                : null,
            label: Text('$d días'),
            selected: dias == d,
            tooltip: bloqueado && d > 7 ? 'Disponible con Premium' : null,
            onSelected: (_) {
              if (bloqueado && d > 7) {
                context.push('/premium');
              } else {
                onElegir(d);
              }
            },
          ),
      ],
    );
  }
}

class _MetricsGrid extends StatelessWidget {
  const _MetricsGrid({required this.report});

  final CaregiverReport report;

  @override
  Widget build(BuildContext context) {
    final metrics = [
      _MetricData(Icons.check_circle_rounded, '${report.tasksCompleted}',
          'Tareas completadas', AppColors.statusOk),
      _MetricData(Icons.schedule_rounded, '${report.punctualityPct.round()}%',
          'Puntualidad', AppColors.primary),
      _MetricData(Icons.login_rounded, '${report.checkinsOnTime}',
          'Check-ins a tiempo', AppColors.secondary),
      _MetricData(Icons.edit_note_rounded, '${report.observationsLogged}',
          'Observaciones', AppColors.statusWarning),
    ];
    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      crossAxisSpacing: 12,
      mainAxisSpacing: 12,
      childAspectRatio: 1.5,
      children: [for (final m in metrics) _MetricCard(data: m)],
    );
  }
}

class _MetricData {
  const _MetricData(this.icon, this.value, this.label, this.color);
  final IconData icon;
  final String value;
  final String label;
  final Color color;
}

class _MetricCard extends StatelessWidget {
  const _MetricCard({required this.data});

  final _MetricData data;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(data.icon, color: data.color, size: 26),
          const SizedBox(height: 8),
          Text(data.value,
              style:
                  const TextStyle(fontSize: 24, fontWeight: FontWeight.w700)),
          const SizedBox(height: 2),
          Text(data.label,
              style: const TextStyle(
                  fontSize: 12, color: AppColors.textSecondary)),
        ],
      ),
    );
  }
}

class _TasksChart extends StatelessWidget {
  const _TasksChart({required this.points});

  final List<ReportPoint> points;

  @override
  Widget build(BuildContext context) {
    if (points.isEmpty) {
      return const Center(
        child: Text('Sin datos para este periodo',
            style: TextStyle(color: AppColors.textSecondary)),
      );
    }
    final maxY = points.map((p) => p.value).reduce((a, b) => a > b ? a : b);
    // Con 30 barras no caben 30 etiquetas: se muestra una cada tantas,
    // siempre la de hoy (la última).
    final cada = points.length > 14 ? (points.length / 6).ceil() : 1;
    final ancho = points.length > 14 ? 6.0 : 14.0;
    return BarChart(
      BarChartData(
        minY: 0,
        maxY: (maxY + 1).ceilToDouble(),
        alignment: BarChartAlignment.spaceAround,
        gridData: FlGridData(
          show: true,
          drawVerticalLine: false,
          getDrawingHorizontalLine: (v) =>
              const FlLine(color: AppColors.divider, strokeWidth: 1),
        ),
        borderData: FlBorderData(show: false),
        titlesData: FlTitlesData(
          topTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          leftTitles: const AxisTitles(
            sideTitles: SideTitles(showTitles: true, reservedSize: 28),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 24,
              getTitlesWidget: (value, meta) {
                final i = value.toInt();
                if (i < 0 || i >= points.length) {
                  return const SizedBox.shrink();
                }
                if ((points.length - 1 - i) % cada != 0) {
                  return const SizedBox.shrink();
                }
                return Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(points[i].label,
                      style: const TextStyle(
                          fontSize: 10, color: AppColors.textSecondary)),
                );
              },
            ),
          ),
        ),
        barGroups: [
          for (var i = 0; i < points.length; i++)
            BarChartGroupData(x: i, barRods: [
              BarChartRodData(
                toY: points[i].value,
                width: ancho,
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(4)),
                color: AppColors.primary,
              ),
            ]),
        ],
      ),
    );
  }
}

class _PremiumUpsell extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return AppCard(
      onTap: () => context.push('/premium'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppColors.statusWarning.withValues(alpha: .15),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(Icons.workspace_premium_rounded,
                    color: AppColors.statusWarning),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Text('Mira tu desempeño de 30 y 90 días con Premium',
                    style:
                        TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              ),
            ],
          ),
          const SizedBox(height: 10),
          const Text(
            'Con el plan gratuito ves tus últimos 7 días. Con Premium ves '
            'también el último mes y los últimos tres meses.',
            style: TextStyle(color: AppColors.textSecondary),
          ),
          const SizedBox(height: 14),
          FilledButton.icon(
            onPressed: () => context.push('/premium'),
            style: FilledButton.styleFrom(
                backgroundColor: AppColors.statusWarning),
            icon: const Icon(Icons.arrow_forward_rounded),
            label: const Text('Ver planes Premium'),
          ),
        ],
      ),
    );
  }
}
