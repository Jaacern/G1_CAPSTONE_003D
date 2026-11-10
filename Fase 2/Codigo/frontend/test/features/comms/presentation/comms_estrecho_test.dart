import 'package:agecare_app/core/theme/app_theme.dart';
import 'package:agecare_app/features/auth/application/auth_controller.dart';
import 'package:agecare_app/features/auth/domain/models.dart';
import 'package:agecare_app/features/comms/presentation/comms_screen.dart';
import 'package:agecare_app/features/patients/data/patients_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// El hub de Comunicaciones en 320 dp: dos tarjetas con título largo
/// ("Chat con el equipo de cuidado") y un badge "Próximamente" en la misma
/// línea cuando el módulo está apagado.
void main() {
  testWidgets('las tarjetas del hub de comunicaciones caben en 320 dp',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(ProviderScope(
      overrides: [
        patientsRepositoryProvider
            .overrideWithValue(PatientsRepositoryMock()),
        currentUserProvider.overrideWith((ref) => const User(
              userId: 'u-1',
              fullName: 'Benjamín Camus',
              accountType: RoleType.family,
              email: 'familia@agecare.app',
              memberships: [
                Membership(
                    patientId: 'p-elena',
                    patientName: 'Elena Ramírez',
                    role: RoleType.family),
              ],
            )),
      ],
      child: MaterialApp(theme: AppTheme.light(), home: const CommsScreen()),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('Chat con el equipo de cuidado'), findsOneWidget);
    expect(find.text('Asistente IA'), findsOneWidget);
  });
}
