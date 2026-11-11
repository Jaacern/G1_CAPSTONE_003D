import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/common.dart';
import '../application/timeline_providers.dart';
import '../domain/timeline.dart';

/// Historial del paciente con scroll: todo lo que pasó, del más reciente al
/// más antiguo, en una sola lista (dosis, signos vitales, bitácora, alertas,
/// tratamientos). Se cargan 20 eventos y, al acercarse al final, los
/// siguientes, sin botón.
///
/// Es el "histórico con scroll de datos del paciente para tomar decisiones"
/// que pide el escenario E-MED-02: antes de cambiar un tratamiento, el médico
/// mira qué pasó en los días previos.
class PatientTimeline extends ConsumerStatefulWidget {
  const PatientTimeline({super.key, required this.patientId});

  final String patientId;

  @override
  ConsumerState<PatientTimeline> createState() => _PatientTimelineState();
}

class _PatientTimelineState extends ConsumerState<PatientTimeline> {
  final _scroll = ScrollController();
  TimelineFilter _filtro = TimelineFilter.todo;

  TimelineKey get _key => (patientId: widget.patientId, filter: _filtro);

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_alBajar);
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _alBajar() {
    // A 400 px del final se pide la página siguiente: cuando la persona
    // llega abajo, ya está cargada.
    if (_scroll.position.extentAfter < 400) {
      ref.read(timelineControllerProvider(_key).notifier).cargarMas();
    }
  }

  @override
  Widget build(BuildContext context) {
    final estado = ref.watch(timelineControllerProvider(_key));
    final notifier = ref.read(timelineControllerProvider(_key).notifier);

    // Si la primera página no llena la pantalla no hay scroll que dispare la
    // siguiente: se pide sola.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      if (_scroll.position.maxScrollExtent == 0 && estado.hayMas) {
        notifier.cargarMas();
      }
    });

    final filas = _filas(estado.items);
    return Column(
      children: [
        SizedBox(
          height: 52,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            children: [
              for (final f in TimelineFilter.values)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(f.label),
                    selected: _filtro == f,
                    onSelected: (_) => setState(() => _filtro = f),
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: notifier.recargar,
            child: estado.cargando
                ? const LoadingView()
                : estado.items.isEmpty && estado.error != null
                    ? ErrorView(
                        message: 'No se pudo cargar el historial.',
                        onRetry: notifier.recargar)
                    : estado.items.isEmpty
                        ? ListView(children: const [
                            SizedBox(height: 40),
                            EmptyView(
                              icon: Icons.history_rounded,
                              title: 'Sin eventos',
                              subtitle:
                                  'Aquí aparecerá lo que se registre del adulto mayor.',
                            ),
                          ])
                        : ListView.builder(
                            controller: _scroll,
                            physics: const AlwaysScrollableScrollPhysics(),
                            padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
                            itemCount: filas.length + 1,
                            itemBuilder: (context, i) {
                              if (i == filas.length) {
                                return _Pie(
                                  cargando: estado.cargandoMas,
                                  hayMas: estado.hayMas,
                                  error: estado.error != null,
                                  onReintentar: notifier.cargarMas,
                                );
                              }
                              final f = filas[i];
                              return f is DateTime
                                  ? _EncabezadoDia(dia: f)
                                  : _EventoTile(evento: f as TimelineEvent);
                            },
                          ),
          ),
        ),
      ],
    );
  }

  /// Eventos intercalados con el encabezado de su día.
  static List<Object> _filas(List<TimelineEvent> items) {
    final out = <Object>[];
    DateTime? ultimo;
    for (final e in items) {
      final local = e.ts.toLocal();
      final dia = DateTime(local.year, local.month, local.day);
      if (ultimo == null || dia != ultimo) {
        out.add(dia);
        ultimo = dia;
      }
      out.add(e);
    }
    return out;
  }
}

