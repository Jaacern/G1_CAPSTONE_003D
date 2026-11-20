import 'package:flutter_test/flutter_test.dart';

import 'package:agecare_app/features/marketplace/domain/models.dart';

Map<String, dynamic> _productoJson(Map<String, dynamic> extra) => {
      'id': 'p-1',
      'name': 'Andadera plegable',
      'price': 12000,
      'category': 'mobility',
      'description': 'Andadera de aluminio.',
      ...extra,
    };

void main() {
  group('precio del catálogo', () {
    test('los miles se separan con punto, como se lee en Chile', () {
      final p = MarketProduct.fromJson(_productoJson({}));

      expect(p.precioLabel, '\$12.000');
    });

    test('la moneda viaja con el producto', () {
      final p = MarketProduct.fromJson(_productoJson({'currency': 'usd'}));

      expect(p.currency, 'USD');
      expect(p.precioLabel, 'USD 12.000');
    });

    test('sin moneda se asume la de la tabla, CLP', () {
      final p = MarketProduct.fromJson(_productoJson({'currency': null}));

      expect(p.currency, 'CLP');
    });

    test('un producto sin precio sale en cero y no reviente la tarjeta', () {
      final p = MarketProduct.fromJson(_productoJson({'price': null}));

      expect(p.price, 0);
      expect(p.precioLabel, '\$0');
    });
  });

  group('tarifa por hora', () {
    test('se formatea con separador de miles', () {
      const resumen = CaregiverProfileSummary(
        profileId: 'cg-1',
        name: 'María',
        headline: '',
        rating: 5,
        reviewsCount: 1,
        pricePerHour: 12000,
      );

      expect(resumen.tarifaLabel, '\$12.000');
    });

    test('quiere decir que no publicó tarifa', () {
      const resumen = CaregiverProfileSummary(
        profileId: 'cg-2',
        name: 'Rosa',
        headline: '',
        rating: 4,
        reviewsCount: 0,
      );

      expect(resumen.tarifaLabel, isNull);
    });
  });
}
