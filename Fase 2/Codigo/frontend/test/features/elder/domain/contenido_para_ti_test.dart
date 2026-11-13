// Las tarjetas de "Para ti" en la pantalla del adulto mayor.
import 'package:agecare_app/features/elder/domain/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('cada tipo de la API tiene su etiqueta en espanol', () {
    expect(ContentType.fromApi('joke').label, 'Chiste');
    expect(ContentType.fromApi('exercise').label, 'Ejercicio suave');
  });

  test('un tipo desconocido se muestra como consejo', () {
    expect(ContentType.fromApi('podcast'), ContentType.tip);
  });

  test('se lee en voz alta el titulo y luego el texto', () {
    final item = ContentItem.fromJson(const {
      'id': 'c-1',
      'type': 'news',
      'title': 'Llega la primavera',
      'body': 'Esta semana sube la temperatura',
    });

    expect(item.type, ContentType.news);
    expect(item.spokenText, 'Llega la primavera. Esta semana sube la temperatura');
  });

  test('una tarjeta sin tipo ni textos no rompe la pantalla', () {
    final item = ContentItem.fromJson(const {'id': 'c-2'});

    expect(item.type, ContentType.tip);
    expect(item.title, '');
    expect(item.imageUrl, isNull);
  });
}
