// La cuenta del adulto mayor viaja con el alta de su perfil.
import 'package:agecare_app/features/patients/domain/models.dart';
import 'package:flutter_test/flutter_test.dart';

NewPatient _paciente({NewElderAccount? cuenta}) => NewPatient(
      firstName: 'Elena',
      lastName: 'Ramírez',
      rut: '5.123.456-7',
      birthDate: DateTime(1948, 3, 9),
      sex: 'female',
      address: 'Los Aromos 123, Concepción',
      emergencyContact: const NewEmergencyContact(
        firstName: 'Daniela',
        lastName: 'Fuentes',
        relationship: 'hija',
        phone: '+56912345678',
      ),
      elderAccount: cuenta,
    );

void main() {
  test('con cuenta, el alta lleva correo y contrasena del adulto mayor', () {
    final json = _paciente(
      cuenta: const NewElderAccount(
          email: '  elena@agecare.cl ', password: 'Abuela2026'),
    ).toJson();

    expect(json['elder_account'],
        {'email': 'elena@agecare.cl', 'password': 'Abuela2026'});
  });

  test('sin cuenta, el alta no lleva elder_account', () {
    expect(_paciente().toJson().containsKey('elder_account'), isFalse);
  });
}
