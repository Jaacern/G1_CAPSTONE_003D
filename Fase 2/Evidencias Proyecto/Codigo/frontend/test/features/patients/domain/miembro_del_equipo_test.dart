// Un miembro del equipo de cuidado y como se nombra su rol.
import 'package:agecare_app/features/patients/domain/models.dart';
import 'package:flutter_test/flutter_test.dart';

CareMember _miembro(String role, {String? profession}) => CareMember(
      userId: 'u',
      fullName: 'Persona',
      email: 'p@agecare.cl',
      role: role,
      profession: profession,
    );

void main() {
  test('sin profesion se nombra por su rol en el circulo', () {
    expect(_miembro('family').label, 'Familiar');
    expect(_miembro('caregiver').label, 'Cuidador(a)');
    expect(_miembro('doctor').label, 'Médico');
    expect(_miembro('elder').label, 'Adulto mayor');
  });

  test('si tiene profesion, se muestra la profesion', () {
    expect(_miembro('doctor', profession: 'kinesiologo').label,
        'Kinesiólogo(a)');
  });

  test('se lee de la API y, si no dice, no es el administrador', () {
    final m = CareMember.fromJson(const {
      'user_id': 'u2',
      'full_name': 'Marisol Tapia',
      'email': 'cuidadora@agecare.cl',
      'role': 'caregiver',
      'profession': 'cuidadora',
    });

    expect(m.fullName, 'Marisol Tapia');
    expect(m.isOwner, isFalse);
    expect(m.label, 'Cuidador(a)');
  });
}
