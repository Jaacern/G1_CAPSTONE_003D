import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../patients/application/patients_providers.dart';
import '../data/documents_repository.dart';
import '../domain/models.dart';

/// Documentos del paciente indicado. Si se pasa `null`, usa el paciente
/// seleccionado en la sesión (selectedPatientProvider).
final documentsProvider = FutureProvider.autoDispose
    .family<List<PatientDocument>, String?>((ref, patientId) async {
  final id = patientId ?? ref.watch(selectedPatientProvider)?.patientId;
  if (id == null) return const [];
  return ref.watch(documentsRepositoryProvider).listDocuments(id);
});
