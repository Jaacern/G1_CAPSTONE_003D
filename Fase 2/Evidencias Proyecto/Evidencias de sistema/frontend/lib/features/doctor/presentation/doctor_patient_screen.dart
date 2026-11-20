import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/common.dart';
import '../../health/application/health_providers.dart';
import '../../health/domain/models.dart' as health;
import '../../medications/application/medications_providers.dart';
import '../../medications/application/treatments_providers.dart';
import '../../medications/domain/treatment.dart';
import '../../patients/application/patients_providers.dart';
import '../../patients/domain/models.dart';
import '../../documents/presentation/patient_documents_view.dart';
import '../../patients/presentation/patient_timeline.dart';
import '../../../core/widgets/bloques.dart';

/// Ficha clínica del paciente para el rol médico (solo lectura del historial +
/// recetar). Toda la información viene de endpoints existentes:
/// - GET /patients/{id}/vitals/latest      (signos vitales actuales)
/// - GET /patients/{id}/medications        (medicación activa)
/// - GET /patients/{id}/adherence          (adherencia de los últimos 7 días)
/// - GET /patients/{id}/observations       (notas del círculo de cuidado)
/// - POST /patients/{id}/medications       (recetar; el backend guarda
///   prescribed_by cuando el rol es doctor)
class DoctorPatientScreen extends ConsumerWidget {
  const DoctorPatientScreen({super.key, required this.patientId});

  final String patientId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final patient = ref.watch(selectedPatientProvider);
    // Edad, sexo y enfermedades: van aparte porque el listado de pacientes no
    // los trae completos, solo el detalle.
    final detalle = ref.watch(selectedPatientDetailProvider);
    final name = patient?.fullName ?? 'Paciente';

