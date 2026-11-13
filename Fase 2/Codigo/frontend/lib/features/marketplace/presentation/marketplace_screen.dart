import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/config/app_config.dart';
import '../../../core/config/comunas.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/common.dart';
import '../../auth/application/auth_controller.dart';
import '../../auth/domain/models.dart';
import '../application/marketplace_providers.dart';
import '../domain/models.dart';

/// Marketplace de AgeCare: búsqueda de cuidadoras y, para la cuidadora,
/// ofertas de trabajo. La venta de productos se sacó por decisión del equipo.
class MarketplaceScreen extends ConsumerWidget {
  const MarketplaceScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // El módulo ya existe en el backend; la bandera queda por si se mueve,
    // para no llamar a un endpoint que de pronto deja de estar.
    if (!AppConfig.hasMarketplace) {
      return Scaffold(
        appBar: AppBar(title: const Text('Marketplace')),
        body: const ComingSoonView(
          icon: Icons.storefront_rounded,
          title: 'Marketplace de cuidado',
          subtitle: 'Aquí podrás encontrar cuidadoras para tu familiar. '
              'Esta función estará disponible en una próxima versión.',
        ),
      );
    }

    final user = ref.watch(currentUserProvider);
    final isCaregiver = user?.primaryRole == RoleType.caregiver;

    // Sin pestañas cuando hay una sola sección: el familiar ve directamente
    // la búsqueda de cuidadoras.
    if (!isCaregiver) {
      return Scaffold(
        appBar: AppBar(title: const Text('Marketplace')),
        body: const _CaregiversTab(),
      );
    }

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Marketplace'),
          bottom: const TabBar(
            isScrollable: false,
            labelColor: AppColors.primary,
            unselectedLabelColor: AppColors.textSecondary,
            indicatorColor: AppColors.primary,
            tabs: [
              Tab(text: 'Cuidadoras'),
              Tab(text: 'Trabajos'),
            ],
          ),
        ),
        body: const TabBarView(
          children: [
            _CaregiversTab(),
            _JobsTab(),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Cuidadoras
// ---------------------------------------------------------------------------
class _CaregiversTab extends ConsumerStatefulWidget {
  const _CaregiversTab();

  @override
  ConsumerState<_CaregiversTab> createState() => _CaregiversTabState();
}

class _CaregiversTabState extends ConsumerState<_CaregiversTab> {
  // El backend filtra por código territorial (zone=08101); escribir el nombre
  // de la comuna nunca coincidía con nada.
  String? _zone;
  final _specialtyCtrl = TextEditingController();
  CaregiverFilters _filters = const CaregiverFilters();

  @override
  void dispose() {
    _specialtyCtrl.dispose();
    super.dispose();
  }

  void _apply() {
    setState(() {
      _filters = CaregiverFilters(
        zone: _zone,
        specialty: _specialtyCtrl.text.trim().isEmpty
            ? null
            : _specialtyCtrl.text.trim(),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final caregivers = ref.watch(caregiversProvider(_filters));
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: DropdownButtonFormField<String>(
                  initialValue: _zone,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Comuna',
                    prefixIcon: Icon(Icons.location_on_outlined),
                  ),
                  hint: const Text('Todas las comunas'),
                  items: [
                    const DropdownMenuItem<String>(
                      child: Text('Todas las comunas'),
                    ),
                    for (final (codigo, nombre) in comunasConocidas)
                      DropdownMenuItem(value: codigo, child: Text(nombre)),
                  ],
                  onChanged: (codigo) => setState(() => _zone = codigo),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: _specialtyCtrl,
                  maxLength: 40,
                  onSubmitted: (_) => _apply(),
                  decoration: const InputDecoration(
                    labelText: 'Especialidad',
                    prefixIcon: Icon(Icons.medical_services_outlined),
                    counterText: '',
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                onPressed: _apply,
                icon: const Icon(Icons.search_rounded),
              ),
            ],
          ),
        ),
        Expanded(
          child: caregivers.when(
            loading: () => const LoadingView(),
            error: (e, _) => ErrorView(
              message: e.toString(),
              onRetry: () => ref.invalidate(caregiversProvider(_filters)),
            ),
            data: (list) => list.isEmpty
                ? const EmptyView(
                    icon: Icons.person_search_rounded,
                    title: 'Sin resultados',
                    subtitle:
                        'No encontramos cuidadoras con esos filtros. Prueba con otros.',
                  )
                : RefreshIndicator(
                    onRefresh: () async =>
                        ref.invalidate(caregiversProvider(_filters)),
                    child: ListView.separated(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                      itemCount: list.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 12),
                      itemBuilder: (_, i) => _CaregiverCard(caregiver: list[i]),
                    ),
                  ),
          ),
        ),
      ],
    );
  }
}

