import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/common.dart';
import '../application/medications_providers.dart';
import '../application/treatments_providers.dart';
import '../data/treatments_repository.dart';
import '../domain/treatment.dart';

/// Editor de "Nuevo tratamiento" (Hito 3, DEF-008).
///
/// Precarga las indicaciones del tratamiento vigente. El médico mantiene,
/// cambia la dosis/horarios, elimina o agrega fármacos, y guarda TODO el
/// esquema como un tratamiento nuevo. El anterior queda como histórico; nada
/// se edita en el lugar. "Diferencia vital entre cambiar un medicamento y
/// cambiar el tratamiento": aquí se cambia el tratamiento completo.
class TreatmentEditorScreen extends ConsumerStatefulWidget {
  const TreatmentEditorScreen({
    super.key,
    required this.patientId,
    this.specialty = 'general',
    this.agregados = const [],
  });

  final String patientId;

  /// Especialidad del tratamiento que se edita. Precarga el vigente de esa
  /// especialidad; si no existe, parte vacío (tratamiento nuevo de esa área).
  final String specialty;

  /// Indicaciones nuevas que se suman a las vigentes al abrir, por ejemplo
  /// las que leyó el escaneo de una receta. El médico las revisa (fármaco
  /// del catálogo, dosis, horarios) antes de guardar.
  final List<TreatmentItemDraft> agregados;

  @override
  ConsumerState<TreatmentEditorScreen> createState() =>
      _TreatmentEditorScreenState();
}

class _TreatmentEditorScreenState extends ConsumerState<TreatmentEditorScreen> {
  List<TreatmentItemDraft>? _drafts;
  final _noteCtrl = TextEditingController();
  bool _saving = false;
  // Duración: permanente (crónico) o hasta una fecha (temporal).
  bool _permanente = true;
  DateTime? _reviewDate;

  @override
  void dispose() {
    _noteCtrl.dispose();
    super.dispose();
  }

  void _precargar(TreatmentBundle bundle) {
    if (_drafts != null) return;
    // Precarga las indicaciones vigentes DE ESTA ESPECIALIDAD como borradores.
    final grupo = bundle.bySpecialty
        .where((g) => g.specialty == widget.specialty)
        .toList();
    final actual = grupo.isNotEmpty ? grupo.first.current : null;
    final List<TreatmentItem> items = actual?.items ?? const [];
    _drafts = [
      ...items.map(TreatmentItemDraft.fromItem),
      ...widget.agregados,
    ];
    // Precarga la duración del tratamiento vigente de esta especialidad.
    if (actual?.reviewDate != null) {
      _permanente = false;
      _reviewDate = actual!.reviewDate;
    }
  }

