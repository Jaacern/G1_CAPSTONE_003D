import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../patients/application/patients_providers.dart';
import '../data/medications_repository.dart';
import '../domain/models.dart';

/// Medicamentos activos del paciente seleccionado.
final medicationsProvider =
    FutureProvider.autoDispose<List<Medication>>((ref) async {
  final patient = ref.watch(selectedPatientProvider);
  if (patient == null) return const [];
  return ref.watch(medicationsRepositoryProvider).listMedications(patient.patientId);
});

/// Dosis de hoy del paciente seleccionado.
final todayDosesProvider = FutureProvider.autoDispose<List<Dose>>((ref) async {
  final patient = ref.watch(selectedPatientProvider);
  if (patient == null) return const [];
  return ref
      .watch(medicationsRepositoryProvider)
      .listDoses(patient.patientId, date: DateTime.now());
});

/// Adherencia (últimos 7 días) del paciente seleccionado.
final adherenceProvider = FutureProvider.autoDispose<Adherence?>((ref) async {
  final patient = ref.watch(selectedPatientProvider);
  if (patient == null) return null;
  final to = DateTime.now();
  return ref.watch(medicationsRepositoryProvider).adherence(
        patient.patientId,
        from: to.subtract(const Duration(days: 6)),
        to: to,
      );
});
