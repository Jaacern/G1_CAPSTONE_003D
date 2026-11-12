// Pruebas del modo sin conexion para leer (RF-80).
//
// Lo que tiene que pasar: con conexion se trae del servidor y queda
// guardado; sin conexion se muestra lo guardado y se le dice a la persona de
// cuando es. Y lo que NO tiene que pasar: que un 403 o un 404 saquen datos
// viejos del guardado, porque esas son respuestas del servidor y significan
// algo.
import 'dart:convert';

import 'package:agecare_app/core/network/api_client.dart';
import 'package:agecare_app/core/offline/almacen_local.dart';
import 'package:agecare_app/core/offline/cache_de_lectura.dart';
import 'package:agecare_app/core/offline/estado_de_conexion.dart';
import 'package:agecare_app/core/widgets/aviso_sin_conexion.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Almacen de mentira, en memoria. flutter_secure_storage no tiene
/// implementacion de plataforma dentro de flutter_test.
class _AlmacenDeMentira implements AlmacenCifrado {
  final Map<String, String> datos = {};
  bool revienta = false;

  @override
  Future<void> escribir(String clave, String valor) async {
    if (revienta) throw Exception('almacen no disponible');
    datos[clave] = valor;
  }

  @override
  Future<String?> leer(String clave) async {
    if (revienta) throw Exception('almacen no disponible');
    return datos[clave];
  }

  @override
  Future<void> borrar(String clave) async => datos.remove(clave);

  @override
  Future<List<String>> claves() async => datos.keys.toList();
}

ApiException _sinRed() => ApiException(
    statusCode: 0, code: 'NETWORK_ERROR', message: 'Sin conexión.');

ApiException _prohibido() => ApiException(
    statusCode: 403, code: 'FORBIDDEN', message: 'Ya no tienes acceso.');

/// Una peticion que falla, con el tipo puesto.
///
/// Un `() async => throw x` tiene tipo Future<Never> y el generico de leer()
/// quedaria en Never, que no es lo que pasa en la app: ahi el repositorio
/// pide un Map.
Future<Map<String, dynamic>> _falla(ApiException e) => Future.error(e);