class _EncabezadoDia extends StatelessWidget {
  const _EncabezadoDia({required this.dia});
  final DateTime dia;

  String get _texto {
    final hoy = DateTime.now();
    final h = DateTime(hoy.year, hoy.month, hoy.day);
    if (dia == h) return 'Hoy';
    if (dia == h.subtract(const Duration(days: 1))) return 'Ayer';
    final t = DateFormat("EEEE d 'de' MMMM", 'es').format(dia);
    return t[0].toUpperCase() + t.substring(1);
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 18, 4, 8),
        child: Semantics(
          header: true,
          child: Text(_texto,
              style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  color: AppColors.textSecondary)),
        ),
      );
}

class _EventoTile extends StatelessWidget {
  const _EventoTile({required this.evento});
  final TimelineEvent evento;

  IconData get _icono => switch (evento.kind) {
        TimelineKind.dose => evento.subtype == 'taken'
            ? Icons.check_circle_rounded
            : Icons.medication_rounded,
        TimelineKind.prn => Icons.emergency_rounded,
        TimelineKind.vital => Icons.monitor_heart_rounded,
        TimelineKind.observation => Icons.edit_note_rounded,
        TimelineKind.handover => Icons.swap_horiz_rounded,
        TimelineKind.incident => Icons.report_rounded,
        TimelineKind.alert => Icons.notifications_active_rounded,
        TimelineKind.treatment => Icons.assignment_rounded,
        TimelineKind.unknown => Icons.circle_outlined,
      };

  Color get _color {
    if (evento.esCritico) return AppColors.critical;
    if (evento.esImportante) return AgeColors.warn700;
    if (evento.kind == TimelineKind.dose && evento.subtype == 'taken') {
      return AppColors.statusOk;
    }
    return AppColors.primary;
  }

  /// Primera línea: qué fue, en palabras.
  String get _titulo {
    final e = evento;
    return switch (e.kind) {
      TimelineKind.dose => '${e.title} · ${e.estadoDosis ?? e.subtype ?? ''}',
      TimelineKind.prn => '${e.title} · uso SOS',
      TimelineKind.vital => '${e.title} ${e.valorLegible ?? ''}'.trim(),
      _ => e.title,
    };
  }

  @override
  Widget build(BuildContext context) {
    final e = evento;
    final hora = DateFormat('HH:mm').format(e.ts.toLocal());
    final pie = [
      e.kind.label,
      if ((e.author ?? '').isNotEmpty) e.author!,
    ].join(' · ');
    return Semantics(
      label: '$hora. ${e.kind.label}. $_titulo. ${e.detail ?? ''}',
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: AppCard(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 44,
                child: Text(hora,
                    style: const TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                        color: AppColors.textSecondary)),
              ),
              Icon(_icono, size: 20, color: _color),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(_titulo,
                        style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            color: e.esImportante ? _color : null)),
                    if ((e.detail ?? '').isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(e.detail!,
                          style: const TextStyle(
                              fontSize: 13, color: AppColors.textSecondary)),
                    ],
                    const SizedBox(height: 4),
                    Text(pie,
                        style: const TextStyle(
                            fontSize: 11.5, color: AppColors.textSecondary)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Pie extends StatelessWidget {
  const _Pie({
    required this.cargando,
    required this.hayMas,
    required this.error,
    required this.onReintentar,
  });

  final bool cargando;
  final bool hayMas;
  final bool error;
  final VoidCallback onReintentar;

  @override
  Widget build(BuildContext context) {
    if (cargando) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (error) {
      return Center(
        child: TextButton.icon(
          onPressed: onReintentar,
          icon: const Icon(Icons.refresh_rounded),
          label: const Text('No se pudieron cargar más. Reintentar'),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Center(
        child: Text(hayMas ? '' : 'No hay eventos más antiguos.',
            style: const TextStyle(color: AppColors.textSecondary)),
      ),
    );
  }
}
