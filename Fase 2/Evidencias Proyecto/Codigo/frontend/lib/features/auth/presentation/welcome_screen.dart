import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_theme.dart';
import 'auth_backdrop.dart';

/// Primera pantalla para quien no tiene sesión: marca arriba, mensaje abajo y
/// un solo camino claro hacia el acceso.
class WelcomeScreen extends StatelessWidget {
  const WelcomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final h = MediaQuery.sizeOf(context).height;
    final text = dark ? AgeColors.darkTextPrimary : AgeColors.textPrimary;
    final muted = dark ? AgeColors.darkTextSecondary : AgeColors.textSecondary;

    return Scaffold(
      backgroundColor: dark ? AgeColors.darkSurfaceBg : AgeColors.surfaceBg,
      body: Column(
        children: [
          AuthHeader(
            height: (h * .56).clamp(330.0, 520.0),
            logoSize: (h * .30).clamp(170.0, 300.0),
          ),
          Expanded(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 460),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(28, 8, 28, 28),
                  child: TweenAnimationBuilder<double>(
                    tween: Tween(begin: 0, end: 1),
                    duration: const Duration(milliseconds: 600),
                    curve: Curves.easeOutCubic,
                    builder: (context, t, child) => Opacity(
                      opacity: t,
                      child: Transform.translate(
                          offset: Offset(0, 16 * (1 - t)), child: child),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Bienvenido a AgeCare',
                            style: AgeText.h1.copyWith(color: text)),
                        const SizedBox(height: 8),
                        Text(
                          'La tranquilidad de saber que está bien. Familia, '
                          'cuidadores y médicos, juntos en un solo lugar.',
                          style: AgeText.body.copyWith(color: muted),
                        ),
                        const Spacer(),
                        FilledButton.icon(
                          onPressed: () => context.go('/login'),
                          icon: const Icon(Icons.arrow_forward),
                          iconAlignment: IconAlignment.end,
                          label: const Text('Continuar'),
                        ),
                        const SizedBox(height: 4),
                        Center(
                          child: TextButton(
                            onPressed: () => context.go('/register'),
                            child: const Text('Crear una cuenta'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
