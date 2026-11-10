import 'package:agecare_app/features/medications/application/treatments_providers.dart';
import 'package:agecare_app/features/medications/domain/treatment.dart';

/// Tratamiento vigente fijo para las pruebas de la ficha del médico.
///
/// El repositorio de tratamientos no tiene versión simulada: siempre llama al
/// backend. Sin este reemplazo, el Resumen dispararía una llamada HTTP que en
/// una prueba queda colgando.
final tratamientoFijo = TreatmentBundle(
  bySpecialty: [
    SpecialtyGroup(
      specialty: 'cardiologia',
      current: Treatment(
        treatmentId: 't-1',
        status: 'vigente',
        specialty: 'cardiologia',
        prescriberName: 'Dra. Carmen Orellana',
        effectiveFrom: DateTime(2026, 10, 1),
        items: const [
          TreatmentItem(
            itemId: 'i-1',
            name: 'Losartán',
            dose: '50 mg',
            doseAmount: 50,
            doseUnit: 'mg',
            times: ['08:00', '20:00'],
            daysOfWeek: [1, 2, 3, 4, 5, 6, 7],
            graceWindowMin: 60,
            action: 'kept',
          ),
          TreatmentItem(
            itemId: 'i-2',
            name: 'Paracetamol',
            dose: '500 mg',
            doseAmount: 500,
            doseUnit: 'mg',
            times: [],
            daysOfWeek: [],
            graceWindowMin: 0,
            action: 'kept',
            isPrn: true,
          ),
        ],
      ),
    ),
  ],
);

final tratamientoFijoOverride =
    treatmentsProvider.overrideWith((ref) async => tratamientoFijo);