    // Ficha organizada en pestañas para que el médico llegue y ubique todo sin
    // una columna infinita. La cabecera del paciente queda fija arriba.
    return DefaultTabController(
      length: 5,
      child: Scaffold(
        appBar: AppBar(
          title: Text(name),
          actions: [
            // Acceso al perfil completo: botón con texto, visible arriba a la
            // derecha. Un ícono suelto no decía a dónde llevaba.
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: FilledButton.tonalIcon(
                onPressed: () =>
                    context.push('/patient/profile?patient=$patientId'),
                icon: const Icon(Icons.contact_page_outlined),
                label: const Text('Perfil completo'),
                style: FilledButton.styleFrom(
                  minimumSize: const Size(0, 44),
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  textStyle: const TextStyle(
                      fontSize: 14.5, fontWeight: FontWeight.w700),
                ),
              ),
            ),
          ],
          bottom: const TabBar(
            isScrollable: true,
            tabs: [
              Tab(text: 'Resumen'),
              Tab(text: 'Tratamientos'),
              Tab(text: 'Controles'),
              Tab(text: 'Historial'),
              Tab(text: 'Documentos'),
            ],
          ),
        ),
        body: Column(
          children: [
            // Lo primero que se lee en cualquier pestaña: cómo está el
            // paciente y por qué. Edad, sexo y el resto de la identificación
            // viven en "Datos del paciente", al final del Resumen.
            if (patient != null) _Contexto(patient: patient),
            Expanded(
              child: TabBarView(
                children: [
                  _ResumenTab(
                    patientId: patientId,
                    patient: patient,
                    detalle: detalle.valueOrNull,
                  ),
                  _TratamientosTab(patientId: patientId),
                  const _ControlesTab(),
                  // Historial con scroll: bitácora, dosis, signos vitales,
                  // alertas y tratamientos en una sola línea de tiempo.
                  PatientTimeline(patientId: patientId),
                  _DocumentosTab(patientId: patientId),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Resumen ordenado por lo que el médico necesita para decidir, de lo más
/// urgente a lo de contexto:
///   1. Alergias: una alergia no vista puede ser fatal al indicar un fármaco.
///   2. Signos vitales: cómo está ahora.
///   3. Antecedentes y niveles de riesgo: con qué carga clínica llega.
///   4. Tratamiento vigente y adherencia: qué toma y si lo está tomando.
///   5. Contacto de emergencia: a quién llamar.
///   6. Datos del paciente: identificación y contexto (edad, sexo, RUT...).
/// El estado (semáforo y motivo) va fijo arriba, fuera de esta lista.
class _ResumenTab extends ConsumerWidget {
  const _ResumenTab(
      {required this.patientId, required this.patient, required this.detalle});
  final String patientId;
  final PatientCard? patient;
  final Patient? detalle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final latestVitals = ref.watch(latestVitalsProvider);
    final adherence = ref.watch(adherenceProvider);
    final condiciones = detalle?.conditionLabels ?? const <String>[];
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
      children: [
        const EncabezadoDeSeccion('Alergias'),
        _AlergiasResumen(
          detalle: detalle?.allergies ?? const [],
          mini: patient?.allergies ?? const [],
        ),
        const EncabezadoDeSeccion('Signos vitales actuales'),
        _SignosVitalesResumen(latestVitals: latestVitals),
        const EncabezadoDeSeccion('Antecedentes'),
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (condiciones.isEmpty)
                const Text('Sin enfermedades registradas.',
                    style: TextStyle(color: AppColors.textSecondary))
              else
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final c in condiciones) _Antecedente(texto: c),
                  ],
                ),
              if (detalle != null) ...[
                const SizedBox(height: 12),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    _Nivel(
                        etiqueta: 'Complejidad',
                        valor: detalle!.complexity,
                        alto: 'alta',
                        medio: 'moderada'),
                    _Nivel(
                        etiqueta: 'Prioridad',
                        valor: detalle!.priority,
                        alto: 'alta',
                        medio: 'media'),
                    _Nivel(
                        etiqueta: 'Riesgo CV',
                        valor: detalle!.rcvLevel,
                        alto: 'alto',
                        medio: 'moderado'),
                  ],
                ),
              ],
            ],
          ),
        ),
        Row(
          children: [
            const Expanded(child: EncabezadoDeSeccion('Tratamiento vigente')),
            TextButton(
              onPressed: () => DefaultTabController.of(context).animateTo(1),
              child: const Text('Ver detalle'),
            ),
          ],
        ),
        const _TratamientoResumen(),
        const EncabezadoDeSeccion('Adherencia (últimos 7 días)'),
        adherence.when(
          loading: () =>
              const AppCard(child: SizedBox(height: 70, child: LoadingView())),
          error: (_, __) => AppCard(
            child: ErrorView(
              message: 'No se pudo calcular la adherencia.',
              onRetry: () => ref.invalidate(adherenceProvider),
            ),
          ),
          data: (adh) {
            if (adh == null) return const SizedBox.shrink();
            return AppCard(
              child: Row(
                children: [
                  Text('${adh.pct.round()}%',
                      style: const TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.w800,
                        color: AppColors.primary,
                      )),
                  const SizedBox(width: 16),
                  const Expanded(
                    child: Text('de las dosis registradas en la semana',
                        style: TextStyle(color: AppColors.textSecondary)),
                  ),
                ],
              ),
            );
          },
        ),
        const EncabezadoDeSeccion('Contacto de emergencia'),
        _ContactoEmergenciaResumen(patientId: patientId),
        if (detalle != null) ...[
          const EncabezadoDeSeccion('Datos del paciente'),
          _DatosPaciente(detalle: detalle!),
        ],
      ],
    );
  }
}

/// Signos vitales actuales, uno por fila con su valor y si está en rango.
class _SignosVitalesResumen extends ConsumerWidget {
  const _SignosVitalesResumen({required this.latestVitals});

