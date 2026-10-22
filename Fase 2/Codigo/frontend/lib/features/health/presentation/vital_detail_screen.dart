import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart' hide Threshold;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/common.dart';
import '../../patients/application/patients_providers.dart';
import '../data/vitals_repository.dart';
import '../domain/models.dart';

/// Rango de días seleccionado en el detalle.
final _rangeProvider = StateProvider<int>((ref) => 7);

/// Granularidad con la que se muestra el gráfico. Determina el formato del eje
/// X y de la leyenda/tooltip.
enum _Grain { hour, day, week }

extension _GrainApi on _Grain {
  String get api => switch (this) {
        _Grain.hour => 'hour',
        _Grain.day => 'day',
        _Grain.week => 'week',
      };

  /// Formato del eje X según la granularidad (es_CL implícito por intl).
  String get axisFormat => switch (this) {
        _Grain.hour => 'HH:mm',
        _Grain.day => 'd/M',
        _Grain.week => 'd MMM',
      };

  String get legend => switch (this) {
        _Grain.hour => 'Línea: promedio por hora · banda: rango mín–máx',
        _Grain.day => 'Línea: promedio del día · banda: rango mín–máx',
        _Grain.week => 'Línea: promedio semanal · banda: rango mín–máx',
      };
}

/// Mapea el rango elegido (7/30/90 días) a una granularidad PREDECIBLE:
/// 7 días → por día · 30 días → por día · 90 días → por semana.
/// Así el gráfico es consistente en producción, no "siempre por día".
_Grain _grainForRange(int days) {
  if (days >= 90) return _Grain.week;
  return _Grain.day; // 7 y 30 días
}

/// Serie + la granularidad con la que realmente se graficó, para que el eje y
/// el tooltip se adapten.
class _AdaptiveSeries {
  const _AdaptiveSeries(this.series, {required this.grain});
  final VitalSeries series;
  final _Grain grain;
}

final _seriesProvider =
    FutureProvider.family<_AdaptiveSeries?, VitalType>((ref, type) async {
  final patient = ref.watch(selectedPatientProvider);
  if (patient == null) return null;
  final days = ref.watch(_rangeProvider);
  final repo = ref.watch(vitalsRepositoryProvider);
  final to = DateTime.now();
  final from = to.subtract(Duration(days: days));

  // Granularidad PREDECIBLE según el rango (consistencia en producción).
  final grain = _grainForRange(days);
  final primary = await repo.getSeries(patient.patientId, type,
      from: from, to: to, granularity: grain.api);
  if (primary.points.length >= 2) {
    return _AdaptiveSeries(primary, grain: grain);
  }

  // Fallback SOLO cuando hay tan poco historial que el rango elegido no llena
  // ni 2 puntos (típico: apenas datos de hoy). Mostramos el detalle por hora
  // del periodo para que la curva no sea un punto suelto.
  if (grain != _Grain.hour) {
    final hourly = await repo.getSeries(patient.patientId, type,
        from: from, to: to, granularity: 'hour');
    if (hourly.points.length > primary.points.length) {
      return _AdaptiveSeries(hourly, grain: _Grain.hour);
    }
  }
  return _AdaptiveSeries(primary, grain: grain);
});

/// Detalle de un vital con gráfica de tendencia y umbral (ticket AGE-304).
class VitalDetailScreen extends ConsumerWidget {
  const VitalDetailScreen({super.key, required this.typeApiValue});

  final String typeApiValue;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final type = VitalType.fromApi(typeApiValue);
    final range = ref.watch(_rangeProvider);
    final series = ref.watch(_seriesProvider(type));

    return Scaffold(
      appBar: AppBar(title: Text(type.label)),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: SegmentedButton<int>(
              segments: const [
                ButtonSegment(value: 7, label: Text('7 días')),
                ButtonSegment(value: 30, label: Text('30 días')),
                ButtonSegment(value: 90, label: Text('90 días')),
              ],
              selected: {range},
              onSelectionChanged: (s) =>
                  ref.read(_rangeProvider.notifier).state = s.first,
              showSelectedIcon: false,
            ),
          ),
          Expanded(
            child: series.when(
              loading: () => const LoadingView(),
              error: (e, _) => ErrorView(
                  message: e.toString(),
                  onRetry: () => ref.invalidate(_seriesProvider(type))),
              data: (adaptive) {
                final data = adaptive?.series;
                final grain = adaptive?.grain ?? _grainForRange(range);
                // El fallback por hora se usó si pedimos semana/día pero el
                // backend solo tenía datos de hoy.
                final isFallbackHour =
                    grain == _Grain.hour && _grainForRange(range) != _Grain.hour;
                if (data == null || data.points.isEmpty) {
                  return const EmptyView(
                      icon: Icons.show_chart_rounded,
                      title: 'Sin datos en este rango');
                }
                return Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 24, 24),
                      child: Column(
                        children: [
                          Expanded(
                              child:
                                  _TrendChart(series: data, grain: grain)),
                          if (data.points.any((p) => p.min != null && p.max != null))
                            Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: Text(
                                grain.legend,
                                style: const TextStyle(
                                    fontSize: 12,
                                    color: AppColors.textSecondary),
                              ),
                            ),
                          if (isFallbackHour)
                            const Padding(
                              padding: EdgeInsets.only(top: 4),
                              child: Text(
                                'Aún hay poco historial: se muestra el detalle por hora de hoy.',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                    fontSize: 11,
                                    color: AppColors.textSecondary),
                              ),
                            ),
                          if (data.sources.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 10),
                              child: _SourcesSummary(sources: data.sources),
                            ),
                          if (data.threshold != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Container(
                                      width: 18, height: 3,
                                      color: AppColors.statusAttention),
                                  const SizedBox(width: 6),
                                  Text(
                                    _thresholdLabel(data.threshold!, type),
                                    style: const TextStyle(
                                        fontSize: 12,
                                        color: AppColors.textSecondary),
                                  ),
                                ],
                              ),
                            ),
                        ],
                      ),
                    );
              },
            ),
          ),
        ],
      ),
    );
  }

  String _thresholdLabel(Threshold t, VitalType type) {
    final parts = <String>[];
    if (t.minValue != null) parts.add('mín ${t.minValue!.toStringAsFixed(0)}');
    if (t.maxValue != null) parts.add('máx ${t.maxValue!.toStringAsFixed(0)}');
    return 'Umbral de alerta: ${parts.join(' · ')} ${type.unit}';
  }
}

