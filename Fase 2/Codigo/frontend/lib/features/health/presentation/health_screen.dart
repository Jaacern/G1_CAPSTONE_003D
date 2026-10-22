import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart' hide Threshold;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../core/config/app_config.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/common.dart';
import '../../medications/presentation/medications_screen.dart';
import '../../patients/application/patients_providers.dart';
import '../application/health_providers.dart';
import '../domain/models.dart';

/// Pantalla Salud con sub-pestañas (fiel al wireframe Suite/Familiar v1):
/// Vitales · Medicinas. Las medicinas se muestran embebidas, reutilizando
/// [MedicationsBody] (mismo contrato de backend, sin Scaffold anidado).
class HealthScreen extends ConsumerWidget {
  const HealthScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final patient = ref.watch(selectedPatientProvider);

    if (patient == null) {
      return const EmptyView(
          icon: Icons.monitor_heart_outlined,
          title: 'Sin paciente seleccionado',
          subtitle: 'Crea o selecciona un paciente para ver su salud.');
    }

    // Sub-pestañas fieles al wireframe: Vitals · Medicinas · Bitácora · Docs.
    // Bitácora no tiene backend aún (Próximamente). Docs solo si hasDocuments.
    final showDocs = AppConfig.hasDocuments;
    final tabs = <Tab>[
      const Tab(text: 'Vitals', icon: Text('❤️', style: TextStyle(fontSize: 18))),
      const Tab(text: 'Medicinas', icon: Text('💊', style: TextStyle(fontSize: 18))),
      const Tab(text: 'Bitácora', icon: Text('📝', style: TextStyle(fontSize: 18))),
      if (showDocs)
        const Tab(text: 'Docs', icon: Text('📄', style: TextStyle(fontSize: 18))),
    ];

