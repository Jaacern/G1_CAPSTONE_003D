import 'package:agecare_app/core/theme/app_theme.dart';
import 'package:agecare_app/features/alerts/data/alerts_repository.dart';
import 'package:agecare_app/features/alerts/presentation/alerts_screen.dart';
import 'package:agecare_app/features/auth/application/auth_controller.dart';
import 'package:agecare_app/features/auth/domain/models.dart';
import 'package:agecare_app/features/patients/data/patients_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// El centro de alertas en 320 dp. Cada tarjeta tiene ícono, título/paciente y
/// la hora en la misma fila, y debajo dos botones de acción lado a lado; las
/// tres son filas donde algo tiene que ceder.
void main() {
  testWidgets('las tarjetas de alertas caben en 320 dp', (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(ProviderScope(
      overrides: [
        patientsRepositoryProvider
            .overrideWithValue(PatientsRepositoryMock()),
        alertsRepositoryProvider.overrideWithValue(AlertsRepositoryMock()),
        // Sesión fija de cuidadora: evita el timer de restauración y mantiene
        // los botones de gestión que esta prueba mide (el familiar no los ve).
        currentUserProvider.overrideWith((ref) => const User(
              userId: 'u-care',
              fullName: 'Rosa Millán',
              email: 'cuidadora@agecare.app',
              memberships: [
                Membership(
                  patientId: 'p-elena',
                  patientName: 'Elena Ramírez',
                  role: RoleType.caregiver,
                ),
              ],
            )),
      ],
      child: MaterialApp(
          theme: AppTheme.light(), home: const AlertsScreen()),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('Centro de alertas'), findsOneWidget);
    expect(find.text('Reconocer'), findsWidgets);
  });
}
