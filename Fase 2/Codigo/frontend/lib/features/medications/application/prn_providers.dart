import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/prn_repository.dart';
import '../domain/prn.dart';

/// SOS vigentes de un paciente con su estado (último uso, lo dado en 24 h).
final prnItemsProvider = FutureProvider.autoDispose
    .family<List<PrnItem>, String>((ref, patientId) {
  return ref.watch(prnRepositoryProvider).listPrn(patientId);
});

/// Usos SOS de los últimos días, del más reciente al más antiguo.
final prnUsesProvider = FutureProvider.autoDispose
    .family<List<PrnUse>, String>((ref, patientId) {
  return ref.watch(prnRepositoryProvider).listUses(patientId);
});