  final AsyncValue<List<health.LatestVital>> latestVitals;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return latestVitals.when(
      loading: () =>
          const AppCard(child: SizedBox(height: 70, child: LoadingView())),
      error: (_, __) => AppCard(
        child: ErrorView(
          message: 'No se pudieron cargar las constantes.',
          onRetry: () => ref.invalidate(latestVitalsProvider),
        ),
      ),
      data: (vitals) {
        final withData = vitals.where((v) => v.hasData).toList();
        if (withData.isEmpty) {
          return const AppCard(
            child: Text(
              'Aún no hay lecturas para este paciente.',
              style: TextStyle(color: AppColors.textSecondary),
            ),
          );
        }
        return AppCard(
          padding: EdgeInsets.zero,
          child: Column(
            children: [
              for (var i = 0; i < withData.length; i++) ...[
                if (i != 0) const Divider(height: 1),
                _VitalTile(vital: withData[i]),
              ],
            ],
          ),
        );
      },
    );
  }
}

/// Alergias con su gravedad y reacción. Las graves van en rojo. Sin alergias
/// se dice explícitamente, para que el médico no confunda "no hay" con "no
/// cargó".
class _AlergiasResumen extends StatelessWidget {
  const _AlergiasResumen({required this.detalle, required this.mini});

  /// Del detalle del paciente: trae gravedad y reacción.
  final List<AllergyDetail> detalle;

  /// De la tarjeta del listado: respaldo si el detalle aún no llega.
  final List<AllergyMini> mini;

  @override
  Widget build(BuildContext context) {
    final items = detalle.isNotEmpty
        ? [
            for (final a in detalle)
              (a.label, a.severity, a.reaction, a.esGrave),
          ]
        : [for (final a in mini) (a.label, a.severity, null, a.esGrave)];

    if (items.isEmpty) {
      return const AppCard(
        child: Row(
          children: [
            Icon(Icons.check_circle_outline_rounded,
                color: AppColors.statusOk, size: 20),
            SizedBox(width: 10),
            Expanded(
              child: Text('Sin alergias registradas.',
                  style: TextStyle(color: AppColors.textSecondary)),
            ),
          ],
        ),
      );
    }

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < items.length; i++) ...[
            if (i > 0) const SizedBox(height: 10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.warning_amber_rounded,
                    size: 18,
                    color:
                        items[i].$4 ? AppColors.critical : AgeColors.warn700),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${items[i].$1} · ${allergySeverityLabel(items[i].$2)}',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: items[i].$4
                              ? AppColors.critical
                              : AgeColors.warn700,
                        ),
                      ),
                      if ((items[i].$3 ?? '').isNotEmpty)
                        Text('Reacción: ${items[i].$3}',
                            style: const TextStyle(
                                fontSize: 12.5,
                                color: AppColors.textSecondary)),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// Nivel de complejidad, prioridad o riesgo como etiqueta de color. Sin
/// valor dice "sin definir" en vez de esconderse: que falte también es un dato.
class _Nivel extends StatelessWidget {
  const _Nivel({
    required this.etiqueta,
    required this.valor,
    required this.alto,
    required this.medio,
  });

  final String etiqueta;
  final String? valor;
  final String alto;
  final String medio;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final (fondo, texto) = switch (valor) {
      null => (cs.surfaceContainerHighest, cs.onSurfaceVariant),
      final v when v == alto => (
          AppColors.critical.withValues(alpha: .12),
          AppColors.critical
        ),
      final v when v == medio => (
          AppColors.statusWarning.withValues(alpha: .15),
          AgeColors.warn700
        ),
      _ => (AppColors.statusOk.withValues(alpha: .12), AppColors.statusOk),
    };
    final v = valor == null
        ? 'sin definir'
        : valor![0].toUpperCase() + valor!.substring(1);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: fondo,
        borderRadius: BorderRadius.circular(AgeRadius.full),
      ),
      child: Text('$etiqueta: $v',
          style: TextStyle(
              fontSize: 12, fontWeight: FontWeight.w700, color: texto)),
    );
  }
}

