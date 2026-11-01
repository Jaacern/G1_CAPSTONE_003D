import 'package:flutter_test/flutter_test.dart';

import 'package:agecare_app/features/marketplace/domain/models.dart';

/// /marketplace/caregivers/{id} devuelve `created_at` con su desplazamiento de
/// zona; la ficha imprime esa fecha, así que tiene que quedar en hora local.
void main() {
  group('Review', () {
    test('la reseña en UTC se lee en la zona de la máquina', () {
      const crudo = '2026-10-31T02:00:00+00:00';
      final resena = Review.fromJson({
        'author_name': 'Ana P.',
        'rating': 5,
        'comment': 'Muy atenta.',
        'created_at': crudo,
      });

      expect(resena.createdAt.isUtc, isFalse);
      expect(resena.createdAt, DateTime.parse(crudo).toLocal());
    });

    test('el instante no cambia al pasar a hora local', () {
      const crudo = '2026-10-31T02:00:00Z';
      final resena = Review.fromJson({'created_at': crudo});

      expect(resena.createdAt.millisecondsSinceEpoch,
          DateTime.parse(crudo).millisecondsSinceEpoch);
    });

    test('una reseña sin fecha se muestra como de ahora', () {
      final resena = Review.fromJson({'author_name': 'Ana', 'rating': 4});

      expect(
          resena.createdAt
              .isAfter(DateTime.now().subtract(const Duration(seconds: 5))),
          isTrue);
    });
  });
}
