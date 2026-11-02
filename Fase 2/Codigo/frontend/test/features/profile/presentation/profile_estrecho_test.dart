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
              fullName: 'Benjamín Camus',
              email: 'familia@agecare.app',
              memberships: [
                Membership(
                    patientId: 'p-elena',
                    patientName: 'Elena Ramírez',
                    role: RoleType.family),
              ],
            )),
      ],
      child:
          MaterialApp(theme: AppTheme.light(), home: const ProfileScreen()),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('Benjamín Camus'), findsOneWidget);
  });
}