/// Fármacos vigentes de todas las especialidades, en una línea cada uno.
/// El detalle (quién lo indicó, desde cuándo, cambiar el esquema) sigue en la
/// pestaña Tratamientos.
class _TratamientoResumen extends ConsumerWidget {
  const _TratamientoResumen();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bundle = ref.watch(treatmentsProvider);
    return bundle.when(
      loading: () =>
          const AppCard(child: SizedBox(height: 50, child: LoadingView())),
      error: (_, __) => AppCard(
        child: Row(
          children: [
            const Expanded(
              child: Text('No se pudo cargar el tratamiento.',
                  style: TextStyle(color: AppColors.textSecondary)),
            ),
            TextButton(
              onPressed: () => ref.invalidate(treatmentsProvider),
              child: const Text('Reintentar'),
            ),
          ],
        ),
      ),
      data: (b) {
        final grupos = b.vigentes;
        if (grupos.isEmpty) {
          return const AppCard(
            child: Text('Sin tratamientos vigentes.',
                style: TextStyle(color: AppColors.textSecondary)),
          );
        }
        return AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final g in grupos) ...[
                Padding(
                  padding: const EdgeInsets.only(top: 4, bottom: 4),
                  child: Text(specialtyLabel(g.specialty),
                      style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: AppColors.textSecondary)),
                ),
                for (final it in g.current!.items)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                            it.isPrn
                                ? Icons.emergency_rounded
                                : Icons.medication_rounded,
                            size: 18,
                            color: it.isPrn
                                ? AppColors.statusWarning
                                : AppColors.primary),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text.rich(
                            TextSpan(children: [
                              TextSpan(
                                  text: it.name,
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w700)),
                              TextSpan(
                                text: it.isPrn
                                    ? '  ${it.dose} · SOS, solo si se necesita'
                                    : '  ${it.dose} · ${it.times.join(', ')}',
                                style: const TextStyle(
                                    color: AppColors.textSecondary),
                              ),
                            ]),
                            style: const TextStyle(fontSize: 13.5),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ],
          ),
        );
      },
    );
  }
}

/// Identificación y datos de contexto: edad, sexo, RUT, previsión, domicilio,
/// peso e IMC, y quién lo vio por última vez.
class _DatosPaciente extends StatelessWidget {
  const _DatosPaciente({required this.detalle});

  final Patient detalle;

  /// El backend manda female/male/other y hay datos con una sola letra
  /// (F, M, O): se mira la inicial para aceptar ambas formas.
  static String _sexo(String? s) {
    if (s == null || s.isEmpty) return '—';
    return switch (s[0].toUpperCase()) {
      'M' => 'Masculino',
      'F' => 'Femenino',
      _ => 'Otro',
    };
  }

  static String _prevision(String? v) => switch (v) {
        'fonasa' => 'Fonasa',
        'isapre' => 'Isapre',
        'particular' => 'Particular',
        'otra' => 'Otra',
        _ => 'No informada',
      };