void main() {
  group('almacen local', () {
    test('lo guardado vuelve igual, con su fecha', () async {
      final almacen = AlmacenLocal(_AlmacenDeMentira());
      await almacen.guardar('tablero', {'items': [1, 2, 3]});

      final g = await almacen.leer('tablero');
      expect(g, isNotNull);
      expect(g!.dato, {'items': [1, 2, 3]});
      expect(DateTime.now().difference(g.fecha).inSeconds, lessThan(5));
    });

    test('una clave que nunca se guardo da nulo', () async {
      final almacen = AlmacenLocal(_AlmacenDeMentira());
      expect(await almacen.leer('nada'), isNull);
    });

    test('un guardado ilegible se trata como si no existiera', () async {
      final crudo = _AlmacenDeMentira();
      crudo.datos['${AlmacenLocal.prefijo}tablero'] = 'esto no es json';
      expect(await AlmacenLocal(crudo).leer('tablero'), isNull);
    });

    test('si el almacen falla, no se cae nada', () async {
      final crudo = _AlmacenDeMentira()..revienta = true;
      final almacen = AlmacenLocal(crudo);
      // Ninguna de las dos debe levantar.
      await almacen.guardar('tablero', {'a': 1});
      expect(await almacen.leer('tablero'), isNull);
    });

    test('limpiar borra lo guardado y no la sesion', () async {
      final crudo = _AlmacenDeMentira();
      crudo.datos['agecare_tokens'] = 'no me toques';
      final almacen = AlmacenLocal(crudo);
      await almacen.guardar('tablero', {'a': 1});
      await almacen.guardar('pacientes', {'b': 2});

      await almacen.limpiarTodo();

      expect(crudo.datos.keys, ['agecare_tokens'],
          reason: 'solo se borra lo que empieza con el prefijo propio');
    });
  });

  group('lectura con guardado', () {
    ({CacheDeLectura cache, _AlmacenDeMentira crudo, ProviderContainer c})
        armar() {
      final crudo = _AlmacenDeMentira();
      final c = ProviderContainer();
      addTearDown(c.dispose);
      return (
        cache: CacheDeLectura(
            AlmacenLocal(crudo), c.read(conexionProvider.notifier)),
        crudo: crudo,
        c: c,
      );
    }

    test('con conexion devuelve lo del servidor y lo deja guardado', () async {
      final a = armar();

      final r = await a.cache.leer('tablero', () async => {'items': [1]});

      expect(r, {'items': [1]});
      expect(a.crudo.datos.keys, contains('${AlmacenLocal.prefijo}tablero'));
      expect(a.c.read(conexionProvider).sinConexion, isFalse);
    });

    test('sin conexion devuelve lo guardado y avisa de cuando es', () async {
      final a = armar();
      await a.cache.leer('tablero', () async => {'items': [1]});

      final r = await a.cache.leer('tablero', () => _falla(_sinRed()));

      expect(r, {'items': [1]}, reason: 'se muestra lo ultimo que se supo');
      final estado = a.c.read(conexionProvider);
      expect(estado.sinConexion, isTrue);
      expect(estado.datoMasViejo, isNotNull);
    });

    test('sin conexion y sin nada guardado, deja pasar el error', () async {
      final a = armar();

      await expectLater(
        a.cache.leer('tablero', () => _falla(_sinRed())),
        throwsA(isA<ApiException>()),
      );
      expect(a.c.read(conexionProvider).sinConexion, isTrue);
      expect(a.c.read(conexionProvider).datoMasViejo, isNull,
          reason: 'no se mostro nada guardado, asi que no hay fecha que decir');
    });

    test('un 403 no saca datos viejos del guardado', () async {
      final a = armar();
      await a.cache.leer('tablero', () async => {'items': [1]});

      // A esta persona la sacaron del circulo. Mostrarle el tablero guardado
      // seria taparle que ya no tiene acceso a ese expediente.
      await expectLater(
        a.cache.leer('tablero', () => _falla(_prohibido())),
        throwsA(isA<ApiException>()
            .having((e) => e.code, 'code', 'FORBIDDEN')),
      );
      expect(a.c.read(conexionProvider).sinConexion, isFalse);
    });

    test('se recuerda la fecha del dato mas viejo que se mostro', () async {
      final a = armar();
      // Dos pantallas guardadas, una de hace rato y otra de ahora.
      final ayer = DateTime.now().subtract(const Duration(days: 1));
      a.crudo.datos['${AlmacenLocal.prefijo}dosis'] = jsonEncode(
          {'fecha': ayer.toIso8601String(), 'dato': {'items': []}});
      await a.cache.leer('tablero', () async => {'items': [1]});

      await a.cache.leer('tablero', () => _falla(_sinRed()));
      await a.cache.leer('dosis', () => _falla(_sinRed()));

      final viejo = a.c.read(conexionProvider).datoMasViejo!;
      expect(viejo.difference(ayer).inSeconds.abs(), lessThan(5),
          reason: 'lo honesto es decir que hay algo de ayer');
    });

    test('al volver la conexion se olvida la fecha', () async {
      final a = armar();
      await a.cache.leer('tablero', () async => {'items': [1]});
      await a.cache.leer('tablero', () => _falla(_sinRed()));
      expect(a.c.read(conexionProvider).sinConexion, isTrue);

      await a.cache.leer('tablero', () async => {'items': [2]});

      expect(a.c.read(conexionProvider).sinConexion, isFalse);
      expect(a.c.read(conexionProvider).datoMasViejo, isNull);
    });

    test('la variante sin guardar solo pasa la llamada', () async {
      const cache = CacheDeLectura.sinGuardar();
      expect(await cache.leer('x', () async => {'a': 1}), {'a': 1});
      await expectLater(cache.leer('x', () => _falla(_sinRed())),
          throwsA(isA<ApiException>()),
          reason: 'sin almacen no hay nada a lo que caer');
    });
  });

  group('el aviso', () {
    test('dice la hora si el dato es de hoy', () {
      final ahora = DateTime(2026, 11, 12, 18, 0);
      expect(textoDelAviso(DateTime(2026, 11, 12, 14, 30), ahora: ahora),
          contains('de las 14:30'));
    });

    test('dice ayer si es de ayer', () {
      final ahora = DateTime(2026, 11, 12, 9, 0);
      expect(textoDelAviso(DateTime(2026, 11, 11, 22, 5), ahora: ahora),
          contains('de ayer a las 22:05'));
    });

    test('dice la fecha si es de antes', () {
      final ahora = DateTime(2026, 11, 12, 9, 0);
      final t = textoDelAviso(DateTime(2026, 11, 3, 8, 15), ahora: ahora);
      expect(t, contains('3 de noviembre'));
      expect(t, contains('08:15'));
    });

    test('sin dato guardado no inventa una hora', () {
      expect(textoDelAviso(null), isNot(contains(':')));
    });

    testWidgets('no ocupa alto mientras hay conexion', (tester) async {
      await tester.pumpWidget(const ProviderScope(
          child: MaterialApp(home: Scaffold(body: AvisoSinConexion()))));

      expect(find.byIcon(Icons.cloud_off_rounded), findsNothing);
      expect(tester.getSize(find.byType(AvisoSinConexion)).height, 0);
    });

    testWidgets('sin conexion aparece y dice de cuando son los datos',
        (tester) async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      c.read(conexionProvider.notifier).perdida(
          fechaDelDato: DateTime.now().subtract(const Duration(hours: 2)));

      await tester.pumpWidget(UncontrolledProviderScope(
        container: c,
        child: const MaterialApp(home: Scaffold(body: AvisoSinConexion())),
      ));

      expect(find.byIcon(Icons.cloud_off_rounded), findsOneWidget);
      expect(find.textContaining('Sin conexión'), findsOneWidget);
      expect(find.textContaining('información guardada'), findsOneWidget);
    });

    testWidgets('la version del adulto mayor usa una frase corta',
        (tester) async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      c.read(conexionProvider.notifier)
          .perdida(fechaDelDato: DateTime(2026, 11, 12, 10, 5));

      await tester.pumpWidget(UncontrolledProviderScope(
        container: c,
        child: const MaterialApp(
            home: Scaffold(body: AvisoSinConexion(grande: true))),
      ));

      expect(find.text('Sin internet. Esto es de las 10:05.'), findsOneWidget);
      final texto = tester.widget<Text>(find.byType(Text));
      expect(texto.style!.fontSize, greaterThanOrEqualTo(18),
          reason: 'en la vista del adulto mayor la letra va grande (RNF-19)');
    });
  });
}
