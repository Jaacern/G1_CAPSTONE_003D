import 'package:flutter_test/flutter_test.dart';

import 'package:agecare_app/features/patients/domain/models.dart';

/// El cuerpo que se le manda a `POST /patients`.
void main() {
  NewPatient paciente(
          {String sexo = 'female', List<String> condiciones = const []}) =>
      NewPatient(
        fullName: 'Elena Ramírez',
        birthDate: DateTime(1948, 3, 9),
        sex: sexo,
        conditions: condiciones,
      );

  test('el alta siempre lleva el sexo', () {
    // patients.sex es NOT NULL y PatientCreateIn lo pide obligatorio: un body
    // sin la clave devuelve 422, no deja al paciente sin sexo.
    expect(paciente().toJson()['sex'], 'female');
  });

  test('la fecha de nacimiento sale con dos dígitos por mes y por día', () {
    expect(paciente().toJson()['birth_date'], '1948-03-09');
  });

  test('el nombre completo se parte en nombre y apellido', () {
    final json = paciente().toJson();
    expect(json['first_name'], 'Elena');
    expect(json['last_name'], 'Ramírez');
  });

  test('un apellido compuesto se manda entero', () {
    final json = NewPatient(
      fullName: 'Rosa Pérez de la Fuente',
      birthDate: DateTime(1951, 11, 2),
      sex: 'female',
    ).toJson();
    expect(json['first_name'], 'Rosa');
    expect(json['last_name'], 'Pérez de la Fuente');
  });

  test('sin apellidos el backend igual recibe los dos campos', () {
    // first_name y last_name tienen min_length 1, así que una sola palabra no
    // puede quedarse en apellido vacío.
    final json = NewPatient(
      fullName: 'Elena',
      birthDate: DateTime(1948, 3, 9),
      sex: 'other',
    ).toJson();
    expect(json['first_name'], 'Elena');
    expect(json['last_name'], 'Elena');
  });

  test('padecimientos vacíos no viajan en el body', () {
    expect(paciente().toJson().containsKey('conditions'), isFalse);
    expect(
      paciente(condiciones: const ['hipertensión']).toJson()['conditions'],
      ['hipertensión'],
    );
  });
}
