import 'package:flutter/material.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

import '../theme/app_theme.dart';
import '../widgets/common.dart';

/// Boton para escribir dictando (RF-64).
///
/// Se toca para empezar a escuchar y se vuelve a tocar para terminar; si la
/// persona deja de hablar, termina solo. Lo que se reconoce se va escribiendo
/// en [controller], a continuacion de lo que ya habia, asi se puede dictar
/// por partes y corregir a mano antes de enviar.
///
/// Usa el reconocimiento de voz del propio navegador o telefono
/// (speech_to_text): funciona en Chrome y en Android sin configurar nada en
/// el servidor. El audio lo procesa el servicio del sistema (Google o Apple),
/// no nuestro backend.
class BotonDictado extends StatefulWidget {
  const BotonDictado({
    super.key,
    required this.controller,
    this.enabled = true,
  });

  final TextEditingController controller;
  final bool enabled;

  @override
  State<BotonDictado> createState() => _BotonDictadoState();
}

class _BotonDictadoState extends State<BotonDictado> {
  final _voz = SpeechToText();
  bool _listo = false;
  bool _escuchando = false;

  /// Texto que habia antes de empezar a dictar. Lo dictado se agrega despues.
  String _base = '';

  @override
  void dispose() {
    if (_listo) _voz.cancel();
    super.dispose();
  }

  Future<bool> _preparar() async {
    if (_listo) return true;
    _listo = await _voz.initialize(
      onStatus: (estado) {
        // 'done' / 'notListening': termino solo (silencio o tiempo maximo).
        if ((estado == 'done' || estado == 'notListening') && mounted) {
          setState(() => _escuchando = false);
        }
      },
      onError: (SpeechRecognitionError e) {
        if (!mounted) return;
        setState(() => _escuchando = false);
        // Silencio o "no te entendi" no son fallas: se deja de escuchar y ya.
        if (e.errorMsg == 'error_no_match' ||
            e.errorMsg == 'error_speech_timeout' ||
            e.errorMsg == 'no-speech') {
          return;
        }
        showAppSnackBar(
          context,
          'No se pudo dictar. Revisa el permiso del micrófono.',
          error: true,
        );
      },
    );
    return _listo;
  }

  Future<void> _alternar() async {
    if (_escuchando) {
      await _voz.stop();
      if (mounted) setState(() => _escuchando = false);
      return;
    }
    if (!await _preparar()) {
      if (mounted) {
        showAppSnackBar(
          context,
          'Este navegador no permite dictar. Prueba con Chrome o desde el '
          'teléfono.',
          error: true,
        );
      }
      return;
    }
    final actual = widget.controller.text.trimRight();
    _base = actual.isEmpty ? '' : '$actual ';
    setState(() => _escuchando = true);
    await _voz.listen(
      onResult: _alReconocer,
      listenOptions: SpeechListenOptions(
        localeId: 'es_CL',
        partialResults: true,
        listenMode: ListenMode.dictation,
      ),
    );
  }

  void _alReconocer(SpeechRecognitionResult r) {
    final texto = '$_base${r.recognizedWords}';
    widget.controller.value = TextEditingValue(
      text: texto,
      selection: TextSelection.collapsed(offset: texto.length),
    );
  }

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: _escuchando ? 'Terminar de dictar' : 'Dictar con la voz',
      onPressed: widget.enabled ? _alternar : null,
      icon: Icon(
        _escuchando ? Icons.stop_circle_rounded : Icons.keyboard_voice_rounded,
        color: _escuchando ? AppColors.critical : AppColors.primary,
      ),
    );
  }
}
