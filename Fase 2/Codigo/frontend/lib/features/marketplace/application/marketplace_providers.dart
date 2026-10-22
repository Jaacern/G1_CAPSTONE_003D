import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/marketplace_repository.dart';
import '../domain/models.dart';

/// Filtros del listado de cuidadoras.
class CaregiverFilters {
  const CaregiverFilters({this.zone, this.specialty});
  final String? zone;
  final String? specialty;
}

/// Listado de cuidadoras (con filtros opcionales de zona/especialidad).
final caregiversProvider = FutureProvider.autoDispose
    .family<List<CaregiverProfileSummary>, CaregiverFilters>(
  (ref, filters) => ref.watch(marketplaceRepositoryProvider).listCaregivers(
        zone: filters.zone,
        specialty: filters.specialty,
      ),
);

/// Listado de productos/ayudas técnicas (categoría opcional).
final productsProvider =
    FutureProvider.autoDispose.family<List<MarketProduct>, String?>(
  (ref, category) =>
      ref.watch(marketplaceRepositoryProvider).listProducts(category: category),
);

/// Ofertas de trabajo para cuidadoras.
final jobsProvider = FutureProvider.autoDispose<List<JobOffer>>(
  (ref) => ref.watch(marketplaceRepositoryProvider).listJobs(),
);

/// Detalle de un perfil de cuidadora.
final caregiverDetailProvider = FutureProvider.autoDispose
    .family<CaregiverProfileDetail, String>(
  (ref, profileId) =>
      ref.watch(marketplaceRepositoryProvider).getCaregiver(profileId),
);
