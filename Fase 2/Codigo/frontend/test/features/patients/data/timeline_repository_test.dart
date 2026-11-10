import 'package:agecare_app/features/patients/data/timeline_repository.dart';
import 'package:agecare_app/features/patients/domain/timeline.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('el historial se entrega por páginas hasta agotarse, sin repetir',
      () async {
    final repo = TimelineRepositoryMock();
    final vistos = <String>{};
    String? cursor;
    var paginas = 0;
    do {
      final p = await repo.page('p1', cursor: cursor, limit: 20);
      expect(p.items.length, lessThanOrEqualTo(20));
      for (final e in p.items) {
        expect(vistos.add(e.id), isTrue, reason: 'evento repetido ${e.id}');
      }
      cursor = p.nextCursor;
      paginas++;
    } while (cursor != null);

    expect(paginas, greaterThan(1), reason: 'debe haber más de una página');
    expect(vistos.length, greaterThan(20));
  });

  test('viene del más nuevo al más antiguo', () async {
    final p = await TimelineRepositoryMock().page('p1', limit: 50);
    for (var i = 1; i < p.items.length; i++) {
      expect(p.items[i - 1].ts.isBefore(p.items[i].ts), isFalse);
    }
  });

  test('el filtro por tipo solo devuelve ese tipo', () async {
    final p = await TimelineRepositoryMock()
        .page('p1', limit: 50, kinds: [TimelineKind.vital]);
    expect(p.items, isNotEmpty);
    expect(p.items.every((e) => e.kind == TimelineKind.vital), isTrue);
  });
}
