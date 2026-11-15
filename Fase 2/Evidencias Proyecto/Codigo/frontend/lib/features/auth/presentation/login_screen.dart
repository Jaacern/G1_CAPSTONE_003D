import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/config/app_config.dart';
import '../../../core/network/api_client.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/common.dart';
import '../application/auth_controller.dart';
import '../data/auth_repository.dart';
import 'auth_backdrop.dart';

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  static const _pagePadding = EdgeInsets.fromLTRB(24, 24, 24, 32);

  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController(
      text: AppConfig.useMocks ? AuthRepositoryMock.demoEmail : '');
  final _password = TextEditingController(
      text: AppConfig.useMocks ? AuthRepositoryMock.demoPassword : '');
  bool _loading = false;
  bool _obscure = true;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await ref
          .read(authControllerProvider.notifier)
          .login(_email.text.trim(), _password.text);
      // El redirect del router lleva al home.
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _clearError() {
    if (_error != null) setState(() => _error = null);
  }

  /// Campo en píldora con relleno suave y sin borde. El texto de ayuda es la
  /// etiqueta (no flota), así los lectores de pantalla lo siguen anunciando.
  InputDecoration _fieldDecoration(
    String label,
    IconData icon, {
    Widget? suffix,
    required bool dark,
  }) {
    OutlineInputBorder border([Color? color, double width = 0]) =>
        OutlineInputBorder(
          borderRadius: BorderRadius.circular(28),
          borderSide: color == null
              ? BorderSide.none
              : BorderSide(color: color, width: width),
        );
    return InputDecoration(
      labelText: label,
      floatingLabelBehavior: FloatingLabelBehavior.never,
      prefixIcon: Icon(icon),
      suffixIcon: suffix,
      filled: true,
      fillColor: dark ? AgeColors.darkSurfaceBg : AgeColors.surfaceSunken,
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 17),
      border: border(),
      enabledBorder: border(),
      disabledBorder: border(),
      focusedBorder: border(dark ? AgeColors.darkTeal : AgeColors.teal600, 2),
      errorBorder: border(AgeColors.attention600, 1.5),
      focusedErrorBorder: border(AgeColors.attention600, 2),
    );
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final textPrimary =
        dark ? AgeColors.darkTextPrimary : AgeColors.textPrimary;
    final textSecondary =
        dark ? AgeColors.darkTextSecondary : AgeColors.textSecondary;

    // El arte ocupa _headerH y el panel blanco lo tapa los últimos _overlap.
    const headerH = 230.0;
    const overlap = 32.0;

    return Scaffold(
      backgroundColor: dark ? AgeColors.darkSurfaceBg : AgeColors.navy100,
      body: AuthPageBackground(
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, box) => AutofillGroup(
              child: SingleChildScrollView(
                padding: _pagePadding,
                child: ConstrainedBox(
                  // minHeight centra la tarjeta cuando sobra pantalla; con el
                  // teclado abierto el contenido sigue pudiendo scrollear.
                  constraints: BoxConstraints(
                      minHeight: box.maxHeight - _pagePadding.vertical),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 400),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          DecoratedBox(
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(32),
                              boxShadow: dark
                                  ? null
                                  : const [
                                      BoxShadow(
                                        color: Color(0x2612283F),
                                        blurRadius: 40,
                                        offset: Offset(0, 18),
                                      ),
                                    ],
                            ),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(32),
                              child: Stack(
                                children: [
                                  const Positioned(
                                    top: 0,
                                    left: 0,
                                    right: 0,
                                    height: headerH,
                                    child: BrandArt(
                                      logoSize: 140,
                                      logoAlignment: Alignment(0, -.14),
                                    ),
                                  ),
                                  Padding(
                                    padding: const EdgeInsets.only(
                                        top: headerH - overlap),
                                    child: Container(
                                      padding: const EdgeInsets.fromLTRB(
                                          24, 26, 24, 20),
                                      decoration: BoxDecoration(
                                        color: dark
                                            ? AgeColors.darkSurfaceCard
                                            : AgeColors.surfaceCard,
                                        borderRadius:
                                            const BorderRadius.vertical(
                                                top: Radius.circular(30)),
                                      ),
                                      child: Form(
                                        key: _formKey,
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.stretch,
                                          children: [
                                            Text('Iniciar sesión',
                                                textAlign: TextAlign.center,
                                                style: AgeText.h2.copyWith(
                                                    color: textPrimary)),
                                            const SizedBox(height: 4),
                                            Text(
                                                'La tranquilidad de saber que está bien',
                                                textAlign: TextAlign.center,
                                                style: AgeText.small.copyWith(
                                                    color: textSecondary)),
                                            const SizedBox(height: 22),
                                            TextFormField(
                                              controller: _email,
                                              enabled: !_loading,
                                              keyboardType:
                                                  TextInputType.emailAddress,
                                              textInputAction:
                                                  TextInputAction.next,
                                              autocorrect: false,
                                              autofillHints: const [
                                                AutofillHints.email
                                              ],
                                              onChanged: (_) => _clearError(),
                                              decoration: _fieldDecoration(
                                                  'Correo electrónico',
                                                  Icons.mail_outline,
                                                  dark: dark),
                                              validator: (v) => v != null &&
                                                      v.contains('@')
                                                  ? null
                                                  : 'Escribe un correo válido',
                                            ),
                                            const SizedBox(height: 12),
                                            TextFormField(
                                              controller: _password,
                                              enabled: !_loading,
                                              obscureText: _obscure,
                                              textInputAction:
                                                  TextInputAction.done,
                                              autofillHints: const [
                                                AutofillHints.password
                                              ],
                                              onChanged: (_) => _clearError(),
                                              decoration: _fieldDecoration(
                                                'Contraseña',
                                                Icons.lock_outline,
                                                dark: dark,
                                                suffix: IconButton(
                                                  icon: Icon(_obscure
                                                      ? Icons
                                                          .visibility_off_outlined
                                                      : Icons
                                                          .visibility_outlined),
                                                  tooltip: _obscure
                                                      ? 'Mostrar contraseña'
                                                      : 'Ocultar contraseña',
                                                  onPressed: () => setState(
                                                      () =>
                                                          _obscure = !_obscure),
                                                ),
                                              ),
                                              validator: (v) =>
                                                  v != null && v.length >= 8
                                                      ? null
                                                      : 'Mínimo 8 caracteres',
                                              onFieldSubmitted: (_) =>
                                                  _submit(),
                                            ),
                                            Align(
                                              alignment: Alignment.centerRight,
                                              child: Padding(
                                                padding: const EdgeInsets.only(
                                                    top: 4),
                                                child: TextButton(
                                                  onPressed: _loading
                                                      ? null
                                                      : () => context
                                                          .push('/recover'),
                                                  style: TextButton.styleFrom(
                                                    padding: const EdgeInsets
                                                        .symmetric(
                                                        horizontal: 8,
                                                        vertical: 4),
                                                    minimumSize:
                                                        const Size(0, 36),
                                                    tapTargetSize:
                                                        MaterialTapTargetSize
                                                            .shrinkWrap,
                                                  ),
                                                  child: const Text(
                                                      '¿Olvidaste tu contraseña?'),
                                                ),
                                              ),
                                            ),
                                            if (_error != null) ...[
                                              const SizedBox(height: 8),
                                              InlineError(
                                                  message: _error!,
                                                  onDismiss: _clearError),
                                            ],
                                            const SizedBox(height: 12),
                                            // Marino AgeCare: el tono oscuro
                                            // de la marca para la acción
                                            // principal.
                                            FilledButton(
                                              onPressed:
                                                  _loading ? null : _submit,
                                              style: FilledButton.styleFrom(
                                                backgroundColor: dark
                                                    ? AgeColors.darkTeal
                                                    : AgeColors.navy800,
                                                foregroundColor: dark
                                                    ? AgeColors.darkSurfaceBg
                                                    : Colors.white,
                                                minimumSize:
                                                    const Size.fromHeight(54),
                                                shape: const StadiumBorder(),
                                                textStyle: AgeText.label,
                                              ),
                                              child: _loading
                                                  ? SizedBox(
                                                      width: 22,
                                                      height: 22,
                                                      child: CircularProgressIndicator(
                                                          strokeWidth: 2,
                                                          color: dark
                                                              ? AgeColors
                                                                  .darkSurfaceBg
                                                              : Colors.white))
                                                  : const Text(
                                                      'Iniciar sesión'),
                                            ),
                                            const SizedBox(height: 10),
                                            Wrap(
                                              alignment: WrapAlignment.center,
                                              crossAxisAlignment:
                                                  WrapCrossAlignment.center,
                                              children: [
                                                Text('¿No tienes cuenta?',
                                                    style: TextStyle(
                                                        fontSize: 14,
                                                        color: textSecondary)),
                                                TextButton(
                                                  onPressed: _loading
                                                      ? null
                                                      : () => context
                                                          .push('/register'),
                                                  child: const Text(
                                                      'Regístrate aquí',
                                                      style: TextStyle(
                                                          fontWeight:
                                                              FontWeight.w800)),
                                                ),
                                              ],
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          // Demo: datos simulados. Compilación de desarrollo
                          // contra el backend real: las mismas cuentas del
                          // seed. En release no sale nunca (kDebugMode).
                          if (AppConfig.useMocks || kDebugMode) ...[
                            const SizedBox(height: 16),
                            _DemoBadge(
                              real: !AppConfig.useMocks,
                              onSelect: (correo) => setState(() {
                                _email.text = correo;
                                _password.text =
                                    AuthRepositoryMock.demoPassword;
                              }),
                            ),
                          ],
                        ],
                      ),
                    ),
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

/// Aviso de que la app corre con datos simulados.
/// Aviso de modo demo con las personas de prueba. Cada ficha escribe su correo
/// en el formulario, así que no hay que teclear para cambiar de rol. En
/// producción el adulto mayor autentica su dispositivo (sin contraseña); aquí
/// se incluye solo para poder revisar su vista desde el navegador.
class _DemoBadge extends StatelessWidget {
  const _DemoBadge({required this.onSelect, this.real = false});

  final ValueChanged<String> onSelect;

  /// true: backend real en una compilación de desarrollo. Suma al
  /// administrador, que solo existe en la base real.
  final bool real;

  static const _personas = <(String, String)>[
    ('Familiar', AuthRepositoryMock.demoEmail),
    ('Cuidadora', AuthRepositoryMock.demoCaregiverEmail),
    ('Médico', AuthRepositoryMock.demoDoctorEmail),
    ('Adulto mayor', AuthRepositoryMock.demoElderEmail),
  ];
  static const _administrador = ('Administrador', 'administrador@agecare.cl');

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final tint = dark ? Colors.white : AppColors.primaryDark;
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      decoration: BoxDecoration(
        color: AppColors.primary.withValues(alpha: dark ? .22 : .09),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.science_outlined, size: 14, color: tint),
              const SizedBox(width: 6),
              Text(
                  '${real ? 'Cuentas de desarrollo' : 'Modo demo'} · contraseña ${AuthRepositoryMock.demoPassword}',
                  style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                      color: tint)),
            ],
          ),
          const SizedBox(height: 6),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final (rol, correo) in [
                ..._personas,
                if (real) _administrador,
              ])
                InkWell(
                  onTap: () => onSelect(correo),
                  borderRadius: BorderRadius.circular(999),
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      border: Border.all(color: tint.withValues(alpha: .45)),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(rol,
                        style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w600,
                            color: tint)),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Pantalla de recuperación de contraseña (RF-05), en dos pasos:
/// 1) la persona escribe su correo y recibe un código de 6 dígitos;
/// 2) escribe el código y la contraseña nueva.
///
/// El servidor responde igual exista o no el correo, así que la pantalla del
/// paso 2 dice "si el correo está registrado" y no confirma nada.
class RecoverPasswordScreen extends ConsumerStatefulWidget {
  const RecoverPasswordScreen({super.key});

  @override
  ConsumerState<RecoverPasswordScreen> createState() =>
      _RecoverPasswordScreenState();
}

enum _Paso { correo, codigo }

class _RecoverPasswordScreenState extends ConsumerState<RecoverPasswordScreen> {
  // Mismas reglas que el servidor (auth.py): 8+ caracteres con letra y número.
  static final _reClave = RegExp(r'^(?=.*[A-Za-z])(?=.*\d).{8,}$');

  final _email = TextEditingController();
  final _code = TextEditingController();
  final _pass = TextEditingController();
  final _pass2 = TextEditingController();
  _Paso _paso = _Paso.correo;
  bool _loading = false;
  bool _obscure = true;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _code.dispose();
    _pass.dispose();
    _pass2.dispose();
    super.dispose();
  }

  /// Pide el código. También se usa para reenviarlo desde el paso 2.
  Future<void> _pedirCodigo() async {
    final correo = _email.text.trim();
    if (!correo.contains('@')) {
      setState(() => _error = 'Escribe un correo válido.');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await ref.read(authControllerProvider.notifier).recoverPassword(correo);
      if (!mounted) return;
      if (_paso == _Paso.codigo) {
        showAppSnackBar(
            context, 'Si el correo está registrado, enviamos un código nuevo.');
      }
      setState(() => _paso = _Paso.codigo);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _cambiarClave() async {
    final codigo = _code.text.replaceAll(RegExp(r'\s'), '');
    if (!RegExp(r'^\d{6}$').hasMatch(codigo)) {
      setState(() => _error = 'El código tiene 6 dígitos.');
      return;
    }
    if (!_reClave.hasMatch(_pass.text)) {
      setState(() => _error =
          'La contraseña debe tener al menos 8 caracteres, con letras y números.');
      return;
    }
    if (_pass.text != _pass2.text) {
      setState(() => _error = 'Las contraseñas no coinciden.');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await ref.read(authControllerProvider.notifier).resetPassword(
            email: _email.text.trim(),
            code: codigo,
            newPassword: _pass.text,
          );
      if (!mounted) return;
      showAppSnackBar(
          context, 'Listo. Ya puedes entrar con tu contraseña nueva.');
      context.go('/login');
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final enCodigo = _paso == _Paso.codigo;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Recuperar contraseña'),
        leading: enCodigo
            ? IconButton(
                icon: const Icon(Icons.arrow_back),
                tooltip: 'Cambiar el correo',
                onPressed: _loading
                    ? null
                    : () => setState(() {
                          _paso = _Paso.correo;
                          _error = null;
                        }),
              )
            : null,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!enCodigo) ...[
              const Text(
                  'Escribe tu correo y te enviaremos un código de 6 dígitos para restablecer tu contraseña.',
                  style: TextStyle(color: AppColors.textSecondary)),
              const SizedBox(height: 24),
              TextField(
                controller: _email,
                keyboardType: TextInputType.emailAddress,
                autofillHints: const [AutofillHints.email],
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _loading ? null : _pedirCodigo(),
                decoration: const InputDecoration(
                    labelText: 'Correo electrónico',
                    prefixIcon: Icon(Icons.mail_outline)),
              ),
            ] else ...[
              Text(
                  'Si ${_email.text.trim()} está registrado, te enviamos un código de 6 dígitos. '
                  'Revisa también la carpeta de spam. El código vence en pocos minutos.',
                  style: const TextStyle(color: AppColors.textSecondary)),
              const SizedBox(height: 24),
              TextField(
                controller: _code,
                keyboardType: TextInputType.number,
                autofillHints: const [AutofillHints.oneTimeCode],
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9 ]')),
                  LengthLimitingTextInputFormatter(7),
                ],
                decoration: const InputDecoration(
                    labelText: 'Código de 6 dígitos',
                    prefixIcon: Icon(Icons.pin_outlined)),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _pass,
                obscureText: _obscure,
                autofillHints: const [AutofillHints.newPassword],
                decoration: InputDecoration(
                  labelText: 'Contraseña nueva',
                  helperText: 'Mínimo 8 caracteres, con letras y números',
                  prefixIcon: const Icon(Icons.lock_outline),
                  suffixIcon: IconButton(
                    icon: Icon(_obscure
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined),
                    tooltip:
                        _obscure ? 'Mostrar contraseña' : 'Ocultar contraseña',
                    onPressed: () => setState(() => _obscure = !_obscure),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _pass2,
                obscureText: _obscure,
                autofillHints: const [AutofillHints.newPassword],
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _loading ? null : _cambiarClave(),
                decoration: const InputDecoration(
                    labelText: 'Repite la contraseña nueva',
                    prefixIcon: Icon(Icons.lock_outline)),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 16),
              InlineError(
                  message: _error!,
                  onDismiss: () => setState(() => _error = null)),
            ],
            const SizedBox(height: 24),
            FilledButton(
              onPressed:
                  _loading ? null : (enCodigo ? _cambiarClave : _pedirCodigo),
              child: _loading
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : Text(enCodigo ? 'Cambiar contraseña' : 'Enviar código'),
            ),
            if (enCodigo)
              TextButton(
                onPressed: _loading ? null : _pedirCodigo,
                child: const Text('Reenviar código'),
              ),
          ],
        ),
      ),
    );
  }
}
