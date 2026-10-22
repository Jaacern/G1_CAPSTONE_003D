import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/config/app_config.dart';
import '../../../core/speech/speech_service.dart';
import '../../../core/theme/app_theme.dart';
import '../../alerts/presentation/sos_button.dart';
import '../../auth/application/auth_controller.dart';
import '../application/elder_providers.dart';
import 'elder_content_screen.dart';
import 'elder_photos_screen.dart';

/// Pantalla PRINCIPAL de la vista del adulto mayor (shell del rol elder).
///
/// Diseño accesible: saludo grande, fecha en palabras y un mosaico de botones
/// enormes con icono + etiqueta. Cada acción se lee en voz alta al tocarla y
/// hay un botón de emergencia (SOS) muy visible.
class ElderHomeScreen extends ConsumerWidget {
  const ElderHomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(currentUserProvider);
    final firstName = _firstName(user?.fullName);
    final patientId = ref.watch(elderPatientIdProvider);
    final speech = ref.read(speechServiceProvider);

    final tiles = <_ElderTile>[
      // "Llamar a la familia" depende del chat (Comunicación), sin backend aún.
      if (AppConfig.hasComms)
        _ElderTile(
          icon: Icons.video_call_rounded,
          label: 'Llamar a la\nfamilia',
          color: AppColors.primary,
          speak: 'Llamar a la familia',
          onTap: () => context.push(
              patientId == null ? '/chat' : '/chat?patient=$patientId'),
        ),
      // Fotos y contenido ("Para ti") aún no tienen backend.
      if (AppConfig.hasElderContent) ...[
        _ElderTile(
          icon: Icons.photo_library_rounded,
          label: 'Mis fotos',
          color: AppColors.secondary,
          speak: 'Mis fotos',
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const ElderPhotosScreen()),
          ),
        ),
        _ElderTile(
          icon: Icons.favorite_rounded,
          label: 'Para ti',
          color: AppColors.statusWarning,
          speak: 'Para ti. Noticias, chistes y ejercicios.',
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const ElderContentScreen()),
          ),
        ),
      ],
      _ElderTile(
        icon: Icons.medication_rounded,
        label: 'Mis\nmedicinas',
        color: AppColors.statusOk,
        speak: 'Mis medicinas',
        onTap: () {
          if (patientId == null) {
            speech.speak('Aún no hay medicinas configuradas.');
            return;
          }
          context.push('/meds/plan?patient=$patientId');
        },
      ),
    ];

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Hola, $firstName',
                          style: const TextStyle(
                            fontSize: 34,
                            fontWeight: FontWeight.w800,
                            color: AppColors.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          _spanishDate(DateTime.now()),
                          style: const TextStyle(
                            fontSize: 20,
                            color: AppColors.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  _HelpButton(
                    onTap: () => speech.speak(
                      'Esta es tu pantalla de inicio. Toca un botón grande para '
                      'llamar a tu familia, ver tus fotos, escuchar contenido '
                      'para ti o revisar tus medicinas. El botón rojo de abajo '
                      'es para pedir ayuda en una emergencia.',
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              Expanded(
                child: GridView.count(
                  crossAxisCount: 2,
                  mainAxisSpacing: 16,
                  crossAxisSpacing: 16,
                  childAspectRatio: 1,
                  children: [
                    for (final tile in tiles)
                      _ElderTileButton(tile: tile, speech: speech),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      floatingActionButton: const SosButton(),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
    );
  }

  static String _firstName(String? fullName) {
    if (fullName == null || fullName.trim().isEmpty) return 'hola';
    return fullName.trim().split(RegExp(r'\s+')).first;
  }

  /// Fecha en español sin depender de datos de locale de intl.
  static String _spanishDate(DateTime d) {
    const days = [
      'lunes', 'martes', 'miércoles', 'jueves', 'viernes', 'sábado', 'domingo'
    ];
    const months = [
      'enero', 'febrero', 'marzo', 'abril', 'mayo', 'junio', 'julio', 'agosto',
      'septiembre', 'octubre', 'noviembre', 'diciembre'
    ];
    final day = days[d.weekday - 1];
    final month = months[d.month - 1];
    final capitalized = day[0].toUpperCase() + day.substring(1);
    return '$capitalized ${d.day} de $month';
  }
}

class _ElderTile {
  const _ElderTile({
    required this.icon,
    required this.label,
    required this.color,
    required this.speak,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final Color color;
  final String speak;
  final VoidCallback onTap;
}

class _ElderTileButton extends StatelessWidget {
  const _ElderTileButton({required this.tile, required this.speech});

  final _ElderTile tile;
  final SpeechService speech;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: tile.speak,
      child: Material(
        color: tile.color,
        borderRadius: BorderRadius.circular(24),
        child: InkWell(
          borderRadius: BorderRadius.circular(24),
          onTap: () {
            speech.speak(tile.speak);
            tile.onTap();
          },
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(tile.icon, size: 64, color: Colors.white),
                const SizedBox(height: 14),
                Text(
                  tile.label,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w800,
                    color: Colors.white,
                    height: 1.1,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _HelpButton extends StatelessWidget {
  const _HelpButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Ayuda. Escuchar cómo usar esta pantalla.',
      child: Material(
        color: AppColors.primary.withOpacity(.12),
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: const Padding(
            padding: EdgeInsets.all(14),
            child: Icon(Icons.volume_up_rounded,
                size: 36, color: AppColors.primaryDark),
          ),
        ),
      ),
    );
  }
}
