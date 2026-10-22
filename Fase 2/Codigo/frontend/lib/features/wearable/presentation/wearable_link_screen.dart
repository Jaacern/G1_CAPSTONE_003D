import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:spike_flutter_sdk/spike_flutter_sdk.dart' as spike;

import '../../../core/config/app_config.dart';
import '../../../core/network/api_client.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/common.dart';
import '../../../core/wearable/wearable_service.dart';
import '../../../core/wearable/health_connect/health_connect_sync.dart';
import '../../../core/wearable/health_connect/health_connect_live.dart';
import '../../../core/wearable/simulator/wearable_simulator.dart';
import '../../health/application/health_providers.dart';
import '../../health/domain/models.dart';

/// Pantalla de vinculación del wearable de un paciente.
///
/// Explica el vínculo con la salud del teléfono (Apple Salud / Health Connect)
/// y ofrece conectar proveedores de terceros (Garmin, Whoop, ...).
class WearableLinkScreen extends ConsumerStatefulWidget {
  const WearableLinkScreen({super.key, required this.patientId});

  final String patientId;

  @override
  ConsumerState<WearableLinkScreen> createState() => _WearableLinkScreenState();
}

class _WearableLinkScreenState extends ConsumerState<WearableLinkScreen> {
  bool _linking = false;
  spike.Provider? _connectingProvider;

  Future<void> _linkPhoneHealth() async {
    setState(() => _linking = true);
    try {
      await ref.read(wearableServiceProvider).linkPatient(widget.patientId);
      if (!mounted) return;
      showAppSnackBar(context, 'Wearable vinculado correctamente.');
      context.pop();
    } on ApiException catch (e) {
      if (!mounted) return;
      showAppSnackBar(context, e.message, error: true);
    } catch (_) {
      if (!mounted) return;
      showAppSnackBar(
          context, 'No se pudo vincular la salud del teléfono. Intenta de nuevo.',
          error: true);
    } finally {
      if (mounted) setState(() => _linking = false);
    }
  }