/// Leyenda de las lineas punteadas de minimo/maximo diario del grafico
/// (AGE-304 / AC: "...mostrando minimos y maximos").
/// Gráfico de tendencia rediseñado: UNA sola línea = promedio por día, con una
/// banda sombreada suave para el rango mín–máx del día (en vez de dos líneas
/// punteadas que confundían). Los umbrales son líneas tenues de referencia.
/// No grafica en tiempo real: muestra la media diaria (tendencia histórica).
class _TrendChart extends StatelessWidget {
  const _TrendChart({required this.series, this.grain = _Grain.day});

  final VitalSeries series;

  /// Determina el formato del eje X (HH:mm / d/M / d MMM) y del tooltip.
  final _Grain grain;

  @override
  Widget build(BuildContext context) {
    final points = series.points;
    final avgSpots = <FlSpot>[
      for (var i = 0; i < points.length; i++) FlSpot(i.toDouble(), points[i].value)
    ];

    // Banda mín–máx como ÁREA sombreada: se dibuja la línea del máximo con su
    // relleno hacia abajo recortado a la línea del mínimo. Más limpia.
    final hasMinMax = points.any((p) => p.min != null && p.max != null);
    final maxSpots = <FlSpot>[
      for (var i = 0; i < points.length; i++)
        FlSpot(i.toDouble(), points[i].max ?? points[i].value)
    ];
    final minSpots = <FlSpot>[
      for (var i = 0; i < points.length; i++)
        FlSpot(i.toDouble(), points[i].min ?? points[i].value)
    ];

    final values = points.map((p) => p.value).toList();
    var minY = values.reduce((a, b) => a < b ? a : b);
    var maxY = values.reduce((a, b) => a > b ? a : b);
    for (final p in points) {
      if (p.min != null && p.min! < minY) minY = p.min!;
      if (p.max != null && p.max! > maxY) maxY = p.max!;
    }
    final t = series.threshold;
    if (t?.minValue != null && t!.minValue! < minY) minY = t.minValue!;
    if (t?.maxValue != null && t!.maxValue! > maxY) maxY = t.maxValue!;
    final pad = (maxY - minY) * .15 + 1;

    return LineChart(
      LineChartData(
        minY: minY - pad,
        maxY: maxY + pad,
        gridData: FlGridData(
          show: true,
          drawVerticalLine: false,
          getDrawingHorizontalLine: (v) =>
              FlLine(color: AppColors.divider.withOpacity(.6), strokeWidth: 1),
        ),
        titlesData: FlTitlesData(
          topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          leftTitles: const AxisTitles(
            sideTitles: SideTitles(showTitles: true, reservedSize: 42),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 28,
              interval: (points.length / 4).ceilToDouble().clamp(1, 999),
              getTitlesWidget: (value, meta) {
                final i = value.toInt();
                if (i < 0 || i >= points.length) return const SizedBox.shrink();
                return Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                      DateFormat(grain.axisFormat).format(points[i].ts),
                      style: const TextStyle(
                          fontSize: 11, color: AppColors.textSecondary)),
                );
              },
            ),
          ),
        ),
        borderData: FlBorderData(show: false),
        // ZONA SEGURA: banda verde tenue entre el umbral mínimo y el máximo.
        // Deja ver de un vistazo cuándo el valor entra/sale del rango normal.
        rangeAnnotations: RangeAnnotations(
          horizontalRangeAnnotations: [
            if (t?.minValue != null || t?.maxValue != null)
              HorizontalRangeAnnotation(
                y1: t?.minValue ?? (minY - pad),
                y2: t?.maxValue ?? (maxY + pad),
                color: AppColors.statusOk.withOpacity(.08),
              ),
          ],
        ),
        extraLinesData: ExtraLinesData(horizontalLines: [
          if (t?.minValue != null)
            HorizontalLine(
                y: t!.minValue!,
                color: AppColors.statusAttention.withOpacity(.45),
                strokeWidth: 1,
                dashArray: [6, 6],
                label: HorizontalLineLabel(
                  show: true,
                  alignment: Alignment.topRight,
                  style: const TextStyle(
                      fontSize: 9, color: AppColors.statusAttention),
                  labelResolver: (_) => 'mín ${t.minValue!.toStringAsFixed(0)}',
                )),
          if (t?.maxValue != null)
            HorizontalLine(
                y: t!.maxValue!,
                color: AppColors.statusAttention.withOpacity(.45),
                strokeWidth: 1,
                dashArray: [6, 6],
                label: HorizontalLineLabel(
                  show: true,
                  alignment: Alignment.bottomRight,
                  style: const TextStyle(
                      fontSize: 9, color: AppColors.statusAttention),
                  labelResolver: (_) => 'máx ${t.maxValue!.toStringAsFixed(0)}',
                )),
        ]),
        lineBarsData: [
          // Banda mín–máx (sombreada, sin líneas visibles).
          if (hasMinMax) ...[
            LineChartBarData(
              spots: maxSpots,
              isCurved: true,
              curveSmoothness: .2,
              color: Colors.transparent,
              barWidth: 0,
              dotData: const FlDotData(show: false),
              belowBarData: BarAreaData(
                show: true,
                color: AppColors.primary.withOpacity(.10),
                // Recorta el relleno a la línea del mínimo → queda la banda.
                cutOffY: 0,
                applyCutOffY: false,
              ),
            ),
            LineChartBarData(
              spots: minSpots,
              isCurved: true,
              curveSmoothness: .2,
              color: Colors.transparent,
              barWidth: 0,
              dotData: const FlDotData(show: false),
              belowBarData: BarAreaData(
                show: true,
                color: Colors.white.withOpacity(0),
              ),
            ),
          ],
          // Línea del promedio (la protagonista). Los puntos que caen fuera
          // del rango normal se pintan en color de atención para que las
          // elevaciones o caídas salten a la vista.
          LineChartBarData(
            spots: avgSpots,
            isCurved: true,
            curveSmoothness: .2,
            color: AppColors.primary,
            barWidth: 3,
            dotData: FlDotData(
              show: points.length <= 31,
              getDotPainter: (spot, _, __, ___) {
                final out = _outOfRange(spot.y, t);
                return FlDotCirclePainter(
                  radius: out ? 4 : 3,
                  color: out ? AppColors.statusAttention : AppColors.primary,
                  strokeWidth: out ? 1.5 : 0,
                  strokeColor: Colors.white,
                );
              },
            ),
            belowBarData: BarAreaData(
              show: true,
              color: AppColors.primary.withOpacity(.06),
            ),
          ),
        ],
        lineTouchData: LineTouchData(
          touchTooltipData: LineTouchTooltipData(
            getTooltipItems: (touched) => touched
                .where((s) => s.barIndex == touched.length - 1)
                .map((s) {
              final p = points[s.spotIndex];
              final mn = p.min != null ? ' · mín ${p.min!.toStringAsFixed(0)}' : '';
              final mx = p.max != null ? ' · máx ${p.max!.toStringAsFixed(0)}' : '';
              final when = switch (grain) {
                _Grain.hour => DateFormat("d MMM HH:mm", 'es').format(p.ts),
                _Grain.day => DateFormat('d MMM', 'es').format(p.ts),
                _Grain.week =>
                  'Semana del ${DateFormat('d MMM', 'es').format(p.ts)}',
              };
              return LineTooltipItem(
                '${p.value.toStringAsFixed(0)} ${series.type.unit} (promedio)$mn$mx\n'
                '$when',
                const TextStyle(color: Colors.white, fontSize: 12),
              );
            }).toList(),
          ),
        ),
      ),
    );
  }

  /// true si el valor queda fuera del rango normal definido por el umbral.
  static bool _outOfRange(double v, Threshold? t) {
    if (t == null) return false;
    if (t.minValue != null && v < t.minValue!) return true;
    if (t.maxValue != null && v > t.maxValue!) return true;
    return false;
  }
}

/// Resumen de orígenes del rango mostrado (transparencia de fuente).
class _SourcesSummary extends StatelessWidget {
  const _SourcesSummary({required this.sources});
  final Map<VitalSource, int> sources;

  @override
  Widget build(BuildContext context) {
    final entries = sources.entries.where((e) => e.value > 0).toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    if (entries.isEmpty) return const SizedBox.shrink();
    return Wrap(
      alignment: WrapAlignment.center,
      spacing: 8,
      runSpacing: 6,
      children: [
        for (final e in entries)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: AppColors.background,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: AppColors.divider),
            ),
            child: Text(
              '${e.key.emoji} ${e.key.label}: ${e.value}',
              style: const TextStyle(
                  fontSize: 11, color: AppColors.textSecondary),
            ),
          ),
      ],
    );
  }
}
