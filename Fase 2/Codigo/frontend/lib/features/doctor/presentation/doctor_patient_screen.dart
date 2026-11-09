import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/common.dart';
import '../../caregiver/application/caregiver_providers.dart';
import '../../caregiver/domain/models.dart';
import '../../health/application/health_providers.dart';
import '../../health/domain/models.dart' as health;
import '../../medications/application/medications_providers.dart';
import '../../medications/application/treatments_providers.dart';
import '../../medications/domain/treatment.dart';
import '../../patients/application/patients_providers.dart';
import '../../patients/domain/models.dart';

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
          bottom: const TabBar(
            isScrollable: true,
            tabs: [
              Tab(text: 'Resumen'),
              Tab(text: 'Tratamientos'),
              Tab(text: 'Controles'),
              Tab(text: 'Bitácora'),
              Tab(text: 'Documentos'),
            ],
          ),
        ),
        body: Column(
          children: [
            // Contexto fijo y mínimo en todas las pestañas: edad, sexo y
            // semáforo. La edad hace falta para leer cualquier valor (54 lpm
            // no significa lo mismo a los 50 que a los 90). El nombre ya está
            // en la barra; el detalle clínico vive en Resumen.
            if (patient != null)
              _Contexto(
                patient: patient,
                detalle: detalle.valueOrNull,
                onTap: () =>
                    context.push('/patient/profile?patient=$patientId'),
              ),
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
                  _BitacoraTab(patientId: patientId),
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

/// Resumen: la vista de 5 segundos. Por qué mirarlo hoy, qué no se puede
/// pasar por alto (alergias y enfermedades de base), sus vitales y cómo va
/// con la medicación.
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
    final motivo = (patient?.topReason ?? '').trim();
    final alergias = patient?.allergies ?? const <AllergyMini>[];
    final condiciones = detalle?.conditions ?? const <String>[];
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
      children: [
        if (patient != null && motivo.isNotEmpty) ...[
          const SizedBox(height: 12),
          _Motivo(estado: patient!.wellbeingStatus, texto: motivo),
        ],
        if (alergias.isNotEmpty || condiciones.isNotEmpty) ...[
          const _SectionLabel('Antecedentes'),
          AppCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (alergias.isNotEmpty)
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.warning_amber_rounded,
                          size: 18,
                          color: alergias.any((a) => a.esGrave)
                              ? AppColors.critical
                              : AgeColors.warn700),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Alergias: ${alergias.map((a) => a.label).join(', ')}',
                          style: TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w700,
                            color: alergias.any((a) => a.esGrave)
                                ? AppColors.critical
                                : AgeColors.warn700,
                          ),
                        ),
                      ),
                    ],
                  ),
                if (alergias.isNotEmpty && condiciones.isNotEmpty)
                  const SizedBox(height: 12),
                if (condiciones.isNotEmpty)
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final c in condiciones) _Antecedente(texto: c),
                    ],
                  ),
              ],
            ),
          ),
        ],
        const _SectionLabel('Signos vitales actuales'),
        latestVitals.when(
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
                  'Aún no hay lecturas del wearable para este paciente.',
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
        ),
        const _SectionLabel('Adherencia (últimos 7 días)'),
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
      ],
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
                child: _SectionLabel('Tratamientos por especialidad')),
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

/// Bitácora: notas del círculo de cuidado (observaciones).
class _BitacoraTab extends ConsumerWidget {
  const _BitacoraTab({required this.patientId});
  final String patientId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final observations = ref.watch(observationsProvider);
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        const _SectionLabel('Notas del círculo de cuidado'),
        observations.when(
          loading: () =>
              const AppCard(child: SizedBox(height: 70, child: LoadingView())),
          error: (_, __) => AppCard(
            child: ErrorView(
              message: 'No se pudieron cargar las observaciones.',
              onRetry: () => ref.invalidate(observationsProvider),
            ),
          ),
          data: (notes) {
            if (notes.isEmpty) {
              return const AppCard(
                child: Text('Aún no hay observaciones registradas.',
                    style: TextStyle(color: AppColors.textSecondary)),
              );
            }
            return AppCard(
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  for (var i = 0; i < notes.length; i++) ...[
                    if (i != 0) const Divider(height: 1),
                    _ObservationTile(observation: notes[i]),
                  ],
                ],
              ),
            );
          },
        ),
      ],
    );
  }
}

