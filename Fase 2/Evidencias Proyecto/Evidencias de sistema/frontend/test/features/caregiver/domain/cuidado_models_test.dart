import 'package:flutter_test/flutter_test.dart';

import 'package:agecare_app/features/caregiver/domain/models.dart';

/// Lo que `tasks.py` y `logbook.py` devuelven en crudo no es lo que se muestra:
/// las categorías vienen como código de base y la hora de la tarea como
/// instante UTC. Estas pruebas dejan fija la traducción de las dos cosas.
void main() {
  group('categorías', () {
    test('la tarjeta traduce el código que devuelve la API', () {
      expect(categoryLabel('hygiene'), 'Higiene');
      expect(categoryLabel('food'), 'Alimentación');
      expect(categoryLabel('activity'), 'Actividad física');
    });

    test('el texto ya traducido del modo demo pasa tal cual',
        () => expect(categoryLabel('Medicación'), 'Medicación'));

    test('un valor fuera del catálogo se muestra legible, no se inventa',
        () => expect(categoryLabel('oter'), 'oter'));

    test('sin categoría no hay etiqueta', () {
      expect(categoryLabel(null), '');
      expect(categoryLabel(''), '');
    });

    test('el formulario normaliza código y etiqueta al mismo código', () {
      expect(categoryCode('hygiene'), 'hygiene');
      expect(categoryCode('Higiene'), 'hygiene');
    });

    test('una categoría desconocida no rellena el desplegable', () {
      // DropdownButton exige que el valor esté entre sus opciones; dejar el
      // valor crudo corta la pantalla con un assert.
      expect(categoryCode('duarato'), isNull);
      expect(categoryCode(null), isNull);
    });

    test('las opciones del desplegable mandan código y muestran etiqueta', () {
      final opciones = categoryOptions(taskCategories);

      expect(opciones.map((c) => c.apiValue), taskCategories);
      expect(opciones.map((c) => c.label), [
        'Higiene',
        'Medicación',
        'Alimentación',
        'Actividad física',
        'Compañía',
        'Otro'
      ]);
    });
  });

  group('hora de la tarea', () {
    test('se muestra en la zona de la cuidadora, no en UTC', () {
      final local = DateTime(2026, 11, 1, 8, 0);
      final tarea = CareTask.fromJson({
        'id': 't1',
        'title': 'Medicación del mediodía',
        'due': local.toUtc().toIso8601String(),
        'status': 'pending',
      });

      expect(tarea.due, local);
      expect(tarea.timeLabel, '08:00');
    });

    test('la medianoche UTC es la señal de tarea de todo el día', () {
      // tasks.py no manda null cuando no hay due_time: arma la medianoche.
      final tarea = CareTask.fromJson({
        'id': 't1',
        'title': 'Paseo',
        'due': '2026-11-01T00:00:00+00:00',
        'status': 'pending',
      });

      expect(tarea.due, isNull);
      expect(tarea.timeLabel, 'Sin hora');
    });

    test('el alta viaja con designación de zona', () {
      // Escrito sin zona, el backend lo lee como UTC y la hora se corre.
      final local = DateTime(2026, 11, 1, 8, 0);
      final cuerpo = NewCareTask(title: 'Baño', due: local).toJson();

      expect(cuerpo['due'], endsWith('Z'));
      expect(DateTime.parse(cuerpo['due'] as String), local.toUtc());
    });

    test('una tarea sin hora no manda el campo', () {
      expect(const NewCareTask(title: 'Baño').toJson().containsKey('due'),
          isFalse);
    });
  });

  group('estado', () {
    test('cancelada se lee como cancelada',
        () => expect(TaskStatus.fromApi('cancelled'), TaskStatus.cancelled));

    test('el estado que llega de la API es siempre done',
        () => expect(TaskStatus.fromApi('done').label, 'Completada'));
  });
}
