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
import '../../wearable/application/watch_link_service.dart';
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
class _VitalsTab extends ConsumerStatefulWidget {
  const _VitalsTab();

  @override
  ConsumerState<_VitalsTab> createState() => _VitalsTabState();
}

class _VitalsTabState extends ConsumerState<_VitalsTab> {
  // Se guarda el controlador, y no se vuelve a pedir en dispose, porque ahi
  // "ref" ya no se puede usar.
  LiveController? _live;

  @override
  void initState() {
    super.initState();
    // Auto-refresco "En vivo" activado al entrar a Salud: las lecturas que
    // sube el reloj aparecen solas, sin que el usuario arrastre para refrescar.
    // Se enciende tras el primer frame para no modificar providers en build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _live = ref.read(liveControllerProvider.notifier);
      if (!ref.read(liveControllerProvider).enabled) _live!.start();
    });
  }

  @override
  void dispose() {
    // El sondeo lo enciende esta pantalla, asi que es esta la que tiene que
    // apagarlo. El provider no es autoDispose, de modo que sin esto el
    // temporizador le sobrevive a la pantalla y la aplicacion sigue pidiendo
    // a la API cada diez segundos por el resto de la sesion, con el usuario
    // en cualquier otra parte.
    _live?.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final latest = ref.watch(latestVitalsProvider);

    // UX de "actualización suave": mientras recarga (auto-refresco o pull),
    // NO tapamos la pantalla con un spinner. Si ya hay datos previos, los
    // seguimos mostrando y se reemplazan solos cuando llegan los nuevos
    // (efecto server-side events). El spinner a pantalla completa solo aparece
    // en la PRIMERA carga, cuando aún no hay nada que mostrar.
    final vitals = latest.valueOrNull;
    if (vitals == null) {
      if (latest.hasError) {
        return ErrorView(
          message: latest.error.toString(),
          onRetry: () => ref.invalidate(latestVitalsProvider),
        );
      }
      return const LoadingView();
    }

    return RefreshIndicator(
      onRefresh: () async => refreshVitalsViews(ref.invalidate),
      child: Builder(
        builder: (context) {
          return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // Estado del wearable (ticket AGE-306, criterio de visibilidad de sync)
            // Estado del Reloj AgeCare en Salud: conectado / desconectado /
            // sin vincular + aviso de batería baja. Usa watchStatusProvider,
            // la misma fuente de verdad que el panel de Dispositivos.
            const _WatchStatusBanner(),
            // Fila: interruptor "En vivo" (auto-refresco) + sincronizar reloj.
            // En un teléfono de 320 dp no cabe todo en una línea, así que los
            // botones bajan solos en vez de desbordar la pantalla.
            Wrap(
              spacing: 4,
              runSpacing: 4,
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                const _LiveToggle(),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
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
                      label: const Text('Sincronizar'),
                    ),
                  ],
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
          );
        },
      ),
    );
  }
}

/// Interruptor "En vivo": activa el auto-refresco que sondea el backend cada
/// pocos segundos, para que las lecturas que sube el reloj aparezcan solas sin
/// arrastrar para refrescar. Muestra cuándo fue la última actualización.
/// Indicador "En vivo": un punto verde que late para comunicar que los datos
/// se actualizan solos. NO es un interruptor (el auto-refresco está siempre
/// activo al entrar a Salud); es solo una señal visual del estado. Muestra la
/// hora de la última actualización.
class _LiveToggle extends ConsumerStatefulWidget {
  const _LiveToggle();

  @override
  ConsumerState<_LiveToggle> createState() => _LiveToggleState();
}

