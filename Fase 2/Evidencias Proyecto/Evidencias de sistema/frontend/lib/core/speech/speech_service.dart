import 'package:audioplayers/audioplayers.dart';
import 'package:cross_file/cross_file.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:record/record.dart';

import '../network/api_client.dart';
import '../network/upload_service.dart';
import 'grabacion.dart';

/// Servicio de voz: grabación de notas, transcripción (STT) y lectura (TTS).
///
/// - STT: POST /stt  { audio_url } -> { text }   (Azure AI Speech en backend)
/// - TTS: POST /tts  { text, voice } -> { audio_url }
///
/// Pensado para la vista del adulto mayor (chat con voz) y notas de voz en el
/// chat familiar-cuidadora.
class SpeechService {
  SpeechService(this._api, this._uploads);

  final ApiClient _api;
  final UploadService _uploads;
  final AudioRecorder _recorder = AudioRecorder();
  final AudioPlayer _player = AudioPlayer();

  FormatoGrabacion? _formato;

  Future<bool> get hasPermission => _recorder.hasPermission();

  /// Comienza a grabar una nota de voz.
  ///
  /// Levanta [SinFormatoSoportado] si la plataforma no puede grabar en
  /// ninguno de los formatos que el servidor acepta.
  Future<void> startRecording() async {
    if (!await _recorder.hasPermission()) {
      throw StateError('Permiso de micrófono no concedido.');
    }
    final formato = await formatoDeGrabacion(_recorder);
    _formato = formato;
    await _recorder.start(
      RecordConfig(encoder: formato.encoder),
      path: await rutaDeGrabacion('voice', formato.extension),
    );
  }

  /// Detiene la grabación y devuelve el audio resultante.
  ///
  /// Va con nombre y tipo puestos a mano porque en el navegador la ruta que
  /// devuelve el grabador es un blob sin extension, y el servidor decide si
  /// acepta el archivo justamente por su tipo.
  Future<XFile?> stopRecording() async {
    final path = await _recorder.stop();
    if (path == null) return null;
    final f = _formato;
    return XFile(
      path,
      name: f == null ? 'nota_de_voz' : 'nota_de_voz.${f.extension}',
      mimeType: f?.mime,
    );
  }

  /// Sube el audio y devuelve su URL (para adjuntar a un mensaje).
  Future<String> uploadVoiceNote(XFile audio,
      {required String patientId}) async {
    final uploaded = await _uploads
        .uploadFile(audio, kind: 'audio', patientId: patientId);
    return uploaded.fileUrl;
  }

  /// Transcribe un audio ya subido (STT).
  Future<String> transcribe(String audioUrl) async {
    final res = await _api.post<Map<String, dynamic>>('/stt',
        data: {'audio_url': audioUrl});
    return (res['text'] ?? '') as String;
  }

  /// Graba, sube y transcribe en un solo paso.
  Future<({String text, String audioUrl})> recordAndTranscribe(XFile audio,
      {required String patientId}) async {
    final url = await uploadVoiceNote(audio, patientId: patientId);
    final text = await transcribe(url);
    return (text: text, audioUrl: url);
  }

  /// Convierte texto a voz y lo reproduce (TTS) — útil para el adulto mayor.
  Future<void> speak(String text, {String voice = 'es-MX-DaliaNeural'}) async {
    final res = await _api.post<Map<String, dynamic>>('/tts',
        data: {'text': text, 'voice': voice});
    final audioUrl = res['audio_url'] as String;
    await _player.play(UrlSource(audioUrl));
  }

  Future<void> playUrl(String url) => _player.play(UrlSource(url));
  Future<void> stopPlayback() => _player.stop();

  /// Avisa cada vez que un audio termina de sonar solo (no al detenerlo).
  /// Sirve para que un boton de "escuchar" vuelva a su estado.
  Stream<void> get onPlaybackComplete => _player.onPlayerComplete;

  Future<void> dispose() async {
    await _recorder.dispose();
    await _player.dispose();
  }
}

final speechServiceProvider = Provider<SpeechService>((ref) {
  final s = SpeechService(
    ref.watch(apiClientProvider),
    ref.watch(uploadServiceProvider),
  );
  ref.onDispose(s.dispose);
  return s;
});
