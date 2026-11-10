import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:agecare_app/core/network/api_client.dart';
import 'package:agecare_app/features/auth/data/auth_repository.dart';
import 'package:agecare_app/features/auth/domain/models.dart';
import 'package:agecare_app/features/auth/presentation/register_screen.dart';

/// Repositorio que guarda lo que se le pidió registrar.
class _RepoEspia implements AuthRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);

  int registros = 0;
  RoleType? tipo;
  String? codigo;
  String? rut;
  String? telefono;
  String? segundoApellido;

  @override
  Future<AuthTokens> register({
    required String firstName,
    String? secondName,
    required String lastName,
    String? secondLastName,
    String? rut,
    required String email,
    required String password,
    RoleType? accountType,
    String? doctorEnrollmentToken,
    String? phone,
    String? invitationToken,
  }) async {
    registros++;
    tipo = accountType;
    codigo = doctorEnrollmentToken;
    this.rut = rut;
    telefono = phone;
    segundoApellido = secondLastName;
    // Responde como el backend ante un correo repetido: así la prueba
    // también mide que el mensaje del servidor llega a la pantalla.
    throw ApiException(
      statusCode: 409,
      code: 'EMAIL_ALREADY_EXISTS',
      message: 'Ya existe una cuenta con este correo electrónico.',
    );
  }
}

void main() {
  Future<_RepoEspia> montar(WidgetTester tester, {String? invitacion}) async {
    final repo = _RepoEspia();
    await tester.pumpWidget(ProviderScope(
      overrides: [authRepositoryProvider.overrideWithValue(repo)],
      child: MaterialApp(home: RegisterScreen(invitationToken: invitacion)),
    ));
    await tester.pump();
    return repo;
  }

  Future<void> enviar(WidgetTester tester) async {
    final boton = find.widgetWithText(FilledButton, 'Crear cuenta');
    await tester.ensureVisible(boton);
    await tester.tap(boton);
    await tester.pump();
  }

  testWidgets('ofrece familiar, cuidador(a) y médico, pero no adulto mayor',
      (tester) async {
    await montar(tester);
    expect(find.text('Familiar'), findsOne);
    expect(find.text('Cuidador(a)'), findsOne);
    expect(find.text('Médico(a)'), findsOne);
    expect(find.text('Adulto mayor'), findsNothing);
  });

  testWidgets('sin elegir tipo de cuenta no se registra (no asume familiar)',
      (tester) async {
    final repo = await montar(tester);
    await enviar(tester);
    expect(find.text('Elige qué tipo de cuenta vas a crear.'), findsOne);
    expect(repo.registros, 0);
  });

  testWidgets('médico pide el código de habilitación', (tester) async {
    final repo = await montar(tester);
    expect(find.text('Código de habilitación'), findsNothing);

    await tester.tap(find.text('Médico(a)'));
    await tester.pump();
    expect(find.text('Código de habilitación'), findsOne);

    await enviar(tester);
    expect(find.text('Escribe el código de habilitación'), findsOne);
    expect(repo.registros, 0);
  });

  testWidgets('con invitación no pregunta el tipo de cuenta', (tester) async {
    await montar(tester, invitacion: 'tok');
    expect(find.text('Familiar'), findsNothing);
    expect(find.text('Médico(a)'), findsNothing);
  });

  Future<void> llenarBase(WidgetTester tester) async {
    await tester.enterText(
        find.widgetWithText(TextFormField, 'Nombre'), 'Rosa');
    await tester.enterText(
        find.widgetWithText(TextFormField, 'Apellido'), 'Medina');
    await tester.enterText(
        find.widgetWithText(TextFormField, 'Correo electrónico'), 'rosa@t.cl');
    await tester.enterText(
        find.widgetWithText(TextFormField, 'Contraseña'), 'clave1234');
  }

  testWidgets('el familiar no ve el RUT; la cuidadora sí, y es obligatorio',
      (tester) async {
    final repo = await montar(tester);
    await tester.tap(find.text('Familiar'));
    await tester.pump();
    expect(find.widgetWithText(TextFormField, 'RUT'), findsNothing);
    expect(find.text('Teléfono (opcional)'), findsOne);

    await tester.tap(find.text('Cuidador(a)'));
    await tester.pump();
    expect(find.widgetWithText(TextFormField, 'RUT'), findsOne);
    expect(find.widgetWithText(TextFormField, 'Teléfono'), findsOne);

    await llenarBase(tester);
    await enviar(tester);
    expect(find.text('Escribe tu RUT'), findsOne);
    expect(find.text('Escribe el teléfono'), findsOne);
    expect(repo.registros, 0);
  });

  testWidgets('cuidador(a) válido envía el tipo de cuenta, RUT y teléfono',
      (tester) async {
    final repo = await montar(tester);
    await tester.tap(find.text('Cuidador(a)'));
    await tester.pump();
    await llenarBase(tester);
    await tester.enterText(
        find.widgetWithText(TextFormField, 'Segundo apellido (opcional)'),
        'Díaz');
    await tester.enterText(
        find.widgetWithText(TextFormField, 'RUT'), '152345674');
    await tester.enterText(
        find.widgetWithText(TextFormField, 'Teléfono'), '987654321');
    await enviar(tester);

    expect(repo.registros, 1);
    expect(repo.tipo, RoleType.caregiver);
    expect(repo.codigo, isNull);
    expect(repo.rut, '15.234.567-4');
    expect(repo.telefono, '+56987654321');
    expect(repo.segundoApellido, 'Díaz');
    await tester.pump();
    expect(find.text('Ya existe una cuenta con este correo electrónico.'),
        findsOne);
    // El AuthController arma su splash con un temporizador de 1,6 s.
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('elegir médico no borra los errores de los campos de abajo',
      (tester) async {
    await montar(tester);
    await tester.tap(find.text('Familiar'));
    await tester.pump();
    await enviar(tester);
    expect(find.text('Escribe tu nombre'), findsOne);

    await tester.ensureVisible(find.text('Médico(a)'));
    await tester.tap(find.text('Médico(a)'));
    await tester.pump();
    // Antes, insertar el bloque del médico recreaba los campos y su error se
    // perdía.
    expect(find.text('Escribe tu nombre'), findsOne);
  });
}