  Future<void> _guardar() async {
    final activos = (_drafts ?? []).where((d) => !d.removed).toList();
    if (activos.isEmpty) {
      showAppSnackBar(
          context, 'El tratamiento debe tener al menos una indicación.',
          error: true);
      return;
    }
    for (final d in activos) {
      // Un item SOS no exige horario; uno programado sí.
      final faltaHorario = !d.isPrn && d.times.isEmpty;
      if (d.name.trim().length < 2 || d.doseAmount <= 0 || faltaHorario) {
        showAppSnackBar(
            context,
            'Revisa ${d.name.isEmpty ? "una indicación" : d.name}: '
            'nombre, dosis y ${d.isPrn ? "datos" : "al menos un horario"}.',
            error: true);
        return;
      }
    }

    if (!_permanente && _reviewDate == null) {
      showAppSnackBar(context,
          'Indica hasta qué fecha, o marca el tratamiento como permanente.',
          error: true);
      return;
    }

    setState(() => _saving = true);
    try {
      await _enviar(activos, confirmAllergy: false);
    } on ApiException catch (e) {
      // El backend advierte de una alergia que choca con lo prescrito. La
      // decisión de prescribir igual es del MÉDICO: se le muestra y confirma.
      if (e.code == 'ALLERGY_WARNING' && mounted) {
        final confirmar = await _confirmarAlergia(e.message);
        if (confirmar == true) {
          try {
            await _enviar(activos, confirmAllergy: true);
          } on Object catch (e2) {
            if (mounted) showAppSnackBar(context, e2.toString(), error: true);
          }
        }
      } else if (mounted) {
        showAppSnackBar(context, e.toString(), error: true);
      }
    } on Object catch (e) {
      if (mounted) showAppSnackBar(context, e.toString(), error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// Envía el tratamiento al backend. [confirmAllergy] pasa la confirmación del
  /// médico cuando ya se le advirtió de una alergia.
  Future<void> _enviar(List<TreatmentItemDraft> activos,
      {required bool confirmAllergy}) async {
    await ref.read(treatmentsRepositoryProvider).createTreatment(
          widget.patientId,
          specialty: widget.specialty,
          items: activos,
          note: _noteCtrl.text,
          reviewDate: _permanente ? null : _reviewDate,
          confirmAllergy: confirmAllergy,
        );
    ref.invalidate(treatmentsProvider);
    ref.invalidate(medicationsProvider);
    ref.invalidate(todayDosesProvider);
    if (mounted) {
      Navigator.of(context).pop(true);
      showAppSnackBar(context, 'Nuevo tratamiento vigente guardado.');
    }
  }

  /// Diálogo de advertencia por alergia. Rojo, explícito, con el detalle del
  /// choque. El médico asume la responsabilidad al confirmar.
  Future<bool?> _confirmarAlergia(String mensaje) => showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          icon: const Icon(Icons.warning_amber_rounded,
              color: AppColors.critical, size: 36),
          title: const Text('Alergia detectada'),
          content: Text(
            '$mensaje\n\n¿Confirmas prescribir de todas formas? '
            'Quedará bajo tu responsabilidad.',
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('Cancelar')),
            FilledButton(
              style:
                  FilledButton.styleFrom(backgroundColor: AppColors.critical),
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Prescribir igual'),
            ),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    final bundle = ref.watch(treatmentsProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text('Tratamiento · ${specialtyLabel(widget.specialty)}'),
      ),
      body: bundle.when(
        loading: () => const LoadingView(),
        error: (e, _) => ErrorView(
          message: e.toString(),
          onRetry: () => ref.invalidate(treatmentsProvider),
        ),
        data: (b) {
          _precargar(b);
          final drafts = _drafts!;
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 120),
            children: [
              const _Explicacion(),
              for (var i = 0; i < drafts.length; i++)
                _ItemCard(
                  key: ValueKey(drafts[i]),
                  draft: drafts[i],
                  onChanged: () => setState(() {}),
                  onRemove: () => setState(() {
                    // Si continúa un fármaco del vigente, se marca como
                    // eliminado (sale del esquema). Si era nuevo, se descarta.
                    if (drafts[i].continuesItemId != null) {
                      drafts[i].removed = true;
                    } else {
                      drafts.removeAt(i);
                    }
                  }),
                  onRestore: () => setState(() => drafts[i].removed = false),
                ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: () => setState(() => drafts.add(TreatmentItemDraft(
                      name: '',
                      doseAmount: 1,
                      doseUnit: 'mg',
                      times: ['08:00'],
                    ))),
                icon: const Icon(Icons.add_rounded),
                label: const Text('Agregar fármaco'),
              ),
              const SizedBox(height: 16),
              // Duración del tratamiento.
              AppCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Duración',
                        style: TextStyle(
                            fontWeight: FontWeight.w700, fontSize: 14)),
                    const SizedBox(height: 8),
                    SegmentedButton<bool>(
                      segments: const [
                        ButtonSegment(value: true, label: Text('Permanente')),
                        ButtonSegment(value: false, label: Text('Hasta fecha')),
                      ],
                      selected: {_permanente},
                      onSelectionChanged: (s) =>
                          setState(() => _permanente = s.first),
                      showSelectedIcon: false,
                    ),
                    if (!_permanente) ...[
                      const SizedBox(height: 8),
                      OutlinedButton.icon(
                        onPressed: () async {
                          final hoy = DateTime.now();
                          final picked = await showDatePicker(
                            context: context,
                            initialDate:
                                _reviewDate ?? hoy.add(const Duration(days: 7)),
                            firstDate: hoy,
                            lastDate: hoy.add(const Duration(days: 3650)),
                          );
                          if (picked != null) {
                            setState(() => _reviewDate = picked);
                          }
                        },
                        icon: const Icon(Icons.event_rounded, size: 18),
                        label: Text(_reviewDate == null
                            ? 'Elegir fecha de término'
                            : 'Hasta ${_reviewDate!.day.toString().padLeft(2, '0')}/${_reviewDate!.month.toString().padLeft(2, '0')}/${_reviewDate!.year}'),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _noteCtrl,
                decoration: const InputDecoration(
                  labelText: 'Motivo del cambio (opcional)',
                  hintText: 'Por ejemplo: ajuste de presión',
                ),
                maxLines: 2,
              ),
            ],
          );
        },
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: FilledButton.icon(
            onPressed: _saving ? null : _guardar,
            icon: _saving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.save_rounded),
            label: const Text('Guardar tratamiento'),
            style:
                FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
          ),
        ),
      ),
    );
  }
}

