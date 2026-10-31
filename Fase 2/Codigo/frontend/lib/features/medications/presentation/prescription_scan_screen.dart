import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../../../core/config/app_config.dart';
import '../../../core/network/upload_service.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/common.dart';
import '../application/medications_providers.dart';
import '../data/medications_repository.dart';
import '../domain/models.dart';

/// Escaneo de receta con OCR (ticket AGE-405): foto -> subida -> borrador
/// estructurado editable -> guardar como medicamento(s).
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

  File? _image;
  bool _scanning = false;
  bool _saving = false;
  String? _error;
  List<_DraftEntry>? _drafts;

  Future<void> _pick(ImageSource source) async {
    try {
      final picked = await _picker.pickImage(
          source: source, imageQuality: 85, maxWidth: 2000);
      if (picked == null) return;
      setState(() {
        _image = File(picked.path);
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
      final uploaded = await ref
          .read(uploadServiceProvider)
          .uploadFile(_image!, kind: 'prescription', patientId: widget.patientId);
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
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  Future<void> _saveAll() async {
    final drafts = _drafts;
    if (drafts == null || drafts.isEmpty) return;
    setState(() => _saving = true);
    final repo = ref.read(medicationsRepositoryProvider);
    try {
      for (final d in drafts) {
        await repo.createMedication(widget.patientId, d.toNewMedication());
      }
      ref.invalidate(medicationsProvider);
      ref.invalidate(todayDosesProvider);
      if (mounted) {
        showAppSnackBar(context,
            'Se guardó ${drafts.length} medicamento(s) de la receta.');
        context.pop();
      }
    } catch (e) {
      if (mounted) showAppSnackBar(context, e.toString(), error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
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
          subtitle: 'El reconocimiento de recetas (OCR) estará disponible pronto.',
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
                    child: Image.file(_image!,
                        height: 180, fit: BoxFit.cover),
                  )
                else
                  Container(
                    height: 140,
                    decoration: BoxDecoration(
                      color: AppColors.primary.withOpacity(.06),
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
                        onPressed: _scanning || _saving
                            ? null
                            : () => _pick(ImageSource.camera),
                        icon: const Icon(Icons.photo_camera_rounded),
                        label: const Text('Cámara'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _scanning || _saving
                            ? null
                            : () => _pick(ImageSource.gallery),
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
                ),
              ),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: _saving ? null : _saveAll,
              icon: _saving
                  ? const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.save_rounded),
              label: Text('Guardar como medicamento(s) (${_drafts!.length})'),
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
    required this.form,
    required this.schedule,
    required this.instructions,
    required this.startDate,
    this.endDate,
  });

  final TextEditingController name;
  final TextEditingController dose;
  final TextEditingController unit;
  final TextEditingController form;
  final TextEditingController schedule; // 'HH:mm, HH:mm'
  final TextEditingController instructions;
  DateTime startDate;
  DateTime? endDate;

  factory _DraftEntry.from(NewMedication m) => _DraftEntry(
        name: TextEditingController(text: m.name),
        dose: TextEditingController(text: m.dose),
        unit: TextEditingController(text: m.unit),
        form: TextEditingController(text: m.form),
        schedule: TextEditingController(text: m.schedule.join(', ')),
        instructions: TextEditingController(text: m.instructions ?? ''),
        startDate: m.startDate,
        endDate: m.endDate,
      );

  NewMedication toNewMedication() => NewMedication(
        name: name.text.trim(),
        dose: dose.text.trim(),
        unit: unit.text.trim(),
        form: form.text.trim(),
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
    unit.dispose();
    form.dispose();
    schedule.dispose();
    instructions.dispose();
  }
}

class _DraftCard extends StatelessWidget {
  const _DraftCard({required this.entry, required this.onRemove});

  final _DraftEntry entry;
  final VoidCallback onRemove;

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
                child: TextField(
                  controller: entry.unit,
                  decoration: const InputDecoration(labelText: 'Unidad'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: entry.form,
            decoration: const InputDecoration(labelText: 'Forma'),
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
            decoration:
                const InputDecoration(labelText: 'Instrucciones'),
          ),
        ],
      ),
    );
  }
}
