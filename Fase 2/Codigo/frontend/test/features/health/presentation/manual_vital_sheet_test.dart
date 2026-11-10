import 'package:agecare_app/features/health/data/vitals_repository.dart';
import 'package:agecare_app/features/health/domain/models.dart';
import 'package:agecare_app/features/health/presentation/manual_vital_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Guarda lo que la hoja manda, para comprobar que no envía datos inválidos.
class _RepoQueGraba extends VitalsRepositoryMock {
  final List<ManualVitalEntry> enviados = [];

  @override
  Future<bool> addManual(String patientId, ManualVitalEntry entry) async {
    enviados.add(entry);
    return false;
  }
}

void main() {
  Future<_RepoQueGraba> abrir(WidgetTester tester) async {
    final repo = _RepoQueGraba();
    await tester.pumpWidget(ProviderScope(
      overrides: [vitalsRepositoryProvider.overrideWithValue(repo)],
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => showManualVitalSheet(context, patientId: 'p1'),
                child: const Text('abrir'),
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('abrir'));
    await tester.pumpAndSettle();
    return repo;
  }

  testWidgets('presión sin diastólica no se envía y pide el dato',
      (tester) async {
    final repo = await abrir(tester);
    await tester.enterText(find.widgetWithText(TextFormField, 'Sistólica (arriba)'), '128');
    await tester.tap(find.text('Guardar medición'));
    await tester.pumpAndSettle();

    expect(find.text('Escribe la diastólica'), findsOneWidget);
    expect(repo.enviados, isEmpty);
  });

  testWidgets('diastólica mayor o igual a la sistólica se rechaza',
      (tester) async {
    final repo = await abrir(tester);
    await tester.enterText(find.widgetWithText(TextFormField, 'Sistólica (arriba)'), '120');
    await tester.enterText(find.widgetWithText(TextFormField, 'Diastólica (abajo)'), '130');
    await tester.tap(find.text('Guardar medición'));
    await tester.pumpAndSettle();

    expect(find.text('Debe ser menor que la sistólica'), findsOneWidget);
    expect(repo.enviados, isEmpty);
  });

  testWidgets('un valor imposible se rechaza con su rango', (tester) async {
    final repo = await abrir(tester);
    await tester.enterText(find.widgetWithText(TextFormField, 'Sistólica (arriba)'), '999');
    await tester.enterText(find.widgetWithText(TextFormField, 'Diastólica (abajo)'), '80');
    await tester.tap(find.text('Guardar medición'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Debe estar entre 50 y 260'), findsOneWidget);
    expect(repo.enviados, isEmpty);
  });

  testWidgets('una presión válida se envía con sistólica y diastólica',
      (tester) async {
    final repo = await abrir(tester);
    await tester.enterText(find.widgetWithText(TextFormField, 'Sistólica (arriba)'), '128');
    await tester.enterText(find.widgetWithText(TextFormField, 'Diastólica (abajo)'), '80');
    await tester.tap(find.text('Guardar medición'));
    await tester.pumpAndSettle();

    expect(repo.enviados, hasLength(1));
    expect(repo.enviados.single.type, VitalType.bloodPressure);
    expect(repo.enviados.single.value, 128);
    expect(repo.enviados.single.valueSecondary, 80);
  });

  test('la presión se muestra como sistólica/diastólica', () {
    final pa = LatestVital(
      type: VitalType.bloodPressure,
      value: 128,
      valueSecondary: 80,
      measuredAt: DateTime(2026, 1, 1),
      inRange: true,
      source: VitalSource.manual,
    );
    expect(pa.displayValue, '128/80');
  });
}
