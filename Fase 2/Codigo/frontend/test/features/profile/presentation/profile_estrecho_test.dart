import 'package:agecare_app/core/theme/app_theme.dart';
import 'package:agecare_app/features/auth/application/auth_controller.dart';
import 'package:agecare_app/features/auth/domain/models.dart';
import 'package:agecare_app/features/profile/presentation/profile_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// El perfil en 320 dp: sus filas son "etiqueta + valor" (correo, teléfono,
/// idioma, notificaciones) y el valor largo es el que se sale primero.
void main() {
  testWidgets('el perfil cabe en 320 dp', (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(ProviderScope(
      overrides: [
        currentUserProvider.overrideWith((ref) => const User(
              userId: 'u-1',
              fullName: 'Benjamín Andrés Camus Rojas',
              firstName: 'Benjamín',
              secondName: 'Andrés',
              lastName: 'Camus',
              secondLastName: 'Rojas',
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
      child: MaterialApp(theme: AppTheme.light(), home: const ProfileScreen()),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));

    // El nombre va en cuatro campos, no en uno que hay que partir adivinando.
    for (final parte in ['Benjamín', 'Andrés', 'Camus', 'Rojas']) {
      expect(find.text(parte), findsOneWidget);
    }
    // El familiar no tiene perfil profesional ni ofertas de trabajo.
    expect(find.text('Mi perfil profesional'), findsNothing);
  });

  testWidgets('la cuidadora ve su RUT y el acceso a su perfil profesional',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 1800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(ProviderScope(
      overrides: [
        currentUserProvider.overrideWith((ref) => const User(
              userId: 'u-2',
              fullName: 'Rosa Medina Díaz',
              firstName: 'Rosa',
              lastName: 'Medina',
              secondLastName: 'Díaz',
              rut: '15.234.567-4',
              phone: '+56987654321',
              accountType: RoleType.caregiver,
              email: 'rosa@cuidados.cl',
            )),
      ],
      child: MaterialApp(theme: AppTheme.light(), home: const ProfileScreen()),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('15.234.567-4'), findsOneWidget);
    expect(find.text('Mi perfil profesional'), findsOneWidget);
    expect(find.text('Ofertas de trabajo'), findsOneWidget);
  });
}
