import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:agecare_app/core/theme/app_theme.dart';
import 'package:agecare_app/features/alerts/presentation/sos_button.dart';
import 'package:agecare_app/features/auth/application/auth_controller.dart';
import 'package:agecare_app/features/auth/domain/models.dart';
import 'package:agecare_app/features/patients/application/patients_providers.dart';
import 'package:agecare_app/features/patients/domain/models.dart';

/// Quién ve el botón SOS.
///
/// El backend autoriza a la cuidadora y al adulto mayor (9.6), y lo decide por
/// la membresía en ESE paciente. Si la pantalla decidiera por el tipo de
/// cuenta, una persona que cuida a un paciente y es familiar de otro vería el
/// botón en los dos y en el segundo recibiría un 403 justo cuando lo aprieta,
/// que es el peor momento posible para enterarse.
void main() {
  const elena = 'p-elena';
  const luis = 'p-luis';

  User usuario(RoleType cuenta, List<Membership> membresias) => User(
        userId: 'u-1',
        fullName: 'Persona de prueba',
        accountType: cuenta,
        email: 'prueba@agecare.app',
        memberships: membresias,
      );

  Membership en(String patientId, RoleType rol) => Membership(
        patientId: patientId,
        patientName: patientId,
        role: rol,
      );

  PatientCard tarjeta(String patientId) => PatientCard(
        patientId: patientId,
        fullName: patientId,
        role: RoleType.family,
        wellbeingStatus: WellbeingStatus.ok,
      );

  Future<void> montar(WidgetTester tester,
      {required User user, PatientCard? seleccionado}) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        currentUserProvider.overrideWith((ref) => user),
        // Siempre fijo, incluso en null: el controlador de verdad se suscribe
        // a la lista de pacientes y sale a buscarla.
        selectedPatientProvider.overrideWith(() => _SeleccionFija(seleccionado)),
      ],
      child: const MaterialApp(
        home: Scaffold(floatingActionButton: SosButton()),
      ),
    ));
    await tester.pump();
  }

  bool hayBoton() => find.text('SOS').evaluate().isNotEmpty;

  testWidgets('la cuidadora lo ve en el paciente que cuida', (tester) async {
    await montar(tester,
        user: usuario(RoleType.caregiver, [en(elena, RoleType.caregiver)]),
        seleccionado: tarjeta(elena));
    expect(hayBoton(), isTrue);
  });

  testWidgets('el familiar no lo ve', (tester) async {
    await montar(tester,
        user: usuario(RoleType.family, [en(elena, RoleType.family)]),
        seleccionado: tarjeta(elena));
    expect(hayBoton(), isFalse);
  });

  testWidgets('el médico tampoco', (tester) async {
    await montar(tester,
        user: usuario(RoleType.doctor, [en(elena, RoleType.doctor)]),
        seleccionado: tarjeta(elena));
    expect(hayBoton(), isFalse);
  });

  testWidgets('el adulto mayor lo ve sin haber elegido paciente',
      (tester) async {
    // No tiene selector: el paciente es él mismo y sale de su membresía.
    await montar(tester,
        user: usuario(RoleType.elder, [en(elena, RoleType.elder)]));
    expect(hayBoton(), isTrue);
  });

  group('la misma persona con dos roles', () {
    final dosRoles = [en(elena, RoleType.caregiver), en(luis, RoleType.family)];

    testWidgets('lo ve en el paciente que cuida', (tester) async {
      await montar(tester,
          user: usuario(RoleType.caregiver, dosRoles),
          seleccionado: tarjeta(elena));
      expect(hayBoton(), isTrue);
    });

    testWidgets('y NO en el paciente del que solo es familiar',
        (tester) async {
      // Aquí fallaba: con el tipo de cuenta el botón salía igual, y el
      // servidor respondía 403 al apretarlo.
      await montar(tester,
          user: usuario(RoleType.caregiver, dosRoles),
          seleccionado: tarjeta(luis));
      expect(hayBoton(), isFalse);
    });
  });

  testWidgets('sin paciente a la vista no se ofrece', (tester) async {
    await montar(tester,
        user: usuario(RoleType.caregiver, [en(elena, RoleType.caregiver)]));
    expect(hayBoton(), isFalse);
  });

  testWidgets('alguien fuera del círculo de ese paciente no lo ve',
      (tester) async {
    await montar(tester,
        user: usuario(RoleType.caregiver, [en(elena, RoleType.caregiver)]),
        seleccionado: tarjeta(luis));
    expect(hayBoton(), isFalse);
  });
}

class _SeleccionFija extends SelectedPatientController {
  _SeleccionFija(this._valor);
  final PatientCard? _valor;

  @override
  PatientCard? build() => _valor;
}