class _Explicacion extends StatelessWidget {
  const _Explicacion();
  @override
  Widget build(BuildContext context) => const Padding(
        padding: EdgeInsets.only(bottom: 12),
        child: Text(
          'Este es el esquema completo del paciente. Ajusta las dosis y los '
          'horarios, quita o agrega fármacos, y guarda. El tratamiento anterior '
          'queda en el historial.',
          style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
        ),
      );
}

class _ItemCard extends ConsumerWidget {
  const _ItemCard({
    super.key,
    required this.draft,
    required this.onChanged,
    required this.onRemove,
    required this.onRestore,
  });

  final TreatmentItemDraft draft;
  final VoidCallback onChanged;
  final VoidCallback onRemove;
  final VoidCallback onRestore;

  static const _units = [
    'mg',
    'g',
    'ml',
    'mcg',
    'UI',
    'gotas',
    'comprimido',
    'cápsula',
    'puff',
    'parche'
  ];

  /// Fármaco del catálogo elegido para este borrador (o null si texto libre).
  DrugCatalogItem? _elegido(List<DrugCatalogItem> catalogo) {
    if (draft.drugCode == null) return null;
    for (final d in catalogo) {
      if (d.code == draft.drugCode) return d;
    }
    return null;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (draft.removed) {
      return AppCard(
        child: Row(
          children: [
            Expanded(
              child: Text(
                '${draft.name} — se quita del tratamiento',
                style: const TextStyle(
                  color: AppColors.textSecondary,
                  decoration: TextDecoration.lineThrough,
                ),
              ),
            ),
            TextButton(onPressed: onRestore, child: const Text('Deshacer')),
          ],
        ),
      );
    }

    final catalogo = ref.watch(drugCatalogProvider).asData?.value ??
        const <DrugCatalogItem>[];
    final elegido = _elegido(catalogo);

    // ¿La dosis actual está fuera del rango seguro del fármaco del catálogo?
    final fueraDeRango = elegido != null &&
        (draft.doseAmount < elegido.doseMin ||
            draft.doseAmount > elegido.doseMax);

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Selector de fármaco: del catálogo (guiado) o texto libre ──
          Row(
            children: [
              Expanded(
                child: elegido != null
                    ? _FarmacoElegido(elegido: elegido)
                    : _SelectorCatalogo(
                        catalogo: catalogo,
                        nombreLibre: draft.name,
                        onNombreLibre: (v) => draft.name = v,
                        onElegir: (d) {
                          draft.drugCode = d.code;
                          draft.name = d.label;
                          draft.doseUnit = d.unit;
                          // Ajusta la dosis al mínimo seguro si estaba fuera.
                          if (draft.doseAmount < d.doseMin ||
                              draft.doseAmount > d.doseMax) {
                            draft.doseAmount = d.doseMin;
                          }
                          onChanged();
                        },
                      ),
              ),
              IconButton(
                tooltip: 'Quitar',
                icon: const Icon(Icons.delete_outline_rounded,
                    color: AppColors.critical),
                onPressed: onRemove,
              ),
            ],
          ),
          if (elegido != null)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                style: TextButton.styleFrom(
                    padding: EdgeInsets.zero,
                    minimumSize: const Size(0, 32),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                icon: const Icon(Icons.edit_note_rounded, size: 18),
                label: const Text('Cambiar fármaco'),
                onPressed: () {
                  draft.drugCode = null;
                  onChanged();
                },
              ),
            ),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 90,
                child: TextFormField(
                  initialValue: _fmt(draft.doseAmount),
                  decoration: InputDecoration(
                    labelText: 'Dosis',
                    errorText: fueraDeRango ? 'Fuera de rango' : null,
                  ),
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  onChanged: (v) {
                    draft.doseAmount = double.tryParse(v) ?? draft.doseAmount;
                    onChanged();
                  },
                ),
              ),
              const SizedBox(width: 12),
              // Con fármaco del catálogo la unidad es FIJA (no se teclea): se
              // hereda del fármaco. Es la clave para evitar errores de unidad.
              if (elegido != null)
                Padding(
                  padding: const EdgeInsets.only(top: 14),
                  child: Chip(
                    label: Text(elegido.unit),
                    visualDensity: VisualDensity.compact,
                    backgroundColor: AppColors.primary.withValues(alpha: 0.08),
                  ),
                )
              else
                DropdownButton<String>(
                  value:
                      _units.contains(draft.doseUnit) ? draft.doseUnit : 'mg',
                  items: [
                    for (final u in _units)
                      DropdownMenuItem(value: u, child: Text(u)),
                  ],
                  onChanged: (v) {
                    draft.doseUnit = v ?? 'mg';
                    onChanged();
                  },
                ),
            ],
          ),
          if (elegido != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'Rango seguro: ${elegido.rangoLegible}'
                '${elegido.maxDaily != null ? ' · máx. ${_fmt(elegido.maxDaily!)} ${elegido.unit}/día' : ''}',
                style: TextStyle(
                  fontSize: 12,
                  color: fueraDeRango
                      ? AppColors.critical
                      : AppColors.textSecondary,
                  fontWeight: fueraDeRango ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ),
          const SizedBox(height: 4),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: const Text('Solo si se necesita (SOS)',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
            subtitle: const Text(
                'No entra a la agenda de tomas; se registra al usarse.',
                style: TextStyle(fontSize: 12)),
            value: draft.isPrn,
            activeThumbColor: AppColors.primary,
            onChanged: (v) {
              draft.isPrn = v;
              onChanged();
            },
          ),
          if (draft.isPrn) ...[
            const SizedBox(height: 4),
            DropdownButtonFormField<int?>(
              initialValue: draft.prnMinIntervalMin,
              decoration: const InputDecoration(
                labelText: 'Intervalo mínimo entre usos',
                helperText: 'Avisa a quien cuida si lo usa antes de tiempo.',
              ),
              items: const [
                DropdownMenuItem<int?>(
                    value: null, child: Text('Sin intervalo')),
                DropdownMenuItem<int?>(value: 60, child: Text('Cada 1 h')),
                DropdownMenuItem<int?>(value: 120, child: Text('Cada 2 h')),
                DropdownMenuItem<int?>(value: 240, child: Text('Cada 4 h')),
                DropdownMenuItem<int?>(value: 360, child: Text('Cada 6 h')),
                DropdownMenuItem<int?>(value: 480, child: Text('Cada 8 h')),
                DropdownMenuItem<int?>(value: 720, child: Text('Cada 12 h')),
                DropdownMenuItem<int?>(
                    value: 1440, child: Text('Una vez al día')),
              ],
              onChanged: (v) {
                draft.prnMinIntervalMin = v;
                onChanged();
              },
            ),
          ],
          if (!draft.isPrn) ...[
            const SizedBox(height: 8),
            _HorariosEditor(
              times: draft.times,
              onChanged: (nuevos) {
                draft.times = nuevos;
                onChanged();
              },
            ),
            const SizedBox(height: 8),
            TextFormField(
              initialValue: draft.scheduleLabel,
              decoration: const InputDecoration(
                labelText: 'Referencia (opcional)',
                hintText: 'Ej: con el desayuno',
              ),
              onChanged: (v) => draft.scheduleLabel = v,
            ),
          ],
        ],
      ),
    );
  }

  static String _fmt(double v) =>
      v == v.roundToDouble() ? v.toInt().toString() : v.toString();
}

