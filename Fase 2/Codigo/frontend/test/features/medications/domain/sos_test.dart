// Las indicaciones SOS ("solo si se necesita").
import 'package:agecare_app/features/medications/domain/_prn.dart';
import 'package:flutter_test/flutter_test.dart';

PrnItem _sos({double? maxDaily, double usado = 0, DateTime? proxima}) =>
    PrnItem(
      itemId: 'i-1',
      name: 'Bromuro de ipratropio',
      dose: '2 puff',
      doseAmount: 2,
      doseUnit: 'puff',
      specialty: 'broncopulmonar',
      minIntervalMin: 360,
      maxDaily: maxDaily,
      usedLast24h: usado,
      nextAllowedAt: proxima,
    );

void main() {
  test('no se puede dar si pasaria el maximo de 24 horas', () {
    expect(_sos(maxDaily: 8, usado: 6).alcanzoMaximo, isFalse); // 6 + 2 = 8
    expect(_sos(maxDaily: 8, usado: 7).alcanzoMaximo, isTrue); // 7 + 2 > 8
  });

  test('sin maximo indicado nunca lo alcanza', () {
    expect(_sos(usado: 100).alcanzoMaximo, isFalse);
  });

  test('avisa si todavia no se cumple el intervalo', () {
    final ahora = DateTime(2026, 11, 12, 10);
    final sos = _sos(proxima: DateTime(2026, 11, 12, 12));

    expect(sos.antesDeTiempo(ahora), isTrue);
    expect(sos.antesDeTiempo(DateTime(2026, 11, 12, 13)), isFalse);
    expect(_sos().antesDeTiempo(ahora), isFalse);
  });

  test('el intervalo se lee en horas cuando es exacto', () {
    expect(_sos().intervaloLegible, 'cada 6 h');
    expect(intervaloTexto(90), 'cada 90 min');
  });
}
