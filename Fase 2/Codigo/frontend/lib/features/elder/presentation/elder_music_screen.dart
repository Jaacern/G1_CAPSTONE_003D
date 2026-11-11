import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:uuid/uuid.dart';

import '../../../core/audio/tone_service.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/upload_service.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/common.dart';
import '../../auth/application/auth_controller.dart';
import '../application/elder_providers.dart';

/// Director Musical (RF-65 a RF-67, RF-69).
///
/// El adulto mayor toca las notas, la app graba lo que suena y, cuando pulsa
/// "Guardar", sube el audio al backend y lo registra como una creación musical.
///
/// FLUJO
///   1. Al pulsar una nota suena (ToneService, igual que antes).
///   2. Si la grabación está activa, el micrófono capta el sonido ambiente,
///      que incluye los tonos que salen por el altavoz. Es el enfoque más
///      simple: no requiere mezcla de audio en código.
///   3. Al pulsar ● Grabar, el micrófono empieza a escuchar.
///   4. Al pulsar ■ Guardar, se detiene la grabación, sube el archivo y
///      se registra en POST /patients/{id}/music con un client_uuid local
///      (RF-66: idempotente ante reintentos).
///
/// DECISIÓN DE DISEÑO
///   El título lo pone el adulto mayor en un diálogo antes de guardar. Si
///   cancela el diálogo, el audio se descarta sin subir nada.
class ElderMusicScreen extends ConsumerStatefulWidget {
  const ElderMusicScreen({super.key});

  @override
  ConsumerState<ElderMusicScreen> createState() => _ElderMusicScreenState();
}

class _ElderMusicScreenState extends ConsumerState<ElderMusicScreen> {
  static const _notes = <_Note>[
    _Note('Do',  261.63, AgeColors.teal600),
    _Note('Re',  293.66, AgeColors.coral600),
    _Note('Mi',  329.63, AgeColors.gold500),
    _Note('Fa',  349.23, AgeColors.navy700),
    _Note('Sol', 392.00, AgeColors.teal500),
    _Note('La',  440.00, AgeColors.coral500),
    _Note('Si',  493.88, AgeColors.info600),
    _Note('Do²', 523.25, AgeColors.teal700),
  ];

  final _recorder = AudioRecorder();
  bool _grabando = false;
  bool _subiendo = false;
  String? _archivoTemporal;
  int _duracionSeg = 0;
  late final Stopwatch _stopwatch;

  @override
  void initState() {
    super.initState();
    _stopwatch = Stopwatch();
  }

  @override
  void dispose() {
    _recorder.dispose();
    super.dispose();
  }

