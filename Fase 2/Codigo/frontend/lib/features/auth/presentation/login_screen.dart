import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/config/app_config.dart';
import '../../../core/network/api_client.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/common.dart';
import '../application/auth_controller.dart';
import '../data/auth_repository.dart';

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

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) => AutofillGroup(
            child: SingleChildScrollView(
              padding: _pagePadding,
              child: ConstrainedBox(
                // minHeight fuerza a centrar el bloque cuando sobra pantalla;
                // con el teclado abierto el contenido sigue pudiendo scrollear.
                constraints: BoxConstraints(
                    minHeight: constraints.maxHeight - _pagePadding.vertical),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 420),
                    child: Form(
                      key: _formKey,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const _BrandHeader(),
                          const SizedBox(height: 28),
                          _FormPanel(
                            dark: dark,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                TextFormField(
                                  controller: _email,
                                  enabled: !_loading,
                                  keyboardType: TextInputType.emailAddress,
                                  textInputAction: TextInputAction.next,
                                  autocorrect: false,
                                  autofillHints: const [AutofillHints.email],
                                  onChanged: (_) => _clearError(),
                                  decoration: const InputDecoration(
                                      labelText: 'Correo electrónico',
                                      prefixIcon: Icon(Icons.mail_outline)),
                                  validator: (v) => v != null && v.contains('@')
                                      ? null
                                      : 'Escribe un correo válido',
                                ),
                                const SizedBox(height: 14),
                                TextFormField(
                                  controller: _password,
                                  enabled: !_loading,
                                  obscureText: _obscure,
                                  textInputAction: TextInputAction.done,
                                  autofillHints: const [AutofillHints.password],
                                  onChanged: (_) => _clearError(),
                                  decoration: InputDecoration(
                                    labelText: 'Contraseña',
                                    prefixIcon: const Icon(Icons.lock_outline),
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
                                  validator: (v) => v != null && v.length >= 8
                                      ? null
                                      : 'Mínimo 8 caracteres',
                                  onFieldSubmitted: (_) => _submit(),
                                ),
                                Align(
                                  alignment: Alignment.centerRight,
                                  child: Padding(
                                    padding: const EdgeInsets.only(top: 4),
                                    child: TextButton(
                                      onPressed: _loading
                                          ? null
                                          : () => context.push('/recover'),
                                      style: TextButton.styleFrom(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 8, vertical: 4),
                                        minimumSize: const Size(0, 36),
                                        tapTargetSize:
                                            MaterialTapTargetSize.shrinkWrap,
                                      ),
                                      child: const Text(
                                          '¿Olvidaste tu contraseña?'),
                                    ),
                                  ),
                                ),
                                if (_error != null) ...[
                                  const SizedBox(height: 8),
                                  InlineError(
                                      message: _error!, onDismiss: _clearError),
                                ],
                                const SizedBox(height: 12),
                                FilledButton(
                                  onPressed: _loading ? null : _submit,
                                  child: _loading
                                      ? const SizedBox(
                                          width: 22,
                                          height: 22,
                                          child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                              color: Colors.white))
                                      : const Text('Iniciar sesión'),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 20),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text('¿No tienes cuenta?',
                                  style: TextStyle(
                                      fontSize: 14,
                                      color: dark
                                          ? const Color(0xFF9AA6B5)
                                          : AppColors.textSecondary)),
                              TextButton(
                                onPressed: _loading
                                    ? null
                                    : () => context.push('/register'),
                                child: const Text('Regístrate'),
                              ),
                            ],
                          ),
                          if (AppConfig.useMocks) const _DemoBadge(),
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

/// Encabezado de marca: logo, bienvenida y lema. Separado del formulario para
/// que la tarjeta de acceso no compita con el logo.
class _BrandHeader extends StatelessWidget {
  const _BrandHeader();

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Column(
      children: [
        Image.asset(
          'assets/images/Agecare.png',
          width: 132,
          height: 132,
          fit: BoxFit.contain,
        ),
        const SizedBox(height: 12),
        Text(
          'Bienvenido de vuelta',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w800,
            letterSpacing: -.2,
            color: dark ? Colors.white : AppColors.textPrimary,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          'La tranquilidad de saber que está bien',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 14,
            height: 1.3,
            color: dark ? const Color(0xFF9AA6B5) : AppColors.textSecondary,
          ),
        ),
      ],
    );
  }
}

/// Contenedor del formulario. Se usa `surfaceAlt` para que los campos blancos
/// se despeguen del fondo de la tarjeta.
class _FormPanel extends StatelessWidget {
  const _FormPanel({required this.child, required this.dark});

  final Widget child;
  final bool dark;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 20, 18, 20),
      decoration: BoxDecoration(
        color: dark ? AppColors.darkSurface : AppColors.surfaceAlt,
        borderRadius: BorderRadius.circular(22),
        border:
            Border.all(color: dark ? AppColors.darkDivider : AppColors.divider),
        boxShadow: dark
            ? null
            : const [
                BoxShadow(
                  color: AppColors.cardShadow,
                  blurRadius: 30,
                  offset: Offset(0, 12),
                ),
              ],
      ),
      child: child,
    );
  }
}

/// Aviso de que la app corre con datos simulados.
class _DemoBadge extends StatelessWidget {
  const _DemoBadge();

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Center(
      child: Container(
        margin: const EdgeInsets.only(top: 12),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: AppColors.primary.withValues(alpha: dark ? .22 : .09),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.science_outlined,
                size: 14, color: dark ? Colors.white : AppColors.primaryDark),
            const SizedBox(width: 6),
            Text(
              'Modo demo · credenciales precargadas',
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
                color: dark ? Colors.white : AppColors.primaryDark,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Pantalla de recuperación de contraseña.
class RecoverPasswordScreen extends ConsumerStatefulWidget {
  const RecoverPasswordScreen({super.key});

  @override
  ConsumerState<RecoverPasswordScreen> createState() =>
      _RecoverPasswordScreenState();
}

class _RecoverPasswordScreenState extends ConsumerState<RecoverPasswordScreen> {
  final _email = TextEditingController();
  bool _sent = false;
  bool _loading = false;

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_email.text.contains('@')) return;
    setState(() => _loading = true);
    try {
      await ref
          .read(authControllerProvider.notifier)
          .recoverPassword(_email.text.trim());
      setState(() => _sent = true);
    } on ApiException catch (e) {
      if (mounted) showAppSnackBar(context, e.message, error: true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Recuperar contraseña')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: _sent
            ? const EmptyView(
                icon: Icons.mark_email_read_outlined,
                title: 'Revisa tu correo',
                subtitle:
                    'Si el correo está registrado, te enviamos un enlace para restablecer tu contraseña.',
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                      'Escribe tu correo y te enviaremos un enlace para restablecer tu contraseña.',
                      style: TextStyle(color: AppColors.textSecondary)),
                  const SizedBox(height: 24),
                  TextField(
                    controller: _email,
                    keyboardType: TextInputType.emailAddress,
                    decoration: const InputDecoration(
                        labelText: 'Correo electrónico',
                        prefixIcon: Icon(Icons.mail_outline)),
                  ),
                  const SizedBox(height: 24),
                  FilledButton(
                    onPressed: _loading ? null : _submit,
                    child: const Text('Enviar enlace'),
                  ),
                ],
              ),
      ),
    );
  }
}