    return DefaultTabController(
      length: tabs.length,
      child: Column(
        children: [
          Material(
            color: AppColors.surface,
            child: TabBar(
              isScrollable: true,
              labelColor: AppColors.primary,
              unselectedLabelColor: AppColors.textSecondary,
              indicatorColor: AppColors.primary,
              tabs: tabs,
            ),
          ),
          Expanded(
            child: TabBarView(
              children: [
                const _VitalsTab(),
                const MedicationsBody(),
                const _BitacoraTab(),
                if (showDocs) const _DocsTab(),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Bitácora / observaciones de la cuidadora. Sin backend todavía.
/// PENDIENTE BACKEND: tabla `observations` + GET /patients/{id}/observations.
class _BitacoraTab extends StatelessWidget {
  const _BitacoraTab();

  @override
  Widget build(BuildContext context) {
    return const ComingSoonView(
      icon: Icons.edit_note_rounded,
      title: 'Bitácora de cuidado',
      subtitle:
          'Aquí verás las observaciones de la cuidadora (ánimo, apetito, '
          'sueño, notas y fotos) y el check-in del paciente.',
    );
  }
}

/// Documentos del paciente embebidos en Salud. Solo si el backend los soporta.
class _DocsTab extends ConsumerWidget {
  const _DocsTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final patient = ref.watch(selectedPatientProvider);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: FilledButton.icon(
          onPressed: () => context.push(
              '/documents?patient=${patient?.patientId ?? ''}'),
          icon: const Icon(Icons.folder_open_rounded),
          label: const Text('Abrir expediente'),
        ),
      ),
    );
  }
}

/// Contenido de la sub-pestaña "Vitales": estado del wearable + tarjetas de
/// signos vitales con acceso al detalle de tendencias.
class _VitalsTab extends ConsumerWidget {
  const _VitalsTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final latest = ref.watch(latestVitalsProvider);
    final detail = ref.watch(selectedPatientDetailProvider);

    return RefreshIndicator(
      onRefresh: () async => refreshVitalsViews(ref.invalidate),
      child: latest.when(
        loading: () => const LoadingView(),
        error: (e, _) => ErrorView(
            message: e.toString(),
            onRetry: () => ref.invalidate(latestVitalsProvider)),
        data: (vitals) => ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // Estado del wearable (ticket AGE-306, criterio de visibilidad de sync)
            detail.maybeWhen(
              data: (p) => p?.wearable != null
                  ? _WearableStatusCard(
                      lastSync: p!.wearable!.lastSyncAt,
                      battery: p.wearable!.batteryPct,
                      isStale: p.wearable!.isStale,
                    )
                  : const _WearableLinkCard(),
              orElse: () => const SizedBox.shrink(),
            ),
            // Fila: interruptor "En vivo" (auto-refresco) + sincronizar reloj.
            Row(
              children: [
                const _LiveToggle(),
                const Spacer(),
                IconButton(
                  tooltip: 'Rangos de alerta',
                  onPressed: () => context.push('/health/thresholds'),
                  icon: const Icon(Icons.tune_rounded, size: 20),
                ),
                TextButton.icon(
                  onPressed: () {
                    final p = ref.read(selectedPatientProvider);
                    if (p != null) {
                      context.push('/wearable/link/${p.patientId}');
                    }
                  },
                  icon: const Text('⌚'),
                  label: const Text('Sincronizar reloj'),
                ),
              ],
            ),
            const SizedBox(height: 4),
            // Mostramos TODOS los vitales esperados (transparencia: no
            // escondemos un signo solo porque hoy no llegó dato). Los que el
            // backend ya tiene muestran su valor; el resto, "sin datos aún".
            ...() {
              final byType = {for (final v in vitals) v.type: v};
              final cards = [
                for (final t in VitalType.expected)
                  byType[t] ?? LatestVital.empty(t),
              ];
              return [
                _VitalGroup(
                  title: 'Vitales',
                  vitals: cards.where((v) => v.type.isCoreVital).toList(),
                ),
                _VitalGroup(
                  title: 'Actividad',
                  vitals: cards.where((v) => !v.type.isCoreVital).toList(),
                ),
              ];
            }(),
          ],
        ),
      ),
    );
  }
}

/// Interruptor "En vivo": activa el auto-refresco que sondea el backend cada
/// pocos segundos, para que las lecturas que sube el reloj aparezcan solas sin
/// arrastrar para refrescar. Muestra cuándo fue la última actualización.
class _LiveToggle extends ConsumerWidget {
  const _LiveToggle();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final live = ref.watch(liveControllerProvider);
    final color = live.enabled ? AppColors.statusOk : AppColors.textSecondary;
    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: () => ref.read(liveControllerProvider.notifier).toggle(),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              live.enabled
                  ? Icons.sensors_rounded
                  : Icons.sensors_off_rounded,
              size: 18,
              color: color,
            ),
            const SizedBox(width: 6),
            Text(
              live.enabled ? 'En vivo' : 'En vivo (off)',
              style: TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w700, color: color),
            ),
            if (live.enabled && live.lastRefresh != null) ...[
              const SizedBox(width: 6),
              Text(
                '· ${DateFormat('HH:mm:ss').format(live.lastRefresh!)}',
                style: const TextStyle(
                    fontSize: 11, color: AppColors.textSecondary),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Grupo de tarjetas de vitals con encabezado (AGE-304 / DAC05-60).
/// No se dibuja si no hay vitals de ese grupo para el paciente.
class _VitalGroup extends StatelessWidget {
  const _VitalGroup({required this.title, required this.vitals});

  final String title;
  final List<LatestVital> vitals;

  @override
  Widget build(BuildContext context) {
    if (vitals.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          ...vitals.map((v) => Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: _VitalCard(vital: v),
              )),
        ],
      ),
    );
  }
}

class _VitalCard extends ConsumerWidget {
  const _VitalCard({required this.vital});

  final LatestVital vital;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Tarjeta "sin datos aún": no navega ni muestra sparkline (transparencia).
    if (!vital.hasData) return _EmptyVitalCard(type: vital.type);

