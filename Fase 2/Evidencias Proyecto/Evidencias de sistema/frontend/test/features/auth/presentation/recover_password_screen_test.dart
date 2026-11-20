// Pantalla de recuperación de contraseña (RF-05): correo -> código + clave.
import 'package:agecare_app/core/network/api_client.dart';
import 'package:agecare_app/core/storage/token_storage.dart';
import 'package:agecare_app/features/auth/data/auth_repository.dart';
import 'package:agecare_app/features/auth/presentation/login_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

class _SinSesion extends TokenStorage {
  @override
  Future<bool> get hasSession async => false;

  @override
  Future<String?> get accessToken async => null;

  @override
  Future<String?> get refreshToken async => null;

  @override
  Future<void> save({required String access, required String refresh}) async {}

  @override
  Future<void> clear() async {}
}

/// Anota lo que se le pide y puede rechazar el código.
class _RepoEspia implements AuthRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);

  final pedidos = <String>[];
  final canjes = <Map<String, String>>[];
  bool codigoValido = true;

  @override
  Future<void> requestPasswordRecovery(String email) async => pedidos.add(email);

  @override
  Future<void> resetPassword({
    required String email,
    required String code,
    required String newPassword,
  }) async {
    canjes.add({'email': email, 'code': code, 'pass': newPassword});
    if (!codigoValido) {
      throw ApiException(
        statusCode: 400,
        code: 'INVALID_RESET_CODE',
        message: 'El código es inválido o expiró. Revísalo o solicita uno nuevo.',
      );
    }
  }
}

void main() {
  late _RepoEspia repo;

  Future<void> montar(WidgetTester tester) async {
    repo = _RepoEspia();
    final router = GoRouter(routes: [
      GoRoute(path: '/', builder: (_, __) => const RecoverPasswordScreen()),
      GoRoute(
          path: '/login',
          builder: (_, __) => const Scaffold(body: Text('PANTALLA-LOGIN'))),
    ]);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        authRepositoryProvider.overrideWithValue(repo),
        tokenStorageProvider.overrideWithValue(_SinSesion()),
      ],
      child: MaterialApp.router(routerConfig: router),
    ));
    await tester.pump();
  }

  Future<void> terminar(WidgetTester tester) async {
    // El controlador de sesión deja un temporizador de 1,6 s del splash.
    await tester.pump(const Duration(seconds: 2));
  }

  Future<void> escribir(WidgetTester tester, String etiqueta, String valor) async {
    await tester.enterText(find.widgetWithText(TextField, etiqueta), valor);
  }

  Future<void> tocar(WidgetTester tester, String texto) async {
    final b = find.widgetWithText(FilledButton, texto);
    await tester.ensureVisible(b);
    await tester.tap(b);
    await tester.pump();
    await tester.pump();
  }

  testWidgets('paso 1: pide el correo y no avanza si no es válido', (tester) async {
    await montar(tester);
    expect(find.text('Enviar código'), findsOneWidget);

    await escribir(tester, 'Correo electrónico', 'sin-arroba');
    await tocar(tester, 'Enviar código');

    expect(repo.pedidos, isEmpty);
    expect(find.text('Escribe un correo válido.'), findsOneWidget);
    await terminar(tester);
  });

  testWidgets('paso 1 -> 2: con un correo válido pide el código y pasa a ingresarlo',
      (tester) async {
    await montar(tester);
    await escribir(tester, 'Correo electrónico', 'ana@agecare.cl');
    await tocar(tester, 'Enviar código');

    expect(repo.pedidos, ['ana@agecare.cl']);
    expect(find.text('Cambiar contraseña'), findsOneWidget);
    expect(find.text('Código de 6 dígitos'), findsOneWidget);
    // No confirma que el correo exista.
    expect(find.textContaining('Si ana@agecare.cl está registrado'), findsOneWidget);
    await terminar(tester);
  });

  testWidgets('paso 2: valida código, contraseña y coincidencia antes de enviar',
      (tester) async {
    await montar(tester);
    await escribir(tester, 'Correo electrónico', 'ana@agecare.cl');
    await tocar(tester, 'Enviar código');

    await escribir(tester, 'Código de 6 dígitos', '123');
    await tocar(tester, 'Cambiar contraseña');
    expect(find.text('El código tiene 6 dígitos.'), findsOneWidget);

    await escribir(tester, 'Código de 6 dígitos', '123 456');
    await escribir(tester, 'Contraseña nueva', 'corta');
    await tocar(tester, 'Cambiar contraseña');
    expect(find.textContaining('al menos 8 caracteres'), findsOneWidget);

    await escribir(tester, 'Contraseña nueva', 'Clave1234');
    await escribir(tester, 'Repite la contraseña nueva', 'Clave9999');
    await tocar(tester, 'Cambiar contraseña');
    expect(find.text('Las contraseñas no coinciden.'), findsOneWidget);

    expect(repo.canjes, isEmpty, reason: 'nada de eso debía llegar al servidor');
    await terminar(tester);
  });

  testWidgets('paso 2: envía el código sin espacios y vuelve al acceso', (tester) async {
    await montar(tester);
    await escribir(tester, 'Correo electrónico', 'ana@agecare.cl');
    await tocar(tester, 'Enviar código');

    await escribir(tester, 'Código de 6 dígitos', '123 456');
    await escribir(tester, 'Contraseña nueva', 'Clave1234');
    await escribir(tester, 'Repite la contraseña nueva', 'Clave1234');
    await tocar(tester, 'Cambiar contraseña');
    await tester.pumpAndSettle(const Duration(milliseconds: 100));

    expect(repo.canjes, [
      {'email': 'ana@agecare.cl', 'code': '123456', 'pass': 'Clave1234'}
    ]);
    expect(find.text('PANTALLA-LOGIN'), findsOneWidget);
    await terminar(tester);
  });

  testWidgets('un código rechazado por el servidor muestra su mensaje y no sale',
      (tester) async {
    await montar(tester);
    repo.codigoValido = false;
    await escribir(tester, 'Correo electrónico', 'ana@agecare.cl');
    await tocar(tester, 'Enviar código');

    await escribir(tester, 'Código de 6 dígitos', '000000');
    await escribir(tester, 'Contraseña nueva', 'Clave1234');
    await escribir(tester, 'Repite la contraseña nueva', 'Clave1234');
    await tocar(tester, 'Cambiar contraseña');

    expect(find.textContaining('El código es inválido o expiró'), findsOneWidget);
    expect(find.text('PANTALLA-LOGIN'), findsNothing);
    await terminar(tester);
  });

  testWidgets('se puede reenviar el código desde el paso 2', (tester) async {
    await montar(tester);
    await escribir(tester, 'Correo electrónico', 'ana@agecare.cl');
    await tocar(tester, 'Enviar código');

    await tester.tap(find.text('Reenviar código'));
    await tester.pump();
    await tester.pump();

    expect(repo.pedidos, ['ana@agecare.cl', 'ana@agecare.cl']);
    await terminar(tester);
  });
}