class _LiveToggleState extends ConsumerState<_LiveToggle>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final live = ref.watch(liveControllerProvider);
    final on = live.enabled;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Punto que late cuando está en vivo (fijo y gris si no).
          FadeTransition(
            opacity: on
                ? Tween(begin: 0.3, end: 1.0).animate(_pulse)
                : const AlwaysStoppedAnimation(1.0),
            child: Container(
              width: 9,
              height: 9,
              decoration: BoxDecoration(
                color: on ? AppColors.statusOk : AppColors.textSecondary,
                shape: BoxShape.circle,
              ),
            ),
          ),
          const SizedBox(width: 7),
          Text(
            'En vivo',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: on ? AppColors.statusOk : AppColors.textSecondary,
            ),
          ),
          if (on && live.lastRefresh != null) ...[
            const SizedBox(width: 6),
            Text(
              '· ${DateFormat('HH:mm:ss').format(live.lastRefresh!)}',
              style: const TextStyle(
                  fontSize: 11, color: AppColors.textSecondary),
            ),
          ],
        ],
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

    // Número en estado (verde/rojo); la tendencia usa el color fijo del vital.
    final color = vital.inRange ? AppColors.textPrimary : AppColors.statusAttention;
    final sparkColor = vital.type.seriesColor;
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
                    color: sparkColor,
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

/// Banner de estado del Reloj AgeCare en la pantalla de Salud.
/// Muestra, con la misma fuente de verdad del panel de Dispositivos
/// (watchStatusProvider): Sin vincular / Desconectado / Conectado, el nivel de
/// batería y un aviso cuando está baja. Es donde el familiar ve de un vistazo
/// si el monitoreo está activo.
class _WatchStatusBanner extends ConsumerWidget {
  const _WatchStatusBanner();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final patient = ref.watch(selectedPatientProvider);
    if (patient == null) return const SizedBox.shrink();
    final statusAsync = ref.watch(watchStatusProvider(patient.patientId));
    final s = statusAsync.valueOrNull;

    // Mientras carga la primera vez, no mostramos nada (evita parpadeo).
    if (s == null) return const SizedBox.shrink();

    // Caso 1: sin vincular → tarjeta con acción de vincular.
    if (!s.linked) {
      return AppCard(
        child: Row(
          children: [
            const Icon(Icons.watch_off_outlined, color: AppColors.textSecondary),
            const SizedBox(width: 10),
            const Expanded(
              child: Text('Sin reloj vinculado',
                  style: TextStyle(color: AppColors.textSecondary)),
            ),
            TextButton(
              onPressed: () =>
                  context.push('/wearable/watch/${patient.patientId}'),
              child: const Text('Vincular'),
            ),
          ],
        ),
      );
    }

    // Caso 2/3: vinculado → conectado o desconectado, con batería.
    final connected = s.connected;
    final color = connected ? AppColors.statusOk : AppColors.statusAttention;
    final label = connected ? 'Reloj conectado' : 'Reloj desconectado';
    final subtitle = connected
        ? 'Midiendo y enviando signos vitales'
        : 'Sin señal: puede estar apagado, sin batería o fuera de alcance';
    final battery = s.batteryPct;

    return Column(
      children: [
        AppCard(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              Icon(connected ? Icons.watch_rounded : Icons.watch_off_rounded,
                  color: color),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label,
                        style: TextStyle(
                            color: color,
                            fontWeight: FontWeight.w700,
                            fontSize: 14)),
                    Text(subtitle,
                        style: const TextStyle(
                            fontSize: 12, color: AppColors.textSecondary)),
                  ],
                ),
              ),
              if (battery != null) ...[
                Icon(
                  battery > 20
                      ? Icons.battery_std_rounded
                      : Icons.battery_alert_rounded,
                  size: 18,
                  color: battery > 20
                      ? AppColors.textSecondary
                      : AppColors.critical,
                ),
                const SizedBox(width: 2),
                Text('$battery%',
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: battery > 20
                            ? AppColors.textSecondary
                            : AppColors.critical)),
              ],
            ],
          ),
        ),
        // Aviso de batería baja (≤15%) SOLO si el reloj está conectado: es un
        // aviso preventivo ("cárgalo antes de que se apague"). Si ya está
        // desconectado, el banner de arriba lo cubre y repetirlo es redundante.
        if (connected && s.batteryLow) ...[
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColors.critical.withOpacity(.10),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                const Text('🪫', style: TextStyle(fontSize: 18)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Batería del reloj baja (${battery ?? 0}%). Ponlo a cargar '
                    'para no perder el monitoreo.',
                    style: const TextStyle(
                        fontSize: 12,
                        color: AppColors.critical,
                        fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}
