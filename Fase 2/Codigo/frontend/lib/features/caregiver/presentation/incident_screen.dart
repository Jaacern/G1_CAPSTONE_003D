import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../../../core/config/app_config.dart';
import '../../../core/network/upload_service.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/common.dart';
import '../application/caregiver_providers.dart';
import '../data/caregiver_repository.dart';

/// Severidad de un incidente (afecta color y prioridad).
enum _Severity {
  low('low', 'Leve', AppColors.statusOk),
  medium('medium', 'Moderada', AppColors.statusWarning),
  high('high', 'Grave', AppColors.statusAttention);

  const _Severity(this.apiValue, this.label, this.color);
  final String apiValue;
  final String label;
  final Color color;
}

/// Formulario para reportar un incidente.
class IncidentScreen extends ConsumerStatefulWidget {
  const IncidentScreen({super.key, required this.patientId});

  final String patientId;

  @override
  ConsumerState<IncidentScreen> createState() => _IncidentScreenState();
}

class _IncidentScreenState extends ConsumerState<IncidentScreen> {
  final _formKey = GlobalKey<FormState>();
  final _description = TextEditingController();
  final _picker = ImagePicker();

  final _types = const [
    'Caída',
    'Reacción adversa',
    'Fuga / desorientación',
    'Golpe o lesión',
    'Emergencia médica',
    'Otro',
  ];
  String? _type;
  _Severity _severity = _Severity.medium;
  File? _image;
  bool _saving = false;

  Future<void> _pick(ImageSource source) async {
    try {
      final picked =
          await _picker.pickImage(source: source, imageQuality: 85, maxWidth: 2000);
      if (picked == null) return;
      setState(() => _image = File(picked.path));
    } catch (_) {
      if (mounted) {
        showAppSnackBar(context, 'No se pudo obtener la imagen.', error: true);
      }
    }
  }

  @override
  void dispose() {
    _description.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    if (_type == null) {
      showAppSnackBar(context, 'Selecciona el tipo de incidente.', error: true);
      return;
    }
    setState(() => _saving = true);
    try {
      String? mediaUrl;
      if (_image != null) {
        final uploaded = await ref
            .read(uploadServiceProvider)
            .uploadFile(_image!, kind: 'photo', patientId: widget.patientId);
        mediaUrl = uploaded.fileUrl;
      }
      await ref.read(caregiverRepositoryProvider).createIncident(
            widget.patientId,
            type: _type!,
            severity: _severity.apiValue,
            description: _description.text.trim(),
            mediaUrl: mediaUrl,
          );
      ref.invalidate(observationsProvider);
      ref.invalidate(caregiverTodayProvider);
      if (mounted) {
        showAppSnackBar(context, 'Incidente reportado.');
        context.pop();
      }
    } catch (e) {
      if (mounted) showAppSnackBar(context, e.toString(), error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!AppConfig.hasCaregiverLog) {
      return Scaffold(
        appBar: AppBar(title: const Text('Incidente')),
        body: const ComingSoonView(
          icon: Icons.report_rounded,
          title: 'Registro de incidentes',
          subtitle: 'La bitácora de la cuidadora estará disponible pronto.',
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Reportar incidente')),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
          children: [
            DropdownButtonFormField<String>(
              value: _type,
              decoration: const InputDecoration(labelText: 'Tipo de incidente'),
              items: [
                for (final t in _types)
                  DropdownMenuItem(value: t, child: Text(t)),
              ],
              onChanged: (v) => setState(() => _type = v),
              validator: (v) => v == null ? 'Selecciona un tipo' : null,
            ),
            const SizedBox(height: 16),
            const Text('Severidad',
                style: TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                for (final s in _Severity.values)
                  ChoiceChip(
                    label: Text(s.label),
                    selected: _severity == s,
                    selectedColor: s.color.withOpacity(.18),
                    labelStyle: TextStyle(
                        color: _severity == s ? s.color : AppColors.textPrimary,
                        fontWeight: FontWeight.w600),
                    onSelected: (_) => setState(() => _severity = s),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _description,
              maxLines: 5,
              decoration: const InputDecoration(
                labelText: 'Descripción de lo ocurrido',
                alignLabelWithHint: true,
              ),
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? 'Describe el incidente' : null,
            ),
            const SizedBox(height: 16),
            if (_image != null)
              Stack(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: Image.file(_image!,
                        height: 180,
                        width: double.infinity,
                        fit: BoxFit.cover),
                  ),
                  Positioned(
                    top: 8,
                    right: 8,
                    child: CircleAvatar(
                      backgroundColor: Colors.black54,
                      child: IconButton(
                        icon: const Icon(Icons.close_rounded,
                            color: Colors.white),
                        onPressed: () => setState(() => _image = null),
                      ),
                    ),
                  ),
                ],
              ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _saving ? null : () => _pick(ImageSource.camera),
                    icon: const Icon(Icons.photo_camera_rounded),
                    label: const Text('Cámara'),
                    style: OutlinedButton.styleFrom(
                        minimumSize: const Size.fromHeight(52)),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed:
                        _saving ? null : () => _pick(ImageSource.gallery),
                    icon: const Icon(Icons.photo_library_rounded),
                    label: const Text('Galería'),
                    style: OutlinedButton.styleFrom(
                        minimumSize: const Size.fromHeight(52)),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _saving ? null : _save,
              style: FilledButton.styleFrom(
                  backgroundColor: AppColors.statusAttention),
              icon: _saving
                  ? const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.report_rounded),
              label: const Text('Reportar incidente'),
            ),
          ],
        ),
      ),
    );
  }
}
