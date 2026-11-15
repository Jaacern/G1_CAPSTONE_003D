import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/comunas.dart';
import '../../../core/network/api_client.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/validation/identity_validators.dart';
import '../../../core/widgets/common.dart';
import '../../auth/application/auth_controller.dart';
import '../data/professional_profile_repository.dart';
import '../domain/professional_profile.dart';

/// Perfil profesional de la cuidadora (RF-72) y su publicación en el
/// marketplace, donde la encuentran las familias (RF-75, RF-76).
///
/// Tiene lo justo para que una familia decida a quién deja a cargo de su
/// familiar: quién es (nombre en cuatro partes, RUT, teléfono), qué sabe
/// hacer (experiencia, especialidades, idiomas, certificaciones) y dónde y
/// cuándo trabaja (comunas, disponibilidad, noches, tarifa).
class ProfessionalProfileScreen extends ConsumerWidget {
  const ProfessionalProfileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final perfil = ref.watch(professionalProfileProvider);
    final opciones = ref.watch(professionalProfileOptionsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Mi perfil profesional')),
      body: perfil.when(
        loading: () => const LoadingView(),
        error: (e, _) => ErrorView(
          message: e is ApiException ? e.detailedMessage : e.toString(),
          onRetry: () => ref.invalidate(professionalProfileProvider),
        ),
        data: (p) => opciones.when(
          loading: () => const LoadingView(),
          error: (e, _) => ErrorView(
            message: e.toString(),
            onRetry: () => ref.invalidate(professionalProfileOptionsProvider),
          ),
          data: (o) => _Formulario(perfil: p, opciones: o),
        ),
      ),
    );
  }
}

class _Formulario extends ConsumerStatefulWidget {
  const _Formulario({required this.perfil, required this.opciones});

  final ProfessionalProfile perfil;
  final ProfileOptions opciones;

  @override
  ConsumerState<_Formulario> createState() => _FormularioState();
}

class _FormularioState extends ConsumerState<_Formulario> {
  final _formKey = GlobalKey<FormState>();
  late final _first = TextEditingController(text: widget.perfil.firstName);
  late final _second =
      TextEditingController(text: widget.perfil.secondName ?? '');
  late final _last = TextEditingController(text: widget.perfil.lastName);
  late final _secondLast =
      TextEditingController(text: widget.perfil.secondLastName ?? '');
  late final _rut = TextEditingController(text: widget.perfil.rut ?? '');
  late final _phone = TextEditingController(text: widget.perfil.phone ?? '');
  late final _headline = TextEditingController(text: widget.perfil.headline);
  late final _bio = TextEditingController(text: widget.perfil.bio);
  late final _years = TextEditingController(
      text: widget.perfil.yearsExperience == 0
          ? ''
          : '${widget.perfil.yearsExperience}');
  late final _rate = TextEditingController(
      text: widget.perfil.hourlyRate?.toString() ?? '');

  late String _availability = widget.perfil.availability;
  late bool _overnight = widget.perfil.acceptsOvernight;
  late final Set<String> _specialties = {...widget.perfil.specialties};
  late final Set<String> _languages = {...widget.perfil.languages};
  late final Set<String> _zones = {...widget.perfil.zones};
  late bool _publicar = widget.perfil.publicado;
  late ProfessionalProfile _guardado = widget.perfil;

  bool _guardando = false;
  String? _error;

