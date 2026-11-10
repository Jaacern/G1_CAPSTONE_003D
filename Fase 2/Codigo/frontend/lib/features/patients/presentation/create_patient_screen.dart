import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../core/network/api_client.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/validation/identity_validators.dart';
import '../../../core/widgets/common.dart';
import '../../auth/application/auth_controller.dart';
import '../application/patients_providers.dart';
import '../data/patients_repository.dart';
import '../domain/models.dart';

/// Onboarding: crear el perfil del adulto mayor (ticket AGE-204).
///
/// Pide lo que se necesita para identificar a la persona y actuar en una
/// urgencia (obligatorio) y deja lo clínico como opcional, porque no todos
/// tienen alergias ni enfermedades crónicas, y quien crea el perfil puede no
/// saberlo todavía. Dejar la sección de salud vacía significa "no informado",
/// no "sano": se puede completar después desde la ficha.
class CreatePatientScreen extends ConsumerStatefulWidget {
  const CreatePatientScreen({super.key});

  @override
  ConsumerState<CreatePatientScreen> createState() =>
      _CreatePatientScreenState();
}

class _CreatePatientScreenState extends ConsumerState<CreatePatientScreen> {
  final _formKey = GlobalKey<FormState>();

  // Identidad
  final _firstName = TextEditingController();
  final _secondName = TextEditingController();
  final _lastName = TextEditingController();
  final _secondLastName = TextEditingController();
  final _rut = TextEditingController();
  DateTime? _birthDate;
  String? _sex;

  // Domicilio
  final _address = TextEditingController();

  // Contacto de emergencia
  final _ecFirstName = TextEditingController();
  final _ecLastName = TextEditingController();
  final _ecRelationship = TextEditingController();
  final _ecPhone = TextEditingController();

  // Salud (opcional)
  String? _insurance;
  final Set<String> _conditions = {};
  final Map<String, NewAllergy> _allergies = {};

  bool _loading = false;
  bool _birthDateMissing = false;
  String? _error;

