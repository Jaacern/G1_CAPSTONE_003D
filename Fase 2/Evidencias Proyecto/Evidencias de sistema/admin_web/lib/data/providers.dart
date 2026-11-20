import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'admin_repository.dart';
import 'models.dart';

/// Todos los planes (incluye borradores y archivados).
final plansProvider = FutureProvider.autoDispose<List<PlanItem>>(
  (ref) => ref.watch(adminRepositoryProvider).plans(),
);
