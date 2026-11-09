import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/common.dart';
import '../../alerts/domain/models.dart';
import '../../health/application/health_providers.dart';
import '../../health/domain/models.dart' as health;
import '../../patients/application/patients_providers.dart';
import '../../patients/domain/models.dart';

/// "Hoy" del médico: lista de pacientes asignados con su estado (semáforo y
/// alertas activas). Al tocar un paciente se selecciona y se abre su ficha
/// clínica (doctor_patient_screen).
///
/// Solo consume endpoints existentes: GET /patients devuelve los pacientes
/// donde el usuario es miembro, con cualquier rol (incluido doctor).
class DoctorHomeScreen extends ConsumerWidget {
  const DoctorHomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final patientsAsync = ref.watch(myPatientsProvider);

    return Scaffold(
      body: patientsAsync.when(
        loading: () => const LoadingView(),
        error: (e, _) => ErrorView(message: e.toString()),
        data: (patients) {
          if (patients.isEmpty) {
            return const EmptyView(
              icon: Icons.medical_services_rounded,
              title: 'Sin pacientes asignados',
              subtitle:
                  'Cuando un familiar te invite a su círculo de cuidado con el '
                  'rol médico, verás a tus pacientes aquí.',
            );
          }
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
            children: [
              for (final p in patients)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: _DoctorPatientCard(patient: p),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _DoctorPatientCard extends ConsumerWidget {
  const _DoctorPatientCard({required this.patient});

  final PatientCard patient;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return AppCard(
      onTap: () {
        ref.read(selectedPatientProvider.notifier).select(patient);
        context.push('/doctor/patient?patient=${patient.patientId}');
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              InitialsAvatar(
                name: patient.fullName,
                photoUrl: patient.photoUrl,
                radius: 24,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(patient.fullName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w700)),
                    // Edad · sexo · RUT: con esto se distingue a dos pacientes
                    // con el mismo nombre sin abrir la ficha.
                    if (_identidad(patient).isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(_identidad(patient),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: AppColors.textPrimary)),
                    ],
                    if ((patient.topReason ?? '').isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(patient.topReason!,
                          style: const TextStyle(
                              fontSize: 13, color: AppColors.textSecondary)),
                    ],
                  ],
                ),
              ),
              // El semaforo es lo unico que va a la derecha del nombre. El
              // conteo de alertas se bajo a la linea de estado porque en 320
              // dp "2 alertas activas" no cabe aqui y desbordaba la tarjeta.
              WellbeingChip(status: patient.wellbeingStatus),
              const SizedBox(width: 4),
              const Icon(Icons.chevron_right_rounded,
                  color: AppColors.textSecondary),
            ],
          ),
          // Domicilio: el otro desempate práctico (y útil si hay que ir).
          if ((patient.address ?? '').trim().isNotEmpty)
            _LineaDato(
              icon: Icons.home_outlined,
              texto: patient.address!.trim(),
            ),
          // Alergias primero: es lo que no se puede pasar por alto.
          if (patient.allergies.isNotEmpty)
            _LineaDato(
              icon: Icons.warning_amber_rounded,
              texto: 'Alergias: '
                  '${patient.allergies.map((a) => a.label).join(', ')}',
              color: patient.allergies.any((a) => a.esGrave)
                  ? AppColors.critical
                  : AppColors.statusWarning,
              negrita: true,
            ),
          if (_cronicas(patient).isNotEmpty)
            _LineaDato(
              icon: Icons.monitor_heart_outlined,
              texto: 'Crónico: ${_cronicas(patient).join(' · ')}',
            ),
          if (patient.complexity != null || patient.priority != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  if (patient.priority != null)
                    _Etiqueta(
                      texto: 'Prioridad ${_nivel(patient.priority!)}',
                      color: _colorNivel(patient.priority!),
                    ),
                  if (patient.complexity != null)
                    _Etiqueta(
                      texto: 'Complejidad ${_nivel(patient.complexity!)}',
                      color: _colorNivel(patient.complexity!),
                    ),
                ],
              ),
            ),
          // Los numeros, en la misma tarjeta. El semaforo dice que algo pasa;
          // esto dice que. Sin ello hay que entrar a la ficha de cada
          // paciente, mirar, salir y entrar al siguiente para comparar.
          _VitalesEnLinea(patientId: patient.patientId),
          if (patient.activeAlertsCount > 0)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(
                children: [
                  const Icon(Icons.notifications_active_rounded,
                      size: 15, color: AppColors.statusAttention),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      textoDeAlertasActivas(patient.activeAlertsCount),
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: AppColors.statusAttention,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// "76 años · Femenino · RUT 5.123.456-K". Solo lo que exista.
  static String _identidad(PatientCard p) => [
        if (p.age != null) '${p.age} años',
        if ((p.sex ?? '').isNotEmpty) _sexo(p.sex!),
        if ((p.rut ?? '').isNotEmpty) 'RUT ${p.rut}',
      ].join(' · ');

  /// La base guarda una letra y la API la traduce a palabra; se mira la
  /// inicial para aceptar las dos formas (igual que la cabecera de la ficha).
  static String _sexo(String s) => switch (s[0].toUpperCase()) {
        'F' => 'Femenino',
        'M' => 'Masculino',
        _ => 'Otro',
      };

  /// Enfermedades con su nombre legible; si el backend no las trae (datos de
  /// prueba antiguos), se humaniza el código.
  static List<String> _cronicas(PatientCard p) => p.conditionsLabels.isNotEmpty
      ? p.conditionsLabels
      : p.conditions.map((c) {
          final t = c.replaceAll('_', ' ').trim();
          return t.isEmpty ? c : t[0].toUpperCase() + t.substring(1);
        }).toList();

  static String _nivel(String v) => switch (v) {
        'alta' => 'alta',
        'media' || 'moderada' => v,
        'baja' => 'baja',
        _ => v,
      };

  static Color _colorNivel(String v) => switch (v) {
        'alta' => AppColors.statusAttention,
        'media' || 'moderada' => AppColors.statusWarning,
        _ => AppColors.statusOk,
      };
}

/// Una línea de dato con ícono, recortada a una línea para que la tarjeta no
/// crezca sin control en pantallas angostas.
class _LineaDato extends StatelessWidget {
  const _LineaDato({
    required this.icon,
    required this.texto,
    this.color = AppColors.textSecondary,
    this.negrita = false,
  });

  final IconData icon;
  final String texto;
  final Color color;
  final bool negrita;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        children: [
          Icon(icon, size: 15, color: color),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              texto,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                color: color,
                fontWeight: negrita ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Etiqueta extends StatelessWidget {
  const _Etiqueta({required this.texto, required this.color});
  final String texto;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .12),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(texto,
          style: TextStyle(
              fontSize: 11, fontWeight: FontWeight.w700, color: color)),
    );
  }
}

