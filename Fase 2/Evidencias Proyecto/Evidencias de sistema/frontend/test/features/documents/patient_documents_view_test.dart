import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'package:agecare_app/core/theme/app_theme.dart';
import 'package:agecare_app/features/auth/application/auth_controller.dart';
import 'package:agecare_app/features/auth/domain/models.dart';
import 'package:agecare_app/features/documents/data/documents_repository.dart';
import 'package:agecare_app/features/documents/domain/models.dart';
import 'package:agecare_app/features/documents/presentation/patient_documents_view.dart';

PatientDocument _d(String t, String cat, {String? autor}) => PatientDocument(
      id: t,
      title: t,
      category: cat,
      fileUrl: 'x.pdf',
      createdAt: DateTime(2026, 1, 1),
      uploaderName: autor,
    );

void main() {
  setUpAll(() => initializeDateFormatting('es'));

  group('filtrarDocumentos', () {
    final docs = [
      _d('Radiografía de tórax', 'imagen'),
      _d('Receta losartán', 'receta', autor: 'Dra. Soto'),
      _d('Hemograma', 'estudio'),
    ];

    test('busca sin importar tildes ni mayúsculas', () {
      expect(filtrarDocumentos(docs, texto: 'RADIOGRAFIA').single.title,
          'Radiografía de tórax');
    });

    test('busca también por quién lo subió y por categoría', () {
      expect(filtrarDocumentos(docs, texto: 'soto').single.title,
          'Receta losartán');
      expect(filtrarDocumentos(docs, texto: 'laboratorio').single.title,
          'Hemograma');
    });

    test('filtra por categoría', () {
      expect(
          filtrarDocumentos(docs, categoria: DocumentCategory.receta)
              .map((d) => d.title),
          ['Receta losartán']);
    });

    test('una clave desconocida cae en Otros', () {
      expect(DocumentCategory.fromApi('rara'), DocumentCategory.general);
    });
  });

  Future<void> montar(WidgetTester tester, RoleType rol,
      {ThemeData? tema, double ancho = 400}) async {
    await tester.binding.setSurfaceSize(Size(ancho, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(ProviderScope(
      overrides: [
        documentsRepositoryProvider
            .overrideWithValue(DocumentsRepositoryMock()),
        currentUserProvider.overrideWith((ref) => User(
              userId: 'u',
              fullName: 'Persona',
              email: 'p@t.cl',
              accountType: rol,
              doctorVerified: rol == RoleType.doctor,
              memberships: [
                Membership(patientId: 'p1', patientName: 'Elena', role: rol),
              ],
            )),
      ],
      child: MaterialApp(
          theme: tema,
          home: const Scaffold(body: PatientDocumentsView(patientId: 'p1'))),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('los documentos se ven al entrar, agrupados, sin botón extra',
      (tester) async {
    await montar(tester, RoleType.family);
    expect(find.text('Abrir documentos'), findsNothing);
    expect(find.text('Receta cardiología (losartán)'), findsOne);
    expect(find.text('Recetas · 2'), findsOne);
    expect(find.text('Todos (9)'), findsOne);
  });

  testWidgets('el buscador y el chip de categoría filtran la lista',
      (tester) async {
    await montar(tester, RoleType.caregiver);
    await tester.enterText(find.byType(TextField), 'fonasa');
    await tester.pump();
    expect(find.text('Credencial Fonasa'), findsOne);
    expect(find.text('Receta metformina'), findsNothing);

    await tester.tap(find.byTooltip('Limpiar búsqueda'));
    await tester.pump();
    await tester.ensureVisible(find.text('Imágenes (1)'));
    await tester.pump();
    await tester.tap(find.text('Imágenes (1)'));
    await tester.pump();
    expect(find.text('Radiografía de tórax'), findsOne);
    expect(find.text('Hemograma y perfil bioquímico'), findsNothing);
  });

  testWidgets('el médico sube pero no quita (el servidor se lo niega)',
      (tester) async {
    await montar(tester, RoleType.doctor);
    expect(find.text('Subir'), findsOne);
    expect(find.byTooltip('Quitar del expediente'), findsNothing);
    expect(find.byTooltip('Abrir'), findsWidgets);
  });

  testWidgets('el familiar puede quitar documentos', (tester) async {
    await montar(tester, RoleType.family);
    expect(find.byTooltip('Quitar del expediente'), findsWidgets);
  });

  testWidgets('con el tema de la app el boton Subir cabe junto al buscador',
      (tester) async {
    // El tema real da a los botones ancho infinito; sin un ancho propio el
    // boton dentro de la fila del buscador rompia el dibujo de la vista.
    await montar(tester, RoleType.family, tema: AppTheme.light(), ancho: 320);
    expect(find.text('Subir'), findsOne);
    expect(find.text('Recetas · 2'), findsOne);
  });
}
