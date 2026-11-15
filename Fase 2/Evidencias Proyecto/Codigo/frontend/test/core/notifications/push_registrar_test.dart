import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:agecare_app/core/notifications/push_registrar.dart';
import 'package:agecare_app/features/profile/data/profile_repository.dart';

/// Repositorio que anota lo que se le pide y puede fallar a pedido.
class _RepoEspia implements ProfileRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);

  final registros = <(String token, String plataforma)>[];
  final confirmaciones = <(String id, bool abierta)>[];
  bool fallaRegistro = false;
  bool fallaConfirmacion = false;
  Completer<void>? demora;
  int _n = 0;

  @override
  Future<String?> registerDevice(String pushToken, String platform,
      {String? appVersion}) async {
    registros.add((pushToken, platform));
    if (demora != null) await demora!.future;
    if (fallaRegistro) throw Exception('sin red');
    return 'aparato-${++_n}';
  }

  @override
  Future<void> ackDelivery(String deliveryId, {required bool opened}) async {
    confirmaciones.add((deliveryId, opened));
    if (fallaConfirmacion) throw Exception('sin red');
  }
}

void main() {
  late _RepoEspia repo;
  late StreamController<String> tokens;
  late StreamController<Map<String, dynamic>> recibidos;
  late StreamController<Map<String, dynamic>> toques;
  late PushRegistrar registrar;
  String? token;
  final ids = <String?>[];

  setUp(() {
    repo = _RepoEspia();
    tokens = StreamController<String>.broadcast(sync: true);
    recibidos = StreamController<Map<String, dynamic>>.broadcast(sync: true);
    toques = StreamController<Map<String, dynamic>>.broadcast(sync: true);
    token = null;
    ids.clear();
    registrar = PushRegistrar(
      repo: repo,
      platform: 'android',
      tokens: tokens.stream,
      currentToken: () => token,
      received: recibidos.stream,
      taps: toques.stream,
      onDeviceId: ids.add,
    );
  });

  tearDown(() {
    registrar.dispose();
    tokens.close();
    recibidos.close();
    toques.close();
  });

  /// Deja correr lo que quedó encolado en el bucle de eventos.
  Future<void> asentar() => Future<void>.delayed(Duration.zero);

  group('registro del token', () {
    test('con sesión y token, lo registra con su plataforma', () async {
      token = 'tok-1';
      await registrar.onSignedIn('ana');
      expect(repo.registros, [('tok-1', 'android')]);
      expect(registrar.deviceId, 'aparato-1');
      expect(ids, ['aparato-1']);
    });

    test('sin sesión no registra nada, aunque haya token', () async {
      token = 'tok-1';
      tokens.add('tok-1');
      await asentar();
      expect(repo.registros, isEmpty);
    });

    test('si el token llega después de iniciar sesión, lo registra ahí',
        () async {
      await registrar.onSignedIn('ana');
      expect(repo.registros, isEmpty);
      token = 'tok-1';
      tokens.add('tok-1');
      await asentar();
      expect(repo.registros, [('tok-1', 'android')]);
    });

    test('un token renovado se vuelve a registrar', () async {
      token = 'tok-1';
      await registrar.onSignedIn('ana');
      token = 'tok-2';
      tokens.add('tok-2');
      await asentar();
      expect(repo.registros.map((r) => r.$1), ['tok-1', 'tok-2']);
      expect(registrar.deviceId, 'aparato-2');
    });

    test('el mismo token no se registra dos veces', () async {
      token = 'tok-1';
      await registrar.onSignedIn('ana');
      tokens.add('tok-1');
      await registrar.onSignedIn('ana');
      await asentar();
      expect(repo.registros, hasLength(1));
    });

    test('otra persona en el mismo teléfono registra el token a su nombre',
        () async {
      token = 'tok-1';
      await registrar.onSignedIn('ana');
      registrar.onSignedOut();
      await registrar.onSignedIn('beto');
      // El backend reasigna el token al usuario que lo registra: sin esta
      // segunda llamada, Beto recibiría las alertas del paciente de Ana.
      expect(repo.registros, hasLength(2));
    });

    test('si el registro falla no lanza, y se reintenta más tarde', () async {
      token = 'tok-1';
      repo.fallaRegistro = true;
      await registrar.onSignedIn('ana');
      expect(registrar.deviceId, isNull);

      repo.fallaRegistro = false;
      tokens.add('tok-1');
      await asentar();
      expect(repo.registros, hasLength(2));
      expect(registrar.deviceId, isNotNull);
    });

    test('un token que llega mientras se registra otro no se pierde', () async {
      token = 'tok-1';
      repo.demora = Completer<void>();
      final enCurso = registrar.onSignedIn('ana');
      await asentar();
      token = 'tok-2';
      tokens.add('tok-2');
      repo.demora!.complete();
      repo.demora = null;
      await enCurso;
      await asentar();
      expect(repo.registros.map((r) => r.$1), ['tok-1', 'tok-2']);
    });
  });

  group('cierre de sesión', () {
    test('olvida el aparato, para que la siguiente persona registre el suyo',
        () async {
      token = 'tok-1';
      await registrar.onSignedIn('ana');
      registrar.onSignedOut();
      expect(registrar.deviceId, isNull);
      expect(ids, ['aparato-1', null]);
    });

    test(
        'si se cierra la sesión mientras respondía el servidor, no queda '
        'un aparato a nombre de quien ya salió', () async {
      token = 'tok-1';
      repo.demora = Completer<void>();
      final enCurso = registrar.onSignedIn('ana');
      await asentar();
      registrar.onSignedOut();
      repo.demora!.complete();
      await enCurso;
      expect(registrar.deviceId, isNull);
    });
  });

  group('confirmación de entregas', () {
    test('un push recibido se confirma como entregado', () async {
      await registrar.onSignedIn('ana');
      recibidos.add({'type': 'alert', 'delivery_id': 'ent-1'});
      await asentar();
      expect(repo.confirmaciones, [('ent-1', false)]);
    });

    test('tocar la notificación se confirma como abierta', () async {
      await registrar.onSignedIn('ana');
      toques.add({'type': 'alert', 'delivery_id': 'ent-1'});
      await asentar();
      expect(repo.confirmaciones, [('ent-1', true)]);
    });

    test('la notificación que abrió la aplicación cerrada también', () async {
      await registrar.onSignedIn('ana');
      await registrar.confirmOpened({'delivery_id': 'ent-9'});
      expect(repo.confirmaciones, [('ent-9', true)]);
    });

    test('una notificación local, sin id de entrega, no confirma nada',
        () async {
      await registrar.onSignedIn('ana');
      toques.add({'type': 'dose', 'dose_id': 'd-1'});
      await asentar();
      expect(repo.confirmaciones, isEmpty);
    });

    test('sin sesión no se confirma: no habría con qué autenticarse', () async {
      recibidos.add({'delivery_id': 'ent-1'});
      await asentar();
      expect(repo.confirmaciones, isEmpty);
    });

    test('si la confirmación falla, no lanza', () async {
      await registrar.onSignedIn('ana');
      repo.fallaConfirmacion = true;
      recibidos.add({'delivery_id': 'ent-1'});
      await asentar();
      expect(repo.confirmaciones, hasLength(1));
    });
  });
}