  Future<void> _connectProvider(spike.Provider provider) async {
    setState(() => _connectingProvider = provider);
    try {
      await ref
          .read(wearableServiceProvider)
          .connectProvider(widget.patientId, provider);
      if (!mounted) return;
      showAppSnackBar(context, 'Abriendo la conexión con ${provider.name}...');
    } on ApiException catch (e) {
      if (!mounted) return;
      showAppSnackBar(context, e.message, error: true);
    } catch (_) {
      if (!mounted) return;
      showAppSnackBar(context,
          'No se pudo conectar el proveedor. Intenta de nuevo.',
          error: true);
    } finally {
      if (mounted) setState(() => _connectingProvider = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final providers = spike.Provider.values;
    final mode = ref.watch(dataSourceModeProvider);
    // Spike (SaaS de pago) solo se muestra si hay un Application ID configurado.
    final spikeEnabled = AppConfig.spikeAppId != 0;
    return Scaffold(
      appBar: AppBar(title: const Text('Dispositivos y datos')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Panel de transparencia: qué fuentes están aportando datos hoy.
          const _SourcesPanel(),
          const SizedBox(height: 20),

          // Selector de fuente: reloj real o datos de prueba.
          const Padding(
            padding: EdgeInsets.only(left: 4, bottom: 8),
            child: Text('¿De dónde vienen los datos?',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          ),
          SegmentedButton<DataSourceMode>(
            segments: const [
              ButtonSegment(
                value: DataSourceMode.real,
                label: Text('Reloj real'),
                icon: Text('⌚'),
              ),
              ButtonSegment(
                value: DataSourceMode.demo,
                label: Text('Datos de prueba'),
                icon: Text('🧪'),
              ),
            ],
            selected: {mode},
            onSelectionChanged: (s) =>
                ref.read(dataSourceModeProvider.notifier).state = s.first,
          ),
          const SizedBox(height: 16),
          if (mode == DataSourceMode.real)
            _HealthConnectCard(patientId: widget.patientId)
          else
            _SimulatorCard(patientId: widget.patientId),
          const SizedBox(height: 20),

          if (spikeEnabled) ...[
          // Explicación del vínculo.
          AppCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: const [
                    Icon(Icons.favorite_rounded, color: AppColors.primary),
                    SizedBox(width: 10),
                    Expanded(
                      child: Text('Salud del teléfono',
                          style: TextStyle(
                              fontSize: 16, fontWeight: FontWeight.w700)),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                const Text(
                  'Conecta la app con Apple Salud (iPhone) o Health Connect (Android) '
                  'para seguir el ritmo cardíaco, la actividad y el sueño de tu familiar. '
                  'Solo se leen los datos de salud necesarios y puedes revocar el acceso '
                  'cuando quieras desde los ajustes del teléfono.',
                  style: TextStyle(
                      color: AppColors.textSecondary, height: 1.4, fontSize: 14),
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: _linking ? null : _linkPhoneHealth,
                  icon: _linking
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white),
                        )
                      : const Icon(Icons.health_and_safety_rounded),
                  label: Text(_linking
                      ? 'Conectando...'
                      : 'Conectar salud del teléfono'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),

          // Proveedores de terceros.
          const Padding(
            padding: EdgeInsets.only(left: 4, bottom: 8),
            child: Text('Proveedores',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          ),
          const Padding(
            padding: EdgeInsets.only(left: 4, bottom: 12),
            child: Text(
              'Conecta una cuenta de proveedor si tu familiar usa una pulsera o '
              'reloj compatible.',
              style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
            ),
          ),
          ...providers.map((p) {
            final busy = _connectingProvider == p;
            return Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: AppCard(
                onTap: busy ? null : () => _connectProvider(p),
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                child: Row(
                  children: [
                    const Icon(Icons.watch_rounded, color: AppColors.primary),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(_prettyName(p.name),
                          style: const TextStyle(
                              fontWeight: FontWeight.w600, fontSize: 15)),
                    ),
                    if (busy)
                      const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    else
                      const Icon(Icons.chevron_right_rounded,
                          color: AppColors.textSecondary),
                  ],
                ),
              ),
            );
          }),
          const SizedBox(height: 16),
          ],

          // Nota de sincronización y accesibilidad.
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: AppColors.primary.withOpacity(.06),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: const [
                Icon(Icons.info_outline_rounded,
                    size: 20, color: AppColors.primary),
                SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Reloj real: los datos se leen de Health Connect cuando tocas '
                    '"Sincronizar ahora". Datos de prueba: cargan lecturas '
                    'simuladas con la hora actual para demostrar el semáforo sin '
                    'depender del reloj. Ambas fuentes quedan registradas por '
                    'separado en el backend.',
                    style: TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 13,
                        height: 1.4),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Nombre legible del proveedor (capitaliza el enum del SDK).
  String _prettyName(String raw) {
    if (raw.isEmpty) return raw;
    return raw[0].toUpperCase() + raw.substring(1);
  }
}

/// Panel de transparencia: muestra las 3 fuentes de datos, cuántas lecturas
/// aportó cada una hoy y si el Reloj AgeCare está emitiendo en vivo.
/// Hace visible el origen del dato (nada oculto), como piden las apps serias.
class _SourcesPanel extends ConsumerWidget {
  const _SourcesPanel();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(sourcesTodayProvider);
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text('Fuentes de datos (hoy)',
                    style:
                        TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.refresh_rounded, size: 20),
                onPressed: () => ref.invalidate(sourcesTodayProvider),
              ),
            ],
          ),
          const SizedBox(height: 4),
          async.when(
            loading: () => const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Center(
                  child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2))),
            ),
            error: (e, _) => const Text('No se pudo leer el estado de fuentes.',
                style: TextStyle(color: AppColors.textSecondary, fontSize: 13)),
            data: (s) => Column(
              children: [
                _SourceRow(
                  source: VitalSource.watch,
                  count: s.countOf(VitalSource.watch),
                  live: s.watchLive,
                ),
                _SourceRow(
                  source: VitalSource.healthConnect,
                  count: s.countOf(VitalSource.healthConnect),
                ),
                _SourceRow(
                  source: VitalSource.simulator,
                  count: s.countOf(VitalSource.simulator),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SourceRow extends StatelessWidget {
  const _SourceRow({required this.source, required this.count, this.live = false});
  final VitalSource source;
  final int count;
  final bool live;

  @override
  Widget build(BuildContext context) {
    final active = count > 0;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Text(source.emoji, style: const TextStyle(fontSize: 18)),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(source.label,
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                Text(
                  active
                      ? '$count lecturas de ritmo hoy'
                      : 'Sin datos hoy',
                  style: const TextStyle(
                      fontSize: 12, color: AppColors.textSecondary),
                ),
              ],
            ),
          ),
          if (source == VitalSource.watch)
            _StatusDot(
              label: live ? 'En vivo' : (active ? 'Conectado' : 'Sin señal'),
              color: live
                  ? AppColors.statusOk
                  : (active ? AppColors.statusWarning : AppColors.textSecondary),
            )
          else if (active)
            _StatusDot(label: 'Activa', color: AppColors.statusOk),
        ],
      ),
    );
  }
}

