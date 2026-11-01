import 'package:flutter_test/flutter_test.dart';

import 'package:agecare_app/features/marketplace/domain/models.dart';

/// El catálogo del producto.
///
/// `GET /marketplace/products` rechaza con 422 cualquier categoría que no
/// esté en su lista, así que el filtro del chip tiene que mandar exactamente
/// esos códigos; la etiqueta en español es sólo para el humano.
void main() {
  const codigosBackend = [
    'mobility',
    'bathroom',
    'bedroom',
    'hygiene',
    'monitoring',
    'nutrition',
    'other',
  ];

  test('los códigos del catálogo son los que acepta la API', () {
    expect(categoriasProducto.map((c) => c.$1), codigosBackend);
  });

  test('cada código tiene su etiqueta en español', () {
    for (final (codigo, etiqueta) in categoriasProducto) {
      expect(categoriaProducto(codigo), etiqueta);
    }
  });

  test('un código que no conocemos se muestra tal cual, no se inventa', () {
    expect(categoriaProducto('respiratorio'), 'respiratorio');
  });

  test('sin categoría no hay filtro y la pantalla lo dice', () {
    expect(categoriaProducto(null), 'Sin categoría');
    expect(categoriaProducto(''), 'Sin categoría');
  });

  test('el listado del catálogo no se puede mutar desde afuera', () {
    expect(() => categoriasProducto.clear(), throwsUnsupportedError);
  });
}
