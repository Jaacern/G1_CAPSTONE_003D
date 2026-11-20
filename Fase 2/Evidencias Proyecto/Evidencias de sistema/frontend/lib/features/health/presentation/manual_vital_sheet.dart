import 'package:flutter/material.dart' hide Threshold;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/network/api_client.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/common.dart';
import '../application/health_providers.dart';
import '../data/vitals_repository.dart';
import '../domain/models.dart';

/// Abre el formulario para anotar una medición tomada a mano.
///
/// Es la vía para lo que el reloj no mide: la presión del tensiómetro, la
/// temperatura del termómetro, la glucosa del glucómetro. La usa la
/// cuidadora, que es quien está con el paciente (el backend solo acepta ese
/// rol). Devuelve true si se guardó.
Future<bool> showManualVitalSheet(BuildContext context,
    {required String patientId}) async {
  final guardado = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _ManualVitalSheet(patientId: patientId),
  );
  return guardado == true;
}

class _ManualVitalSheet extends ConsumerStatefulWidget {
  const _ManualVitalSheet({required this.patientId});
  final String patientId;

  @override
  ConsumerState<_ManualVitalSheet> createState() => _ManualVitalSheetState();
}

class _ManualVitalSheetState extends ConsumerState<_ManualVitalSheet> {
  final _formKey = GlobalKey<FormState>();
  final _valor = TextEditingController();
  final _diastolica = TextEditingController();
  final _nota = TextEditingController();
  VitalType _tipo = VitalType.bloodPressure;
  DateTime? _hora; // null = ahora
  bool _guardando = false;
  String? _error;

  @override
  void dispose() {
    _valor.dispose();
    _diastolica.dispose();
    _nota.dispose();
    super.dispose();
  }

  bool get _esPresion => _tipo == VitalType.bloodPressure;
  bool get _admiteDecimal => _tipo == VitalType.temperature;

  /// Acepta coma decimal, que es como se escribe en Chile ("36,8").
  double? _numero(String s) => double.tryParse(s.trim().replaceAll(',', '.'));

  String? _validarValor(String? v) {
    final n = _numero(v ?? '');
    if (n == null) return 'Escribe el valor';
    final (min, max) = rangoPosibleManual[_tipo]!;
    if (n < min || n > max) {
      return 'Debe estar entre ${_fmt(min)} y ${_fmt(max)}. Revisa que esté bien escrito.';
    }
    return null;
  }

  String? _validarDiastolica(String? v) {
    if (!_esPresion) return null;
    final n = _numero(v ?? '');
    if (n == null) return 'Escribe la diastólica';
    final (min, max) = rangoPosibleDiastolica;
    if (n < min || n > max) return 'Entre ${_fmt(min)} y ${_fmt(max)}';
    final sis = _numero(_valor.text);
    if (sis != null && n >= sis) return 'Debe ser menor que la sistólica';
    return null;
  }

  static String _fmt(double v) =>
      v == v.roundToDouble() ? v.toInt().toString() : v.toString();

  Future<void> _elegirHora() async {
    final ahora = DateTime.now();
    final t = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_hora ?? ahora),
      helpText: 'Hora en que se tomó',
    );
    if (t == null) return;
    var elegido =
        DateTime(ahora.year, ahora.month, ahora.day, t.hour, t.minute);
    // Una hora "posterior" a la actual es de ayer: nadie anota el futuro.
    if (elegido.isAfter(ahora)) {
      elegido = elegido.subtract(const Duration(days: 1));
    }
    setState(() => _hora = elegido);
  }

  Future<void> _guardar() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _guardando = true;
      _error = null;
    });
    try {
      final alerta = await ref.read(vitalsRepositoryProvider).addManual(
            widget.patientId,
            ManualVitalEntry(
              type: _tipo,
              value: _numero(_valor.text)!,
              valueSecondary: _esPresion ? _numero(_diastolica.text) : null,
              measuredAt: _hora,
              note: _nota.text,
            ),
          );
      refreshVitalsViews(ref.invalidate);
      if (!mounted) return;
      Navigator.of(context).pop(true);
      showAppSnackBar(
        context,
        alerta
            ? 'Medición guardada. Está fuera de su rango habitual: se avisó al círculo de cuidado.'
            : 'Medición guardada.',
        error: alerta,
      );
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.detailedMessage);
    } finally {
      if (mounted) setState(() => _guardando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final teclado = TextInputType.numberWithOptions(decimal: _admiteDecimal);
    final soloNumeros = [
      FilteringTextInputFormatter.allow(
          _admiteDecimal ? RegExp(r'[0-9.,]') : RegExp(r'[0-9]')),
    ];
    return Padding(
      padding: EdgeInsets.fromLTRB(
          20, 0, 20, 20 + MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Semantics(
                header: true,
                child: const Text('Registrar medición',
                    style:
                        TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
              ),
              const SizedBox(height: 4),
              const Text(
                'Anota lo que mediste con el tensiómetro, el termómetro o el glucómetro.',
                style: TextStyle(color: AppColors.textSecondary),
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final t in manualVitalTypes)
                    ChoiceChip(
                      label: Text('${t.emoji} ${t.label}'),
                      selected: _tipo == t,
                      onSelected: _guardando
                          ? null
                          : (_) => setState(() {
                                _tipo = t;
                                _valor.clear();
                                _diastolica.clear();
                                _error = null;
                              }),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              // La diastólica solo existe en presión y va al final de la fila:
              // aparecer o desaparecer no desplaza a otro campo del
              // formulario, así ninguno pierde su validación.
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: TextFormField(
                      key: ValueKey('valor-${_tipo.apiValue}'),
                      controller: _valor,
                      enabled: !_guardando,
                      keyboardType: teclado,
                      inputFormatters: soloNumeros,
                      autofocus: true,
                      decoration: InputDecoration(
                        labelText:
                            _esPresion ? 'Sistólica (arriba)' : _tipo.label,
                        suffixText: _tipo.unit,
                      ),
                      validator: _validarValor,
                    ),
                  ),
                  if (_esPresion) ...[
                    const Padding(
                      padding: EdgeInsets.only(top: 14, left: 8, right: 8),
                      child: Text('/',
                          style: TextStyle(
                              fontSize: 22, fontWeight: FontWeight.w700)),
                    ),
                    Expanded(
                      child: TextFormField(
                        controller: _diastolica,
                        enabled: !_guardando,
                        keyboardType: teclado,
                        inputFormatters: soloNumeros,
                        decoration: const InputDecoration(
                          labelText: 'Diastólica (abajo)',
                          suffixText: 'mmHg',
                        ),
                        validator: _validarDiastolica,
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _guardando ? null : _elegirHora,
                icon: const Icon(Icons.schedule_rounded),
                label: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(_hora == null
                      ? 'Tomada ahora · cambiar hora'
                      : 'Tomada a las ${DateFormat('HH:mm').format(_hora!)}'
                          '${_hora!.day != DateTime.now().day ? ' de ayer' : ''}'
                          ' · cambiar'),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _nota,
                enabled: !_guardando,
                maxLength: 200,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  labelText: 'Nota (opcional)',
                  hintText: 'Ej: en reposo, después de almorzar',
                ),
              ),
              _error == null
                  ? const SizedBox.shrink()
                  : Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: InlineError(
                          message: _error!,
                          onDismiss: () => setState(() => _error = null)),
                    ),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: _guardando ? null : _guardar,
                child: _guardando
                    ? const SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : const Text('Guardar medición'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
