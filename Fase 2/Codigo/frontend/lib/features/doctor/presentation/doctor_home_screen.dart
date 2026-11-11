import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/common.dart';
import '../../auth/application/auth_controller.dart';
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

  /// Ancho máximo de la lista; más allá, las tarjetas se centran.
  static const _anchoMaximo = 720.0;

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
          // En pantallas anchas las tarjetas no se estiran de borde a borde:
          // con pocos pacientes quedaban como franjas vacías. Un ancho
          // máximo, centrado, las mantiene legibles.
          return Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: _anchoMaximo),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
                children: [
                  _Saludo(
                      total: patients.length,
                      porRevisar: _porRevisar(patients)),
                  const SizedBox(height: 14),
                  for (final p in patients)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: _DoctorPatientCard(patient: p),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  /// Pacientes que no están en verde: los que el médico mira primero.
  static int _porRevisar(List<PatientCard> ps) =>
      ps.where((p) => p.wellbeingStatus != WellbeingStatus.ok).length;
}

/// Saludo al médico por su nombre, con el resumen del día.
///
/// La barra superior dice "Hoy" para todos los roles por igual, lo que no
/// recibe a nadie. Aquí el médico llega a su nombre y a una frase que le dice
/// de una cuántos pacientes tiene y cuántos necesitan atención, en vez de una
/// lista fría. El saludo cambia con la hora.
class _Saludo extends ConsumerWidget {
  const _Saludo({required this.total, required this.porRevisar});

  final int total;
  final int porRevisar;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(currentUserProvider);
    final nombre = _nombreCorto(user?.fullName);
    // Va sobre el fondo de pantalla (no una tarjeta): colorScheme para que no
    // quede texto oscuro sobre fondo oscuro.
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          nombre.isEmpty ? '${_saludoHora()}.' : '${_saludoHora()}, $nombre',
          style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.3,
              color: cs.onSurface),
        ),
        const SizedBox(height: 2),
        Text(
          _resumen(total, porRevisar),
          style: TextStyle(fontSize: 13.5, color: cs.onSurfaceVariant),
        ),
      ],
    );
  }

  static String _saludoHora() {
    final h = DateTime.now().hour;
    if (h < 12) return 'Buenos días';
    if (h < 20) return 'Buenas tardes';
    return 'Buenas noches';
  }

  static String _resumen(int total, int porRevisar) {
    if (total == 0) return 'No tienes pacientes asignados.';
    final pac = total == 1 ? '1 paciente' : '$total pacientes';
    if (porRevisar == 0) return 'Tienes $pac, todos estables.';
    if (porRevisar == 1) return 'Tienes $pac · 1 por revisar.';
    return 'Tienes $pac · $porRevisar por revisar.';
  }

  /// "Dra. Carmen Orellana" -> "Dra. Carmen". Un saludo con el nombre completo
  /// y sus dos apellidos suena a formulario, no a saludo.
  static String _nombreCorto(String? full) {
    final n = (full ?? '').trim();
    if (n.isEmpty) return '';
    final partes = n.split(RegExp(r'\s+'));
    // Si parte con tratamiento (Dr., Dra.), se deja el tratamiento + nombre.
    if (RegExp(r'^(dr|dra)\.?$', caseSensitive: false).hasMatch(partes.first)) {
      return partes.take(2).join(' ');
    }
    return partes.first;
  }
}

/// Tarjeta de un paciente en la lista del médico.
///
/// Está hecha para escanearse en dos o tres segundos entre consulta y
/// consulta: responde "¿a quién miro primero?" y nada más. De arriba hacia
/// abajo:
///
///  1. **Quién es** y **cómo está** (semáforo). Solo nombre y edad: el RUT, el
///     domicilio y los antecedentes viven en la ficha, un toque más allá.
///  2. **Por qué mirarlo ahora**: una franja con el motivo del semáforo,
///     teñida con el color del estado. Solo aparece si hay algo que decir.
///  3. **Todos los vitales** en una línea. Los que están en rango van
///     sobrios; el que está fuera de rango se pinta en rojo y lleva su
///     nombre, sin fondo ni chip aparte: el motivo de la franja y ese número
///     son la misma historia y no deben verse como dos alarmas.
///
/// El borde izquierdo lleva el color del semáforo, y ese color ya comunica la
/// prioridad: no se repite con otras etiquetas. El número de alertas tampoco
/// se repite aquí; la campana de arriba ya lo muestra.
class _DoctorPatientCard extends ConsumerWidget {
  const _DoctorPatientCard({required this.patient});

  final PatientCard patient;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final estado = patient.wellbeingStatus;
    return AppCard(
      padding: EdgeInsets.zero,
      onTap: () {
        ref.read(selectedPatientProvider.notifier).select(patient);
        context.push('/doctor/patient?patient=${patient.patientId}');
      },
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AgeRadius.xl),
        child: Stack(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 14, 12, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _Cabecera(patient: patient),
                  if (_hayMotivo(patient)) ...[
                    const SizedBox(height: 10),
                    _FranjaMotivo(patient: patient),
                  ],
                  _VitalesEnLinea(patientId: patient.patientId),
                ],
              ),
            ),
            // Borde de estado: decorativo, el semáforo ya se anuncia con texto.
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              width: 4,
              child: ExcludeSemantics(child: ColoredBox(color: estado.color)),
            ),
          ],
        ),
      ),
    );
  }

  static bool _hayMotivo(PatientCard p) =>
      (p.topReason ?? '').trim().isNotEmpty || p.activeAlertsCount > 0;
}

/// Fila de arriba: avatar y nombre a la izquierda, semáforo a la derecha.
class _Cabecera extends StatelessWidget {
  const _Cabecera({required this.patient});

  final PatientCard patient;