class _CaregiverCard extends StatelessWidget {
  const _CaregiverCard({required this.caregiver});

  final CaregiverProfileSummary caregiver;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      onTap: () =>
          context.push('/marketplace/caregivers/${caregiver.profileId}'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              InitialsAvatar(
                name: caregiver.name,
                photoUrl: caregiver.photoUrl,
                radius: 28,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(caregiver.name,
                        style: const TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 2),
                    Text(caregiver.headline,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: AppColors.textSecondary, fontSize: 13)),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              // La nota va al lado del nombre y no abajo: es con lo que se
              // compara una cuidadora con otra al recorrer la lista, y ahi
              // arriba se lee de un vistazo en todas las filas a la vez.
              _NotaDestacada(
                  rating: caregiver.rating, resenas: caregiver.reviewsCount),
            ],
          ),
          const SizedBox(height: 10),
          // La tarifa baja de línea en vez de desbordar la tarjeta si el
          // teléfono es chico o el texto está grande.
          Wrap(
            spacing: 6,
            runSpacing: 6,
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (caregiver.zones.isNotEmpty)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.location_on_rounded,
                        size: 15, color: AppColors.textSecondary),
                    const SizedBox(width: 4),
                    Text(
                      nombreComuna(caregiver.zones.first) +
                          (caregiver.zones.length > 1
                              ? ' +${caregiver.zones.length - 1}'
                              : ''),
                      style: const TextStyle(
                          fontSize: 13, color: AppColors.textSecondary),
                    ),
                  ],
                ),
              if (caregiver.tarifaLabel != null)
                Text(
                  '${caregiver.tarifaLabel!}/h',
                  style: const TextStyle(
                      fontWeight: FontWeight.w800, color: AppColors.primary),
                ),
            ],
          ),
          if (caregiver.specialties.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final s in caregiver.specialties.take(3)) _Pill(label: s),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Trabajos (solo cuidadora)
// ---------------------------------------------------------------------------
class _JobsTab extends ConsumerWidget {
  const _JobsTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final jobs = ref.watch(jobsProvider);
    return jobs.when(
      loading: () => const LoadingView(),
      error: (e, _) => ErrorView(
        message: e.toString(),
        onRetry: () => ref.invalidate(jobsProvider),
      ),
      data: (list) => list.isEmpty
          ? const EmptyView(
              icon: Icons.work_outline_rounded,
              title: 'Sin ofertas',
              subtitle: 'Por ahora no hay ofertas de trabajo disponibles.',
            )
          : RefreshIndicator(
              onRefresh: () async => ref.invalidate(jobsProvider),
              child: ListView.separated(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                itemCount: list.length,
                separatorBuilder: (_, __) => const SizedBox(height: 12),
                itemBuilder: (_, i) => _JobCard(job: list[i]),
              ),
            ),
    );
  }
}

class _JobCard extends StatelessWidget {
  const _JobCard({required this.job});

  final JobOffer job;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(job.title,
              style:
                  const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          Row(
            children: [
              const Icon(Icons.location_on_outlined,
                  size: 15, color: AppColors.textSecondary),
              const SizedBox(width: 4),
              Expanded(
                child: Text(nombreComuna(job.zone),
                    style: const TextStyle(
                        fontSize: 13, color: AppColors.textSecondary)),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              const Icon(Icons.payments_outlined,
                  size: 15, color: AppColors.secondary),
              const SizedBox(width: 4),
              Text(job.pay,
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w700)),
            ],
          ),
          const SizedBox(height: 8),
          Text(job.description,
              style: const TextStyle(color: AppColors.textSecondary)),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Widgets auxiliares
// ---------------------------------------------------------------------------
/// La nota, con su estrella, como etiqueta compacta.
class _NotaDestacada extends StatelessWidget {
  const _NotaDestacada({required this.rating, required this.resenas});

  final double rating;
  final int resenas;

  @override
  Widget build(BuildContext context) {
    // Sin resenas no hay nota que mostrar, y un 0,0 se lee como una mala
    // calificacion en vez de como "todavia nadie la califico".
    if (resenas == 0) {
      return const Text('Sin resenas',
          style: TextStyle(fontSize: 12, color: AppColors.textSecondary));
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: AgeColors.gold100,
        borderRadius: BorderRadius.circular(AgeRadius.full),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.star_rounded, size: 16, color: AgeColors.gold700),
          const SizedBox(width: 4),
          Text(rating.toStringAsFixed(1),
              style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  color: AgeColors.gold700)),
        ],
      ),
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
        color: AppColors.primary.withValues(alpha: .08),
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
