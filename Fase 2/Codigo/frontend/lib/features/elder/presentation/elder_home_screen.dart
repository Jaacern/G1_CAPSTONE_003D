import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/config/app_config.dart';
import '../../../core/speech/speech_service.dart';
import '../../../core/theme/app_theme.dart';
import '../../alerts/presentation/sos_button.dart';
import '../../auth/application/auth_controller.dart';
import '../../medications/domain/models.dart' as meds;
import '../../medications/presentation/dose_actions.dart';
import '../application/elder_providers.dart';
import 'elder_music_screen.dart';
import 'elder_photos_screen.dart';

/// Pantalla PRINCIPAL de la vista del adulto mayor (shell del rol elder).
///
/// Diseño propio del rol (no comparte el template de los demás): saludo
/// grande, un check-in de ánimo diario ("¿Cómo te sientes hoy?") y tarjetas
/// de acción en lista, con un ítem por fila, icono con fondo tinte y texto de
/// apoyo. Todo con la identidad AgeCare (tipografía Nunito Sans y paleta
/// marino/teal/coral/dorado), objetivos táctiles grandes y lectura por voz.
class ElderHomeScreen extends ConsumerWidget {
  const ElderHomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(currentUserProvider);
    final firstName = _firstName(user?.fullName);
    final patientId = ref.watch(elderPatientIdProvider);
    final speech = ref.read(speechServiceProvider);
    final scheme = Theme.of(context).colorScheme;

    final actions = <_ElderAction>[
      if (AppConfig.hasComms)
        _ElderAction(
          icon: Icons.chat_bubble_rounded,
          title: 'Familia',
          subtitle: 'Hablar y escuchar mensajes',
          accentFg: AgeColors.teal600,
          accentBg: AgeColors.teal100,
          speak: 'Familia. Hablar y escuchar mensajes.',
          onTap: () => context
              .push(patientId == null ? '/chat' : '/chat?patient=$patientId'),
        ),
      if (AppConfig.hasElderContent) ...[
        _ElderAction(
          icon: Icons.photo_library_rounded,
          title: 'Fotos',
          subtitle: 'Ver fotos de la familia',
          accentFg: AgeColors.coral700,
          accentBg: AgeColors.coral100,
          speak: 'Fotos. Ver fotos de la familia.',
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const ElderPhotosScreen()),
          ),
        ),
        _ElderAction(
          icon: Icons.piano_rounded,
          title: 'Entretenimiento',
          subtitle: 'Director musical',
          accentFg: AgeColors.gold700,
          accentBg: AgeColors.gold100,
          speak: 'Entretenimiento. Director musical.',
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const ElderMusicScreen()),
          ),
        ),
      ],
    ];

    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 110),
          children: [
            // Encabezado: saludo + fecha + botón de ayuda por voz.
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Hola, $firstName 👋',
                        style: AgeText.display.copyWith(
                          fontFamily: 'Nunito Sans',
                          color: scheme.onSurface,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _spanishDate(DateTime.now()),
                        style: AgeText.bodyL.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                _HelpButton(
                  onTap: () => speech.speak(
                    'Esta es tu pantalla de inicio. Arriba están tus remedios '
                    'de hoy, con un botón para avisar cuando te tomes uno. '
                    'Después puedes decirnos cómo te sientes hoy. Más abajo, '
                    'toca un botón grande para hablar con tu familia, ver tus '
                    'fotos o entretenerte con la música. El botón rojo es '
                    'para pedir ayuda en una emergencia.',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),

            // Los remedios de hoy, arriba de todo. Es lo unico de esta
            // pantalla que tiene hora: si se pasa, se pasa.
            _RemediosDeHoy(speech: speech),

            // Check-in de ánimo.
            _MoodCheckIn(speech: speech),
            const SizedBox(height: 20),

            // Acciones en lista, un ítem por fila.
            for (final a in actions) ...[
              _ActionCard(action: a, speech: speech),
              const SizedBox(height: 16),
            ],

            const SizedBox(height: 12),
            const _LogoutButton(),
          ],
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
      'lunes',
      'martes',
      'miércoles',
      'jueves',
      'viernes',
      'sábado',
      'domingo'
    ];
    const months = [
      'enero',
      'febrero',
      'marzo',
      'abril',
      'mayo',
      'junio',
      'julio',
      'agosto',
      'septiembre',
      'octubre',
      'noviembre',
      'diciembre'
    ];
    final day = days[d.weekday - 1];
    final month = months[d.month - 1];
    final capitalized = day[0].toUpperCase() + day.substring(1);
    return '$capitalized ${d.day} de $month';
  }
}

/// Tarjeta "¿Cómo te sientes hoy?" con tres caras grandes. Al elegir una, se
/// confirma en voz alta y queda marcada (feedback visual + sonoro, sin iconos
/// de estado crípticos).
class _MoodCheckIn extends StatefulWidget {
  const _MoodCheckIn({required this.speech});
  final SpeechService speech;

  @override
  State<_MoodCheckIn> createState() => _MoodCheckInState();
}