  @override
  void dispose() {
    for (final c in [
      _first, _second, _last, _secondLast, _rut, _phone, _headline, _bio,
      _years, _rate,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  ProfessionalProfile _armar() {
    final phone = _phone.text.trim();
    final rut = _rut.text.trim();
    return ProfessionalProfile(
      firstName: _first.text.trim(),
      secondName: _second.text.trim(),
      lastName: _last.text.trim(),
      secondLastName: _secondLast.text.trim(),
      rut: rut.isEmpty ? null : formatRut(rut),
      phone: phone.isEmpty ? null : normalizePhone(phone),
      email: widget.perfil.email,
      headline: _headline.text.trim(),
      bio: _bio.text.trim(),
      yearsExperience: int.tryParse(_years.text.trim()) ?? 0,
      hourlyRate: int.tryParse(_rate.text.trim()),
      availability: _availability,
      acceptsOvernight: _overnight,
      specialties: _specialties.toList(),
      languages: _languages.toList(),
      zones: _zones.toList(),
    );
  }

  Future<void> _guardar() async {
    if (!_formKey.currentState!.validate()) {
      setState(() => _error = 'Revisa los campos marcados en rojo.');
      return;
    }
    setState(() {
      _guardando = true;
      _error = null;
    });
    try {
      final nuevo = await ref.read(professionalProfileRepositoryProvider).save(
            _armar(),
            // Un perfil suspendido no cambia de estado desde aquí.
            published: _guardado.suspendido ? null : _publicar,
          );
      // El nombre y el teléfono también son de la cuenta: se refresca la
      // sesión para que el resto de la app muestre lo nuevo.
      await ref.read(authControllerProvider.notifier).refreshProfile();
      if (!mounted) return;
      setState(() {
        _guardado = nuevo;
        _publicar = nuevo.publicado;
      });
      showAppSnackBar(
        context,
        nuevo.publicado
            ? 'Perfil guardado. Las familias ya pueden encontrarte.'
            : 'Perfil guardado. Todavía no es visible para las familias.',
      );
    } on ApiException catch (e) {
      // PROFILE_INCOMPLETE ya trae en el mensaje todo lo que falta.
      final msg =
          e.code == 'PROFILE_INCOMPLETE' ? e.message : e.detailedMessage;
      if (mounted) setState(() => _error = msg);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _guardando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final o = widget.opciones;
    final comunas = comunasConocidas;
    return Form(
      key: _formKey,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          _EstadoPublicacion(perfil: _guardado),
          const SizedBox(height: 16),
          const _Titulo('Datos personales'),
          AppCard(
            child: Column(
              children: [
                _Par(
                  _Texto(_first, 'Nombre',
                      validator: (v) => validatePersonName(v, campo: 'tu nombre')),
                  _Texto(_second, 'Segundo nombre (opcional)',
                      validator: (v) => validatePersonName(v,
                          campo: 'tu segundo nombre', required: false)),
                ),
                const SizedBox(height: 12),
                _Par(
                  _Texto(_last, 'Apellido',
                      validator: (v) =>
                          validatePersonName(v, campo: 'tu apellido')),
                  _Texto(_secondLast, 'Segundo apellido (opcional)',
                      validator: (v) => validatePersonName(v,
                          campo: 'tu segundo apellido', required: false)),
                ),
                const SizedBox(height: 12),
                _Par(
                  _Texto(_rut, 'RUT',
                      hint: '12.345.678-5',
                      validator: (v) =>
                          v == null || v.trim().isEmpty ? null : validateRut(v)),
                  _Texto(_phone, 'Teléfono',
                      hint: '9 1234 5678',
                      teclado: TextInputType.phone,
                      validator: (v) => validatePhone(v, required: false)),
                ),
                const SizedBox(height: 12),
                InputDecorator(
                  decoration: const InputDecoration(labelText: 'Correo'),
                  child: Text(widget.perfil.email,
                      style: const TextStyle(color: AppColors.textSecondary)),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          const _Titulo('Cómo trabajas'),
          AppCard(
            child: Column(
              children: [
                _Texto(_headline, 'Título del perfil',
                    hint: 'Ej: Cuidadora con experiencia en demencias',
                    maxLength: 120),
                const SizedBox(height: 4),
                _Texto(_bio, 'Presentación',
                    hint: 'Cuéntale a la familia tu experiencia y cómo cuidas.',
                    maxLength: 2000,
                    lineas: 4),
                const SizedBox(height: 4),
                _Par(
                  _Texto(_years, 'Años de experiencia',
                      teclado: TextInputType.number,
                      soloDigitos: true,
                      validator: (v) {
                        final n = int.tryParse((v ?? '').trim());
                        if ((v ?? '').trim().isEmpty) return null;
                        return n == null || n > 70 ? 'Entre 0 y 70' : null;
                      }),
                  _Texto(_rate, 'Tarifa por hora (opcional)',
                      hint: 'Ej: 6500',
                      prefijo: '\$ ',
                      teclado: TextInputType.number,
                      soloDigitos: true),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: o.availability.any((a) => a.code == _availability)
                      ? _availability
                      : null,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Disponibilidad'),
                  items: [
                    for (final a in o.availability)
                      DropdownMenuItem(value: a.code, child: Text(a.label)),
                  ],
                  onChanged: _guardando
                      ? null
                      : (v) => setState(() => _availability = v ?? _availability),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Acepto turnos de noche'),
                  value: _overnight,
                  onChanged: _guardando
                      ? null
                      : (v) => setState(() => _overnight = v),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          const _Titulo('Especialidades'),
          _Chips(
            opciones: [for (final s in o.specialties) (s.label, s.label)],
            elegidos: _specialties,
            onCambio: () => setState(() {}),
          ),
          const SizedBox(height: 16),
          const _Titulo('Idiomas'),
          _Chips(
            opciones: [for (final l in o.languages) (l.code, l.label)],
            elegidos: _languages,
            onCambio: () => setState(() {}),
          ),
          const SizedBox(height: 16),
          const _Titulo('Comunas donde trabajas'),
          _Chips(
            opciones: comunas,
            elegidos: _zones,
            onCambio: () => setState(() {}),
          ),
          const SizedBox(height: 16),
          const _Titulo('Certificaciones'),
          AppCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (_guardado.certifications.isEmpty)
                  const Text('Aún no tienes certificaciones registradas.')
                else
                  for (final c in _guardado.certifications)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Row(
                        children: [
                          const Icon(Icons.workspace_premium_outlined,
                              size: 18, color: AppColors.primary),
                          const SizedBox(width: 8),
                          Expanded(child: Text(c)),
                        ],
                      ),
                    ),
                const SizedBox(height: 4),
                const Text(
                  'Las certificaciones las verifica el equipo de AgeCare. '
                  'Escríbenos para agregar una.',
                  style:
                      TextStyle(fontSize: 12.5, color: AppColors.textSecondary),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          AppCard(
            child: SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Mostrar mi perfil a las familias',
                  style: TextStyle(fontWeight: FontWeight.w700)),
              subtitle: Text(_guardado.suspendido
                  ? 'Tu perfil está suspendido por el equipo de AgeCare.'
                  : 'Aparecerás en la búsqueda de cuidadoras del marketplace.'),
              value: _publicar,
              onChanged: _guardando || _guardado.suspendido
                  ? null
                  : (v) => setState(() => _publicar = v),
            ),
          ),
          _error == null
              ? const SizedBox.shrink()
              : Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: InlineError(
                      message: _error!,
                      onDismiss: () => setState(() => _error = null)),
                ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _guardando ? null : _guardar,
            icon: _guardando
                ? const SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.save_rounded),
            label: const Text('Guardar perfil'),
          ),
        ],
      ),
    );
  }
}

/// Franja de arriba: si las familias la ven o no, y qué le falta.
class _EstadoPublicacion extends StatelessWidget {
  const _EstadoPublicacion({required this.perfil});
  final ProfessionalProfile perfil;

  @override
  Widget build(BuildContext context) {
    final (color, icono, titulo) = switch (perfil.status) {
      ProfileStatus.published => (
          AppColors.statusOk,
          Icons.visibility_rounded,
          'Publicado: las familias pueden encontrarte',
        ),
      ProfileStatus.suspended => (
          AppColors.critical,
          Icons.block_rounded,
          'Suspendido por el equipo de AgeCare',
        ),
      ProfileStatus.draft => (
          AppColors.statusWarning,
          Icons.visibility_off_rounded,
          'Borrador: las familias aún no te ven',
        ),
    };
    return Semantics(
      container: true,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: color.withValues(alpha: .12),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icono, color: color),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(titulo,
                      style: const TextStyle(fontWeight: FontWeight.w700)),
                ),
              ],
            ),
            if (!perfil.publicado && perfil.missingForPublish.isNotEmpty) ...[
              const SizedBox(height: 8),
              const Text('Para publicarte falta:'),
              for (final m in perfil.missingForPublish)
                Padding(
                  padding: const EdgeInsets.only(left: 8, top: 2),
                  child: Text('• $m'),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Titulo extends StatelessWidget {
  const _Titulo(this.texto);
  final String texto;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8, left: 4),
        child: Semantics(
          header: true,
          child: Text(texto, style: Theme.of(context).textTheme.titleMedium),
        ),
      );
}

/// Dos campos lado a lado; en pantallas angostas, uno bajo el otro.
class _Par extends StatelessWidget {
  const _Par(this.a, this.b);
  final Widget a;
  final Widget b;

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, c) {
        if (c.maxWidth < 360) {
          return Column(children: [a, const SizedBox(height: 12), b]);
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: a),
            const SizedBox(width: 12),
            Expanded(child: b),
          ],
        );
      });
}

class _Texto extends StatelessWidget {
  const _Texto(
    this.controller,
    this.label, {
    this.hint,
    this.validator,
    this.teclado,
    this.soloDigitos = false,
    this.maxLength,
    this.lineas = 1,
    this.prefijo,
  });