  @override
  Widget build(BuildContext context) {
    final detalle = [
      if (patient.age != null) '${patient.age} años',
      if ((patient.sex ?? '').isNotEmpty) _sexo(patient.sex!),
    ].join(' · ');
    final cs = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        InitialsAvatar(
          name: patient.fullName,
          photoUrl: patient.photoUrl,
          radius: 22,
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(patient.fullName,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w700)),
              if (detalle.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(detalle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: cs.onSurfaceVariant)),
              ],
            ],
          ),
        ),
        const SizedBox(width: 8),
        WellbeingChip(status: patient.wellbeingStatus),
        Icon(Icons.chevron_right_rounded, color: cs.onSurfaceVariant),
      ],
    );
  }

  /// La base guarda una letra y la API la traduce a palabra; se mira la
  /// inicial para aceptar las dos formas (igual que la cabecera de la ficha).
  static String _sexo(String s) => switch (s[0].toUpperCase()) {
        'F' => 'Femenino',
        'M' => 'Masculino',
        _ => 'Otro',
      };
}

/// "Por qué mirarlo ahora": el motivo del semáforo, en una franja con el
/// tinte del estado. Es lo primero que el médico necesita para decidir a
/// quién abrir, por eso va entre la identidad y los números.
class _FranjaMotivo extends StatelessWidget {
  const _FranjaMotivo({required this.patient});

  final PatientCard patient;

  @override
  Widget build(BuildContext context) {
    final estado = patient.wellbeingStatus;
    final motivo = (patient.topReason ?? '').trim();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: estado.tint,
        borderRadius: BorderRadius.circular(AgeRadius.s),
      ),
      child: Row(
        children: [
          Icon(estado.icon, size: 16, color: estado.onTint),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              motivo.isNotEmpty ? motivo : 'Revisar alertas',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: estado.onTint),
            ),
          ),
        ],
      ),
    );
  }
}

/// Los últimos valores del paciente, todos, en una línea que se parte sola.
///
/// Los signos clínicos (presión, pulso, saturación, temperatura, glucosa) van
/// primero y los de actividad (sueño, pasos) después y más tenues, porque
/// informan pero no deciden un triage. Un valor fuera de rango se escribe con
/// su nombre y en rojo, así se entiende qué pasa sin abrir la ficha.
///
/// Si la última lectura tiene más de un día se dice: ese número ya no es
/// "cómo está ahora".
///
/// Mientras cargan no se dibuja nada en lugar de un indicador: son varias
/// tarjetas pidiendo a la vez y la lista entera quedaría parpadeando. Si la
/// petición falla tampoco se muestra error, porque el dato de aquí es un
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

    final clinicos = conDatos.where((v) => v.type.isCoreVital).toList();
    final actividad = conDatos.where((v) => !v.type.isCoreVital).toList();
    final ultima = conDatos
        .map((v) => v.measuredAt)
        .reduce((a, b) => a.isAfter(b) ? a : b);
    final antigua = DateTime.now().difference(ultima).inHours >= 24;
    final cs = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 14,
            runSpacing: 6,
            children: [
              for (final v in clinicos) _ValorSuelto(vital: v),
              for (final v in actividad) _ValorSuelto(vital: v, tenue: true),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            antigua
                ? 'Sin lecturas nuevas · ${_hace(ultima)}'
                : 'Última lectura ${_hace(ultima)}',
            style: TextStyle(
              fontSize: 11,
              fontWeight: antigua ? FontWeight.w700 : FontWeight.w500,
              color: antigua ? AgeColors.warn700 : cs.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  static String _hace(DateTime dt) {
    final d = DateTime.now().difference(dt);
    if (d.inMinutes < 1) return 'recién';
    if (d.inMinutes < 60) return 'hace ${d.inMinutes} min';
    if (d.inHours < 24) return 'hace ${d.inHours} h';
    if (d.inDays == 1) return 'ayer';
    return 'hace ${d.inDays} días';
  }
}

class _ValorSuelto extends StatelessWidget {
  const _ValorSuelto({required this.vital, this.tenue = false});

  final health.LatestVital vital;

  /// Datos de actividad: más chicos y grises, salvo que estén fuera de rango.
  final bool tenue;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final fuera = !vital.inRange;
    final color = fuera
        ? AppColors.statusAttention
        : (tenue ? cs.onSurfaceVariant : cs.onSurface);
    final texto = '${_numero(vital)} ${vital.type.unit}';
    return Semantics(
      label: '${vital.type.label}: $texto${fuera ? ', fuera de rango' : ''}',
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(vital.type.icon,
              size: tenue ? 13 : 15,
              color: fuera
                  ? AppColors.statusAttention
                  : (tenue ? cs.onSurfaceVariant : AppColors.primary)),
          const SizedBox(width: 4),
          // Fuera de rango lleva el nombre: "Oxígeno (SpO2) 86 %" se entiende
          // solo; un 86 con un ícono obliga a adivinar qué mide.
          Flexible(
            child: Text(
              fuera ? '${vital.type.label} $texto' : texto,
              style: TextStyle(
                fontSize: tenue ? 12 : 13.5,
                fontWeight: fuera
                    ? FontWeight.w800
                    : (tenue ? FontWeight.w500 : FontWeight.w700),
                color: color,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// La temperatura necesita su decimal; el pulso no. Los conteos (pasos,
  /// minutos, caídas) son enteros: "1431.2 pasos" no existe.
  static String _numero(health.LatestVital v) {
    final x = v.value;
    final entero = v.type == health.VitalType.steps ||
        v.type == health.VitalType.sedentaryMin ||
        v.type == health.VitalType.fallEvent;
    if (entero || x == x.roundToDouble()) return x.round().toString();
    return x.toStringAsFixed(1);
  }
}
