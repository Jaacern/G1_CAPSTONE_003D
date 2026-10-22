import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/patients_repository.dart';
import '../domain/models.dart';

/// Lista de pacientes del usuario (tarjetas con semáforo).
final myPatientsProvider = FutureProvider<List<PatientCard>>((ref) {
  return ref.watch(patientsRepositoryProvider).listMyPatients();
});

/// Paciente seleccionado (persistente en la sesión de la app).
/// null hasta que carga la lista; después, el primero por defecto.
class SelectedPatientController extends Notifier<PatientCard?> {
  @override
  PatientCard? build() {
    // Auto-selección del primer paciente cuando la lista carga.
    ref.listen(myPatientsProvider, (_, next) {
      next.whenData((patients) {
        if (state == null && patients.isNotEmpty) {
          state = patients.first;
          return;
        }
        if (state == null) return;
        final idx = patients.indexWhere((p) => p.patientId == state!.patientId);
        if (idx < 0) {
          // El seleccionado ya no existe (p. ej. lo quitaron): re-selecciona.
          state = patients.isNotEmpty ? patients.first : null;
        } else {
          // Mismo paciente, datos frescos (semáforo, alertas) tras un refresh.
          state = patients[idx];
        }
      });
    });
    return null;
  }

  void select(PatientCard patient) => state = patient;
}

final selectedPatientProvider =
    NotifierProvider<SelectedPatientController, PatientCard?>(
        SelectedPatientController.new);

/// Detalle del paciente seleccionado.
final selectedPatientDetailProvider = FutureProvider<Patient?>((ref) async {
  final selected = ref.watch(selectedPatientProvider);
  if (selected == null) return null;
  return ref.watch(patientsRepositoryProvider).getPatient(selected.patientId);
});
