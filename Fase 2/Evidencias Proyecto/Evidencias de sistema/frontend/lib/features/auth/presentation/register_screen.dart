import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/config/app_config.dart';
import '../../../core/network/api_client.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/validation/identity_validators.dart';
import '../../../core/widgets/common.dart';
import '../application/auth_controller.dart';
import '../data/auth_repository.dart';
import '../domain/models.dart';

/// Registro de cuenta.
///
/// La persona elige QUÉ es (familiar, cuidador/a o médico): ya no se asume
/// "familiar". El médico necesita el código de habilitación que emite el
/// equipo de AgeCare tras verificar su registro profesional, porque su rol
/// permite indicar tratamientos. El adulto mayor no se registra aquí: su
/// cuenta la vincula su familia.
///
/// Si [invitationToken] no es nulo (deep link agecare://invite/<token>), el
/// rol lo define la invitación y no se pregunta.
class RegisterScreen extends ConsumerStatefulWidget {
  const RegisterScreen({super.key, this.invitationToken});

  final String? invitationToken;

  @override
  ConsumerState<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends ConsumerState<RegisterScreen> {
  final _formKey = GlobalKey<FormState>();
  final _firstName = TextEditingController();
  final _secondName = TextEditingController();
  final _lastName = TextEditingController();
  final _secondLastName = TextEditingController();
  final _rut = TextEditingController();
  final _email = TextEditingController();
  final _phone = TextEditingController();
  final _password = TextEditingController();
  final _enrollment = TextEditingController();
  RoleType? _accountType;
  bool _loading = false;
  bool _obscure = true;
  String? _error;

  bool get _conInvitacion => widget.invitationToken != null;

  /// La cuidadora entra a la casa de un adulto mayor y se publica en el
  /// marketplace: la familia tiene que poder identificarla y llamarla.
  bool get _esCuidadora => _accountType == RoleType.caregiver;

  /// Con invitación no se sabe el rol hasta que responde el servidor: el RUT
  /// se ofrece igual, opcional, y el servidor lo exige si es de cuidador(a).
  bool get _pideRut => _esCuidadora || _conInvitacion;

  @override
  void dispose() {
    _firstName.dispose();
    _secondName.dispose();
    _lastName.dispose();
    _secondLastName.dispose();
    _rut.dispose();
    _email.dispose();
    _phone.dispose();
    _password.dispose();
    _enrollment.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_conInvitacion && _accountType == null) {
      setState(() => _error = 'Elige qué tipo de cuenta vas a crear.');
      return;
    }
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await ref.read(authControllerProvider.notifier).register(
            firstName: _firstName.text.trim(),
            secondName: _secondName.text.trim(),
            lastName: _lastName.text.trim(),
            secondLastName: _secondLastName.text.trim(),
            rut: _pideRut && _rut.text.trim().isNotEmpty
                ? formatRut(_rut.text.trim())
                : null,
            email: _email.text.trim(),
            password: _password.text,
            accountType: _conInvitacion ? null : _accountType,
            doctorEnrollmentToken: _accountType == RoleType.doctor
                ? _enrollment.text.trim()
                : null,
            phone: _phone.text.trim().isEmpty
                ? null
                : normalizePhone(_phone.text.trim()),
            invitationToken: widget.invitationToken,
          );
      // El redirect del router lleva al home.
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.detailedMessage);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  String? _validatePassword(String? v) {
    if (v == null || v.length < 8) return 'Mínimo 8 caracteres';
    final hasLetter = v.contains(RegExp(r'[a-zA-Z]'));
    final hasNumber = v.contains(RegExp(r'[0-9]'));
    if (!hasLetter || !hasNumber) {
      return 'Debe incluir al menos una letra y un número';
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final esMedico = _accountType == RoleType.doctor;
    return Scaffold(
      appBar: AppBar(title: const Text('Crear cuenta')),
      body: SafeArea(
        child: AutofillGroup(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 520),
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (_conInvitacion)
                        const _Aviso(
                          icon: Icons.card_giftcard_rounded,
                          texto:
                              'Te invitaron a un círculo de cuidado. Al crear tu cuenta quedarás vinculado con el rol de la invitación.',
                        )
                      else ...[
                        const Text('¿Cómo vas a usar AgeCare?',
                            style: TextStyle(
                                fontSize: 16, fontWeight: FontWeight.w700)),
                        const SizedBox(height: 10),
                        for (final t in selfRegistrableAccountTypes)
                          _OpcionCuenta(
                            tipo: t,
                            seleccionado: _accountType == t,
                            enabled: !_loading,
                            onTap: () => setState(() {
                              _accountType = t;
                              _error = null;
                            }),
                          ),
                        const SizedBox(height: 4),
                        const Text(
                          'La cuenta del adulto mayor la vincula su familia desde la app.',
                          style: TextStyle(
                              fontSize: 12.5, color: AppColors.textSecondary),
                        ),
                        // Un solo hijo fijo: si el bloque del médico se
                        // insertara y quitara de la columna, Flutter
                        // recrearía los campos de abajo y perdería su
                        // validación.
                        _BloqueMedico(
                          visible: esMedico,
                          controller: _enrollment,
                          enabled: !_loading,
                        ),
                        const SizedBox(height: 20),
                      ],
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: TextFormField(
                              controller: _firstName,
                              enabled: !_loading,
                              textCapitalization: TextCapitalization.words,
                              textInputAction: TextInputAction.next,
                              autofillHints: const [AutofillHints.givenName],
                              decoration:
                                  const InputDecoration(labelText: 'Nombre'),
                              validator: (v) =>
                                  validatePersonName(v, campo: 'tu nombre'),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: TextFormField(
                              controller: _lastName,
                              enabled: !_loading,
                              textCapitalization: TextCapitalization.words,
                              textInputAction: TextInputAction.next,
                              autofillHints: const [AutofillHints.familyName],
                              decoration:
                                  const InputDecoration(labelText: 'Apellido'),
                              validator: (v) =>
                                  validatePersonName(v, campo: 'tu apellido'),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: TextFormField(
                              controller: _secondName,
                              enabled: !_loading,
                              textCapitalization: TextCapitalization.words,
                              textInputAction: TextInputAction.next,
                              autofillHints: const [AutofillHints.middleName],
                              decoration: const InputDecoration(
                                  labelText: 'Segundo nombre (opcional)'),
                              validator: (v) => validatePersonName(v,
                                  campo: 'tu segundo nombre', required: false),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: TextFormField(
                              controller: _secondLastName,
                              enabled: !_loading,
                              textCapitalization: TextCapitalization.words,
                              textInputAction: TextInputAction.next,
                              decoration: const InputDecoration(
                                  labelText: 'Segundo apellido (opcional)'),
                              validator: (v) => validatePersonName(v,
                                  campo: 'tu segundo apellido',
                                  required: false),
                            ),
                          ),
                        ],
                      ),
                      // Un solo hijo fijo, vacío si no corresponde (mismo
                      // motivo que el bloque del médico).
                      _BloqueRut(
                        visible: _pideRut,
                        obligatorio: _esCuidadora,
                        controller: _rut,
                        enabled: !_loading,
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: _email,
                        enabled: !_loading,
                        keyboardType: TextInputType.emailAddress,
                        textInputAction: TextInputAction.next,
                        autocorrect: false,
                        autofillHints: const [AutofillHints.email],
                        decoration: const InputDecoration(
                            labelText: 'Correo electrónico',
                            prefixIcon: Icon(Icons.mail_outline)),
                        validator: (v) => v != null &&
                                RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$')
                                    .hasMatch(v.trim())
                            ? null
                            : 'Escribe un correo válido',
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: _phone,
                        enabled: !_loading,
                        keyboardType: TextInputType.phone,
                        textInputAction: TextInputAction.next,
                        autofillHints: const [AutofillHints.telephoneNumber],
                        decoration: InputDecoration(
                            labelText:
                                _esCuidadora ? 'Teléfono' : 'Teléfono (opcional)',
                            hintText: '9 1234 5678',
                            helperText: _esCuidadora
                                ? 'Para que la familia pueda llamarte.'
                                : null,
                            prefixIcon: const Icon(Icons.phone_outlined)),
                        validator: (v) =>
                            validatePhone(v, required: _esCuidadora),
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: _password,
                        enabled: !_loading,
                        obscureText: _obscure,
                        textInputAction: TextInputAction.done,
                        autofillHints: const [AutofillHints.newPassword],
                        decoration: InputDecoration(
                          labelText: 'Contraseña',
                          prefixIcon: const Icon(Icons.lock_outline),
                          helperText:
                              'Al menos 8 caracteres, con letras y números',
                          suffixIcon: IconButton(
                            icon: Icon(_obscure
                                ? Icons.visibility_off
                                : Icons.visibility),
                            tooltip: _obscure
                                ? 'Mostrar contraseña'
                                : 'Ocultar contraseña',
                            onPressed: () =>
                                setState(() => _obscure = !_obscure),
                          ),
                        ),
                        validator: _validatePassword,
                        onFieldSubmitted: (_) => _submit(),
                      ),
                      // Siempre presente, vacío si no hay error (mismo motivo).
                      _error == null
                          ? const SizedBox.shrink()
                          : Padding(
                              padding: const EdgeInsets.only(top: 16),
                              child: InlineError(
                                message: _error!,
                                onDismiss: () => setState(() => _error = null),
                              ),
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
                            : const Text('Crear cuenta'),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Text('¿Ya tienes cuenta?',
                              style: TextStyle(color: AppColors.textSecondary)),
                          TextButton(
                            onPressed: _loading
                                ? null
                                : () => context.canPop()
                                    ? context.pop()
                                    : context.go('/login'),
                            child: const Text('Inicia sesión'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Tarjeta seleccionable de tipo de cuenta. Se anuncia como botón de opción
/// (seleccionado / no seleccionado) para los lectores de pantalla.
class _OpcionCuenta extends StatelessWidget {
  const _OpcionCuenta({
    required this.tipo,
    required this.seleccionado,
    required this.enabled,
    required this.onTap,
  });

  final RoleType tipo;
  final bool seleccionado;
  final bool enabled;
  final VoidCallback onTap;

  String get _titulo => switch (tipo) {
        RoleType.family => 'Familiar',
        RoleType.caregiver => 'Cuidador(a)',
        RoleType.doctor => 'Médico(a)',
        RoleType.elder => 'Adulto mayor',
      };

  String get _detalle => switch (tipo) {
        RoleType.family =>
          'Creo el perfil de mi familiar y coordino a quienes lo cuidan.',
        RoleType.caregiver =>
          'Cuido adultos mayores. Publico mi perfil para que las familias me encuentren.',
        RoleType.doctor =>
          'Atiendo pacientes. Requiere habilitación de AgeCare.',
        RoleType.elder => '',
      };

  IconData get _icono => switch (tipo) {
        RoleType.family => Icons.family_restroom_rounded,
        RoleType.caregiver => Icons.volunteer_activism_outlined,
        RoleType.doctor => Icons.medical_services_outlined,
        RoleType.elder => Icons.elderly_rounded,
      };

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Semantics(
        inMutuallyExclusiveGroup: true,
        checked: seleccionado,
        button: true,
        label: '$_titulo. $_detalle',
        excludeSemantics: true,
        child: InkWell(
          onTap: enabled ? onTap : null,
          borderRadius: BorderRadius.circular(14),
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: seleccionado ? tipo.accentFg : AppColors.divider,
                width: seleccionado ? 2 : 1,
              ),
              color: seleccionado ? tipo.accentBg : null,
            ),
            child: Row(
              children: [
                Icon(_icono, color: tipo.accentFg),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(_titulo,
                          style: const TextStyle(
                              fontWeight: FontWeight.w700, fontSize: 15)),
                      const SizedBox(height: 2),
                      Text(_detalle,
                          style: const TextStyle(
                              fontSize: 13, color: AppColors.textSecondary)),
                    ],
                  ),
                ),
                Icon(
                  seleccionado
                      ? Icons.radio_button_checked
                      : Icons.radio_button_off,
                  color: seleccionado ? tipo.accentFg : AppColors.textSecondary,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// RUT de la cuidadora. Vacío si no corresponde.
class _BloqueRut extends StatelessWidget {
  const _BloqueRut({
    required this.visible,
    required this.obligatorio,
    required this.controller,
    required this.enabled,
  });

  final bool visible;
  final bool obligatorio;
  final TextEditingController controller;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    if (!visible) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: TextFormField(
        controller: controller,
        enabled: enabled,
        autocorrect: false,
        keyboardType: TextInputType.visiblePassword,
        textInputAction: TextInputAction.next,
        decoration: InputDecoration(
          labelText: obligatorio ? 'RUT' : 'RUT (si te invitaron como cuidador/a)',
          hintText: '12.345.678-5',
          helperText: obligatorio
              ? 'Para que la familia sepa quién cuida a su familiar.'
              : null,
          prefixIcon: const Icon(Icons.badge_outlined),
        ),
        validator: (v) {
          final vacio = v == null || v.trim().isEmpty;
          if (vacio) return obligatorio ? 'Escribe tu RUT' : null;
          return validateRut(v);
        },
      ),
    );
  }
}

/// Aviso y código de habilitación del médico. Vacío si no se eligió médico.
class _BloqueMedico extends StatelessWidget {
  const _BloqueMedico({
    required this.visible,
    required this.controller,
    required this.enabled,
  });

  final bool visible;
  final TextEditingController controller;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    if (!visible) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _Aviso(
            icon: Icons.verified_user_outlined,
            texto:
                'Por seguridad de los pacientes, las cuentas de médico las habilita el equipo de AgeCare tras verificar tu registro en la Superintendencia de Salud. Escribe el código que te entregaron y el mismo correo con el que lo solicitaste.',
          ),
          TextFormField(
            controller: controller,
            enabled: enabled,
            autocorrect: false,
            decoration: const InputDecoration(
              labelText: 'Código de habilitación',
              prefixIcon: Icon(Icons.key_outlined),
              helperText: AppConfig.useMocks
                  ? 'Modo demo: ${AuthRepositoryMock.demoDoctorEnrollmentCode}'
                  : null,
            ),
            validator: (v) => v == null || v.trim().isEmpty
                ? 'Escribe el código de habilitación'
                : null,
          ),
        ],
      ),
    );
  }
}

class _Aviso extends StatelessWidget {
  const _Aviso({required this.icon, required this.texto});

  final IconData icon;
  final String texto;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.secondary.withValues(alpha: .15),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: AppColors.primaryDark),
          const SizedBox(width: 10),
          Expanded(child: Text(texto)),
        ],
      ),
    );
  }
}