  Future<void> _iniciarGrabacion() async {
    final tiene = await _recorder.hasPermission();
    if (!tiene) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Necesito permiso para el micrófono.'),
          ),
        );
      }
      return;
    }
    final dir = await getTemporaryDirectory();
    final path =
        '${dir.path}/musica_${DateTime.now().millisecondsSinceEpoch}.m4a';
    await _recorder.start(
      const RecordConfig(encoder: AudioEncoder.aacLc),
      path: path,
    );
    _stopwatch
      ..reset()
      ..start();
    setState(() {
      _grabando = true;
      _archivoTemporal = path;
      _duracionSeg = 0;
    });

    // Actualizar el contador de segundos.
    Future.doWhile(() async {
      await Future.delayed(const Duration(seconds: 1));
      if (!mounted || !_grabando) return false;
      setState(() => _duracionSeg = _stopwatch.elapsed.inSeconds);
      return true;
    });
  }

  Future<void> _detenerYGuardar() async {
    if (!_grabando) return;
    final path = await _recorder.stop();
    _stopwatch.stop();
    setState(() => _grabando = false);

    if (path == null || !mounted) return;

    // Pedir título antes de subir.
    final titulo = await _pedirTitulo();
    if (titulo == null || !mounted) {
      // Usuario canceló: borrar archivo temporal.
      try {
        await File(path).delete();
      } catch (_) {}
      return;
    }

    setState(() => _subiendo = true);
    try {
      final patientId = ref.read(elderPatientIdProvider);
      if (patientId == null) throw Exception('Sin paciente asociado.');

      final uploads = ref.read(uploadServiceProvider);
      final api = ref.read(apiClientProvider);

      // 1. Subir el audio.
      final uploaded = await uploads.uploadFile(
        File(path),
        kind: 'audio',
        patientId: patientId,
      );

      // 2. Registrar la creación con client_uuid para idempotencia (RF-66).
      final clientUuid = const Uuid().v4();
      await api.post<void>(
        '/patients/$patientId/music',
        query: {
          'file_id': uploaded.fileId,
          'title': titulo,
          'duration_seconds': _stopwatch.elapsed.inSeconds.clamp(1, 86400),
          'client_uuid': clientUuid,
        },
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('¡"$titulo" guardada! 🎵'),
            backgroundColor: AgeColors.teal600,
          ),
        );
      }
    } on ApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('No se pudo guardar: ${e.message}'),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('No se pudo guardar: $e'),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _subiendo = false);
      try {
        await File(path).delete();
      } catch (_) {}
    }
  }

  Future<String?> _pedirTitulo() async {
    final ctrl = TextEditingController(
      text: 'Mi melodía ${DateTime.now().day}/${DateTime.now().month}',
    );
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('¿Cómo la llamas?'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          maxLength: 150,
          decoration: const InputDecoration(
            labelText: 'Nombre de la creación',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Descartar'),
          ),
          FilledButton(
            onPressed: () {
              final t = ctrl.text.trim();
              Navigator.pop(ctx, t.isEmpty ? null : t);
            },
            child: const Text('Guardar'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tone = ref.read(toneServiceProvider);
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Director musical'),
        toolbarHeight: 72,
        titleTextStyle: AgeText.h1.copyWith(
          fontFamily: 'Nunito Sans',
          color: scheme.onSurface,
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
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 10),

              // Barra de grabación.
              _GrabacionBar(
                grabando: _grabando,
                subiendo: _subiendo,
                duracionSeg: _duracionSeg,
                onGrabar: _iniciarGrabacion,
                onGuardar: _detenerYGuardar,
              ),

              const SizedBox(height: 14),

              // Rejilla de notas.
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

// ---------------------------------------------------------------------------
// Barra de grabación
// ---------------------------------------------------------------------------

class _GrabacionBar extends StatelessWidget {
  const _GrabacionBar({
    required this.grabando,
    required this.subiendo,
    required this.duracionSeg,
    required this.onGrabar,
    required this.onGuardar,
  });

  final bool grabando;
  final bool subiendo;
  final int duracionSeg;
  final VoidCallback onGrabar;
  final VoidCallback onGuardar;

  String _fmt(int seg) {
    final m = seg ~/ 60;
    final s = seg % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    if (subiendo) {
      return const Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          SizedBox(width: 10),
          Text('Guardando…'),
        ],
      );
    }

    if (grabando) {
      return Row(
        children: [
          const Icon(Icons.circle, color: Colors.red, size: 14),
          const SizedBox(width: 6),
          Text(
            'Grabando ${_fmt(duracionSeg)}',
            style: const TextStyle(color: Colors.red, fontWeight: FontWeight.w600),
          ),
          const Spacer(),
          FilledButton.icon(
            onPressed: onGuardar,
            icon: const Icon(Icons.stop_rounded),
            label: const Text('Guardar'),
            style: FilledButton.styleFrom(backgroundColor: AgeColors.teal600),
          ),
        ],
      );
    }

    return Row(
      children: [
        const Text('¿Quieres guardar tu melodía?'),
        const Spacer(),
        OutlinedButton.icon(
          onPressed: onGrabar,
          icon: const Icon(Icons.fiber_manual_record_rounded, color: Colors.red),
          label: const Text('Grabar'),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Nota musical
// ---------------------------------------------------------------------------

class _Note {
  const _Note(this.label, this.frequency, this.color);
  final String label;
  final double frequency;
  final Color color;
}

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
    final onColor = widget.note.color == AgeColors.gold500
        ? AgeColors.navy800
        : Colors.white;
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
              borderRadius: BorderRadius.circular(20),
              boxShadow: _pressed
                  ? []
                  : [
                      BoxShadow(
                        color: widget.note.color.withOpacity(0.45),
                        blurRadius: 12,
                        offset: const Offset(0, 4),
                      ),
                    ],
            ),
            child: Center(
              child: Text(
                widget.note.label,
                style: AgeText.h2.copyWith(
                  color: onColor,
                  fontFamily: 'Nunito Sans',
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