  @override
  void dispose() {
    for (final c in [
      _firstName,
      _secondName,
      _lastName,
      _secondLastName,
      _rut,
      _address,
      _ecFirstName,
      _ecLastName,
      _ecRelationship,
      _ecPhone,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _pickBirthDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _birthDate ?? DateTime(now.year - 75),
      firstDate: DateTime(1900, 1, 2),
      lastDate: now,
      locale: const Locale('es'),
      helpText: 'Fecha de nacimiento',
    );
    if (picked != null) {
      setState(() {
        _birthDate = picked;
        _birthDateMissing = false;
      });
    }
  }

  Future<void> _submit() async {
    final formOk = _formKey.currentState!.validate();
    setState(() => _birthDateMissing = _birthDate == null);
    if (!formOk || _birthDate == null) {
      setState(() => _error = 'Revisa los campos marcados.');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final patient = await ref.read(patientsRepositoryProvider).createPatient(
            NewPatient(
              firstName: _firstName.text,
              secondName: _secondName.text,
              lastName: _lastName.text,
              secondLastName: _secondLastName.text,
              rut: formatRut(_rut.text),
              birthDate: _birthDate!,
              sex: _sex!,
              address: _address.text,
              emergencyContact: NewEmergencyContact(
                firstName: _ecFirstName.text,
                lastName: _ecLastName.text,
                relationship: _ecRelationship.text,
                phone: normalizePhone(_ecPhone.text)!,
              ),
              conditions: _conditions.toList(),
              allergies: _allergies.values.toList(),
              insurance: _insurance,
            ),
          );
      ref.invalidate(myPatientsProvider);
      await ref.read(authControllerProvider.notifier).refreshProfile();
      if (mounted) {
        showAppSnackBar(context,
            '${patient.fullName} fue agregado. Ahora invita a su círculo de cuidado.');
        context.go('/home');
      }
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.detailedMessage);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final dateLabel = _birthDate == null
        ? 'Fecha de nacimiento *'
        : 'Nació el ${DateFormat('d MMMM y', 'es').format(_birthDate!)}';

    return Scaffold(
      appBar: AppBar(title: const Text('¿A quién vas a cuidar?')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text(
                      'Crea el perfil de tu ser querido. Los campos con * son obligatorios. '
                      'Después podrás invitar a la cuidadora, al médico y a otros familiares.',
                      style: TextStyle(color: AppColors.textSecondary),
                    ),

                    // ── Identidad ──────────────────────────────────────
                    const _Seccion('Identidad'),
                    _fila(
                      _campo(_firstName, 'Nombre *',
                          hints: const [AutofillHints.givenName],
                          validator: (v) =>
                              validatePersonName(v, campo: 'el nombre')),
                      _campo(_secondName, 'Segundo nombre',
                          hints: const [AutofillHints.middleName],
                          validator: (v) => validatePersonName(v,
                              campo: 'el segundo nombre', required: false)),
                    ),
                    const SizedBox(height: 14),
                    _fila(
                      _campo(_lastName, 'Apellido *',
                          hints: const [AutofillHints.familyName],
                          validator: (v) =>
                              validatePersonName(v, campo: 'el apellido')),
                      _campo(_secondLastName, 'Segundo apellido',
                          validator: (v) => validatePersonName(v,
                              campo: 'el segundo apellido', required: false)),
                    ),
                    const SizedBox(height: 14),
                    TextFormField(
                      controller: _rut,
                      enabled: !_loading,
                      decoration: const InputDecoration(
                        labelText: 'RUT *',
                        hintText: '12.345.678-5',
                        prefixIcon: Icon(Icons.badge_outlined),
                      ),
                      validator: validateRut,
                      onEditingComplete: () {
                        if (validateRut(_rut.text) == null) {
                          _rut.text = formatRut(_rut.text);
                        }
                        FocusScope.of(context).nextFocus();
                      },
                    ),
                    const SizedBox(height: 14),
                    OutlinedButton.icon(
                      onPressed: _loading ? null : _pickBirthDate,
                      icon: const Icon(Icons.cake_outlined),
                      label: Align(
                          alignment: Alignment.centerLeft,
                          child: Text(dateLabel)),
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size.fromHeight(52),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14)),
                        side: _birthDateMissing
                            ? const BorderSide(color: AppColors.critical)
                            : null,
                        foregroundColor: _birthDate == null
                            ? AppColors.textSecondary
                            : AppColors.textPrimary,
                      ),
                    ),
                    // Siempre presente (vacío si no hay error): insertar un
                    // widget en medio de la columna hacía que Flutter
                    // recreara los campos de abajo y perdiera su validación.
                    _LineaError(_birthDateMissing
                        ? 'Selecciona la fecha de nacimiento'
                        : null),
                    const SizedBox(height: 14),
                    DropdownButtonFormField<String>(
                      initialValue: _sex,
                      decoration: const InputDecoration(
                          labelText: 'Sexo *',
                          prefixIcon: Icon(Icons.wc_outlined)),
                      items: const [
                        DropdownMenuItem(value: 'female', child: Text('Mujer')),
                        DropdownMenuItem(value: 'male', child: Text('Hombre')),
                        DropdownMenuItem(value: 'other', child: Text('Otro')),
                      ],
                      // patients.sex es NOT NULL: sin sexo el backend da 422.
                      validator: (v) => v == null ? 'Selecciona el sexo' : null,
                      onChanged:
                          _loading ? null : (v) => setState(() => _sex = v),
                    ),

                    // ── Domicilio ──────────────────────────────────────
                    const _Seccion('Domicilio'),
                    TextFormField(
                      controller: _address,
                      enabled: !_loading,
                      textCapitalization: TextCapitalization.sentences,
                      autofillHints: const [AutofillHints.fullStreetAddress],
                      decoration: const InputDecoration(
                        labelText: 'Domicilio *',
                        hintText: 'Calle, número, depto. y comuna',
                        prefixIcon: Icon(Icons.home_outlined),
                      ),
                      validator: (v) => (v ?? '').trim().length >= 5
                          ? null
                          : 'Escribe el domicilio completo (calle, número y comuna)',
                    ),

                    // ── Contacto de emergencia ────────────────────────
                    const _Seccion('Contacto de emergencia',
                        detalle:
                            'A quién llamar si algo pasa. Lo verá el equipo de salud y el SAMU en la hoja de emergencia.'),
                    _fila(
                      _campo(_ecFirstName, 'Nombre *',
                          validator: (v) =>
                              validatePersonName(v, campo: 'el nombre')),
                      _campo(_ecLastName, 'Apellido *',
                          validator: (v) =>
                              validatePersonName(v, campo: 'el apellido')),
                    ),
                    const SizedBox(height: 14),
                    _fila(
                      _campo(_ecRelationship, 'Parentesco *',
                          hint: 'Hijo, hija, cónyuge…',
                          validator: (v) =>
                              validatePersonName(v, campo: 'el parentesco')),
                      TextFormField(
                        controller: _ecPhone,
                        enabled: !_loading,
                        keyboardType: TextInputType.phone,
                        decoration: const InputDecoration(
                          labelText: 'Teléfono *',
                          hintText: '9 1234 5678',
                          prefixIcon: Icon(Icons.phone_outlined),
                        ),
                        validator: validatePhone,
                      ),
                    ),

                    // ── Salud (opcional) ──────────────────────────────
                    const _Seccion('Salud (opcional)',
                        detalle:
                            'Marca solo lo que sepas con certeza. Si lo dejas vacío quedará como “no informado” y podrás completarlo después en la ficha.'),
                    DropdownButtonFormField<String?>(
                      initialValue: _insurance,
                      decoration: const InputDecoration(
                          labelText: 'Previsión de salud',
                          prefixIcon: Icon(Icons.health_and_safety_outlined)),
                      items: const [
                        DropdownMenuItem(
                            value: null, child: Text('No informada')),
                        DropdownMenuItem(
                            value: 'fonasa', child: Text('Fonasa')),
                        DropdownMenuItem(
                            value: 'isapre', child: Text('Isapre')),
                        DropdownMenuItem(
                            value: 'particular', child: Text('Particular')),
                        DropdownMenuItem(value: 'otra', child: Text('Otra')),
                      ],
                      onChanged: _loading
                          ? null
                          : (v) => setState(() => _insurance = v),
                    ),
                    const SizedBox(height: 16),
                    _CondicionesCronicas(
                      seleccionadas: _conditions,
                      enabled: !_loading,
                      onChanged: (code, sel) => setState(() => sel
                          ? _conditions.add(code)
                          : _conditions.remove(code)),
                    ),
                    const SizedBox(height: 16),
                    _Alergias(
                      seleccionadas: _allergies,
                      enabled: !_loading,
                      onChanged: () => setState(() {}),
                    ),

                    _ErrorGeneral(
                      message: _error,
                      onDismiss: () => setState(() => _error = null),
                    ),
                    const SizedBox(height: 28),
                    FilledButton(
                      onPressed: _loading ? null : _submit,
                      child: _loading
                          ? const SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white))
                          : const Text('Crear perfil'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _campo(
    TextEditingController c,
    String label, {
    String? hint,
    List<String>? hints,
    String? Function(String?)? validator,
  }) =>
      TextFormField(
        controller: c,
        enabled: !_loading,
        textCapitalization: TextCapitalization.words,
        textInputAction: TextInputAction.next,
        autofillHints: hints,
        decoration: InputDecoration(labelText: label, hintText: hint),
        validator: validator,
      );

  /// Dos campos lado a lado en pantallas anchas, uno debajo del otro en
  /// teléfonos angostos (no se cortan las etiquetas).
  Widget _fila(Widget a, Widget b) => LayoutBuilder(
        builder: (context, c) => c.maxWidth < 420
            ? Column(children: [a, const SizedBox(height: 14), b])
            : Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: a),
                  const SizedBox(width: 12),
                  Expanded(child: b),
                ],
              ),
      );
}

