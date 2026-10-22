import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/app_config.dart';
import '../../../core/speech/speech_service.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/common.dart';
import '../application/elder_providers.dart';
import '../domain/models.dart';

/// Feed "Para ti": tarjetas grandes de entretenimiento (chistes, recuerdos,
/// ejercicios suaves, consejos) con un botón "Escuchar" que lee el contenido
/// en voz alta.
class ElderContentScreen extends ConsumerWidget {
  const ElderContentScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Sin backend de contenido aún: mostrar "Próximamente" en modo real.
    if (!AppConfig.hasElderContent) {
      return Scaffold(
        appBar: AppBar(title: const Text('Para ti')),
        body: const ComingSoonView(
          icon: Icons.auto_awesome_rounded,
          title: 'Contenido para ti',
          subtitle: 'Pronto tendrás recuerdos, consejos y actividades aquí.',
        ),
      );
    }

    final feedAsync = ref.watch(contentFeedProvider(null));
    final speech = ref.read(speechServiceProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Para ti',
            style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800)),
        toolbarHeight: 72,
      ),
      body: feedAsync.when(
        loading: () => const LoadingView(),
        error: (e, _) => ErrorView(
          message: e is Exception ? e.toString() : 'No se pudo cargar el contenido.',
          onRetry: () => ref.invalidate(contentFeedProvider(null)),
        ),
        data: (items) {
          if (items.isEmpty) {
            return const EmptyView(
              icon: Icons.favorite_rounded,
              title: 'Nada por ahora',
              subtitle: 'Vuelve más tarde para ver contenido nuevo.',
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
            itemCount: items.length,
            separatorBuilder: (_, __) => const SizedBox(height: 20),
            itemBuilder: (context, i) =>
                _ContentCard(item: items[i], speech: speech),
          );
        },
      ),
    );
  }
}

class _ContentCard extends StatelessWidget {
  const _ContentCard({required this.item, required this.speech});

  final ContentItem item;
  final SpeechService speech;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (item.imageUrl != null && item.imageUrl!.isNotEmpty)
            ClipRRect(
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(16)),
              child: AspectRatio(
                aspectRatio: 16 / 9,
                child: Image.network(
                  item.imageUrl!,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => Container(
                    color: item.type.color.withOpacity(.08),
                  ),
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: item.type.color.withOpacity(.12),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Icon(item.type.icon,
                          size: 32, color: item.type.color),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      item.type.label,
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: item.type.color,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Text(
                  item.title,
                  style: const TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.w800,
                    color: AppColors.textPrimary,
                    height: 1.2,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  item.body,
                  style: const TextStyle(
                    fontSize: 22,
                    color: AppColors.textPrimary,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 18),
                SizedBox(
                  height: 68,
                  child: FilledButton.icon(
                    onPressed: () => speech.speak(item.spokenText),
                    style: FilledButton.styleFrom(
                      backgroundColor: item.type.color,
                      minimumSize: const Size.fromHeight(68),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(18)),
                    ),
                    icon: const Icon(Icons.volume_up_rounded, size: 32),
                    label: const Text(
                      'Escuchar',
                      style:
                          TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