/// Muestra el fármaco del catálogo ya elegido (nombre + forma/vía), de solo
/// lectura. La unidad y el rango se muestran aparte en la tarjeta.
class _FarmacoElegido extends StatelessWidget {
  const _FarmacoElegido({required this.elegido});
  final DrugCatalogItem elegido;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.verified_rounded,
                size: 18, color: AppColors.primary),
            const SizedBox(width: 6),
            Expanded(
              child: Text(elegido.label,
                  style: const TextStyle(
                      fontWeight: FontWeight.w700, fontSize: 15)),
            ),
          ],
        ),
        const SizedBox(height: 2),
        Text('${_forma(elegido.form)} · ${_via(elegido.route)}',
            style:
                const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
      ],
    );
  }

  static String _forma(String f) {
    const m = {
      'comprimido': 'Comprimido',
      'capsula': 'Cápsula',
      'jarabe': 'Jarabe',
      'gotas': 'Gotas',
      'aerosol': 'Aerosol',
      'inhalador': 'Inhalador',
      'parche': 'Parche',
      'ampolla': 'Ampolla',
      'supositorio': 'Supositorio',
      'crema': 'Crema',
    };
    return m[f] ?? f;
  }

  static String _via(String r) {
    const m = {
      'oral': 'vía oral',
      'sublingual': 'sublingual',
      'inhalatoria': 'inhalatoria',
      'transdermica': 'transdérmica',
      'intramuscular': 'intramuscular',
      'subcutanea': 'subcutánea',
      'endovenosa': 'endovenosa',
      'rectal': 'rectal',
      'topica': 'tópica',
    };
    return m[r] ?? r;
  }
}