class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.label, required this.color});
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: 5),
        Text(label, style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.w600)),
      ],
    );
  }
}

/// Fuente de datos elegida en la pantalla de dispositivos.
enum DataSourceMode { real, demo }

/// Recuerda la fuente elegida mientras la app está abierta.
final dataSourceModeProvider =
    StateProvider<DataSourceMode>((ref) => DataSourceMode.real);

/// Tarjeta de datos de prueba: carga un escenario simulado (con la hora actual)
/// para demostrar el semáforo sin depender del reloj.
class _SimulatorCard extends ConsumerWidget {
  const _SimulatorCard({required this.patientId});

  final String patientId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(wearableSimulatorProvider);
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: const [
              Text('🧪', style: TextStyle(fontSize: 20)),
              SizedBox(width: 10),
              Expanded(
                child: Text('Datos de prueba',
                    style:
                        TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            'Elige un escenario. Se suben lecturas simuladas con la hora actual '
            'y el semáforo se recalcula al instante.',
            style: TextStyle(
                color: AppColors.textSecondary, height: 1.4, fontSize: 14),
          ),
          const SizedBox(height: 14),
          for (final s in SimScenario.values)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: OutlinedButton(
                onPressed: state.busy
                    ? null
                    : () => ref
                        .read(wearableSimulatorProvider.notifier)
                        .run(patientId, s),
                style: OutlinedButton.styleFrom(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  alignment: Alignment.centerLeft,
                  side: BorderSide(
                    color: state.last == s
                        ? AppColors.primary
                        : AppColors.divider,
                    width: state.last == s ? 2 : 1,
                  ),
                ),
                child: Row(
                  children: [
                    Text(s.emoji, style: const TextStyle(fontSize: 18)),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(s.label,
                              style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                  color: AppColors.textPrimary)),
                          Text(s.description,
                              style: const TextStyle(
                                  fontSize: 12,
                                  color: AppColors.textSecondary)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          if (state.busy)
            const Padding(
              padding: EdgeInsets.only(top: 4),
              child: LinearProgressIndicator(),
            ),
          if (state.message != null) ...[
            const SizedBox(height: 8),
            Text(
              state.message!,
              style: TextStyle(
                fontSize: 13,
                color: state.isError
                    ? AppColors.statusAttention
                    : AppColors.textSecondary,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Tarjeta de sincronización directa con Health Connect (Android).
/// Lee del reloj real (vía Samsung Health → Health Connect) y sube las
/// lecturas al backend. Ideal para probar un Galaxy Watch 4 sin servicios de pago.
/// Es stateful para poder apagar el Modo Live al salir de la pantalla.
class _HealthConnectCard extends ConsumerStatefulWidget {
  const _HealthConnectCard({required this.patientId});

  final String patientId;

  @override
  ConsumerState<_HealthConnectCard> createState() => _HealthConnectCardState();
}

class _HealthConnectCardState extends ConsumerState<_HealthConnectCard> {
  @override
  void dispose() {
    // Detiene el sondeo si el usuario sale con el Live encendido.
    ref.read(healthConnectLiveProvider.notifier).stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final patientId = widget.patientId;
    final state = ref.watch(healthConnectSyncProvider);
    final live = ref.watch(healthConnectLiveProvider);
    final busy = state.isBusy;

    final statusText = switch (state.phase) {
      HcSyncPhase.checking => 'Comprobando Health Connect…',
      HcSyncPhase.needsPermission => 'Faltan permisos de salud.',
      HcSyncPhase.reading => 'Leyendo datos del reloj…',
      HcSyncPhase.uploading => 'Subiendo ${state.read} lecturas…',
      HcSyncPhase.done => state.message ?? 'Sincronización completada.',
      HcSyncPhase.error => state.message ?? 'Ocurrió un error.',
      HcSyncPhase.idle => null,
    };
    final isError = state.phase == HcSyncPhase.error ||
        state.phase == HcSyncPhase.needsPermission;

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: const [
              Text('⌚', style: TextStyle(fontSize: 20)),
              SizedBox(width: 10),
              Expanded(
                child: Text('Reloj real · Health Connect',
                    style:
                        TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              ),
            ],
          ),
          const SizedBox(height: 10),
          const Text(
            'Lee ritmo cardíaco, pasos, SpO₂ y sueño directamente del reloj '
            '(Samsung Health → Health Connect) y los sube a AgeCare. '
            'Gratis y sin servicios externos. Requiere Android con Health '
            'Connect instalado.',
            style: TextStyle(
                color: AppColors.textSecondary, height: 1.4, fontSize: 14),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: busy
                ? null
                : () => ref
                    .read(healthConnectSyncProvider.notifier)
                    .sync(patientId, days: 7),
            icon: busy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white),
                  )
                : const Icon(Icons.sync_rounded),
            label: Text(busy ? 'Sincronizando…' : 'Sincronizar ahora'),
          ),
          const SizedBox(height: 14),
          const Divider(height: 1),
          // ---- Modo Live (sondeo automático) ----
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            activeColor: AppColors.primary,
            title: Row(
              children: [
                if (live.active) ...[
                  const Text('🔴', style: TextStyle(fontSize: 14)),
                  const SizedBox(width: 6),
                ],
                const Text('Modo Live',
                    style: TextStyle(fontWeight: FontWeight.w700)),
              ],
            ),
            subtitle: Text(
              live.active
                  ? 'Leyendo el reloj cada ${HealthConnectLiveController.intervalSeconds}s automáticamente.'
                  : 'Sincroniza solo, sin tocar el botón (sondea cada ${HealthConnectLiveController.intervalSeconds}s).',
              style: const TextStyle(
                  fontSize: 12, color: AppColors.textSecondary),
            ),
            value: live.active,
            onChanged: (on) {
              final ctrl = ref.read(healthConnectLiveProvider.notifier);
              if (on) {
                ctrl.start(patientId);
              } else {
                ctrl.stop();
              }
            },
          ),
          if (live.active || live.message != null) ...[
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: (live.error
                        ? AppColors.statusAttention
                        : AppColors.primary)
                    .withOpacity(.06),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  if (live.lastHeartRate != null) ...[
                    const Text('❤️', style: TextStyle(fontSize: 22)),
                    const SizedBox(width: 8),
                    Text('${live.lastHeartRate!.round()}',
                        style: const TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w800,
                            color: AppColors.textPrimary)),
                    const Text(' lpm',
                        style: TextStyle(color: AppColors.textSecondary)),
                    const SizedBox(width: 12),
                  ],
                  Expanded(
                    child: Text(
                      live.message ?? 'Escuchando…',
                      style: TextStyle(
                        fontSize: 12,
                        color: live.error
                            ? AppColors.statusAttention
                            : AppColors.textSecondary,
                      ),
                    ),
                  ),
                  if (live.active)
                    Text('${live.totalNew} nuevas',
                        style: const TextStyle(
                            fontSize: 11, color: AppColors.textSecondary)),
                ],
              ),
            ),
            const SizedBox(height: 4),
          ],
          if (statusText != null) ...[
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  isError
                      ? Icons.error_outline_rounded
                      : state.phase == HcSyncPhase.done
                          ? Icons.check_circle_outline_rounded
                          : Icons.info_outline_rounded,
                  size: 18,
                  color: isError
                      ? AppColors.statusAttention
                      : state.phase == HcSyncPhase.done
                          ? AppColors.statusOk
                          : AppColors.textSecondary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    statusText,
                    style: TextStyle(
                      fontSize: 13,
                      color: isError
                          ? AppColors.statusAttention
                          : AppColors.textSecondary,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