/// Mensaje de error bajo un control que no es un FormField. Ocupa siempre
/// su lugar en el árbol para no desplazar a los campos siguientes.
class _LineaError extends StatelessWidget {
  const _LineaError(this.texto);

  final String? texto;

  @override
  Widget build(BuildContext context) {
    if (texto == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(left: 12, top: 6),
      child: Text(texto!,
          style: const TextStyle(color: AppColors.critical, fontSize: 12)),
    );
  }
}

/// Error general del envío. Mismo criterio que [_LineaError].
class _ErrorGeneral extends StatelessWidget {
  const _ErrorGeneral({required this.message, required this.onDismiss});

  final String? message;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    if (message == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 20),
      child: InlineError(message: message!, onDismiss: onDismiss),
    );
  }
}

class _Seccion extends StatelessWidget {
  const _Seccion(this.titulo, {this.detalle});

  final String titulo;
  final String? detalle;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 28, bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            header: true,
            child: Text(titulo,
                style:
                    const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
          ),
          if (detalle != null) ...[
            const SizedBox(height: 4),
            Text(detalle!,
                style: const TextStyle(
                    fontSize: 13, color: AppColors.textSecondary)),
          ],
        ],
      ),
    );
  }
}

/// Enfermedades crónicas desde el catálogo. Ninguna es obligatoria.
class _CondicionesCronicas extends ConsumerWidget {
  const _CondicionesCronicas({
    required this.seleccionadas,
    required this.enabled,
    required this.onChanged,
  });

