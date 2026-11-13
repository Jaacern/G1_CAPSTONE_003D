import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/config/app_config.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/upload_service.dart';
import '../../../core/speech/speech_service.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/common.dart';
import '../application/elder_providers.dart';

/// Una melodia guardada con el Director Musical.
class Melodia {
  const Melodia({
    required this.id,
    required this.title,
    required this.durationSeconds,
    required this.audioUrl,
    required this.createdAt,
  });

  final String id;
  final String title;
  final int durationSeconds;
  final String audioUrl;
  final DateTime createdAt;

  factory Melodia.fromJson(Map<String, dynamic> json) => Melodia(
        id: json['id'].toString(),
        title: (json['title'] ?? 'Melodía') as String,
        durationSeconds: (json['duration_seconds'] ?? 0) as int,
        audioUrl: (json['audio_url'] ?? '') as String,
        createdAt: DateTime.parse(json['created_at'] as String).toLocal(),
      );

  /// "1:05" a partir de los segundos.
  String get duracion {
    final m = durationSeconds ~/ 60;
    final s = (durationSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}

/// Enlace para que alguien sin cuenta escuche una melodia (RF-67), por
/// ejemplo la nieta que la recibe por WhatsApp.
///
/// La API (POST /patients/{id}/music/{id}/share) devuelve la ruta sin el
/// servidor ("/api/v1/music/shared/<token>"); aqui se arma el enlace
/// completo para poder pegarlo en un mensaje.
class EnlaceDeEscucha {
  const EnlaceDeEscucha({
    required this.shareId,
    required this.url,
    required this.expiresAt,
  });

  final String shareId;

  /// Enlace completo, listo para compartir.
  final String url;

  /// Despues de esta fecha el enlace deja de funcionar.
  final DateTime expiresAt;

  /// [servidor] es la direccion de la API (AppConfig.apiBaseUrl).
  factory EnlaceDeEscucha.fromJson(Map<String, dynamic> json,
      {required String servidor}) {
    final ruta = (json['url'] ?? '') as String;
    final base = servidor.endsWith('/')
        ? servidor.substring(0, servidor.length - 1)
        : servidor;
    return EnlaceDeEscucha(
      shareId: json['share_id'].toString(),
      url: ruta.startsWith('http') ? ruta : '$base$ruta',
      expiresAt: DateTime.parse(json['expires_at'] as String).toLocal(),
    );
  }
}

/// Melodias del adulto mayor, la mas reciente primero
/// (GET /patients/{id}/music, RF-65).
final melodiasProvider =
    FutureProvider.autoDispose<List<Melodia>>((ref) async {
  final patientId = ref.watch(elderPatientIdProvider);
  if (patientId == null) return const [];
  final res = await ref
      .watch(apiClientProvider)
      .get<Map<String, dynamic>>('/patients/$patientId/music');
  return ((res['items'] ?? []) as List)
      .map((e) => Melodia.fromJson(e as Map<String, dynamic>))
      .toList();
});

/// Pide a la API un enlace de escucha para una melodia (RF-67). Cada vez
/// que se comparte se crea un enlace nuevo; vale 72 horas.
Future<EnlaceDeEscucha> compartirMelodia(
    ApiClient api, String patientId, String melodiaId) async {
  final res = await api.post<Map<String, dynamic>>(
      '/patients/$patientId/music/$melodiaId/share');
  return EnlaceDeEscucha.fromJson(res, servidor: AppConfig.apiBaseUrl);
}

/// "Mis melodías": las creaciones guardadas, para volver a escucharlas.
///
/// Pensada como el resto de la vista del adulto mayor: botones grandes y una
/// sola accion por melodia, sin teclado (RNF-19, RNF-20). Tocar el boton de
/// una melodia la hace sonar; tocarlo de nuevo, o tocar otra, la detiene.
class ElderMelodiesScreen extends ConsumerStatefulWidget {
  const ElderMelodiesScreen({super.key});

  @override
  ConsumerState<ElderMelodiesScreen> createState() =>
      _ElderMelodiesScreenState();
}

class _ElderMelodiesScreenState extends ConsumerState<ElderMelodiesScreen> {
  /// Id de la melodia que esta sonando, o null.
  String? _sonando;
  StreamSubscription<void>? _fin;
  late final SpeechService _speech;

  @override
  void initState() {
    super.initState();
    _speech = ref.read(speechServiceProvider);
    // Cuando el audio termina solo, el boton vuelve a "escuchar".
    _fin = _speech.onPlaybackComplete.listen((_) {
      if (mounted) setState(() => _sonando = null);
    });
  }

  @override
  void dispose() {
    _fin?.cancel();
    // Salir de la pantalla no deja la musica sonando de fondo.
    _speech.stopPlayback();
    super.dispose();
  }

  Future<void> _alternar(Melodia m) async {
    if (_sonando == m.id) {
      await _speech.stopPlayback();
      setState(() => _sonando = null);
      return;
    }
    setState(() => _sonando = m.id);
    try {
      // El audio vive detras de la API: hay que pedir el enlace firmado
      // antes de pasarselo al reproductor (igual que las notas de voz).
      final url = await ref.read(uploadServiceProvider).signedUrl(m.audioUrl);
      await _speech.playUrl(url);
    } catch (_) {
      if (!mounted) return;
      setState(() => _sonando = null);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No se pudo reproducir la melodía.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final melodias = ref.watch(melodiasProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Mis melodías'),
        toolbarHeight: 72,
        titleTextStyle: AgeText.h1.copyWith(
          fontFamily: 'Nunito Sans',
          color: scheme.onSurface,
        ),
      ),
      body: SafeArea(
        child: melodias.when(
          loading: () => const LoadingView(),
          error: (e, _) => ErrorView(
            message: 'No se pudieron cargar tus melodías.',
            onRetry: () => ref.invalidate(melodiasProvider),
          ),
          data: (lista) => lista.isEmpty
              ? const EmptyView(
                  icon: Icons.music_note_rounded,
                  title: 'Todavía no tienes melodías',
                  subtitle:
                      'Graba una en el Director musical y aparecerá aquí.',
                )
              : RefreshIndicator(
                  onRefresh: () async => ref.invalidate(melodiasProvider),
                  child: ListView.separated(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                    itemCount: lista.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 14),
                    itemBuilder: (_, i) => _MelodiaCard(
                      melodia: lista[i],
                      sonando: _sonando == lista[i].id,
                      onTap: () => _alternar(lista[i]),
                    ),
                  ),
                ),
        ),
      ),
    );
  }
}

class _MelodiaCard extends StatelessWidget {
  const _MelodiaCard({
    required this.melodia,
    required this.sonando,
    required this.onTap,
  });

  final Melodia melodia;
  final bool sonando;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fecha = DateFormat("d 'de' MMMM, HH:mm", 'es').format(melodia.createdAt);
    return Semantics(
      button: true,
      label: sonando
          ? 'Detener ${melodia.title}'
          : 'Escuchar ${melodia.title}',
      child: Material(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(20),
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                // Boton grande: 64 x 64, muy por encima del minimo de 48.
                Container(
                  width: 64,
                  height: 64,
                  decoration: BoxDecoration(
                    color: sonando ? AgeColors.coral600 : AgeColors.teal600,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    sonando ? Icons.stop_rounded : Icons.play_arrow_rounded,
                    color: Colors.white,
                    size: 40,
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        melodia.title,
                        style: AgeText.h3.copyWith(fontFamily: 'Nunito Sans'),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        sonando ? 'Sonando…' : '$fecha · ${melodia.duracion}',
                        style: AgeText.bodyL.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
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
