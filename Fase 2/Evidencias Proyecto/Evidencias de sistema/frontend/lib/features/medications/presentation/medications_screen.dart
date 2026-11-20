import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../core/config/app_config.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/common.dart';
import '../../auth/application/auth_controller.dart';
import '../../auth/domain/models.dart';
import '../../patients/application/patients_providers.dart';
import '../application/medications_providers.dart';
import '../application/treatments_providers.dart';
import '../domain/treatment.dart';
import '../domain/models.dart';
import 'dose_actions.dart';

/// Quien puede crear, editar o discontinuar una indicacion. Solo el medico.
///
/// La cuidadora quedaba autorizada junto con el medico, asi que podia cambiar
/// la dosis de un farmaco o sacarlo del plan. Registrar que una dosis se tomo
/// es otra cosa y la sigue haciendo ella; decidir que se toma, no.
///
/// La familia es solo lectura y el backend responde 403.
bool _canManageMeds(WidgetRef ref) =>
    ref.watch(currentUserProvider)?.primaryRole == RoleType.doctor;

/// Quién puede marcar una dosis como tomada. No es lo mismo que gestionar el
/// plan: 6.6 (POST /doses/{id}/log) comprueba a mano que el llamador sea
/// miembro 'caregiver' del paciente, así que al médico lo devuelve con 404
/// aunque sí pueda crear, editar o discontinuar medicamentos.
bool _puedeRegistrarToma(WidgetRef ref) =>
    ref.watch(currentUserProvider)?.primaryRole == RoleType.caregiver;

/// Pestaña principal de Medicamentos: adherencia, plan y dosis de hoy
/// (tickets AGE-401/402/403/404).
///
/// Mantiene su propio Scaffold para cuando se navega directo a `/meds` o se
/// usa como pantalla independiente. El contenido real vive en
/// [MedicationsBody], reutilizable como sub-pestaña dentro de Salud.
class MedicationsScreen extends ConsumerWidget {
  const MedicationsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final patient = ref.watch(selectedPatientProvider);
    final canManage = _canManageMeds(ref);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Medicamentos'),
        actions: [
          // Escanear receta (OCR): solo para quien gestiona el plan y solo si
          // el backend lo soporta (hoy es una función "Próximamente").
          if (canManage && AppConfig.hasPrescriptionScan)
            IconButton(
              tooltip: 'Escanear receta',
              icon: const Icon(Icons.document_scanner_rounded),
              onPressed: patient == null
                  ? null
                  : () =>
                      context.push('/meds/scan?patient=${patient.patientId}'),
            ),
        ],
      ),
      floatingActionButton: (patient == null || !canManage)
          ? null
          : FloatingActionButton.extended(
              onPressed: () =>
                  indicarTratamiento(context, ref, patient.patientId),
              icon: const Icon(Icons.add_rounded),
              label: const Text('Indicar tratamiento'),
            ),
      body: const MedicationsBody(),
    );
  }
}

