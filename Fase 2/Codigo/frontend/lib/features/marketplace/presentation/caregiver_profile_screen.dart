import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show SystemUiOverlayStyle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/config/app_config.dart';
import '../../../core/config/comunas.dart';
import '../../../core/config/idiomas.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/bloques.dart';
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
      // Sin barra de titulo: la cabecera de color ya dice de quien es el
      // perfil y trae su propio boton de volver, y una barra encima le
      // quitaria la mitad del alto a la cabecera.
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: Colors.white,
        systemOverlayStyle: SystemUiOverlayStyle.light,
      ),
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
            padding: const EdgeInsets.only(bottom: 32),
            children: [
              _Cabecera(caregiver: c),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
              if (c.bio.isNotEmpty) ...[
                const EncabezadoDeSeccion('Sobre mí'),
                Text(c.bio,
                    style: const TextStyle(color: AppColors.textPrimary)),
              ],
              // Lo que antes eran tres filas de icono y texto. De un vistazo
              // se compara mejor asi, que es para lo que se mira un perfil
              // al lado de otro.
              const EncabezadoDeSeccion('En números'),
              Row(
                children: [
                  Expanded(
                    child: TarjetaDeDato(
                      etiqueta: 'Experiencia',
                      valor: '${c.yearsExperience} años',
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TarjetaDeDato(
                      etiqueta: 'Reseñas',
                      valor: '${c.reviewsCount}',
                    ),
                  ),
                  if (c.tarifaLabel != null) ...[
                    const SizedBox(width: 10),
                    Expanded(
                      child: TarjetaDeDato(
                        etiqueta: 'Por hora',
                        valor: c.tarifaLabel!,
                      ),
                    ),
                  ],
                ],
              ),
              if (c.specialties.isNotEmpty) ...[
                const EncabezadoDeSeccion('Especialidades'),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final s in c.specialties)
                      Chip2(s, color: AgeColors.teal100),
                  ],
                ),
              ],
              if (c.languages.isNotEmpty) ...[
                const EncabezadoDeSeccion('Idiomas'),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final i in c.languages) Chip2(nombreIdioma(i)),
                  ],
                ),
              ],
              if (c.zones.isNotEmpty) ...[
                const EncabezadoDeSeccion('Dónde atiende'),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final z in c.zones) Chip2(nombreComuna(z)),
                  ],
                ),
              ],
              if (c.certifications.isNotEmpty) ...[
                const EncabezadoDeSeccion('Certificaciones'),
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
              EncabezadoDeSeccion('Reseñas (${c.reviewsCount})'),
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
      builder: (ctx) =>
          _ContactDialog(profileId: c.profileId, controller: controller),
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
/// Cabecera del perfil: bloque de color con la foto y, montada encima, la
/// tarjeta con el nombre y la calificacion.
///
/// El bloque va detras y la tarjeta con un margen superior menor que su alto,
/// asi que la tarjeta la tapa en parte. Sin desplazamientos negativos: el
/// Stack toma el alto de la tarjeta, que siempre es el hijo mas alto.
class _Cabecera extends StatelessWidget {
  const _Cabecera({required this.caregiver});
  final CaregiverProfileDetail caregiver;

  static const _altoDelBloque = 190.0;
  static const _montaje = 150.0;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Container(
          height: _altoDelBloque,
          decoration: const BoxDecoration(
            color: AgeColors.teal600,
            borderRadius: BorderRadius.vertical(
                bottom: Radius.circular(AgeRadius.xxl)),
          ),
          alignment: Alignment.center,
          padding: const EdgeInsets.only(top: 24),
          child: InitialsAvatar(
            name: caregiver.name,
            photoUrl: caregiver.photoUrl,
            radius: 44,
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, _montaje, 16, 0),
          child: AppCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(caregiver.name,
                    style: const TextStyle(
                        fontSize: 20, fontWeight: FontWeight.w800)),
                const SizedBox(height: 4),
                Text(caregiver.headline,
                    style: const TextStyle(
                        color: AppColors.textSecondary, fontSize: 14)),
                const SizedBox(height: 10),
                Row(
                  children: [
                    _RatingStars(rating: caregiver.rating),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        '${caregiver.rating.toStringAsFixed(1)} · '
                        '${caregiver.reviewsCount} reseñas',
                        style: const TextStyle(
                            fontSize: 13, color: AppColors.textSecondary),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
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

