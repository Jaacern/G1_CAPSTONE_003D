import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:agecare_app/features/auth/domain/models.dart';
import 'package:agecare_app/features/patients/data/patients_repository.dart';
import 'package:agecare_app/features/patients/domain/models.dart';
import 'package:agecare_app/features/patients/presentation/create_patient_screen.dart';

/// Repositorio que sólo cuenta los altos que le piden.
class _RepoEspia implements PatientsRepository {

  // Los metodos de la ficha clinica (alergias, vacunas, contactos,
  // tratamientos...) no se usan en esta prueba: si alguno se llamara,
  // falla con NoSuchMethodError en vez de devolver datos inventados.
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
  int altos = 0;

  @override
  Future<Patient> createPatient(NewPatient data) async {
    altos++;
    throw UnimplementedError();
  }

  @override
  Future<List<PatientCard>> listMyPatients() async => const [];

  @override
  Future<Patient> getPatient(String patientId) => throw UnimplementedError();

  @override
  Future<Invitation> invite(
          {required String patientId,
          required RoleType role,
          String? email}) =>
      throw UnimplementedError();

  @override
  Future<PatientCard> acceptInvitation(String token) =>
      throw UnimplementedError();

  @override
  Future<WearableStatus> wearableStatus(String patientId) =>
      throw UnimplementedError();
}

void main() {
  Future<_RepoEspia> montar(WidgetTester tester) async {
    final repo = _RepoEspia();
    await tester.pumpWidget(ProviderScope(
      overrides: [patientsRepositoryProvider.overrideWithValue(repo)],
      child: const MaterialApp(home: CreatePatientScreen()),
    ));
    await tester.pump();
    return repo;
  }

  testWidgets('sin sexo el formulario avisa y no llama al alta',
      (tester) async {
    final repo = await montar(tester);

    await tester.enterText(find.byType(TextFormField).first, 'Elena Ramírez');
    await tester.tap(find.widgetWithText(FilledButton, 'Crear perfil'));
    await tester.pump();

    expect(find.text('Selecciona el sexo'), findsOne);
    // El 422 del backend llegaba después de rellenar todo; ahora corta acá.
    expect(repo.altos, 0);
  });
}