/// Cuerpo de la pantalla de medicamentos, sin Scaffold ni AppBar, para poder
/// embeberlo tanto en [MedicationsScreen] como en una sub-pestaña de Salud.
class MedicationsBody extends ConsumerWidget {
  const MedicationsBody({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final patient = ref.watch(selectedPatientProvider);
    final canManage = _canManageMeds(ref);

    if (patient == null) {
      return const EmptyView(
          icon: Icons.person_search_rounded,
          title: 'Selecciona un paciente',
          subtitle: 'Elige a quién quieres ver los medicamentos.');
    }

    return RefreshIndicator(
      onRefresh: () async {
        ref.invalidate(treatmentsProvider);
        ref.invalidate(todayDosesProvider);
        ref.invalidate(adherenceProvider);
      },
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
        children: [
          const _AdherenceSection(),
          const SizedBox(height: 20),
          const _TodayDosesSection(),
          const SizedBox(height: 20),
          Row(
            children: [
              // Como en "Hoy": el título cede su ancho antes que el Spacer le
              // robe los últimos px al chip de solo lectura.
              Expanded(
                child: Text('Plan de medicación',
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium),
              ),
              // Familia y cuidadora ven el plan en solo lectura: lo indica
              // y lo cambia el médico.
              if (!canManage)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: AppColors.divider,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: const Text('Solo lectura',
                      style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: AppColors.textSecondary)),
                ),
            ],
          ),
          const SizedBox(height: 8),
          _PlanDesdeTratamientos(
              patientId: patient.patientId, canManage: canManage),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Adherencia
// ---------------------------------------------------------------------------
class _AdherenceSection extends ConsumerWidget {
  const _AdherenceSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final adherence = ref.watch(adherenceProvider);
    return adherence.when(
      loading: () =>
          const AppCard(child: SizedBox(height: 160, child: LoadingView())),
      error: (e, _) => AppCard(
        child: ErrorView(
            message: e.toString(),
            onRetry: () => ref.invalidate(adherenceProvider)),
      ),
      data: (data) {
        if (data == null || data.byDay.isEmpty) {
          return const AppCard(
            child: EmptyView(
                icon: Icons.insights_rounded, title: 'Sin datos de adherencia'),
          );
        }
        return AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Text('Adherencia (7 días)',
                        style: TextStyle(fontWeight: FontWeight.w700)),
                  ),
                  Text('${data.pct.toStringAsFixed(0)}%',
                      style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w800,
                          color: _pctColor(data.pct))),
                ],
              ),
              const SizedBox(height: 16),
              SizedBox(height: 140, child: _AdherenceChart(points: data.byDay)),
              if (data.byMedication.isNotEmpty) ...[
                const SizedBox(height: 12),
                const Divider(),
                const SizedBox(height: 4),
                for (final m in data.byMedication)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      children: [
                        Expanded(child: Text(m.medicationName)),
                        Text('${m.pct.toStringAsFixed(0)}%',
                            style: TextStyle(
                                fontWeight: FontWeight.w700,
                                color: _pctColor(m.pct))),
                      ],
                    ),
                  ),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _AdherenceChart extends StatelessWidget {
  const _AdherenceChart({required this.points});

  final List<AdherencePoint> points;

  @override
  Widget build(BuildContext context) {
    return BarChart(
      BarChartData(
        minY: 0,
        maxY: 100,
        alignment: BarChartAlignment.spaceAround,
        gridData: FlGridData(
          show: true,
          drawVerticalLine: false,
          horizontalInterval: 25,
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
            sideTitles:
                SideTitles(showTitles: true, reservedSize: 32, interval: 25),
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
                return Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(DateFormat('E', 'es').format(points[i].date),
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
                toY: points[i].pct,
                width: 14,
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(4)),
                color: _pctColor(points[i].pct),
              ),
            ]),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Dosis de hoy
// ---------------------------------------------------------------------------
class _TodayDosesSection extends ConsumerWidget {
  const _TodayDosesSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final doses = ref.watch(todayDosesProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Dosis de hoy', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        doses.when(
          loading: () => const Padding(
              padding: EdgeInsets.only(top: 16), child: LoadingView()),
          error: (e, _) => ErrorView(
              message: e.toString(),
              onRetry: () => ref.invalidate(todayDosesProvider)),
          data: (list) => list.isEmpty
              ? const AppCard(
                  child: EmptyView(
                      icon: Icons.event_available_rounded,
                      title: 'No hay dosis programadas hoy'))
              : Column(
                  children: [
                    for (final d in list)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: _DoseTile(dose: d),
                      ),
                  ],
                ),
        ),
      ],
    );
  }
}

class _DoseTile extends ConsumerStatefulWidget {
  const _DoseTile({required this.dose});
  final Dose dose;

  @override
  ConsumerState<_DoseTile> createState() => _DoseTileState();
}

class _DoseTileState extends ConsumerState<_DoseTile> {
  bool _busy = false;

  Future<void> _log(DoseStatus status) async {
    setState(() => _busy = true);
    await registrarDosis(
        context: context, ref: ref, dose: widget.dose, status: status);
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.dose;
    final done = d.status != DoseStatus.pending;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: .1),
                  borderRadius: BorderRadius.circular(12),
                ),
                alignment: Alignment.center,
                child: const Icon(Icons.medication_rounded,
                    color: AppColors.primary),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(d.medicationName,
                        style: const TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w700)),
                    Text(
                      '${d.timeLabel}${d.dose != null ? ' · ${d.dose} ${d.unit ?? ''}'.trimRight() : ''}',
                      style: const TextStyle(color: AppColors.textSecondary),
                    ),
                  ],
                ),
              ),
              _StatusChip(status: d.status),
            ],
          ),
          // Registrar la toma le corresponde a la cuidadora: el endpoint 6.6
          // solo autoriza a ese rol (ver [_puedeRegistrarToma]).
          if (!done && _puedeRegistrarToma(ref)) ...[
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _busy ? null : () => _log(DoseStatus.taken),
                icon: const Icon(Icons.check_rounded),
                label: const Text('Tomada'),
                style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(44)),
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _busy ? null : () => _log(DoseStatus.postponed),
                    icon: const Icon(Icons.schedule_rounded, size: 18),
                    label: const Text('Posponer'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _busy ? null : () => _log(DoseStatus.missed),
                    icon: const Icon(Icons.close_rounded, size: 18),
                    label: const Text('No la tomé'),
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

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.status});
  final DoseStatus status;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: status.color.withValues(alpha: .12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(status.label,
          style: TextStyle(
              color: status.color, fontWeight: FontWeight.w700, fontSize: 12)),
    );
  }
}

// ---------------------------------------------------------------------------
// Plan de medicación: los tratamientos vigentes
// ---------------------------------------------------------------------------