/// Selector del catálogo de fármacos con autocompletado. Si el médico no elige
/// ninguno, el texto que escribe queda como fármaco de texto libre (y entonces
/// aplica el tope de cordura del backend, no el rango por fármaco).
class _SelectorCatalogo extends StatelessWidget {
  const _SelectorCatalogo({
    required this.catalogo,
    required this.nombreLibre,
    required this.onNombreLibre,
    required this.onElegir,
  });

  final List<DrugCatalogItem> catalogo;
  final String nombreLibre;
  final ValueChanged<String> onNombreLibre;
  final ValueChanged<DrugCatalogItem> onElegir;

  @override
  Widget build(BuildContext context) {
    return Autocomplete<DrugCatalogItem>(
      displayStringForOption: (d) => d.label,
      initialValue: TextEditingValue(text: nombreLibre),
      optionsBuilder: (value) {
        final q = value.text.trim().toLowerCase();
        if (q.isEmpty) return catalogo;
        return catalogo.where((d) =>
            d.label.toLowerCase().contains(q) ||
            d.activeIngredient.toLowerCase().contains(q));
      },
      onSelected: onElegir,
      fieldViewBuilder: (context, controller, focusNode, onSubmit) {
        return TextFormField(
          controller: controller,
          focusNode: focusNode,
          decoration: const InputDecoration(
            labelText: 'Fármaco',
            hintText: 'Busca en el catálogo o escribe el nombre',
            suffixIcon: Icon(Icons.search_rounded, size: 20),
          ),
          // Lo que se escriba sin elegir queda como texto libre.
          onChanged: onNombreLibre,
        );
      },
      optionsViewBuilder: (context, onSelected, options) {
        return Align(
          alignment: Alignment.topLeft,
          child: Material(
            elevation: 4,
            borderRadius: BorderRadius.circular(12),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 280, maxWidth: 360),
              child: ListView.builder(
                padding: EdgeInsets.zero,
                shrinkWrap: true,
                itemCount: options.length,
                itemBuilder: (context, i) {
                  final d = options.elementAt(i);
                  return ListTile(
                    dense: true,
                    title: Text(d.label),
                    subtitle: Text('${d.activeIngredient} · ${d.rangoLegible}',
                        style: const TextStyle(fontSize: 12)),
                    onTap: () => onSelected(d),
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Editor simple de horarios de toma (chips con hora + agregar).
class _HorariosEditor extends StatelessWidget {
  const _HorariosEditor({required this.times, required this.onChanged});

  final List<String> times;
  final ValueChanged<List<String>> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Horarios',
            style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final t in times)
              Chip(
                label: Text(t),
                onDeleted: times.length > 1
                    ? () => onChanged([...times]..remove(t))
                    : null,
              ),
            ActionChip(
              avatar: const Icon(Icons.add_rounded, size: 18),
              label: const Text('Hora'),
              onPressed: () async {
                final picked = await showTimePicker(
                  context: context,
                  initialTime: const TimeOfDay(hour: 8, minute: 0),
                );
                if (picked != null) {
                  final hh = picked.hour.toString().padLeft(2, '0');
                  final mm = picked.minute.toString().padLeft(2, '0');
                  final nuevo = '$hh:$mm';
                  if (!times.contains(nuevo)) {
                    onChanged([...times, nuevo]..sort());
                  }
                }
              },
            ),
          ],
        ),
      ],
    );
  }
}