    final color = vital.inRange ? AppColors.primary : AppColors.statusAttention;
    final spark = ref.watch(sparkSeriesProvider(vital.type));
    return AppCard(
      onTap: () => context.push('/health/vital/${vital.type.apiValue}'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              // Emoji del vital (fiel al wireframe).
              Text(vital.type.emoji, style: const TextStyle(fontSize: 24)),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(vital.type.label,
                        style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            color: AppColors.textSecondary)),
                    const SizedBox(height: 2),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(vital.displayValue,
                            style: TextStyle(
                                fontSize: 26,
                                fontWeight: FontWeight.w800,
                                color: color)),
                        const SizedBox(width: 4),
                        Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: Text(vital.type.unit,
                              style: const TextStyle(
                                  color: AppColors.textSecondary)),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              if (!vital.inRange)
                const Padding(
                  padding: EdgeInsets.only(right: 4),
                  child: Icon(Icons.error_rounded,
                      color: AppColors.statusAttention),
                ),
              const Icon(Icons.chevron_right_rounded,
                  color: AppColors.textSecondary),
            ],
          ),
          // Sparkline de los últimos 7 días (datos reales del backend).
          spark.maybeWhen(
            data: (series) {
              final pts = series?.points ?? const [];
              if (pts.length < 2) return const SizedBox.shrink();
              return Padding(
                padding: const EdgeInsets.only(top: 10),
                child: SizedBox(
                  height: 34,
                  child: _Sparkline(
                    values: pts.map((p) => p.value).toList(),
                    color: color,
                  ),
                ),
              );
            },
            orElse: () => const SizedBox.shrink(),
          ),
          // Rango/umbral, como "Rango 55–95 lpm" del wireframe.
          spark.maybeWhen(
            data: (series) {
              final th = series?.threshold;
              if (th == null || (th.minValue == null && th.maxValue == null)) {
                return const SizedBox.shrink();
              }
              final txt = th.minValue != null && th.maxValue != null
                  ? 'Rango ${_n(th.minValue!)}–${_n(th.maxValue!)} ${vital.type.unit}'
                  : th.minValue != null
                      ? 'Mínimo ${_n(th.minValue!)} ${vital.type.unit}'
                      : 'Máximo ${_n(th.maxValue!)} ${vital.type.unit}';
              return Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(txt,
                    style: const TextStyle(
                        fontSize: 11, color: AppColors.textSecondary)),
              );
            },
            orElse: () => const SizedBox.shrink(),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Row(
              children: [
                // Etiqueta de ORIGEN del dato (transparencia: nada oculto).
                _SourceChip(source: vital.source),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Última lectura ${DateFormat('HH:mm').format(vital.measuredAt.toLocal())}',
                    style: const TextStyle(
                        fontSize: 12, color: AppColors.textSecondary),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static String _n(double v) =>
      v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(1);
}

/// Tarjeta tenue para un vital que el backend soporta pero que aún no tiene
/// lecturas. Se muestra (no se oculta) para dejar claro qué mide la plataforma
/// y de qué fuente podría venir cada signo.
class _EmptyVitalCard extends StatelessWidget {
  const _EmptyVitalCard({required this.type});
  final VitalType type;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      child: Row(
        children: [
          Opacity(
            opacity: .5,
            child: Text(type.emoji, style: const TextStyle(fontSize: 24)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(type.label,
                    style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        color: AppColors.textSecondary)),
                const SizedBox(height: 2),
                const Text('Sin datos aún',
                    style:
                        TextStyle(fontSize: 13, color: AppColors.textSecondary)),
              ],
            ),
          ),
          const Icon(Icons.hourglass_empty_rounded,
              size: 18, color: AppColors.textSecondary),
        ],
      ),
    );
  }
}