/// Los ultimos valores del paciente, en una linea dentro de su tarjeta.
///
/// El semaforo de la tarjeta dice que algo pasa, pero no que. Con esto el
/// medico compara a sus pacientes de un vistazo en vez de entrar a una ficha,
/// mirar, salir y entrar a la siguiente.
///
/// Mientras cargan no se dibuja nada en lugar de un indicador: son varias
/// tarjetas pidiendo a la vez y la lista entera quedaria parpadeando. Si la
/// peticion falla tampoco se muestra error, porque el dato de aqui es un
/// extra y la ficha ya informa el fallo con su propio reintento.
class _VitalesEnLinea extends ConsumerWidget {
  const _VitalesEnLinea({required this.patientId});

  final String patientId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final vitales = ref.watch(vitalesDePacienteProvider(patientId));
    final conDatos =
        vitales.valueOrNull?.where((v) => v.hasData).toList() ?? const [];
    if (conDatos.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Wrap(
        spacing: 14,
        runSpacing: 6,
        children: [
          for (final v in conDatos) _ValorSuelto(vital: v),
        ],
      ),
    );
  }
}

class _ValorSuelto extends StatelessWidget {
  const _ValorSuelto({required this.vital});

  final health.LatestVital vital;

  @override
  Widget build(BuildContext context) {
    final fuera = !vital.inRange;
    final color = fuera ? AppColors.statusAttention : AppColors.textPrimary;
    return Semantics(
      label: '${vital.type.label}: ${_numero(vital.value)} '
          '${vital.type.unit}${fuera ? ', fuera de rango' : ''}',
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(vital.type.icon,
              size: 15,
              color: fuera ? AppColors.statusAttention : AppColors.primary),
          const SizedBox(width: 4),
          Text(
            '${_numero(vital.value)} ${vital.type.unit}',
            style: TextStyle(
              fontSize: 13,
              fontWeight: fuera ? FontWeight.w800 : FontWeight.w600,
              color: color,
            ),
          ),
          if (fuera) ...[
            const SizedBox(width: 3),
            const Icon(Icons.error_rounded,
                size: 14, color: AppColors.statusAttention),
          ],
        ],
      ),
    );
  }

  /// La temperatura necesita su decimal; el resto no.
  static String _numero(double v) =>
      v == v.roundToDouble() ? v.round().toString() : v.toStringAsFixed(1);
}
