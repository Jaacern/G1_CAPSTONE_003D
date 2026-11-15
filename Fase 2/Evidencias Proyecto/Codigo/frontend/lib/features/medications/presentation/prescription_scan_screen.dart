import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../../../core/config/app_config.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/upload_service.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/common.dart';
import '../../../core/widgets/vista_previa_archivo.dart';
import '../data/medications_repository.dart';
import '../domain/models.dart';
import '../domain/treatment.dart' show TreatmentItemDraft;
import 'dose_unit_field.dart';

/// Escaneo de receta con OCR (ticket AGE-405): foto -> subida -> borrador
/// estructurado editable -> guardar como indicaciones.
class PrescriptionScanScreen extends ConsumerStatefulWidget {
  const PrescriptionScanScreen({super.key, required this.patientId});

  final String patientId;

  @override
  ConsumerState<PrescriptionScanScreen> createState() =>
      _PrescriptionScanScreenState();
}

class _PrescriptionScanScreenState
    extends ConsumerState<PrescriptionScanScreen> {
  final _picker = ImagePicker();

  XFile? _image;
  bool _scanning = false;
  String? _error;
  List<_DraftEntry>? _drafts;

  Future<void> _pick(ImageSource source) async {
    try {
      final picked = await _picker.pickImage(
          source: source, imageQuality: 85, maxWidth: 2000);
      if (picked == null) return;
      setState(() {
        _image = picked;
        _drafts = null;
        _error = null;
      });
      await _scan();
    } catch (e) {
      setState(() => _error = 'No se pudo obtener la imagen.');
    }
  }

  Future<void> _scan() async {
    if (_image == null) return;
    setState(() {
      _scanning = true;
      _error = null;
    });
    try {
      final uploaded = await ref.read(uploadServiceProvider).uploadFile(_image!,
          kind: 'prescription', patientId: widget.patientId);
      final draft = await ref
          .read(medicationsRepositoryProvider)
          .scanPrescription(widget.patientId, uploaded.fileUrl);
      setState(() {
        _drafts = draft.medications.map(_DraftEntry.from).toList();
        if (_drafts!.isEmpty) {
          _error = 'No se detectaron medicamentos en la receta.';
        }
      });
    } catch (e) {
      setState(() => _error = _mensajeDeError(e));
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  /// Traduce el fallo a algo que explique qué hacer.
  ///
  /// Las tres causas son distintas y piden cosas distintas: si el servidor
  /// no tiene el motor encendido, repetir la foto no sirve de nada; si la
  /// foto salió ilegible, sí.
  String _mensajeDeError(Object e) {
    if (e is ApiException) {
      switch (e.code) {
        case 'OCR_NOT_CONFIGURED':
          return 'La lectura de recetas no está habilitada en este '
              'servidor. Puedes agregar los medicamentos a mano.';
        case 'OCR_FAILED':
          return 'No se pudo leer la foto. Intenta de nuevo con más luz, '
              'el papel plano y la cámara en paralelo.';
        case 'STORAGE_ERROR':
          return 'La foto se subió pero no se pudo recuperar. Intenta de '
              'nuevo.';
      }
      return e.message;
    }
    return 'No se pudo leer la receta. Intenta de nuevo.';
  }

  /// Lleva lo leído al editor de tratamientos, donde el médico lo revisa.
  ///
  /// Antes se guardaba directo como "medicamento" con el nombre que leyó el
  /// OCR: sin catálogo de fármacos, sin rango de dosis, sin cruce de alergias
  /// y en una tabla que el generador de dosis ignora si el paciente ya tiene
  /// tratamiento. Una lectura automática de un papel no puede entrar al plan
  /// sin que el médico la confirme.
  Future<void> _saveAll() async {
    final drafts = _drafts;
    if (drafts == null || drafts.isEmpty) return;
    final indicaciones = [
      for (final d in drafts)
        TreatmentItemDraft(
          name: d.name.text.trim(),
          doseAmount:
              double.tryParse(d.dose.text.trim().replaceAll(',', '.')) ?? 0,
          doseUnit: d.unit,
          times: d.schedule.text
              .split(',')
              .map((t) => t.trim())
              .where((t) => RegExp(r'^\d{1,2}:\d{2}$').hasMatch(t))
              .toList(),
          instructions: d.instructions.text.trim().isEmpty
              ? null
              : d.instructions.text.trim(),
        ),
    ];
    context.pushReplacement(
      '/treatment?patient=${widget.patientId}&specialty=general',
      extra: indicaciones,
    );
  }

  @override
  void dispose() {
    for (final d in _drafts ?? const <_DraftEntry>[]) {
      d.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!AppConfig.hasPrescriptionScan) {
      return Scaffold(
        appBar: AppBar(title: const Text('Escanear receta')),
        body: const ComingSoonView(
          icon: Icons.document_scanner_rounded,
          title: 'Escaneo de recetas',
          subtitle:
              'El reconocimiento de recetas (OCR) estará disponible pronto.',
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Escanear receta')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 100),
        children: [
          AppCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_image != null)
                  ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: VistaPreviaArchivo(_image!, height: 180),
                  )
                else
                  Container(
                    height: 140,
                    decoration: BoxDecoration(
                      color: AppColors.primary.withValues(alpha: .06),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    alignment: Alignment.center,
                    child: const Icon(Icons.receipt_long_rounded,
                        size: 56, color: AppColors.primary),
                  ),
                const SizedBox(height: 12),
                const Text(
                  'Toma o elige una foto de la receta. Detectaremos los '
                  'medicamentos automáticamente para que los revises.',
                  style: TextStyle(color: AppColors.textSecondary),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        onPressed:
                            _scanning ? null : () => _pick(ImageSource.camera),
                        icon: const Icon(Icons.photo_camera_rounded),
                        label: const Text('Cámara'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed:
                            _scanning ? null : () => _pick(ImageSource.gallery),
                        icon: const Icon(Icons.photo_library_rounded),
                        label: const Text('Galería'),
                        style: OutlinedButton.styleFrom(
                            minimumSize: const Size.fromHeight(52)),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          if (_scanning)
            const Padding(
              padding: EdgeInsets.only(top: 24),
              child: Column(
                children: [
                  LoadingView(),
                  SizedBox(height: 12),
                  Text('Analizando la receta...',
                      style: TextStyle(color: AppColors.textSecondary)),
                ],
              ),
            )
          else if (_error != null)
            ErrorView(message: _error!, onRetry: _image == null ? null : _scan)
          else if (_drafts != null && _drafts!.isNotEmpty) ...[
            Text('Medicamentos detectados',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            const Text('Revisa y edita antes de guardar.',
                style: TextStyle(color: AppColors.textSecondary)),
            const SizedBox(height: 12),
            for (var i = 0; i < _drafts!.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: _DraftCard(
                  entry: _drafts![i],
                  onRemove: () => setState(() {
                    _drafts!.removeAt(i).dispose();
                  }),
                  onUnitChanged: (u) => setState(() => _drafts![i].unit = u),
                ),
              ),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: _saveAll,
              icon: const Icon(Icons.assignment_rounded),
              label: Text(_drafts!.length == 1
                  ? 'Revisar 1 indicación en el tratamiento'
                  : 'Revisar ${_drafts!.length} indicaciones en el tratamiento'),
            ),
          ],
        ],
      ),
    );
  }
}

/// Modelo mutable de un borrador editable en la UI.
class _DraftEntry {
  _DraftEntry({
    required this.name,
    required this.dose,
    required this.unit,
    required this.schedule,
    required this.instructions,
    required this.startDate,
    this.endDate,
  });

  final TextEditingController name;
  final TextEditingController dose;

  /// Elegida de una lista, no escrita: el backend solo admite diez valores.
  String unit;
  final TextEditingController schedule; // 'HH:mm, HH:mm'
  final TextEditingController instructions;
  DateTime startDate;
  DateTime? endDate;

  factory _DraftEntry.from(NewMedication m) => _DraftEntry(
        name: TextEditingController(text: m.name),
        dose: TextEditingController(text: m.dose),
        unit: unidadesDeDosis.contains(m.unit) ? m.unit : unidadesDeDosis.first,
        schedule: TextEditingController(text: m.schedule.join(', ')),
        instructions: TextEditingController(text: m.instructions ?? ''),
        startDate: m.startDate,
        endDate: m.endDate,
      );

  NewMedication toNewMedication() => NewMedication(
        name: name.text.trim(),
        dose: dose.text.trim(),
        unit: unit,
        schedule: schedule.text
            .split(',')
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty)
            .toList(),
        instructions: instructions.text.trim(),
        startDate: startDate,
        endDate: endDate,
      );

  void dispose() {
    name.dispose();
    dose.dispose();
    schedule.dispose();
    instructions.dispose();
  }
}

class _DraftCard extends StatelessWidget {
  const _DraftCard({
    required this.entry,
    required this.onRemove,
    required this.onUnitChanged,
  });

  final _DraftEntry entry;
  final VoidCallback onRemove;

  /// La unidad vive en el borrador, que es mutable y no notifica solo. El
  /// padre envuelve esto en setState para que la tarjeta se redibuje.
  final ValueChanged<String> onUnitChanged;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.medication_rounded, color: AppColors.primary),
              const SizedBox(width: 8),
              const Expanded(
                child: Text('Medicamento',
                    style: TextStyle(fontWeight: FontWeight.w700)),
              ),
              IconButton(
                tooltip: 'Quitar este medicamento',
                icon: const Icon(Icons.delete_outline_rounded,
                    color: AppColors.textSecondary),
                onPressed: onRemove,
              ),
            ],
          ),
          const SizedBox(height: 4),
          TextField(
            controller: entry.name,
            decoration: const InputDecoration(labelText: 'Nombre'),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: entry.dose,
                  decoration: const InputDecoration(labelText: 'Dosis'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: DoseUnitField(
                  value: entry.unit,
                  onChanged: onUnitChanged,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: entry.schedule,
            decoration: const InputDecoration(
                labelText: 'Horarios (HH:mm, separados por coma)'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: entry.instructions,
            maxLines: 2,
            decoration: const InputDecoration(labelText: 'Instrucciones'),
          ),
        ],
      ),
    );
  }
}
