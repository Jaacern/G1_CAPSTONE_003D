import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:agecare_app/features/auth/domain/models.dart';
import 'package:agecare_app/features/patients/data/patients_repository.dart';
import 'package:agecare_app/features/patients/domain/models.dart';
import 'package:agecare_app/features/patients/presentation/create_patient_screen.dart';

/// Repositorio que solo cuenta las altas que le piden.
class _RepoEspia implements PatientsRepository {
  // Los métodos de la ficha clínica no se usan en esta prueba: si alguno se
  // llamara, falla con NoSuchMethodError en vez de devolver datos inventados.
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
  int altos = 0;

  @override
  Future<Patient> createPatient(NewPatient data) async {
    altos++;
    throw UnimplementedError();
  }

  @override
  Future<List<ConditionDetail>> conditionCatalog() async => const [];

  @override
  Future<List<AllergenCatalogItem>> allergenCatalog() async => const [];

  @override
  Future<List<PatientCard>> listMyPatients() async => const [];

  @override
  Future<Patient> getPatient(String patientId) => throw UnimplementedError();

  @override
  Future<Invitation> invite(
          {required String patientId, required RoleType role, String? email}) =>
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

  Finder campo(String etiqueta) => find.widgetWithText(TextFormField, etiqueta);

  Future<void> enviar(WidgetTester tester) async {
    final boton = find.widgetWithText(FilledButton, 'Crear perfil');
    await tester.ensureVisible(boton);
    await tester.tap(boton);
    await tester.pump();
  }

  testWidgets('formulario vacío: marca los obligatorios y no llama al alta',
      (tester) async {
    final repo = await montar(tester);
    await enviar(tester);

    expect(find.text('Escribe el RUT'), findsOne);
    expect(find.text('Selecciona el sexo'), findsOne);
    expect(find.text('Selecciona la fecha de nacimiento'), findsOne);
    expect(find.text('Escribe el domicilio completo (calle, número y comuna)'),
        findsOne);
    expect(find.text('Escribe el teléfono'), findsOne);
    expect(repo.altos, 0);
  });

  testWidgets('un RUT con dígito verificador malo no pasa', (tester) async {
    final repo = await montar(tester);
    // 5.123.456 lleva dígito 1, no K.
    await tester.enterText(campo('RUT *'), '5.123.456-K');
    await enviar(tester);

    expect(find.text('El dígito verificador no corresponde'), findsOne);
    expect(repo.altos, 0);
  });

  testWidgets('un nombre con números no pasa', (tester) async {
    final repo = await montar(tester);
    await tester.enterText(campo('Nombre *').first, 'Elena2');
    await enviar(tester);

    expect(find.text('Solo letras, espacios, apóstrofe o guion'), findsWidgets);
    expect(repo.altos, 0);
  });

  testWidgets('el segundo nombre y el segundo apellido no son obligatorios',
      (tester) async {
    await montar(tester);
    await enviar(tester);

    expect(find.text('Escribe el segundo nombre'), findsNothing);
    expect(find.text('Escribe el segundo apellido'), findsNothing);
  });

  testWidgets('pide correo y contrasena para la cuenta del adulto mayor',
      (tester) async {
    final repo = await montar(tester);
    await enviar(tester);

    expect(find.text('Escribe el correo del adulto mayor'), findsOne);
    expect(find.text('Escribe una contraseña'), findsOne);
    expect(repo.altos, 0);
  });

  testWidgets('un correo mal escrito y una contrasena corta no pasan',
      (tester) async {
    await montar(tester);
    await tester.enterText(campo('Correo del adulto mayor *'), 'elena.gmail.com');
    await tester.enterText(campo('Contraseña *'), 'abc1');
    await enviar(tester);

    expect(find.text('Revisa el correo: falta algo (ejemplo: elena@gmail.com)'),
        findsOne);
    expect(find.text('Mínimo 8 caracteres'), findsOne);
  });

  testWidgets('la contrasena repetida tiene que coincidir', (tester) async {
    await montar(tester);
    await tester.enterText(campo('Contraseña *'), 'Abuela2026');
    await tester.enterText(campo('Repite la contraseña *'), 'Abuela2025');
    await enviar(tester);

    expect(find.text('Las contraseñas no coinciden'), findsOne);
  });
}