  static String _fecha(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';

  static String _decimal(double v) => v.toStringAsFixed(1).replaceAll('.', ',');

  @override
  Widget build(BuildContext context) {
    final m = detalle.latestMeasurement;
    final medicion = m == null
        ? 'Sin mediciones'
        : [
            if (m.weightKg != null) '${_decimal(m.weightKg!)} kg',
            if (m.bmi != null) 'IMC ${_decimal(m.bmi!)}',
          ].join(' · ');
    final ultimo = detalle.lastSeenBy;
    final filas = <(IconData, String, String)>[
      (Icons.cake_outlined, 'Edad', '${detalle.age} años'),
      (Icons.wc_outlined, 'Sexo', _sexo(detalle.sex)),
      (Icons.badge_outlined, 'RUT', detalle.rut ?? '—'),
      (
        Icons.verified_user_outlined,
        'Previsión',
        _prevision(detalle.insurance)
      ),
      (
        Icons.home_outlined,
        'Domicilio',
        (detalle.address ?? '').isEmpty ? '—' : detalle.address!
      ),
      (Icons.monitor_weight_outlined, 'Peso', medicion),
      if (ultimo != null)
        (
          Icons.medical_services_outlined,
          'Último médico',
          [
            ultimo.name,
            if ((ultimo.specialty ?? '').isNotEmpty)
              specialtyLabel(ultimo.specialty!),
            if (ultimo.date != null) _fecha(ultimo.date!),
          ].join(' · ')
        ),
    ];
    return AppCard(
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          for (var i = 0; i < filas.length; i++) ...[
            if (i > 0) const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(filas[i].$1, size: 18, color: AppColors.textSecondary),
                  const SizedBox(width: 10),
                  SizedBox(
                    width: 92,
                    child: Text(filas[i].$2,
                        style: const TextStyle(
                            fontSize: 13, color: AppColors.textSecondary)),
                  ),
                  Expanded(
                    child: Text(filas[i].$3,
                        style: const TextStyle(
                            fontSize: 13.5, fontWeight: FontWeight.w600)),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Contactos de emergencia activos, con botón para llamar.
class _ContactoEmergenciaResumen extends ConsumerWidget {
  const _ContactoEmergenciaResumen({required this.patientId});

  final String patientId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final contactos = ref.watch(emergencyContactsProvider(patientId));
    return contactos.when(
      loading: () =>
          const AppCard(child: SizedBox(height: 50, child: LoadingView())),
      error: (_, __) => const AppCard(
        child: Text('No se pudieron cargar los contactos.',
            style: TextStyle(color: AppColors.textSecondary)),
      ),
      data: (lista) {
        final activos = lista.where((c) => c.isActive).toList();
        if (activos.isEmpty) {
          return const AppCard(
            child: Text('Sin contacto de emergencia activo.',
                style: TextStyle(color: AppColors.textSecondary)),
          );
        }
        return AppCard(
          padding: EdgeInsets.zero,
          child: Column(
            children: [
              for (var i = 0; i < activos.length; i++) ...[
                if (i > 0) const Divider(height: 1),
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 6, 4, 6),
                  child: Row(
                    children: [
                      const Icon(Icons.person_outline_rounded,
                          size: 18, color: AppColors.textSecondary),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(activos[i].name,
                                style: const TextStyle(
                                    fontSize: 13.5,
                                    fontWeight: FontWeight.w600)),
                            if ((activos[i].phone ?? '').isNotEmpty)
                              Text(activos[i].phone!,
                                  style: const TextStyle(
                                      fontSize: 12.5,
                                      color: AppColors.textSecondary)),
                          ],
                        ),
                      ),
                      if ((activos[i].phone ?? '').isNotEmpty)
                        IconButton(
                          tooltip: 'Llamar a ${activos[i].name}',
                          icon: const Icon(Icons.call_rounded,
                              color: AppColors.statusOk),
                          onPressed: () =>
                              launchUrl(Uri.parse('tel:${activos[i].phone}')),
                        ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

/// Tratamientos por especialidad + nuevo tratamiento + acceso al historial.
class _TratamientosTab extends ConsumerWidget {
  const _TratamientosTab({required this.patientId});
  final String patientId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final treatment = ref.watch(treatmentsProvider);
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        Row(
          children: [
            const Expanded(
                child: EncabezadoDeSeccion('Tratamientos por especialidad')),
            TextButton.icon(
              onPressed: () =>
                  context.push('/treatment/history?patient=$patientId'),
              icon: const Icon(Icons.history_rounded, size: 18),
              label: const Text('Historial'),
            ),
          ],
        ),
        treatment.when(
          loading: () =>
              const AppCard(child: SizedBox(height: 70, child: LoadingView())),
          error: (_, __) => AppCard(
            child: ErrorView(
              message: 'No se pudo cargar el tratamiento.',
              onRetry: () => ref.invalidate(treatmentsProvider),
            ),
          ),
          data: (bundle) {
            final grupos = bundle.vigentes;
            return Column(
              children: [
                if (grupos.isEmpty)
                  const AppCard(
                    child: Text('Aún no hay tratamientos definidos.',
                        style: TextStyle(color: AppColors.textSecondary)),
                  ),
                for (final g in grupos)
                  _SpecialtyTreatmentCard(
                    group: g,
                    patientId: patientId,
                    onChanged: () => ref.invalidate(treatmentsProvider),
                  ),
              ],
            );
          },
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: () => _nuevaEspecialidad(context, ref, patientId),
          icon: const Icon(Icons.add_rounded),
          label: const Text('Nuevo tratamiento (otra especialidad)'),
        ),
      ],
    );
  }
}

/// Controles / consultas clínicas. Entidad propia en la Fase 6; por ahora
/// placeholder honesto en vez de prometer lo que aún no existe.
class _ControlesTab extends StatelessWidget {
  const _ControlesTab();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(24),
        child: EmptyView(
          icon: Icons.event_note_rounded,
          title: 'Controles clínicos',
          subtitle:
              'Aquí irán las consultas con fecha, profesional, mediciones y '
              'próximo control. En construcción.',
        ),
      ),
    );
  }
}

/// Documentos del expediente a la mano, con buscador y categorías. Antes era
/// un botón que abría otra pantalla para recién ver la lista.
class _DocumentosTab extends StatelessWidget {
  const _DocumentosTab({required this.patientId});
  final String patientId;

  @override
  Widget build(BuildContext context) =>
      PatientDocumentsView(patientId: patientId);
}

class _VitalTile extends StatelessWidget {
  const _VitalTile({required this.vital});

  final health.LatestVital vital;

  @override
  Widget build(BuildContext context) {
    final color =
        vital.inRange ? AppColors.textPrimary : AppColors.statusAttention;
    final type = vital.type;
    return ListTile(
      leading: Icon(type.icon, color: AppColors.primary),
      title: Text(type.label),
      subtitle: Text(_timeAgo(vital.measuredAt)),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '${vital.value.round()} ${type.unit}',
            style: TextStyle(
                fontSize: 16, fontWeight: FontWeight.w700, color: color),
          ),
          if (!vital.inRange) ...[
            const SizedBox(width: 6),
            const Icon(Icons.error_rounded,
                size: 18, color: AppColors.statusAttention),
          ],
        ],
      ),
    );
  }
}

// La gestión de medicación del médico pasó al modelo de tratamientos
// (treatment_editor_screen / treatment_history_screen). Se quitó la edición
// fármaco a fármaco a propósito: el médico cambia el esquema completo.

/// Tarjeta de un tratamiento vigente de una especialidad: qué área, qué médico
/// lo definió, los fármacos, y el botón para cambiar el esquema de esa área.
class _SpecialtyTreatmentCard extends StatelessWidget {
  const _SpecialtyTreatmentCard({
    required this.group,
    required this.patientId,
    required this.onChanged,
  });

  final SpecialtyGroup group;
  final String patientId;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final t = group.current!;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: AppCard(
        padding: EdgeInsets.zero,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 8, 6),
              child: Row(
                children: [
                  const Icon(Icons.local_hospital_rounded,
                      size: 18, color: AppColors.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(specialtyLabel(t.specialty),
                            style: const TextStyle(
                                fontWeight: FontWeight.w700, fontSize: 14)),
                        if ((t.prescriberName ?? '').isNotEmpty)
                          Text('Médico: ${t.prescriberName}',
                              style: const TextStyle(
                                  fontSize: 12,
                                  color: AppColors.textSecondary)),
                        Text(
                          t.reviewDate == null
                              ? 'Permanente'
                              : 'Hasta ${_fechaCorta(t.reviewDate!)}',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: t.reviewDate == null
                                ? AppColors.statusOk
                                : AppColors.statusWarning,
                          ),
                        ),
                      ],
                    ),
                  ),
                  TextButton(
                    onPressed: () async {
                      await context.push(
                          '/treatment?patient=$patientId&specialty=${t.specialty}');
                      onChanged();
                    },
                    child: const Text('Cambiar'),
                  ),
                ],
              ),
            ),
            for (final it in t.items) ...[
              const Divider(height: 1),
              ListTile(
                dense: true,
                leading: Icon(
                    it.isPrn
                        ? Icons.emergency_rounded
                        : Icons.medication_rounded,
                    color:
                        it.isPrn ? AppColors.statusWarning : AppColors.primary),
                title: Row(
                  children: [
                    Flexible(child: Text(it.name)),
                    if (it.isPrn) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 1),
                        decoration: BoxDecoration(
                          color: AppColors.statusWarning.withValues(alpha: .15),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Text('SOS',
                            style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                                color: AppColors.statusWarning)),
                      ),
                    ],
                  ],
                ),
                subtitle: Text(
                    it.isPrn
                        ? '${it.dose} · solo si se necesita'
                        : '${it.dose} · ${it.times.join(', ')}'
                            '${(it.scheduleLabel ?? '').isNotEmpty ? ' (${it.scheduleLabel})' : ''}',
                    style: const TextStyle(
                        fontSize: 12, color: AppColors.textSecondary)),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Selector de especialidad para iniciar un tratamiento de un área nueva.
