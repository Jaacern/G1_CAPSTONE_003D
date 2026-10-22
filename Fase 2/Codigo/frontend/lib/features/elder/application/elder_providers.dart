import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../auth/application/auth_controller.dart';
import '../data/elder_repository.dart';
import '../domain/models.dart';

/// Id del paciente para el adulto mayor: él mismo es el paciente, tomado de su
/// primera membresía. Devuelve null si aún no hay paciente asociado.
final elderPatientIdProvider = Provider<String?>((ref) {
  final user = ref.watch(currentUserProvider);
  final memberships = user?.memberships ?? const [];
  return memberships.isEmpty ? null : memberships.first.patientId;
});

/// Fotos familiares compartidas con el adulto mayor.
final photosProvider =
    FutureProvider.autoDispose<List<FamilyPhoto>>((ref) async {
  final patientId = ref.watch(elderPatientIdProvider);
  if (patientId == null) return const [];
  return ref.watch(elderRepositoryProvider).listPhotos(patientId);
});

/// Feed de contenido de entretenimiento ("Para ti"). Opcionalmente filtrable
/// por categoría (ContentType.apiValue).
final contentFeedProvider = FutureProvider.autoDispose
    .family<List<ContentItem>, String?>((ref, category) async {
  return ref.watch(elderRepositoryProvider).contentFeed(category: category);
});