class _MoodCheckInState extends State<_MoodCheckIn> {
  static const _moods = <_Mood>[
    _Mood('bien', '😀', 'Bien', AgeColors.ok600, AgeColors.ok100,
        'Me alegra que te sientas bien hoy.'),
    _Mood('regular', '😐', 'Regular', AgeColors.warn500, AgeColors.warn100,
        'Gracias por contarnos. Cuídate mucho hoy.'),
    _Mood('mal', '😟', 'Mal', AgeColors.attention600, AgeColors.attention100,
        'Lamento que te sientas así. Avisaremos a tu familia.'),
  ];

  String? _selected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(AgeRadius.xxl),
        border: Border.all(color: scheme.outline),
      ),
      child: Column(
        children: [
          Text(
            '¿Cómo te sientes hoy?',
            style: AgeText.h2.copyWith(
              fontFamily: 'Nunito Sans',
              color: scheme.onSurface,
            ),
          ),
          const SizedBox(height: 20),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              for (final mood in _moods)
                _MoodFace(
                  mood: mood,
                  selected: _selected == mood.id,
                  onTap: () {
                    setState(() => _selected = mood.id);
                    widget.speech.speak(mood.spoken);
                  },
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Mood {
  const _Mood(this.id, this.emoji, this.label, this.fg, this.bg, this.spoken);
  final String id;
  final String emoji;
  final String label;
  final Color fg;
  final Color bg;
  final String spoken;
}

class _MoodFace extends StatelessWidget {
  const _MoodFace(
      {required this.mood, required this.selected, required this.onTap});
  final _Mood mood;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      label: 'Me siento ${mood.label}',
      child: GestureDetector(
        onTap: onTap,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 140),
              width: 84,
              height: 84,
              decoration: BoxDecoration(
                color: selected ? mood.bg : Colors.transparent,
                shape: BoxShape.circle,
                border: Border.all(
                  color: selected ? mood.fg : Colors.transparent,
                  width: 3,
                ),
              ),
              alignment: Alignment.center,
              child: Text(mood.emoji, style: const TextStyle(fontSize: 44)),
            ),
            const SizedBox(height: 8),
            Text(
              mood.label,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: selected
                    ? mood.fg
                    : Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ElderAction {
  const _ElderAction({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.accentFg,
    required this.accentBg,
    required this.speak,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Color accentFg;
  final Color accentBg;
  final String speak;
  final VoidCallback onTap;
}

/// Tarjeta de acción en lista: icono con fondo tinte a la izquierda, título
/// grande y subtítulo. Toda la fila es tocable y se lee en voz alta.
class _ActionCard extends StatelessWidget {
  const _ActionCard({required this.action, required this.speech});
  final _ElderAction action;
  final SpeechService speech;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      label: action.speak,
      child: Material(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(AgeRadius.xxl),
        child: InkWell(
          borderRadius: BorderRadius.circular(AgeRadius.xxl),
          onTap: () {
            speech.speak(action.speak);
            action.onTap();
          },
          child: Container(
            constraints: const BoxConstraints(minHeight: 96),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AgeRadius.xxl),
              border: Border.all(color: scheme.outline),
            ),
            child: Row(
              children: [
                Container(
                  width: 68,
                  height: 68,
                  decoration: BoxDecoration(
                    color: action.accentBg,
                    borderRadius: BorderRadius.circular(AgeRadius.l),
                  ),
                  alignment: Alignment.center,
                  child: Icon(action.icon, size: 38, color: action.accentFg),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        action.title,
                        style: AgeText.h2.copyWith(
                          fontFamily: 'Nunito Sans',
                          color: scheme.onSurface,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        action.subtitle,
                        style: AgeText.body.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right_rounded,
                    size: 32, color: scheme.onSurfaceVariant),
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
        color: AgeColors.teal100,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: const Padding(
            padding: EdgeInsets.all(14),
            child: Icon(Icons.volume_up_rounded,
                size: 36, color: AgeColors.teal700),
          ),
        ),
      ),
    );
  }
}

/// Botón grande para cerrar sesión. Pide confirmación en lenguaje natural
/// (sí/no) con botones enormes, para evitar que se cierre por error.
class _LogoutButton extends ConsumerWidget {
  const _LogoutButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Semantics(
      button: true,
      label: 'Cerrar sesión',
      child: Material(
        color: AgeColors.attention100,
        borderRadius: BorderRadius.circular(AgeRadius.xxl),
        child: InkWell(
          borderRadius: BorderRadius.circular(AgeRadius.xxl),
          onTap: () => _confirm(context, ref),
          child: Container(
            constraints: const BoxConstraints(minHeight: 72),
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.logout_rounded,
                    size: 30, color: AgeColors.attention700),
                const SizedBox(width: 10),
                Text(
                  'Cerrar sesión',
                  style: AgeText.label.copyWith(
                    fontFamily: 'Nunito Sans',
                    fontSize: 20,
                    color: AgeColors.attention700,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _confirm(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('¿Cerrar sesión?',
            style: AgeText.h2.copyWith(fontFamily: 'Nunito Sans')),
        content: Text(
          'Tendrás que volver a entrar para usar la aplicación.',
          style: AgeText.bodyL.copyWith(fontFamily: 'Nunito Sans'),
        ),
        actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        actions: [
          SizedBox(
            height: 60,
            child: OutlinedButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text('No, quedarme',
                  style: AgeText.label
                      .copyWith(fontFamily: 'Nunito Sans', fontSize: 18)),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 60,
            width: double.infinity,
            child: FilledButton(
              style: FilledButton.styleFrom(
                  backgroundColor: AgeColors.attention600),
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text('Sí, cerrar sesión',
                  style: AgeText.label
                      .copyWith(fontFamily: 'Nunito Sans', fontSize: 18)),
            ),
          ),
        ],
      ),
    );
    if (ok == true) {
      await ref.read(authControllerProvider.notifier).logout();
    }
  }
}

/// Los remedios de hoy del adulto mayor, en su propia pantalla de inicio.
///
/// Esta pantalla no tiene barra de pestanas, asi que hasta ahora la persona
/// que de hecho se toma las pastillas no tenia donde mirar que le toca. Se
/// enteraba cuando sonaba la notificacion, y si la perdia no habia a donde
/// volver.
///
/// Muestra la proxima que falta, no la lista entera: la pregunta de alguien
/// que mira esto es "que me toca ahora", y una lista de seis filas con horas
/// la responde peor que una sola linea grande. Lo que ya se tomo se resume en
/// el contador de abajo.
class _RemediosDeHoy extends ConsumerWidget {
  const _RemediosDeHoy({required this.speech});

  final SpeechService speech;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dosisAsync = ref.watch(dosisDeHoyProvider);
    final scheme = Theme.of(context).colorScheme;

    final dosis = dosisAsync.valueOrNull;
    // Mientras carga o si falla no se ocupa espacio: el resto de la pantalla
    // sigue siendo util y un error tecnico aqui no le dice nada a esta
    // persona. La notificacion sigue siendo el aviso que no depende de esto.
    if (dosis == null || dosis.isEmpty) return const SizedBox.shrink();

    final pendientes = dosis
        .where((d) =>
            d.status == meds.DoseStatus.pending ||
            d.status == meds.DoseStatus.postponed)
        .toList()
      ..sort((a, b) => a.scheduledAt.compareTo(b.scheduledAt));
    final tomadas =
        dosis.where((d) => d.status == meds.DoseStatus.taken).length;

    final proxima = pendientes.isEmpty ? null : pendientes.first;
    final texto = proxima == null
        ? 'Ya te tomaste todos tus remedios de hoy.'
        : '${proxima.medicationName}, '
            '${meds.etiquetaDeDosis(proxima.dose ?? '', proxima.unit ?? '')}, '
            'a las ${proxima.timeLabel}.';

    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Semantics(
        label: 'Tus remedios de hoy. $texto '
            'Te tomaste $tomadas de ${dosis.length}.',
        child: Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: proxima == null ? AgeColors.ok100 : AgeColors.teal100,
            borderRadius: BorderRadius.circular(AgeRadius.xxl),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    proxima == null
                        ? Icons.check_circle_rounded
                        : Icons.medication_rounded,
                    size: 30,
                    color:
                        proxima == null ? AgeColors.ok600 : AgeColors.teal700,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Tus remedios de hoy',
                      style: AgeText.h2.copyWith(color: scheme.onSurface),
                    ),
                  ),
                  // El mismo gesto de escuchar que el resto de la pantalla.
                  IconButton(
                    tooltip: 'Escuchar',
                    icon: Icon(Icons.volume_up_rounded,
                        size: 28, color: scheme.onSurfaceVariant),
                    onPressed: () => speech.speak(texto),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                proxima == null ? texto : proxima.medicationName,
                style: AgeText.display.copyWith(
                  fontFamily: 'Nunito Sans',
                  color: scheme.onSurface,
                ),
              ),
              if (proxima != null) ...[
                const SizedBox(height: 6),
                Text(
                  '${meds.etiquetaDeDosis(proxima.dose ?? '', proxima.unit ?? '')}'
                  ' · a las ${proxima.timeLabel}',
                  style: AgeText.bodyL.copyWith(color: scheme.onSurfaceVariant),
                ),
                const SizedBox(height: 16),
                // Un solo boton, del ancho de la tarjeta. Las otras opciones
                // (posponer, no la tome) viven en la pantalla de la dosis,
                // que la familia y la cuidadora si tienen: aqui la respuesta
                // normal es una sola.
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 18),
                      backgroundColor: AgeColors.teal600,
                    ),
                    onPressed: () async {
                      final ok = await registrarDosis(
                        context: context,
                        ref: ref,
                        dose: proxima,
                        status: meds.DoseStatus.taken,
                      );
                      if (ok) ref.invalidate(dosisDeHoyProvider);
                    },
                    icon: const Icon(Icons.check_rounded, size: 26),
                    label: const Text('Ya me lo tomé', style: AgeText.bodyL),
                  ),
                ),
              ],
              const SizedBox(height: 10),
              Text(
                'Te tomaste $tomadas de ${dosis.length} de hoy.',
                style: AgeText.body.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