Future<void> _nuevaEspecialidad(
    BuildContext context, WidgetRef ref, String patientId) async {
  final elegida = await showModalBottomSheet<String>(
    context: context,
    builder: (ctx) => SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text('¿Para qué especialidad?',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
          ),
          for (final e in kEspecialidades)
            ListTile(
              leading: const Icon(Icons.local_hospital_outlined),
              title: Text(specialtyLabel(e)),
              onTap: () => Navigator.of(ctx).pop(e),
            ),
        ],
      ),
    ),
  );
  if (elegida == null) return;
  if (context.mounted) {
    await context.push('/treatment?patient=$patientId&specialty=$elegida');
    ref.invalidate(treatmentsProvider);
  }
}

class _Contexto extends StatelessWidget {
  const _Contexto({required this.patient});

  final PatientCard patient;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final estado = patient.wellbeingStatus;
    final motivo = (patient.topReason ?? '').trim();
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      decoration: BoxDecoration(
        // colorScheme resuelve claro/oscuro; los AppColors fijos dejaban esta
        // barra blanca en modo oscuro.
        color: motivo.isEmpty ? cs.surface : estado.tint,
        border: Border(bottom: BorderSide(color: cs.outlineVariant, width: 1)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text('Estado',
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: motivo.isEmpty ? cs.onSurfaceVariant : estado.onTint)),
          const SizedBox(width: 10),
          WellbeingChip(status: estado),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              motivo.isEmpty ? 'Sin alertas activas' : motivo,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                  color: motivo.isEmpty ? cs.onSurfaceVariant : estado.onTint),
            ),
          ),
        ],
      ),
    );
  }
}

class _Antecedente extends StatelessWidget {
  const _Antecedente({required this.texto});

  final String texto;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(AgeRadius.full),
        border: Border.all(color: cs.outlineVariant),
      ),
      child: Text(
        texto,
        style: TextStyle(
            fontSize: 12, fontWeight: FontWeight.w600, color: cs.onSurface),
      ),
    );
  }
}

String _fechaCorta(DateTime d) =>
    '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';

String _timeAgo(DateTime dt) {
  final diff = DateTime.now().difference(dt);
  if (diff.inMinutes < 1) return 'ahora';
  if (diff.inMinutes < 60) return 'hace ${diff.inMinutes} min';
  if (diff.inHours < 24) return 'hace ${diff.inHours} h';
  if (diff.inDays == 1) return 'ayer';
  return 'hace ${diff.inDays} días';
}
