import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/speech/speech_service.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/common.dart';
import '../application/elder_providers.dart';
import '../domain/models.dart';

/// "Para ti": contenido de entretenimiento para leer o escuchar (RF-62).
///
/// Tarjetas grandes, una por fila, con un botón "Escuchar" del ancho de la
/// tarjeta (RF-63). El orden lo decide el servidor: alterna los tipos para
/// que la primera pantalla traiga un chiste, un recuerdo y un consejo, y no
/// diez consejos seguidos.
class ElderContentScreen extends ConsumerWidget {
  const ElderContentScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final feed = ref.watch(contentFeedProvider(null));
    final speech = ref.read(speechServiceProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Para ti',
            style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800)),
        toolbarHeight: 72,
      ),
      body: feed.when(
        loading: () => const LoadingView(),
        error: (_, __) => ErrorView(
          message: 'No se pudo cargar. Revisa la conexión.',
          onRetry: () => ref.invalidate(contentFeedProvider(null)),
        ),
        data: (items) {
          if (items.isEmpty) {
            return const EmptyView(
              icon: Icons.auto_stories_rounded,
              title: 'Todavía no hay nada nuevo',
              subtitle: 'Pronto habrá chistes, recuerdos y consejos para ti.',
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
            itemCount: items.length,
            separatorBuilder: (_, __) => const SizedBox(height: 20),
            itemBuilder: (_, i) => _Tarjeta(item: items[i], speech: speech),
          );
        },
      ),
    );
  }
}

class _Tarjeta extends StatelessWidget {
  const _Tarjeta({required this.item, required this.speech});

  final ContentItem item;
  final SpeechService speech;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(AgeRadius.xxl),
        border: Border.all(color: scheme.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(item.type.icon, size: 30, color: item.type.color),
              const SizedBox(width: 10),
              Text(item.type.label,
                  style: AgeText.bodyL.copyWith(
                      color: item.type.color, fontWeight: FontWeight.w700)),
            ],
          ),
          const SizedBox(height: 10),
          Text(item.title,
              style: AgeText.h2.copyWith(
                  fontFamily: 'Nunito Sans', color: scheme.onSurface)),
          const SizedBox(height: 8),
          Text(item.body,
              style: AgeText.bodyL.copyWith(color: scheme.onSurface)),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
              ),
              onPressed: () => speech.speak('${item.title}. ${item.body}'),
              icon: const Icon(Icons.volume_up_rounded, size: 28),
              label: const Text('Escuchar', style: AgeText.bodyL),
            ),
          ),
        ],
      ),
    );
  }
}