/// Abre el editor de tratamientos de la especialidad que el médico elija.
///
/// Es el único camino para indicar o cambiar un medicamento: el editor usa el
/// catálogo de fármacos (unidad fija y dosis dentro del rango seguro), cruza
/// alergias y deja la versión anterior en el historial. La antigua pantalla
/// "Agregar medicamento" escribía un nombre libre en otra tabla y, si el
/// paciente ya tenía tratamiento, esas dosis nunca se generaban.
Future<void> indicarTratamiento(
    BuildContext context, WidgetRef ref, String patientId) async {
  final vigentes =
      ref.read(treatmentsProvider).valueOrNull?.vigentes ?? const [];
  final conTratamiento = {for (final g in vigentes) g.specialty};
  final elegida = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text('¿De qué especialidad es el tratamiento?',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          ),
          for (final sp in kEspecialidades)
            ListTile(
              leading: Icon(conTratamiento.contains(sp)
                  ? Icons.edit_note_rounded
                  : Icons.add_rounded),
              title: Text(specialtyLabel(sp)),
              subtitle: Text(conTratamiento.contains(sp)
                  ? 'Tiene tratamiento vigente: se abre para cambiarlo'
                  : 'Nuevo tratamiento'),
              onTap: () => Navigator.of(ctx).pop(sp),
            ),
        ],
      ),
    ),
  );
  if (elegida != null && context.mounted) {
    await context.push('/treatment?patient=$patientId&specialty=$elegida');
    ref.invalidate(treatmentsProvider);
  }
}

class _PlanDesdeTratamientos extends ConsumerWidget {
  const _PlanDesdeTratamientos(
      {required this.patientId, required this.canManage});

  final String patientId;
  final bool canManage;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bundle = ref.watch(treatmentsProvider);
    return bundle.when(
      loading: () => const Padding(
          padding: EdgeInsets.only(top: 24), child: LoadingView()),
      error: (e, _) => ErrorView(
          message: 'No se pudo cargar el plan de medicación.',
          onRetry: () => ref.invalidate(treatmentsProvider)),
      data: (b) {
        final grupos = b.vigentes;
        if (grupos.isEmpty) {
          return EmptyView(
            icon: Icons.medication_rounded,
            title: 'Sin tratamiento indicado',
            subtitle: canManage
                ? 'Indica el primer tratamiento para empezar.'
                : 'El plan lo indica el médico.',
            action: canManage
                ? FilledButton.icon(
                    onPressed: () =>
                        indicarTratamiento(context, ref, patientId),
                    icon: const Icon(Icons.add_rounded),
                    label: const Text('Indicar tratamiento'),
                  )
                : null,
          );
        }
        return Column(
          children: [
            for (final g in grupos)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: _TratamientoCard(
                    grupo: g, patientId: patientId, canManage: canManage),
              ),
          ],
        );
      },
    );
  }
}

class _TratamientoCard extends ConsumerWidget {
  const _TratamientoCard(
      {required this.grupo, required this.patientId, required this.canManage});

  final SpecialtyGroup grupo;
  final String patientId;
  final bool canManage;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = grupo.current!;
    final items = t.items.where((i) => i.action != 'removed').toList();
    return AppCard(
      // El médico abre el editor de esta especialidad; el resto solo lee.
      onTap: canManage
          ? () async {
              await context.push(
                  '/treatment?patient=$patientId&specialty=${grupo.specialty}');
              ref.invalidate(treatmentsProvider);
            }
          : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(specialtyLabel(grupo.specialty),
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w800)),
              ),
              if (canManage)
                const Icon(Icons.chevron_right_rounded,
                    color: AppColors.textSecondary),
            ],
          ),
          if ((t.prescriberName ?? '').isNotEmpty)
            Text('Indicado por ${t.prescriberName}',
                style: const TextStyle(
                    fontSize: 12.5, color: AppColors.textSecondary)),
          const SizedBox(height: 8),
          for (final it in items)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                      it.isPrn
                          ? Icons.emergency_rounded
                          : Icons.medication_liquid_rounded,
                      size: 20,
                      color: it.isPrn
                          ? AppColors.statusWarning
                          : AppColors.primary),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(it.name,
                            style: const TextStyle(
                                fontSize: 15, fontWeight: FontWeight.w700)),
                        Text(
                          it.isPrn
                              ? '${it.dose} · SOS, solo si se necesita'
                              : '${it.dose} · ${it.times.join(', ')}'
                                  '${(it.scheduleLabel ?? '').isNotEmpty ? ' (${it.scheduleLabel})' : ''}',
                          style: const TextStyle(
                              fontSize: 13, color: AppColors.textSecondary),
                        ),
                        if ((it.instructions ?? '').isNotEmpty)
                          Text(it.instructions!,
                              style: const TextStyle(
                                  fontSize: 12.5,
                                  color: AppColors.textSecondary)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

Color _pctColor(double pct) {
  if (pct >= 80) return AppColors.statusOk;
  if (pct >= 50) return AppColors.statusWarning;
  return AppColors.statusAttention;
}