  final TextEditingController controller;
  final String label;
  final String? hint;
  final String? Function(String?)? validator;
  final TextInputType? teclado;
  final bool soloDigitos;
  final int? maxLength;
  final int lineas;
  final String? prefijo;

  @override
  Widget build(BuildContext context) => TextFormField(
        controller: controller,
        keyboardType: lineas > 1 ? TextInputType.multiline : teclado,
        inputFormatters:
            soloDigitos ? [FilteringTextInputFormatter.digitsOnly] : null,
        maxLength: maxLength,
        minLines: lineas,
        maxLines: lineas == 1 ? 1 : 8,
        textCapitalization: soloDigitos || teclado != null
            ? TextCapitalization.none
            : TextCapitalization.sentences,
        decoration: InputDecoration(
            labelText: label, hintText: hint, prefixText: prefijo),
        validator: validator,
      );
}

/// Selección múltiple con chips. [opciones] son pares (valor, etiqueta).
class _Chips extends StatelessWidget {
  const _Chips({
    required this.opciones,
    required this.elegidos,
    required this.onCambio,
  });

  final List<(String, String)> opciones;
  final Set<String> elegidos;
  final VoidCallback onCambio;

  @override
  Widget build(BuildContext context) => Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final (valor, etiqueta) in opciones)
            FilterChip(
              label: Text(etiqueta),
              selected: elegidos.contains(valor),
              onSelected: (s) {
                s ? elegidos.add(valor) : elegidos.remove(valor);
                onCambio();
              },
            ),
        ],
      );
}
