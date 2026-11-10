import 'package:flutter_test/flutter_test.dart';

import 'package:agecare_app/features/patients/domain/models.dart';

/// El cuerpo que se le manda a `POST /patients`.
void main() {
  const contacto = NewEmergencyContact(
    firstName: 'Luis',
    lastName: 'Rojas',
    relationship: 'Hijo',
    phone: '+56987654321',
  );

  NewPatient paciente({
    String sexo = 'female',
    String? segundoNombre,
    String? segundoApellido,
    List<String> condiciones = const [],
    List<NewAllergy> alergias = const [],
  }) =>
      NewPatient(
        firstName: 'Elena',
        secondName: segundoNombre,
        lastName: 'Ramírez',
        secondLastName: segundoApellido,
        rut: '5.123.456-1',
        birthDate: DateTime(1948, 3, 9),
        sex: sexo,
        address: 'Los Aromos 123, Concepción',
        emergencyContact: contacto,
        conditions: condiciones,
        allergies: alergias,
      );

  test('el alta siempre lleva el sexo', () {
    // patients.sex es NOT NULL y PatientCreateIn lo pide obligatorio.
    expect(paciente().toJson()['sex'], 'female');
  });

  test('la fecha de nacimiento sale con dos dígitos por mes y por día', () {
    expect(paciente().toJson()['birth_date'], '1948-03-09');
  });

  test('cada parte del nombre viaja en su campo, sin partir un nombre completo',
      () {
    // Antes se partía "nombre completo" por el primer espacio y
    // "María José Pérez" quedaba con apellido "José Pérez".
    final json =
        paciente(segundoNombre: 'María', segundoApellido: 'Vega').toJson();
    expect(json['first_name'], 'Elena');
    expect(json['second_name'], 'María');
    expect(json['last_name'], 'Ramírez');
    expect(json['second_last_name'], 'Vega');
    expect(json.containsKey('full_name'), isFalse);
  });

  test('segundo nombre y segundo apellido vacíos no viajan', () {
    final json = paciente(segundoNombre: '  ', segundoApellido: '').toJson();
    expect(json.containsKey('second_name'), isFalse);
    expect(json.containsKey('second_last_name'), isFalse);
  });

  test('el detalle separa nombres y apellidos', () {
    final p = Patient.fromJson({
      'patient_id': 'p-1',
      'full_name': 'Elena Rosa Rosales Riquelme',
      'first_name': 'Elena',
      'second_name': 'Rosa',
      'last_name': 'Rosales',
      'second_last_name': 'Riquelme',
      'birth_date': '1944-03-12',
      'conditions': ['hipertension'],
      'conditions_detail': [
        {
          'condition': 'hipertension',
          'system': 'cardiovascular',
          'label': 'Hipertensión arterial (HTA)'
        }
      ],
    });
    expect(p.givenNames, 'Elena Rosa');
    expect(p.surnames, 'Rosales Riquelme');
    // El backend guarda el código; se muestra la etiqueta.
    expect(p.conditionLabels, ['Hipertensión arterial (HTA)']);
  });

  test('sin segundo nombre ni segundo apellido no quedan espacios', () {
    final p = Patient.fromJson({
      'patient_id': 'p-1',
      'full_name': 'Raúl Núñez',
      'first_name': 'Raúl',
      'last_name': 'Núñez',
      'birth_date': '1944-03-12',
    });
    expect(p.givenNames, 'Raúl');
    expect(p.surnames, 'Núñez');
  });

  test('el nombre completo se arma igual que la columna generada', () {
    expect(paciente().fullName, 'Elena Ramírez');
    expect(paciente(segundoNombre: 'María', segundoApellido: 'Vega').fullName,
        'Elena María Ramírez Vega');
  });

  test('los obligatorios siempre van: RUT, domicilio y contacto de emergencia',
      () {
    final json = paciente().toJson();
    expect(json['rut'], '5.123.456-1');
    expect(json['address'], 'Los Aromos 123, Concepción');
    expect(json['emergency_contact'], {
      'first_name': 'Luis',
      'last_name': 'Rojas',
      'relationship': 'Hijo',
      'phone': '+56987654321',
    });
  });

  test('sin alergias ni condiciones no se mandan listas vacías', () {
    // Una lista vacía se confundiría con "sin alergias"; ausente es
    // "no informado".
    final json = paciente().toJson();
    expect(json.containsKey('conditions'), isFalse);
    expect(json.containsKey('allergies'), isFalse);
  });

  test('alergias y condiciones informadas viajan con su detalle', () {
    final json = paciente(
      condiciones: const ['hipertension'],
      alergias: const [
        NewAllergy(
            substance: 'penicilina',
            category: 'medicamento',
            severity: 'severa'),
      ],
    ).toJson();
    expect(json['conditions'], ['hipertension']);
    expect(json['allergies'], [
      {
        'substance': 'penicilina',
        'category': 'medicamento',
        'severity': 'severa'
      }
    ]);
  });
}
