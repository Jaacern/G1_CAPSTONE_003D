import 'package:agecare_app/core/theme/app_theme.dart';
import 'package:agecare_app/features/auth/application/auth_controller.dart';
import 'package:agecare_app/features/auth/domain/models.dart';
import 'package:agecare_app/features/home/data/dashboard_repository.dart';
import 'package:agecare_app/features/home/presentation/family_home_screen.dart';
import 'package:agecare_app/features/patients/data/patients_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// La pantalla "Hoy" en el teléfono más angosto que atendemos (320 dp).
/// Sus tarjetas son filas con un título a la izquierda y un chip, un valor o
/// un enlace a la derecha; cuando el título no cede ancho, el elemento
/// derecho se sale de la pantalla. Flutter convierte ese desborde en falla de
/// prueba, así que montar la vista a 320 dp lo detecta sin necesitar un
/// teléfono.
void main() {
  testWidgets('las tarjetas de "Hoy" caben en 320 dp', (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(ProviderScope(
      overrides: [
        patientsRepositoryProvider
            .overrideWithValue(PatientsRepositoryMock()),
        dashboardRepositoryProvider
            .overrideWithValue(DashboardRepositoryMock()),
        // El botón SOS del familiar lee la sesión; sin este override el
        // arranque deja un timer de reintentos pendiente al terminar la prueba.
        currentUserProvider.overrideWith((ref) => const User(
              userId: 'u-1',
              fullName: 'Benjamín Camus',
              email: 'familia@agecare.app',
            )),
      ],
      child: MaterialApp(
          theme: AppTheme.light(),
          home: const Scaffold(body: FamilyHomeScreen())),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));

    // Las tres tarjetas que antes se desbordaban: la de vitales ("Ver todo ›"),
    // la de medicamentos (pill de pendientes) y la de observación
    // ("Próximamente").
    expect(find.text('Vitals del wearable'), findsOneWidget);
    expect(find.text('Medicamentos de hoy'), findsOneWidget);
    expect(find.text('Última observación'), findsOneWidget);
  });
}
