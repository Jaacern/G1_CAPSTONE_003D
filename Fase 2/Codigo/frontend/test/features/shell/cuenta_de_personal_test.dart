import 'package:agecare_app/core/theme/app_theme.dart';
import 'package:agecare_app/features/auth/application/auth_controller.dart';
import 'package:agecare_app/features/auth/domain/models.dart';
import 'package:agecare_app/features/shell/main_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// El personal de AgeCare se guarda como cuenta "family", pero no es familia
/// de nadie: la app no le ofrece crear ni cuidar adultos mayores.
void main() {
  testWidgets('el personal ve el aviso y no la app de la familia',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(ProviderScope(
      overrides: [
        currentUserProvider.overrideWith((ref) => const User(
              userId: 'u-admin',
              fullName: 'Tomás Ignacio Bravo Lagos',
              email: 'administrador@agecare.cl',
              accountType: RoleType.family,
              isStaff: true,
            )),
      ],
      child: MaterialApp(theme: AppTheme.light(), home: const MainShell()),
    ));
    await tester.pump();

    expect(find.text('Esta cuenta es del personal de AgeCare'), findsOneWidget);
    expect(find.text('Agregar adulto mayor'), findsNothing);
    expect(find.text('Cerrar sesión'), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
  });

  test('is_staff llega desde el servidor y por omisión es falso', () {
    final base = {
      'user_id': 'u',
      'full_name': 'X Y',
      'email': 'x@y.cl',
      'account_type': 'family',
    };
    expect(User.fromJson(base).isStaff, isFalse);
    expect(User.fromJson({...base, 'is_staff': true}).isStaff, isTrue);
  });
}
