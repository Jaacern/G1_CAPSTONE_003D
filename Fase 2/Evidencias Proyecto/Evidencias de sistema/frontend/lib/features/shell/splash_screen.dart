import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';

/// Pantalla de arranque mientras se restaura la sesión (AuthLoading).
///
/// Fondo blanco, logo de AgeCare con una animación de entrada (fade + escala
/// con un leve "respiro" en bucle) y un indicador de carga en el azul de la
/// marca. El router redirige a /login o /home cuando el estado se resuelve.
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with TickerProviderStateMixin {
  // Animación de entrada: aparece y escala una sola vez.
  late final AnimationController _introController;
  late final Animation<double> _fade;
  late final Animation<double> _introScale;

  // Animación en bucle: leve latido del logo mientras carga.
  late final AnimationController _pulseController;
  late final Animation<double> _pulse;

  @override
  void initState() {
    super.initState();

    _introController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    );
    _fade = CurvedAnimation(parent: _introController, curve: Curves.easeOut);
    _introScale = Tween<double>(begin: 0.82, end: 1.0).animate(
      CurvedAnimation(parent: _introController, curve: Curves.easeOutBack),
    );

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat(reverse: true);
    _pulse = Tween<double>(begin: 1.0, end: 1.05).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    _introController.forward();
  }

  @override
  void dispose() {
    _introController.dispose();
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            FadeTransition(
              opacity: _fade,
              child: ScaleTransition(
                scale: _introScale,
                child: ScaleTransition(
                  scale: _pulse,
                  child: Image.asset(
                    'assets/images/Agecare.png',
                    width: 180,
                    height: 180,
                    fit: BoxFit.contain,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 40),
            const SizedBox(
              width: 30,
              height: 30,
              child: CircularProgressIndicator(
                strokeWidth: 3,
                valueColor: AlwaysStoppedAnimation(AppColors.primary),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
