import 'package:flutter/material.dart' hide Threshold;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/common.dart';
import '../../auth/domain/models.dart';
import '../../patients/application/patients_providers.dart';
import '../application/health_providers.dart';
import '../data/vitals_repository.dart';
import '../domain/models.dart';

/// Pantalla para ver y configurar los umbrales (rangos normales) de cada vital
/// del paciente — endpoints 5.5 (listar) y 5.6 (configurar). Solo familiares y
/// médicos pueden editar; el resto los ve en modo lectura.
///
/// Los umbrales definen cuándo una lectura se considera "fuera de rango": eso
/// alimenta el color del gráfico, el semáforo y las alertas. Por eso es clave
/// que el familiar pueda ajustarlos por paciente.
class ThresholdsScreen extends ConsumerWidget {
  const ThresholdsScreen({super.key});

  /// Vitales que admiten umbral de alerta (los que son un valor comparable).
  static const _editableTypes = [
    VitalType.heartRate,
    VitalType.spo2,
    VitalType.bloodPressure,
    VitalType.temperature,
    VitalType.glucose,
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final patient = ref.watch(selectedPatientProvider);
    final thresholds = ref.watch(thresholdsProvider);
    final canEdit = patient != null &&
        (patient.role == RoleType.family || patient.role == RoleType.doctor);

    return Scaffold(
      appBar: AppBar(title: const Text('Rangos de alerta')),
      body: patient == null
          ? const EmptyView(
              icon: Icons.tune_rounded, title: 'Sin paciente seleccionado')
          : thresholds.when(
              loading: () => const LoadingView(),
              error: (e, _) => ErrorView(
                  message: e.toString(),
                  onRetry: () => ref.invalidate(thresholdsProvider)),
              data: (list) {
                final byType = {for (final t in list) t.type: t};
                return ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Text(
                        canEdit
                            ? 'Define el rango normal de cada signo. Fuera de ese rango, la lectura se marca en el gráfico y cuenta para el semáforo.'
                            : 'Solo un familiar o el médico pueden modificar estos rangos.',
                        style: const TextStyle(
                            fontSize: 13, color: AppColors.textSecondary),
                      ),
                    ),
                    for (final type in _editableTypes)
                      _ThresholdRow(
                        type: type,
                        threshold: byType[type],
                        canEdit: canEdit,
                        patientId: patient.patientId,
                      ),
                  ],
                );
              },
            ),
    );
  }
}

class _ThresholdRow extends ConsumerWidget {
  const _ThresholdRow({
    required this.type,
    required this.threshold,
    required this.canEdit,
    required this.patientId,
  });

  final VitalType type;
  final Threshold? threshold;
  final bool canEdit;
  final String patientId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = threshold;
    final hasRange =
        t != null && (t.minValue != null || t.maxValue != null);
    final rangeText = !hasRange
        ? 'Sin rango definido'
        : [
            if (t.minValue != null) 'mín ${_n(t.minValue!)}',
            if (t.maxValue != null) 'máx ${_n(t.maxValue!)}',
          ].join(' · ') + ' ${type.unit}';

    return AppCard(
      child: Row(
        children: [
          Text(type.emoji, style: const TextStyle(fontSize: 22)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(type.label,
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(rangeText,
                    style: const TextStyle(
                        fontSize: 13, color: AppColors.textSecondary)),
              ],
            ),
          ),
          if (canEdit)
            TextButton(
              onPressed: () => _edit(context, ref),
              child: Text(hasRange ? 'Editar' : 'Definir'),
            ),
        ],
      ),
    );
  }

  Future<void> _edit(BuildContext context, WidgetRef ref) async {
    final result = await showDialog<_ThresholdValues>(
      context: context,
      builder: (_) => _ThresholdDialog(type: type, current: threshold),
    );
    if (result == null) return;

    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(vitalsRepositoryProvider).setThreshold(
            patientId,
            type,
            minValue: result.min,
            maxValue: result.max,
          );
      ref.invalidate(thresholdsProvider);
      // Refresca vistas que dependen del umbral (gráfico, semáforo, tarjetas).
      refreshVitalsViews(ref.invalidate);
      messenger.showSnackBar(
        SnackBar(content: Text('Rango de ${type.label} actualizado')),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text(_friendlyError(e))),
      );
    }
  }

  /// Traduce errores del backend a mensajes claros (sin jerga técnica).
  String _friendlyError(Object e) {
    final s = e.toString();
    if (s.contains('INVALID_THRESHOLD_RANGE')) {
      return 'El mínimo no puede ser mayor o igual que el máximo.';
    }
    if (s.contains('EMPTY_THRESHOLD')) {
      return 'Indica al menos un valor mínimo o máximo.';
    }
    if (s.contains('FORBIDDEN') || s.contains('403')) {
      return 'No tienes permiso para cambiar los rangos de este paciente.';
    }
    return 'No se pudo guardar el rango. Intenta de nuevo.';
  }

  static String _n(double v) =>
      v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(1);
}

/// Valores devueltos por el diálogo de edición.
class _ThresholdValues {
  const _ThresholdValues(this.min, this.max);
  final double? min;
  final double? max;
}

class _ThresholdDialog extends StatefulWidget {
  const _ThresholdDialog({required this.type, this.current});
  final VitalType type;
  final Threshold? current;

  @override
  State<_ThresholdDialog> createState() => _ThresholdDialogState();
}

class _ThresholdDialogState extends State<_ThresholdDialog> {
  late final TextEditingController _min;
  late final TextEditingController _max;
  String? _error;

  @override
  void initState() {
    super.initState();
    _min = TextEditingController(
        text: widget.current?.minValue != null
            ? _ThresholdRow._n(widget.current!.minValue!)
            : '');
    _max = TextEditingController(
        text: widget.current?.maxValue != null
            ? _ThresholdRow._n(widget.current!.maxValue!)
            : '');
  }

  @override
  void dispose() {
    _min.dispose();
    _max.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Rango de ${widget.type.label}'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('Valores en ${widget.type.unit}. Deja un campo vacío si no '
              'quieres ese límite.',
              style: const TextStyle(
                  fontSize: 12, color: AppColors.textSecondary)),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _min,
                  keyboardType: const TextInputType.numberWithOptions(
                      decimal: true),
                  decoration: const InputDecoration(labelText: 'Mínimo'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _max,
                  keyboardType: const TextInputType.numberWithOptions(
                      decimal: true),
                  decoration: const InputDecoration(labelText: 'Máximo'),
                ),
              ),
            ],
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(_error!,
                  style: const TextStyle(
                      color: AppColors.statusAttention, fontSize: 12)),
            ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: _submit,
          child: const Text('Guardar'),
        ),
      ],
    );
  }

  void _submit() {
    final min = _parse(_min.text);
    final max = _parse(_max.text);
    if (_min.text.trim().isNotEmpty && min == null) {
      setState(() => _error = 'El mínimo no es un número válido.');
      return;
    }
    if (_max.text.trim().isNotEmpty && max == null) {
      setState(() => _error = 'El máximo no es un número válido.');
      return;
    }
    if (min == null && max == null) {
      setState(() => _error = 'Indica al menos un valor.');
      return;
    }
    if (min != null && max != null && min >= max) {
      setState(() => _error = 'El mínimo debe ser menor que el máximo.');
      return;
    }
    Navigator.pop(context, _ThresholdValues(min, max));
  }

  double? _parse(String s) {
    final t = s.trim().replaceAll(',', '.');
    if (t.isEmpty) return null;
    return double.tryParse(t);
  }
}
