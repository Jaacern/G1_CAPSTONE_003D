import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../core/network/api_client.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/common.dart';
import '../../auth/application/auth_controller.dart';
import '../application/patients_providers.dart';
import '../data/patients_repository.dart';
import '../domain/models.dart';

/// Onboarding: crear el perfil del adulto mayor (ticket AGE-204).
class CreatePatientScreen extends ConsumerStatefulWidget {
  const CreatePatientScreen({super.key});

  @override
  ConsumerState<CreatePatientScreen> createState() => _CreatePatientScreenState();
}

class _CreatePatientScreenState extends ConsumerState<CreatePatientScreen> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _conditions = TextEditingController();
  final _notes = TextEditingController();
  DateTime? _birthDate;
  String? _sex;
  bool _loading = false;

  Future<void> _pickBirthDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime(now.year - 75),
      firstDate: DateTime(1900),
      lastDate: now,
      locale: const Locale('es'),
    );
    if (picked != null) setState(() => _birthDate = picked);
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    if (_birthDate == null) {
      showAppSnackBar(context, 'Selecciona la fecha de nacimiento', error: true);
      return;
    }
    setState(() => _loading = true);
    try {
      final patient = await ref.read(patientsRepositoryProvider).createPatient(
            NewPatient(
              fullName: _name.text.trim(),
              birthDate: _birthDate!,
              sex: _sex,
              conditions: _conditions.text
                  .split(',')
                  .map((c) => c.trim())
                  .where((c) => c.isNotEmpty)
                  .toList(),
            ),
          );
      ref.invalidate(myPatientsProvider);
      await ref.read(authControllerProvider.notifier).refreshProfile();
      if (mounted) {
        showAppSnackBar(context, '${patient.fullName} fue agregado. Ahora invita a su círculo de cuidado.');
        context.go('/home');
      }
    } on ApiException catch (e) {
      if (mounted) showAppSnackBar(context, e.message, error: true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final dateLabel = _birthDate == null
        ? 'Fecha de nacimiento'
        : DateFormat('d MMMM y', 'es').format(_birthDate!);

    return Scaffold(
      appBar: AppBar(title: const Text('¿A quién vas a cuidar?')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Crea el perfil de tu ser querido. Después podrás invitar a la cuidadora, al médico y a otros familiares.',
                  style: TextStyle(color: AppColors.textSecondary),
                ),
                const SizedBox(height: 24),
                TextFormField(
                  controller: _name,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(
                      labelText: 'Nombre completo', prefixIcon: Icon(Icons.person_outline)),
                  validator: (v) =>
                      v != null && v.trim().length >= 2 ? null : 'Escribe el nombre',
                ),
                const SizedBox(height: 16),
                OutlinedButton.icon(
                  onPressed: _pickBirthDate,
                  icon: const Icon(Icons.cake_outlined),
                  label: Align(alignment: Alignment.centerLeft, child: Text(dateLabel)),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(52),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    foregroundColor: _birthDate == null
                        ? AppColors.textSecondary
                        : AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<String>(
                  value: _sex,
                  decoration: const InputDecoration(
                      labelText: 'Sexo (opcional)', prefixIcon: Icon(Icons.wc_outlined)),
                  items: const [
                    DropdownMenuItem(value: 'female', child: Text('Mujer')),
                    DropdownMenuItem(value: 'male', child: Text('Hombre')),
                    DropdownMenuItem(value: 'other', child: Text('Otro')),
                  ],
                  onChanged: (v) => setState(() => _sex = v),
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _conditions,
                  decoration: const InputDecoration(
                    labelText: 'Padecimientos (separados por coma)',
                    prefixIcon: Icon(Icons.medical_information_outlined),
                    helperText: 'Ej. hipertensión, diabetes',
                  ),
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _notes,
                  maxLines: 3,
                  decoration: const InputDecoration(
                      labelText: 'Notas generales (opcional)', alignLabelWithHint: true),
                ),
                const SizedBox(height: 28),
                FilledButton(
                  onPressed: _loading ? null : _submit,
                  child: _loading
                      ? const SizedBox(
                          width: 22, height: 22,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Text('Crear perfil'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