/// Chip pequeño que muestra de dónde viene el dato (reloj / Samsung Health /
/// prueba). Hace visible el origen sin ocultar nada.
class _SourceChip extends StatelessWidget {
  const _SourceChip({required this.source});
  final VitalSource source;

  @override
  Widget build(BuildContext context) {
    final color = switch (source) {
      VitalSource.watch => AppColors.statusAttention,
      VitalSource.healthConnect => AppColors.primary,
      VitalSource.simulator => AppColors.statusWarning,
      _ => AppColors.textSecondary,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withOpacity(.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        '${source.emoji} ${source.label}',
        style: TextStyle(
            fontSize: 10.5, fontWeight: FontWeight.w700, color: color),
      ),
    );
  }
}

/// Sparkline minimalista (línea suave) para tendencias cortas.
class _Sparkline extends StatelessWidget {
  const _Sparkline({required this.values, required this.color});
  final List<double> values;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final spots = [
      for (var i = 0; i < values.length; i++)
        FlSpot(i.toDouble(), values[i]),
    ];
    final minY = values.reduce((a, b) => a < b ? a : b);
    final maxY = values.reduce((a, b) => a > b ? a : b);
    final pad = (maxY - minY) * .2 + 0.5;
    return LineChart(
      LineChartData(
        minY: minY - pad,
        maxY: maxY + pad,
        titlesData: const FlTitlesData(show: false),
        gridData: const FlGridData(show: false),
        borderData: FlBorderData(show: false),
        lineTouchData: const LineTouchData(enabled: false),
        lineBarsData: [
          LineChartBarData(
            spots: spots,
            isCurved: true,
            color: color,
            barWidth: 2,
            dotData: const FlDotData(show: false),
            belowBarData: BarAreaData(
              show: true,
              color: color.withOpacity(.12),
            ),
          ),
        ],
      ),
    );
  }
}

class _WearableStatusCard extends StatelessWidget {
  const _WearableStatusCard({this.lastSync, this.battery, required this.isStale});

  final DateTime? lastSync;
  final int? battery;
  final bool isStale;

  @override
  Widget build(BuildContext context) {
    final color = isStale ? AppColors.statusWarning : AppColors.statusOk;
    final syncText = lastSync == null
        ? 'sin datos'
        : 'hace ${_ago(DateTime.now().difference(lastSync!.toLocal()))}';
    return AppCard(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Icon(Icons.watch_rounded, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              isStale
                  ? 'Wearable sin datos recientes (última sync $syncText)'
                  : 'Wearable sincronizado $syncText',
              style: TextStyle(color: color, fontWeight: FontWeight.w600, fontSize: 13),
            ),
          ),
          if (battery != null) ...[
            Icon(
                battery! > 20
                    ? Icons.battery_std_rounded
                    : Icons.battery_alert_rounded,
                size: 18,
                color: battery! > 20 ? AppColors.textSecondary : AppColors.critical),
            Text('$battery%',
                style: const TextStyle(fontSize: 13, color: AppColors.textSecondary)),
          ],
        ],
      ),
    );
  }

  String _ago(Duration d) {
    if (d.inMinutes < 60) return '${d.inMinutes} min';
    if (d.inHours < 24) return '${d.inHours} h';
    return '${d.inDays} días';
  }
}

class _WearableLinkCard extends StatelessWidget {
  const _WearableLinkCard();

  @override
  Widget build(BuildContext context) {
    return AppCard(
      child: Row(
        children: [
          const Icon(Icons.watch_off_outlined, color: AppColors.textSecondary),
          const SizedBox(width: 10),
          const Expanded(
              child: Text('Sin wearable vinculado',
                  style: TextStyle(color: AppColors.textSecondary))),
          Consumer(
            builder: (context, ref, _) => TextButton(
              onPressed: () {
                final p = ref.read(selectedPatientProvider);
                if (p != null) context.push('/wearable/link/${p.patientId}');
              },
              child: const Text('Vincular'),
            ),
          ),
        ],
      ),
    );
  }
}
