// Generar un codigo de invitacion para un adulto mayor en especifico. Antes
// el codigo era siempre del adulto mayor seleccionado en la app, que casi
// siempre era el primero de la lista.
import 'package:agecare_app/core/theme/app_theme.dart';
import 'package:agecare_app/features/auth/domain/models.dart';
import 'package:agecare_app/features/patients/data/patients_repository.dart';
import 'package:agecare_app/features/patients/domain/models.dart';
import 'package:agecare_app/features/patients/presentation/invite_member_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<_RepoQueAnota> montar(WidgetTester tester) async {
    final repo = _RepoQueAnota();
    await tester.binding.setSurfaceSize(const Size(400, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(ProviderScope(
      overrides: [patientsRepositoryProvider.overrideWithValue(repo)],
      child: MaterialApp(
        theme: AppTheme.light(),
        home: const InviteMemberScreen(),
      ),
    ));
    // El modo de demostracion tarda un poco en entregar los pacientes.
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    return repo;
  }

  Future<void> elegir(WidgetTester tester, String nombre) async {
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text(nombre).last);
    await tester.pumpAndSettle();
  }

  Future<void> generar(WidgetTester tester) async {
    await tester.tap(find.text('Generar código'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
  }

  testWidgets('con dos adultos mayores pide elegir para cual es',
      (tester) async {
    await montar(tester);

    expect(find.text('¿Para qué adulto mayor es el código?'), findsOneWidget);
    expect(find.text('Invitar a alguien al cuidado de Elena Ramírez'),
        findsOneWidget);
  });

  testWidgets('el codigo se genera para el adulto mayor elegido',
      (tester) async {
    final repo = await montar(tester);

    await elegir(tester, 'José Ramírez');
    await generar(tester);

    expect(repo.invitadosA, ['p-jose']);
  });
}

/// Repositorio de demostracion que anota para quien se pidio cada codigo.
class _RepoQueAnota extends PatientsRepositoryMock {
  final invitadosA = <String>[];

  @override
  Future<Invitation> invite(
      {required String patientId, required RoleType role, String? email}) {
    invitadosA.add(patientId);
    return super.invite(patientId: patientId, role: role, email: email);
  }
}
