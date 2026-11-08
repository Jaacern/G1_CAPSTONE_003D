import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/audio/tone_service.dart';
import '../../../core/theme/app_theme.dart';

/// "Director musical" de la vista del adulto mayor: una rejilla de botones
/// grandes y coloridos que suenan al pulsarlos. Cada botón es una nota de la
/// escala; tocarlas en orden hace una melodía. Es una actividad lúdica y
/// estimulante, pensada para dedos y vista de 75 años (objetivos táctiles
/// enormes, contraste alto, color pleno de la paleta AgeCare).
class ElderMusicScreen extends ConsumerWidget {
  const ElderMusicScreen({super.key});

  // Notas de una escala de Do mayor (C4..C5). Cada nota lleva su color pleno
  // de la paleta AgeCare y una etiqueta grande.
  static const _notes = <_Note>[
    _Note('Do', 261.63, AgeColors.teal600),
    _Note('Re', 293.66, AgeColors.coral600),
    _Note('Mi', 329.63, AgeColors.gold500),
    _Note('Fa', 349.23, AgeColors.navy700),
    _Note('Sol', 392.00, AgeColors.teal500),
    _Note('La', 440.00, AgeColors.coral500),
    _Note('Si', 493.88, AgeColors.info600),
    _Note('Do²', 523.25, AgeColors.teal700),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tone = ref.read(toneServiceProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Director musical'),
        toolbarHeight: 72,
        titleTextStyle: AgeText.h1.copyWith(
          fontFamily: 'Nunito Sans',
          color: Theme.of(context).colorScheme.onSurface,
        ),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Toca los botones y crea tu música',
                style: AgeText.bodyL.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 16),
              Expanded(
                child: GridView.count(
                  crossAxisCount: 2,
                  mainAxisSpacing: 16,
                  crossAxisSpacing: 16,
                  childAspectRatio: 1.15,
                  children: [
                    for (final note in _notes)
                      _NoteButton(note: note, tone: tone),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Note {
  const _Note(this.label, this.frequency, this.color);
  final String label;
  final double frequency;
  final Color color;
}

/// Botón de nota: se hunde y aclara mientras está pulsado, y suena al tocar.
class _NoteButton extends StatefulWidget {
  const _NoteButton({required this.note, required this.tone});
  final _Note note;
  final ToneService tone;

  @override
  State<_NoteButton> createState() => _NoteButtonState();
}

class _NoteButtonState extends State<_NoteButton> {
  bool _pressed = false;

  void _hit() {
    setState(() => _pressed = true);
    widget.tone.play(widget.note.frequency, durationMs: 650);
    Future.delayed(const Duration(milliseconds: 160), () {
      if (mounted) setState(() => _pressed = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    // Marino sobre dorado (contraste), blanco en el resto — regla de la guía.
    final onColor =
        widget.note.color == AgeColors.gold500 ? AgeColors.navy800 : Colors.white;
    return Semantics(
      button: true,
      label: 'Nota ${widget.note.label}',
      child: GestureDetector(
        onTapDown: (_) => _hit(),
        child: AnimatedScale(
          scale: _pressed ? 0.94 : 1.0,
          duration: const Duration(milliseconds: 90),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 90),
            decoration: BoxDecoration(
              color: _pressed
                  ? Color.alphaBlend(Colors.white24, widget.note.color)
                  : widget.note.color,
              borderRadius: BorderRadius.circular(AgeRadius.xxl),
            ),
            alignment: Alignment.center,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.music_note_rounded, size: 48, color: onColor),
                const SizedBox(height: 8),
                Text(
                  widget.note.label,
                  style: TextStyle(
                    fontSize: 30,
                    fontWeight: FontWeight.w800,
                    color: onColor,
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
