import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';

import '../../../core/audio/tone_service.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/upload_service.dart';
import '../../../core/theme/app_theme.dart';
import '../application/elder_providers.dart';
import 'elder_melodies_screen.dart';

/// Director Musical (RF-65 a RF-67, RF-69).
///
/// El adulto mayor toca las notas, la app graba lo que suena y, cuando pulsa
/// "Guardar", sube el audio al backend y lo registra como una creación musical.
///
/// FLUJO
///   1. Al pulsar una nota suena (ToneService, igual que antes).
///   2. Al pulsar ● Grabar se empieza a anotar que nota se toca y cuando.
///      No se usa el microfono: antes se grababa el sonido de la pieza y se
///      colaban la voz y el ruido.
///   3. Al pulsar ■ Guardar se arma un WAV con esas notas
///      (ToneService.mezclar), con la misma forma de onda que se escucho, se
///      sube y se registra en POST /patients/{id}/music con un client_uuid
///      local (RF-66: idempotente ante reintentos).
///
/// DECISIÓN DE DISEÑO
///   El nombre se arma solo con la fecha y la hora (RNF-20: sin teclado). Un
///   dialogo con dos botones grandes pregunta si se guarda; "No guardar"
///   descarta la grabacion. Las melodias guardadas se escuchan en
///   "Mis melodías" (ElderMelodiesScreen).
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

  /// Cuanto suena cada nota. El mismo valor para tocarla y para guardarla,
  /// asi lo grabado suena igual a lo que se escucho.
  static const _duracionNotaMs = 650;

  /// Tope de una grabacion: tres minutos. Evita una que quedo corriendo sola
  /// y mantiene el archivo lejos del limite del servidor (25 MB).
  static const _maximoGrabacion = Duration(minutes: 3);

  /// Notas tocadas durante la grabacion: cuando (ms desde que empezo) y cual.
  final _notasGrabadas = <({int offsetMs, double frequency})>[];
  bool _grabando = false;
  bool _subiendo = false;
  int _duracionSeg = 0;
  late final Stopwatch _stopwatch;

  @override
  void initState() {
    super.initState();
    _stopwatch = Stopwatch();
  }

  /// Se llama cada vez que suena una nota. Si se esta grabando, se anota.
  void _alTocar(double frecuencia) {
    if (!_grabando) return;
    _notasGrabadas.add(
        (offsetMs: _stopwatch.elapsedMilliseconds, frequency: frecuencia));
  }

  /// Empieza a grabar. No usa el microfono: anota las notas que se tocan y
  /// al guardar arma el audio con ellas. Asi no se cuela la voz ni el ruido
  /// de la pieza, no hace falta pedir permiso y funciona en cualquier
  /// navegador.
  void _iniciarGrabacion() {
    _notasGrabadas.clear();
    _stopwatch
      ..reset()
      ..start();
    setState(() {
      _grabando = true;
      _duracionSeg = 0;
    });

    // Contador de segundos, y corte automatico al llegar al tope.
    Future.doWhile(() async {
      await Future.delayed(const Duration(seconds: 1));
      if (!mounted || !_grabando) return false;
      if (_stopwatch.elapsed >= _maximoGrabacion) {
        await _detenerYGuardar();
        return false;
      }
      setState(() => _duracionSeg = _stopwatch.elapsed.inSeconds);
      return true;
    });
  }

  Future<void> _detenerYGuardar() async {
    if (!_grabando) return;
    _stopwatch.stop();
    setState(() => _grabando = false);
    if (!mounted) return;

    if (_notasGrabadas.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No tocaste ninguna nota. Toca algunas y vuelve a '
              'grabar.'),
        ),
      );
      return;
    }

    // Confirmar antes de subir. El nombre se arma solo (RNF-20).
    final titulo = await _pedirTitulo();
    if (titulo == null || !mounted) return;

    setState(() => _subiendo = true);
    try {
      final patientId = ref.read(elderPatientIdProvider);
      if (patientId == null) throw Exception('Sin paciente asociado.');

      final notas = List.of(_notasGrabadas);
      final wav = ref
          .read(toneServiceProvider)
          .mezclar(notas, durationMs: _duracionNotaMs);
      final ultimoMs = notas.map((n) => n.offsetMs).reduce(math.max);
      final segundos =
          ((ultimoMs + _duracionNotaMs) / 1000).ceil().clamp(1, 86400);

      // 1. Subir el audio armado con las notas.
      final uploaded = await ref.read(uploadServiceProvider).uploadBytes(
            wav,
            filename: 'melodia.wav',
            kind: 'audio',
            patientId: patientId,
            contentType: 'audio/wav',
          );

      // 2. Registrar la creación con client_uuid para idempotencia (RF-66).
      // El endpoint pide el id del archivo suelto, no la URL entera.
      final fileId = uploaded.fileId;
      if (fileId == null) {
        throw Exception('El audio se subió pero no se pudo identificar.');
      }
      final clientUuid = const Uuid().v4();
      await ref.read(apiClientProvider).post<void>(
        '/patients/$patientId/music',
        query: {
          'file_id': fileId,
          'title': titulo,
          'duration_seconds': segundos,
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
    }
  }

  /// Pregunta si se guarda la melodia y devuelve su nombre, o null si no.
  ///
  /// RNF-20: las acciones principales del adulto mayor no piden teclado.
  /// Antes este dialogo pedia escribir el nombre; ahora el nombre se arma
  /// solo con la fecha y la hora ("Melodia del 12 de noviembre, 19:30") y
  /// solo queda elegir entre dos botones grandes. Se mantiene la pregunta
  /// porque tambien es la forma de descartar una grabacion que no gusto.
  Future<String?> _pedirTitulo() async {
    final titulo =
        'Melodía del ${DateFormat("d 'de' MMMM, HH:mm", 'es').format(DateTime.now())}';
    final guardar = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('¿Guardamos tu melodía?'),
        content: Text(
          'Se va a guardar como "$titulo".',
          style: AgeText.bodyL,
        ),
        actionsAlignment: MainAxisAlignment.spaceBetween,
        actions: [
          OutlinedButton(
            style: OutlinedButton.styleFrom(minimumSize: const Size(120, 56)),
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('No guardar'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(120, 56)),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Guardar'),
          ),
        ],
      ),
    );
    return guardar == true ? titulo : null;
  }

  @override
  Widget build(BuildContext context) {
    final tone = ref.read(toneServiceProvider);
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Director musical'),
        toolbarHeight: 72,
        actions: [
          // Las melodias guardadas, para volver a escucharlas.
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: TextButton.icon(
              style: TextButton.styleFrom(minimumSize: const Size(48, 52)),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(
                    builder: (_) => const ElderMelodiesScreen()),
              ),
              icon: const Icon(Icons.library_music_rounded, size: 28),
              label: const Text('Mis melodías'),
            ),
          ),
        ],
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
                      _NoteButton(
                        note: note,
                        tone: tone,
                        duracionMs: _duracionNotaMs,
                        onTocar: _alTocar,
                      ),
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
            // El tema da a los botones ancho infinito (Size.fromHeight) para
            // los formularios; dentro de una fila eso rompe el dibujo de la
            // pantalla entera. Aqui el ancho es el del contenido.
            style: FilledButton.styleFrom(
              backgroundColor: AgeColors.teal600,
              minimumSize: const Size(48, 52),
            ),
          ),
        ],
      );
    }

    return Row(
      children: [
        const Expanded(child: Text('¿Quieres guardar tu melodía?')),
        const SizedBox(width: 8),
        OutlinedButton.icon(
          onPressed: onGrabar,
          icon: const Icon(Icons.fiber_manual_record_rounded, color: Colors.red),
          label: const Text('Grabar'),
          // Ver la nota del boton Guardar: sin esto la fila no se puede dibujar.
          style: OutlinedButton.styleFrom(minimumSize: const Size(48, 52)),
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
  const _NoteButton({
    required this.note,
    required this.tone,
    required this.duracionMs,
    required this.onTocar,
  });
  final _Note note;
  final ToneService tone;
  final int duracionMs;

  /// Avisa a la pantalla que sono esta nota (para anotarla si se graba).
  final ValueChanged<double> onTocar;

  @override
  State<_NoteButton> createState() => _NoteButtonState();
}

class _NoteButtonState extends State<_NoteButton> {
  bool _pressed = false;

  void _hit() {
    setState(() => _pressed = true);
    widget.tone.play(widget.note.frequency, durationMs: widget.duracionMs);
    widget.onTocar(widget.note.frequency);
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
                        color: widget.note.color.withValues(alpha: 0.45),
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
