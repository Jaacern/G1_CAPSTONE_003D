// Prueba de que subir un archivo sirve igual en el navegador que en el
// telefono (RF-06).
//
// Lo que se rompia: el selector de imagenes entrega un XFile, y las pantallas
// lo envolvian en un File de dart:io para subirlo. En el navegador eso no es
// un archivo del disco sino un blob, asi que la ruta no se puede abrir y la
// subida fallaba recien al apretar guardar. La vista previa tenia el mismo
// problema con Image.file.
//
// No se puede correr una prueba de verdad en navegador desde aqui, asi que
// esto cubre las dos cosas que si se pueden comprobar en la VM: que la subida
// trabaje con los bytes y el nombre del XFile en vez de con una ruta, y que
// no quede ninguna pantalla usando las formas que solo andan en telefono.
import 'dart:convert';
import 'dart:io' show Directory, File;
import 'dart:typed_data';

import 'package:agecare_app/core/network/api_client.dart';
import 'package:agecare_app/core/network/upload_service.dart';
import 'package:agecare_app/core/storage/token_storage.dart';
import 'package:agecare_app/core/widgets/vista_previa_archivo.dart';
import 'package:cross_file/cross_file.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// PNG de 1x1 valido, para que Image.memory tenga algo real que decodificar.
final _png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAF'
    'AAH/q842iQAAAABJRU5ErkJggg==');

class _FakeTokenStorage extends TokenStorage {
  @override
  Future<String?> get accessToken async => 'token';
  @override
  Future<String?> get refreshToken async => 'refresh';
  @override
  Future<void> save({required String access, required String refresh}) async {}
  @override
  Future<void> clear() async {}
}

class _Peticion {
  _Peticion(this.metodo, this.url, this.headers, this.cuerpo);
  final String metodo;
  final String url;
  final Map<String, dynamic> headers;
  final Uint8List cuerpo;
}

/// Almacenamiento falso: contesta el POST /uploads y guarda el PUT del
/// binario, sin tocar la red.
class _AdaptadorFalso implements HttpClientAdapter {
  final List<_Peticion> peticiones = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final trozos = <int>[];
    if (requestStream != null) {
      await for (final t in requestStream) {
        trozos.addAll(t);
      }
    }
    peticiones.add(_Peticion(options.method, options.uri.toString(),
        options.headers, Uint8List.fromList(trozos)));

    if (options.path.endsWith('/uploads')) {
      return ResponseBody.fromString(
        '{"upload_id":"u-1","upload_url":"https://blob.test/subir/u-1",'
        '"file_url":"https://api.test/files/11111111-1111-4111-8111-111111111111"}',
        200,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType]
        },
      );
    }
    return ResponseBody.fromString('', 201);
  }

  @override
  void close({bool force = false}) {}

  _Peticion get post => peticiones.firstWhere((p) => p.metodo == 'POST');
  _Peticion get put => peticiones.firstWhere((p) => p.metodo == 'PUT');
  Map<String, dynamic> get cuerpoDelPost =>
      jsonDecode(utf8.decode(post.cuerpo)) as Map<String, dynamic>;
}

({UploadService servicio, _AdaptadorFalso adaptador}) _armar() {
  final adaptador = _AdaptadorFalso();
  Dio dio() => Dio(BaseOptions(baseUrl: 'https://api.test/api/v1'))
    ..httpClientAdapter = adaptador;
  final api = ApiClient(_FakeTokenStorage(), dio: dio(), refreshDio: dio());
  return (servicio: UploadService(api, raw: dio()), adaptador: adaptador);
}

void main() {
  test('sube los bytes del archivo elegido, sin pasar por su ruta', () async {
    final a = _armar();

    // Bytes en memoria y ninguna ruta real en el disco: eso es lo que
    // entrega el selector en el navegador. El nombre viaja aparte, que es de
    // donde la subida tiene que sacarlo.
    final subido = await a.servicio.uploadFile(
      XFile.fromData(_png, path: 'receta.jpg', mimeType: 'image/jpeg'),
      kind: 'prescription',
      patientId: 'p-elena',
    );

    final cuerpo = a.adaptador.cuerpoDelPost;
    expect(cuerpo['filename'], 'receta.jpg',
        reason: 'el nombre sale del XFile y no de una ruta del disco');
    expect(cuerpo['content_type'], 'image/jpeg');
    expect(cuerpo['size'], _png.length);
    expect(cuerpo['kind'], 'prescription');
    expect(cuerpo['patient_id'], 'p-elena');

    expect(a.adaptador.put.cuerpo, _png,
        reason: 'el binario que llega al almacenamiento es el mismo');
    expect(a.adaptador.put.headers['Content-Type'], 'image/jpeg');
    expect(subido.fileUrl, contains('/files/'));
  });

  test('si el nombre no trae extension, usa el tipo que informa la plataforma',
      () async {
    final a = _armar();

    // El caso de la grabadora en navegador: devuelve un blob sin extension.
    await a.servicio.uploadFile(
      XFile.fromData(_png,
          path: 'blob:https://app.test/9f1c', mimeType: 'audio/wav'),
      kind: 'audio',
      patientId: 'p-elena',
    );

    expect(a.adaptador.cuerpoDelPost['content_type'], 'audio/wav');
  });

  test('un tipo que el servidor no acepta no se inventa como imagen',
      () async {
    final a = _armar();

    await a.servicio.uploadFile(
      XFile.fromData(_png, path: 'cualquiera.xyz'),
      kind: 'document',
      patientId: 'p-elena',
    );

    // Mejor que llegue el tipo generico y el servidor lo rechace con su
    // mensaje, que mandar uno falso y guardar basura como si fuera una foto.
    expect(a.adaptador.cuerpoDelPost['content_type'],
        'application/octet-stream');
  });

  testWidgets('la vista previa dibuja el archivo elegido desde sus bytes',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: VistaPreviaArchivo(
        XFile.fromData(_png, path: 'foto.png', mimeType: 'image/png'),
      ),
    ));

    // Primer cuadro: todavia esta leyendo, muestra el marcador.
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    await tester.pump();
    await tester.pump();

    expect(find.byType(Image), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  test('ninguna pantalla vuelve a las formas que solo andan en telefono', () {
    final prohibido = {
      'Image.file(': 'no dibuja nada en el navegador, va VistaPreviaArchivo',
      'File(picked.path)': 'en el navegador lo elegido es un blob, se pasa el '
          'XFile tal cual a uploadFile',
    };

    final ofensores = <String>[];
    for (final f in Directory('lib').listSync(recursive: true)) {
      if (f is! File || !f.path.endsWith('.dart')) continue;
      final texto = f.readAsStringSync();
      for (final p in prohibido.entries) {
        if (texto.contains(p.key)) {
          ofensores.add('${f.path}: ${p.key} -> ${p.value}');
        }
      }
    }

    expect(ofensores, isEmpty,
        reason: 'Estas formas rompen la app en navegador:\n'
            '${ofensores.join('\n')}');
  });
}
