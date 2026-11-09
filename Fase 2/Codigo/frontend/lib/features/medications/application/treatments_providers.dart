import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../patients/application/patients_providers.dart';
import '../data/treatments_repository.dart';
import '../domain/treatment.dart';

/// Tratamiento vigente + historial del paciente seleccionado.
final treatmentsProvider =
    FutureProvider.autoDispose<TreatmentBundle>((ref) async {
  final patient = ref.watch(selectedPatientProvider);
  if (patient == null) return const TreatmentBundle();
  return ref
      .watch(treatmentsRepositoryProvider)
      .getTreatments(patient.patientId, history: true);
});