  final Set<String> seleccionadas;
  final bool enabled;
  final void Function(String code, bool selected) onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final catalogo = ref.watch(conditionCatalogProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Enfermedades crónicas',
            style: TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        catalogo.when(
          loading: () => const LinearProgressIndicator(),
          error: (_, __) => const Text(
              'No se pudo cargar el catálogo. Podrás agregarlas después en la ficha.',
              style: TextStyle(color: AppColors.textSecondary)),
          data: (items) => Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final c in items)
                FilterChip(
                  label: Text(c.label),
                  selected: seleccionadas.contains(c.condition),
                  onSelected: enabled ? (s) => onChanged(c.condition, s) : null,
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Alergias desde el catálogo, con su gravedad. Ninguna es obligatoria.
class _Alergias extends ConsumerWidget {
  const _Alergias({
    required this.seleccionadas,
    required this.enabled,
    required this.onChanged,
  });

  final Map<String, NewAllergy> seleccionadas;
  final bool enabled;
  final VoidCallback onChanged;

  static const _gravedades = {
    'leve': 'Leve',
    'moderada': 'Moderada',
    'severa': 'Severa',
    'anafilaxia': 'Anafilaxia',
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final catalogo = ref.watch(allergenCatalogProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Alergias conocidas',
            style: TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        catalogo.when(
          loading: () => const LinearProgressIndicator(),
          error: (_, __) => const Text(
              'No se pudo cargar el catálogo. Podrás agregarlas después en la ficha.',
              style: TextStyle(color: AppColors.textSecondary)),
          data: (items) => Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final a in items)
                    FilterChip(
                      label: Text(a.label),
                      selected: seleccionadas.containsKey(a.code),
                      onSelected: enabled
                          ? (s) {
                              if (s) {
                                seleccionadas[a.code] = NewAllergy(
                                    substance: a.code, category: a.category);
                              } else {
                                seleccionadas.remove(a.code);
                              }
                              onChanged();
                            }
                          : null,
                    ),
                ],
              ),
              for (final a
                  in items.where((i) => seleccionadas.containsKey(i.code)))
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: DropdownButtonFormField<String>(
                    initialValue: seleccionadas[a.code]!.severity,
                    decoration:
                        InputDecoration(labelText: 'Gravedad: ${a.label}'),
                    items: [
                      for (final g in _gravedades.entries)
                        DropdownMenuItem(value: g.key, child: Text(g.value)),
                    ],
                    onChanged: enabled
                        ? (v) {
                            seleccionadas[a.code] = NewAllergy(
                                substance: a.code,
                                category: a.category,
                                severity: v ?? 'moderada');
                            onChanged();
                          }
                        : null,
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
