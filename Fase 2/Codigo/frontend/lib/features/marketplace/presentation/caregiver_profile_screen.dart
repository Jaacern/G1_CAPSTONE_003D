import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/config/app_config.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/common.dart';
import '../application/marketplace_providers.dart';
import '../data/marketplace_repository.dart';
import '../domain/models.dart';

/// Detalle de una cuidadora del marketplace: bio, especialidades, reseñas y
/// acciones de contacto y valoración.
class CaregiverProfileScreen extends ConsumerWidget {
  const CaregiverProfileScreen({super.key, required this.profileId});

  final String profileId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!AppConfig.hasMarketplace) {
      return Scaffold(
        appBar: AppBar(title: const Text('Perfil')),
        body: const ComingSoonView(
          icon: Icons.badge_rounded,
          title: 'Perfil de cuidadora',
          subtitle: 'Esta función estará disponible en una próxima versión.',
        ),
      );
    }
    final detail = ref.watch(caregiverDetailProvider(profileId));
    return Scaffold(
      appBar: AppBar(title: const Text('Perfil')),
      body: detail.when(
        loading: () => const LoadingView(),
        error: (e, _) => ErrorView(
          message: e.toString(),
          onRetry: () => ref.invalidate(caregiverDetailProvider(profileId)),
        ),
        data: (c) => RefreshIndicator(
          onRefresh: () async =>
              ref.invalidate(caregiverDetailProvider(profileId)),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
            children: [
              _Header(caregiver: c),
              const SizedBox(height: 16),
              if (c.bio.isNotEmpty) ...[
                _SectionTitle('Sobre mí'),
                const SizedBox(height: 6),
                Text(c.bio,
                    style: const TextStyle(color: AppColors.textPrimary)),
                const SizedBox(height: 16),
              ],
              _InfoRow(
                icon: Icons.workspace_premium_outlined,
                label: '${c.yearsExperience} años de experiencia',
              ),
              if (c.zones.isNotEmpty)
                _InfoRow(
                  icon: Icons.location_on_outlined,
                  label: 'Zonas: ${c.zones.join(', ')}',
                ),
              if (c.languages.isNotEmpty)
                _InfoRow(
                  icon: Icons.translate_rounded,
                  label: 'Idiomas: ${c.languages.join(', ')}',
                ),
              if (c.pricePerHour != null)
                _InfoRow(
                  icon: Icons.payments_outlined,
                  label:
                      'Tarifa: \$${c.pricePerHour!.toStringAsFixed(0)} por hora',
                ),
              const SizedBox(height: 16),
              if (c.specialties.isNotEmpty) ...[
                _SectionTitle('Especialidades'),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final s in c.specialties) _Pill(label: s),
                  ],
                ),
                const SizedBox(height: 16),
              ],
              if (c.certifications.isNotEmpty) ...[
                _SectionTitle('Certificaciones'),
                const SizedBox(height: 8),
                for (final cert in c.certifications)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Row(
                      children: [
                        const Icon(Icons.verified_outlined,
                            size: 18, color: AppColors.secondary),
                        const SizedBox(width: 8),
                        Expanded(child: Text(cert)),
                      ],
                    ),
                  ),
                const SizedBox(height: 16),
              ],
              _SectionTitle('Reseñas (${c.reviewsCount})'),
              const SizedBox(height: 8),
              if (c.reviews.isEmpty)
                const Text('Aún no hay reseñas.',
                    style: TextStyle(color: AppColors.textSecondary))
              else
                for (final r in c.reviews)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: _ReviewCard(review: r),
                  ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: () => _showContactDialog(context, ref, c),
                      icon: const Icon(Icons.chat_bubble_outline_rounded),
                      label: const Text('Contactar'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => _showReviewDialog(context, ref, c),
                      icon: const Icon(Icons.rate_review_outlined),
                      label: const Text('Dejar reseña'),
                      style: OutlinedButton.styleFrom(
                          minimumSize: const Size.fromHeight(52)),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showContactDialog(
      BuildContext context, WidgetRef ref, CaregiverProfileDetail c) async {
    final controller = TextEditingController(
        text: 'Hola ${c.name}, me gustaría saber tu disponibilidad.');
    await showDialog<void>(
      context: context,
      builder: (ctx) => _ContactDialog(profileId: c.profileId, controller: controller),
    );
    controller.dispose();
  }

  Future<void> _showReviewDialog(
      BuildContext context, WidgetRef ref, CaregiverProfileDetail c) async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => _ReviewDialog(profileId: c.profileId),
    );
  }
}

