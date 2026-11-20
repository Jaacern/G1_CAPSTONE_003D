import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:agecare_app/features/caregiver/application/caregiver_providers.dart';
import 'package:agecare_app/features/caregiver/domain/models.dart';
import 'package:agecare_app/features/caregiver/presentation/checkin_screen.dart';

/// /caregiver/today no recibe paciente: él elige a quién pertenece el estado
/// que muestra. Cuando el turno abierto es de otro, la pantalla no puede
/// ofrecer el botón de iniciar, porque el backend lo devuelve con 409.
CaregiverToday _hoy({
  String patientId = 'p-elena',
  String patientName = 'Elena Ramírez',
  ShiftStatus shiftStatus = ShiftStatus.checkedOut,
}) =>
    CaregiverToday(
      patientId: patientId,
      patientName: patientName,
      shiftStatus: shiftStatus,
    );

Widget _app(CaregiverToday hoy) => ProviderScope(
      overrides: [caregiverTodayProvider.overrideWith((_) async => hoy)],
      child: const MaterialApp(
        home: CheckinScreen(patientId: 'p-elena'),
      ),
    );

/// El provider está en carga el primer frame y el spinner de `LoadingView`
/// nunca termina, así que `pumpAndSettle` expiraría: se avanza un frame más.
Future<void> _abrirTurno(WidgetTester tester, CaregiverToday hoy) async {
  await tester.pumpWidget(_app(hoy));
  await tester.pump();
}

void main() {
  testWidgets('con la cuidadora fuera de turno ofrece iniciar uno',
      (tester) async {
    await _abrirTurno(tester, _hoy());

    expect(find.text('Iniciar turno'), findsOne);
    expect(find.textContaining('Ya tienes un turno abierto'), findsNothing);
  });

  testWidgets('el turno abierto del paciente que se ve sí se puede cerrar',
      (tester) async {
    await _abrirTurno(tester, _hoy(shiftStatus: ShiftStatus.checkedIn));

    expect(find.text('Finalizar turno'), findsOne);
  });

  testWidgets('un turno abierto con otro paciente se avisa, no se intenta',
      (tester) async {
    await _abrirTurno(
        tester,
        _hoy(
          patientId: 'p-jose',
          patientName: 'José Ramírez',
          shiftStatus: ShiftStatus.checkedIn,
        ));

    expect(find.textContaining('José Ramírez'), findsOne);
    expect(find.text('Ir a cerrar ese turno'), findsOne);
    // El botón que produciría el 409 no está en pantalla.
    expect(find.text('Iniciar turno'), findsNothing);
    expect(find.text('Finalizar turno'), findsNothing);
  });

  testWidgets('fuera de turno, el aviso del otro paciente no aparece',
      (tester) async {
    await _abrirTurno(
        tester, _hoy(patientId: 'p-jose', patientName: 'José Ramírez'));

    expect(find.text('Iniciar turno'), findsOne);
    expect(find.text('Ir a cerrar ese turno'), findsNothing);
  });
}