/// Documentos del expediente (recetas, exámenes).
class _DocumentosTab extends StatelessWidget {
  const _DocumentosTab({required this.patientId});
  final String patientId;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: EmptyView(
          icon: Icons.folder_rounded,
          title: 'Documentos del expediente',
          subtitle: 'Recetas, exámenes e informes escaneados.',
          action: FilledButton.icon(
            onPressed: () => context.push('/documents?patient=$patientId'),
            icon: const Icon(Icons.open_in_new_rounded),
            label: const Text('Abrir documentos'),
          ),
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 22, 4, 10),
        child: Text(
          text.toUpperCase(),
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: AppColors.textSecondary,
            letterSpacing: .5,
          ),
        ),
      );
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

class _ObservationTile extends StatelessWidget {
  const _ObservationTile({required this.observation});

  final Observation observation;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title:
          Text(observation.text, maxLines: 3, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        '${observation.authorName} · ${_timeAgo(observation.createdAt)}',
        style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
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

/// Cabecera de la ficha: quien es el paciente antes de mirar un solo numero.
///
/// La edad no es un adorno. Cincuenta y cuatro latidos por minuto son
/// bradicardia en alguien de cincuenta y pueden ser normales en alguien de
/// noventa, asi que una ficha que muestra el pulso sin la edad obliga al
/// profesional a pedir el dato por otro lado antes de decidir. Lo mismo con
/// las enfermedades de base: la misma presion se lee distinto en un paciente
/// hipertenso que en uno que no lo es.
///
/// El dato estaba en la base desde el principio (patients.birth_date y la
/// tabla patient_conditions) y el modelo del front ya calculaba la edad. Solo
/// no se dibujaba.
///
/// [detalle] llega nulo mientras carga o si la peticion falla. En ese caso se
/// muestra lo que ya trae el listado, nombre y estado, en vez de dejar la
/// cabecera en blanco o poner un indicador que empuje el resto de la ficha
/// hacia abajo cuando llegue.
/// Barra de contexto fija arriba de las pestañas. Es deliberadamente mínima:
/// edad y sexo (que hacen falta para leer cualquier valor de la ficha) y el
/// semáforo. No repite nombre, alergias ni enfermedades porque eso ya está en
/// la barra de título y en Resumen; antes esta cabecera traía todo y se veía
/// igual en las cinco pestañas.
class _Contexto extends StatelessWidget {
  const _Contexto({required this.patient, required this.detalle, this.onTap});

  final PatientCard patient;
  final Patient? detalle;

  /// Abre el perfil clínico completo (alergias, vacunas, contactos, PDF).
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final edadYSexo = <String>[
      if (detalle != null) '${detalle!.age} años',
      if (detalle?.sex != null) _sexo(detalle!.sex!),
    ].join(' · ');

    return Material(
      // colorScheme resuelve claro/oscuro; los AppColors fijos dejaban esta
      // barra blanca en modo oscuro.
      color: cs.surface,
      child: InkWell(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.fromLTRB(16, 8, 12, 8),
          decoration: BoxDecoration(
            border:
                Border(bottom: BorderSide(color: cs.outlineVariant, width: 1)),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  edadYSexo.isEmpty ? 'Ficha clínica' : edadYSexo,
                  style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: cs.onSurface),
                ),
              ),
              WellbeingChip(status: patient.wellbeingStatus),
              if (onTap != null)
                Padding(
                  padding: const EdgeInsets.only(left: 2),
                  child: Icon(Icons.chevron_right_rounded,
                      color: cs.onSurfaceVariant),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// El backend guarda una sola letra (ck_patients_sex admite M, F u O), pero
  /// los datos de prueba traian la palabra completa. Se mira la inicial para
  /// que ninguna de las dos formas termine mostrando "Otro".
  static String _sexo(String s) {
    if (s.isEmpty) return 'Otro';
    return switch (s[0].toUpperCase()) {
      'M' => 'Masculino',
      'F' => 'Femenino',
      _ => 'Otro',
    };
  }
}

/// "Por qué mirarlo hoy": el motivo del semáforo con el tinte del estado.
/// Encabeza Resumen porque es lo primero que el médico necesita saber.
class _Motivo extends StatelessWidget {
  const _Motivo({required this.estado, required this.texto});

  final WellbeingStatus estado;
  final String texto;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: estado.tint,
        borderRadius: BorderRadius.circular(AgeRadius.m),
      ),
      child: Row(
        children: [
          Icon(estado.icon, size: 18, color: estado.onTint),
          const SizedBox(width: 8),
          Expanded(
            child: Text(texto,
                style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                    color: estado.onTint)),
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