// ---------------------------------------------------------------------------
class _Header extends StatelessWidget {
  const _Header({required this.caregiver});
  final CaregiverProfileDetail caregiver;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      child: Row(
        children: [
          InitialsAvatar(
            name: caregiver.name,
            photoUrl: caregiver.photoUrl,
            radius: 34,
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(caregiver.name,
                    style: const TextStyle(
                        fontSize: 18, fontWeight: FontWeight.w800)),
                const SizedBox(height: 4),
                Text(caregiver.headline,
                    style: const TextStyle(
                        color: AppColors.textSecondary, fontSize: 13)),
                const SizedBox(height: 8),
                Row(
                  children: [
                    _RatingStars(rating: caregiver.rating),
                    const SizedBox(width: 6),
                    Text(
                      '${caregiver.rating.toStringAsFixed(1)} (${caregiver.reviewsCount})',
                      style: const TextStyle(
                          fontSize: 13, color: AppColors.textSecondary),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ReviewCard extends StatelessWidget {
  const _ReviewCard({required this.review});
  final Review review;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(review.authorName,
                    style: const TextStyle(fontWeight: FontWeight.w700)),
              ),
              _RatingStars(rating: review.rating.toDouble(), size: 14),
            ],
          ),
          const SizedBox(height: 4),
          Text(DateFormat('d MMM yyyy', 'es').format(review.createdAt),
              style: const TextStyle(
                  fontSize: 12, color: AppColors.textSecondary)),
          const SizedBox(height: 6),
          Text(review.comment),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Diálogos
// ---------------------------------------------------------------------------
class _ContactDialog extends ConsumerStatefulWidget {
  const _ContactDialog({required this.profileId, required this.controller});
  final String profileId;
  final TextEditingController controller;

  @override
  ConsumerState<_ContactDialog> createState() => _ContactDialogState();
}

class _ContactDialogState extends ConsumerState<_ContactDialog> {
  bool _busy = false;

  Future<void> _send() async {
    final message = widget.controller.text.trim();
    if (message.isEmpty) return;
    setState(() => _busy = true);
    try {
      await ref
          .read(marketplaceRepositoryProvider)
          .contact(widget.profileId, message);
      if (mounted) {
        Navigator.of(context).pop();
        showAppSnackBar(context, 'Mensaje enviado a la cuidadora.');
      }
    } catch (e) {
      if (mounted) showAppSnackBar(context, e.toString(), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Contactar'),
      content: TextField(
        controller: widget.controller,
        maxLines: 4,
        decoration: const InputDecoration(labelText: 'Mensaje'),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: _busy ? null : _send,
          child: _busy
              ? const SizedBox(
                  height: 18,
                  width: 18,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white))
              : const Text('Enviar'),
        ),
      ],
    );
  }
}

class _ReviewDialog extends ConsumerStatefulWidget {
  const _ReviewDialog({required this.profileId});
  final String profileId;

  @override
  ConsumerState<_ReviewDialog> createState() => _ReviewDialogState();
}

class _ReviewDialogState extends ConsumerState<_ReviewDialog> {
  int _rating = 5;
  final _commentCtrl = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _commentCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() => _busy = true);
    try {
      await ref.read(marketplaceRepositoryProvider).addReview(
            widget.profileId,
            rating: _rating,
            comment: _commentCtrl.text.trim(),
          );
      ref.invalidate(caregiverDetailProvider(widget.profileId));
      if (mounted) {
        Navigator.of(context).pop();
        showAppSnackBar(context, 'Gracias por tu reseña.');
      }
    } catch (e) {
      if (mounted) showAppSnackBar(context, e.toString(), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Dejar reseña'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (var i = 1; i <= 5; i++)
                IconButton(
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  onPressed: () => setState(() => _rating = i),
                  icon: Icon(
                    i <= _rating
                        ? Icons.star_rounded
                        : Icons.star_border_rounded,
                    color: AppColors.statusWarning,
                    size: 34,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _commentCtrl,
            maxLines: 3,
            decoration: const InputDecoration(labelText: 'Comentario'),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: _busy ? null : _submit,
          child: _busy
              ? const SizedBox(
                  height: 18,
                  width: 18,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white))
              : const Text('Publicar'),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Auxiliares
// ---------------------------------------------------------------------------
class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);
  final String text;

  @override
  Widget build(BuildContext context) =>
      Text(text, style: Theme.of(context).textTheme.titleMedium);
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.icon, required this.label});
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: AppColors.primary),
          const SizedBox(width: 8),
          Expanded(child: Text(label)),
        ],
      ),
    );
  }
}

class _RatingStars extends StatelessWidget {
  const _RatingStars({required this.rating, this.size = 16});
  final double rating;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 1; i <= 5; i++)
          Icon(
            i <= rating.round()
                ? Icons.star_rounded
                : Icons.star_border_rounded,
            size: size,
            color: AppColors.statusWarning,
          ),
      ],
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: AppColors.primary.withOpacity(.08),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(label,
          style: const TextStyle(
              fontSize: 12,
              color: AppColors.primaryDark,
              fontWeight: FontWeight.w600)),
    );
  }
}
