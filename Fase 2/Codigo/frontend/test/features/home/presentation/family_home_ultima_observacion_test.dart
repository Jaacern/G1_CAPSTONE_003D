// La tarjeta "Última observación" de la pantalla Hoy del familiar.
//
// Durante mucho tiempo mostró un chip de "Próximamente" diciendo que la
// bitácora no tenía backend, pero `care_observations` y
// GET /patients/{id}/observations (logbook.py) ya existen y el endpoint acepta
// cualquier miembro del paciente, así que la familia puede leerla. Estas
// pruebas montan la pantalla a 320 dp —el teléfono más angosto— para verificar
// a la vez que los datos llegan y que la fila no se desborda.
import 'dart:convert';
import 'dart:typed_data';

import 'package:agecare_app/core/network/api_client.dart';
import 'package:agecare_app/core/storage/token_storage.dart';
import 'package:agecare_app/core/theme/app_theme.dart';
import 'package:agecare_app/features/auth/application/auth_controller.dart';
import 'package:agecare_app/features/auth/domain/models.dart';
import 'package:agecare_app/features/caregiver/data/caregiver_repository.dart';
import 'package:agecare_app/features/home/data/dashboard_repository.dart';
import 'package:agecare_app/features/home/presentation/family_home_screen.dart';
import 'package:agecare_app/features/patients/data/patients_repository.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeTokenStorage extends TokenStorage {
  @override
  Future<String?> get accessToken async => 'token-de-prueba';

  @override
  Future<String?> get refreshToken async => null;

  @override
  Future<void> save({required String access, required String refresh}) async {}

  @override
  Future<void> clear() async {}
}

/// Una observación con la forma exacta de `ObservationOut` del backend.
Map<String, dynamic> _observacion(String id, String hora, String texto) => {
      'id': id,
      'text': texto,
      'category': 'mood',
      'media_url': null,
      'created_at': '2026-11-01T$hora:00Z',
      'author_name': 'Rosa Millán',
    };

/// Servidor falso que responde la bitácora y anota las rutas pedidas.
class _ServidorDeBitacora implements HttpClientAdapter {
  _ServidorDeBitacora(this.items);

  List<Map<String, dynamic>> items;
  final List<String> rutas = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    rutas.add(options.path);
    return ResponseBody.fromString(
      jsonEncode({'items': items}),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

Future<void> montar(WidgetTester tester,
    {required CaregiverRepository repo}) async {
  await tester.binding.setSurfaceSize(const Size(320, 1400));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(ProviderScope(
    overrides: [
      patientsRepositoryProvider.overrideWithValue(PatientsRepositoryMock()),
      dashboardRepositoryProvider.overrideWithValue(DashboardRepositoryMock()),
      caregiverRepositoryProvider.overrideWithValue(repo),
      // El botón SOS lee la sesión; sin esto queda un timer pendiente.
      currentUserProvider.overrideWith((ref) => const User(
            userId: 'u-1',
            fullName: 'Benjamín Camus',
            accountType: RoleType.family,
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
}

void main() {
  testWidgets('muestra la observación más nueva de la cuidadora',
      (tester) async {
    await montar(tester, repo: CaregiverRepositoryMock());

    // El mock siembra dos; la lista viene del más nuevo al más viejo, así que
    // la tarjeta muestra la de las 15:10.
    expect(find.text('Última observación'), findsOneWidget);
    expect(
        find.text('Se notó algo cansada después de la siesta, sin molestias.'),
        findsOneWidget);
    expect(find.text('Rosa Millán'), findsWidgets);
    expect(find.text('Ánimo'), findsOneWidget);

    // Y el aviso falso que ocupaba la tarjeta ya no está.
    expect(find.text('Próximamente'), findsNothing);
  });

  testWidgets('lee la bitácora del endpoint real del familiar', (tester) async {
    final servidor = _ServidorDeBitacora([
      // Orden descendente, igual que `ORDER BY o.observed_at DESC`.
      _observacion('o-3', '18:00', 'Merendó fruta y tomó la medicación.'),
      _observacion('o-2', '15:10', 'Siesta tranquila.'),
    ]);
    final dio = Dio()..httpClientAdapter = servidor;
    await montar(tester,
        repo:
            CaregiverRepositoryHttp(ApiClient(_FakeTokenStorage(), dio: dio)));

    expect(find.text('Merendó fruta y tomó la medicación.'), findsOneWidget);
    // Solo la última: la bitácora completa vive en su propia pantalla.
    expect(find.text('Siesta tranquila.'), findsNothing);
    expect(servidor.rutas, contains('/patients/p-elena/observations'));
  });

  testWidgets('sin observaciones dice la verdad en vez de prometer el futuro',
      (tester) async {
    final dio = Dio()..httpClientAdapter = _ServidorDeBitacora([]);
    await montar(tester,
        repo:
            CaregiverRepositoryHttp(ApiClient(_FakeTokenStorage(), dio: dio)));

    expect(find.textContaining('todavía no ha registrado una observación'),
        findsOneWidget);
  });
}
