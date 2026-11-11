import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../auth/application/auth_controller.dart';
import '../../medications/data/medications_repository.dart';
import '../../medications/domain/models.dart' as meds;
import '../data/elder_repository.dart';
import '../domain/models.dart';

/// Id del paciente para el adulto mayor: él mismo es el paciente, tomado de su
/// primera membresía. Devuelve null si aún no hay paciente asociado.
final elderPatientIdProvider = Provider<String?>((ref) {
  final user = ref.watch(currentUserProvider);
  final memberships = user?.memberships ?? const [];
  return memberships.isEmpty ? null : memberships.first.patientId;
});

/// Los remedios que el adulto mayor tiene que tomar hoy.
///
/// Su pantalla de inicio no tiene barra de pestanas, asi que sin esto la
/// persona que de hecho se toma las pastillas no tenia ninguna forma de
/// mirar que le toca: se enteraba solo cuando llegaba la notificacion, y si
/// la perdia no quedaba donde consultarlo.
///
/// Se usa elderPatientIdProvider y no el paciente seleccionado porque este
/// rol no tiene selector de paciente: el adulto mayor es siempre el mismo.
final dosisDeHoyProvider =
    FutureProvider.autoDispose<List<meds.Dose>>((ref) async {
  final patientId = ref.watch(elderPatientIdProvider);
  if (patientId == null) return const [];
  return ref
      .watch(medicationsRepositoryProvider)
      .listDoses(patientId, date: DateTime.now());
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

/// Cómo dijo sentirse hoy el adulto mayor (RF-38), o null si aún no responde.
final animoDeHoyProvider = FutureProvider.autoDispose<String?>((ref) async {
  final patientId = ref.watch(elderPatientIdProvider);
  if (patientId == null) return null;
  return ref.watch(elderRepositoryProvider).todayMood(patientId);
});
