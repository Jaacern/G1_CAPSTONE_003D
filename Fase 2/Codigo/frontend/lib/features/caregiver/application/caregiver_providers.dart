import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../patients/application/patients_providers.dart';
import '../data/caregiver_repository.dart';
import '../domain/models.dart';

/// Resumen del día / turno de la cuidadora.
final caregiverTodayProvider = FutureProvider<CaregiverToday>((ref) {
  return ref.watch(caregiverRepositoryProvider).getToday();
});

/// Tareas del paciente seleccionado.
final patientTasksProvider =
    FutureProvider.autoDispose<List<CareTask>>((ref) async {
  final patient = ref.watch(selectedPatientProvider);
  if (patient == null) return const [];
  return ref.watch(caregiverRepositoryProvider).listTasks(patient.patientId);
});

/// Observaciones del paciente seleccionado.
final observationsProvider =
    FutureProvider.autoDispose<List<Observation>>((ref) async {
  final patient = ref.watch(selectedPatientProvider);
  if (patient == null) return const [];
  return ref
      .watch(caregiverRepositoryProvider)
      .listObservations(patient.patientId);
});

/// Notas de relevo del paciente seleccionado.
final handoverNotesProvider =
    FutureProvider.autoDispose<List<HandoverNote>>((ref) async {
  final patient = ref.watch(selectedPatientProvider);
  if (patient == null) return const [];
  return ref
      .watch(caregiverRepositoryProvider)
      .listHandoverNotes(patient.patientId);
});

/// Plan freemium de la cuidadora.
final caregiverPlanProvider = FutureProvider<CaregiverPlan>((ref) {
  return ref.watch(caregiverRepositoryProvider).getPlan();
});

/// Reporte de desempeño de la cuidadora.
final caregiverReportProvider = FutureProvider<CaregiverReport>((ref) {
  return ref.watch(caregiverRepositoryProvider).getReport();
});

/// Perfil profesional de la cuidadora.
final caregiverProfileProvider = FutureProvider<CaregiverProfile>((ref) {
  return ref.watch(caregiverRepositoryProvider).getProfile();
});
