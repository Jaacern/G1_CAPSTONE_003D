import 'package:agecare_app/core/theme/app_theme.dart';
import 'package:agecare_app/features/health/data/vitals_repository.dart';
import 'package:agecare_app/features/health/presentation/thresholds_screen.dart';
import 'package:agecare_app/features/patients/data/patients_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// La configuración de rangos en 320 dp: cada fila muestra el nombre del
/// signo, su unidad y los dos campos de límite, así que es la pantalla con más
/// texto apretado en un teléfono chico.
void main() {
  testWidgets('las filas de rangos caben en 320 dp', (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(ProviderScope(
      overrides: [
        patientsRepositoryProvider
            .overrideWithValue(PatientsRepositoryMock()),
        vitalsRepositoryProvider.overrideWithValue(VitalsRepositoryMock()),
      ],
      child: MaterialApp(
          theme: AppTheme.light(), home: const ThresholdsScreen()),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('Rangos de alerta'), findsOneWidget);
  });
}
