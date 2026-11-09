import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/common.dart';
import '../../alerts/domain/models.dart';
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
              _Saludo(
                  total: patients.length, porRevisar: _porRevisar(patients)),
              const SizedBox(height: 14),
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
/// Está ordenada como se lee en un triage, de arriba hacia abajo:
///
///  1. **Quién es** (izquierda) y **cómo está en general** (derecha, el
///     semáforo). Edad, sexo, RUT y domicilio van aquí porque sirven para no
///     confundir a dos pacientes con el mismo nombre.
///  2. **Por qué mirarlo ahora**: una franja con el motivo del semáforo y las
///     alertas activas, teñida con el color del estado. Solo aparece cuando
///     hay algo que decir, así que un paciente estable queda más liviano.
///  3. **Antecedentes** (izquierda: alergias, enfermedades crónicas,
///     prioridad y complejidad) y **vitales** (derecha), lado a lado en
///     pantallas anchas y uno sobre otro en el teléfono.
///
/// El borde izquierdo lleva el color del semáforo, para recorrer la lista
/// con la vista sin leer cada tarjeta.
class _DoctorPatientCard extends ConsumerWidget {
  const _DoctorPatientCard({required this.patient});

  final PatientCard patient;

  /// Desde este ancho de tarjeta, antecedentes y vitales van en dos columnas.
  static const _anchoDosColumnas = 600.0;

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
              child: LayoutBuilder(builder: (context, c) {
                final dosColumnas = c.maxWidth >= _anchoDosColumnas;
                final antecedentes = _Antecedentes(patient: patient);
                final vitales = _VitalesEnLinea(patientId: patient.patientId);
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _Cabecera(patient: patient),
                    if (_hayMotivo(patient)) ...[
                      const SizedBox(height: 10),
                      _FranjaMotivo(patient: patient),
                    ],
                    const SizedBox(height: 12),
                    if (dosColumnas)
                      IntrinsicHeight(
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Expanded(flex: 5, child: antecedentes),
                            VerticalDivider(
                                width: 28,
                                color: Theme.of(context)
                                    .colorScheme
                                    .outlineVariant),
                            Expanded(flex: 4, child: vitales),
                          ],
                        ),
                      )
                    else ...[
                      antecedentes,
                      vitales,
                    ],
                  ],
                );
              }),
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

/// Fila de arriba: avatar e identidad a la izquierda, semáforo a la derecha.
class _Cabecera extends StatelessWidget {
  const _Cabecera({required this.patient});

  final PatientCard patient;

  @override
  Widget build(BuildContext context) {
    final identidad = _identidad(patient);
    final domicilio = (patient.address ?? '').trim();
    final cs = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
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
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w700)),
              // Edad · sexo · RUT: con esto se distingue a dos pacientes con
              // el mismo nombre sin abrir la ficha.
              if (identidad.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(identidad,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: cs.onSurfaceVariant)),
              ],
              // Domicilio: el otro desempate práctico, y útil si hay que ir.
              if (domicilio.isNotEmpty) ...[
                const SizedBox(height: 2),
                Row(
                  children: [
                    Icon(Icons.home_outlined,
                        size: 13, color: cs.onSurfaceVariant),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(domicilio,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 12, color: cs.onSurfaceVariant)),
                    ),
                  ],
                ),
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
}

/// "Por qué mirarlo ahora": motivo del semáforo y alertas activas, en una
/// sola franja con el tinte del estado. Es lo primero que el médico necesita
/// para decidir a quién abrir, por eso va entre la identidad y el detalle.
class _FranjaMotivo extends StatelessWidget {
  const _FranjaMotivo({required this.patient});

  final PatientCard patient;

  @override
  Widget build(BuildContext context) {
    final estado = patient.wellbeingStatus;
    final motivo = (patient.topReason ?? '').trim();
    final alertas = patient.activeAlertsCount;
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
          if (alertas > 0) ...[
            const SizedBox(width: 8),
            Icon(Icons.notifications_active_rounded,
                size: 14, color: estado.onTint),
            const SizedBox(width: 3),
            Text(
              textoDeAlertasActivas(alertas),
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                  color: estado.onTint),
            ),
          ],
        ],
      ),
    );
  }
}

/// Lo que no se puede pasar por alto antes de indicar algo: alergias primero,
/// después enfermedades crónicas, y al final prioridad y complejidad.
class _Antecedentes extends StatelessWidget {
  const _Antecedentes({required this.patient});

  final PatientCard patient;

  @override
  Widget build(BuildContext context) {
    final cronicas = _cronicas(patient);
    final hayEtiquetas = patient.priority != null || patient.complexity != null;
    if (patient.allergies.isEmpty && cronicas.isEmpty && !hayEtiquetas) {
      return const SizedBox.shrink();
    }
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        const _Rotulo('Antecedentes'),
        if (patient.allergies.isNotEmpty)
          _LineaDato(
            icon: Icons.warning_amber_rounded,
            texto: 'Alergias: '
                '${patient.allergies.map((a) => a.label).join(', ')}',
            color: patient.allergies.any((a) => a.esGrave)
                ? AppColors.critical
                : AgeColors.warn700,
            negrita: true,
          ),
        if (cronicas.isNotEmpty)
          _LineaDato(
            icon: Icons.monitor_heart_outlined,
            texto: 'Crónico: ${cronicas.join(' · ')}',
            color: cs.onSurface,
          ),
        if (hayEtiquetas)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                if (patient.priority != null)
                  _Etiqueta(
                    texto: 'Prioridad ${patient.priority!}',
                    color: _colorNivel(patient.priority!),
                  ),
                if (patient.complexity != null)
                  _Etiqueta(
                    texto: 'Complejidad ${patient.complexity!}',
                    color: _colorNivel(patient.complexity!),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  /// Enfermedades con su nombre legible; si el backend no las trae (datos de
  /// prueba antiguos), se humaniza el código.
  static List<String> _cronicas(PatientCard p) => p.conditionsLabels.isNotEmpty
      ? p.conditionsLabels
      : p.conditions.map((c) {
          final t = c.replaceAll('_', ' ').trim();
          return t.isEmpty ? c : t[0].toUpperCase() + t.substring(1);
        }).toList();

  static Color _colorNivel(String v) => switch (v) {
        'alta' => AppColors.statusAttention,
        'media' || 'moderada' => AgeColors.warn700,
        _ => AgeColors.ok700,
      };
}

/// Rótulo pequeño de sección: ordena la tarjeta sin agregar peso visual.
class _Rotulo extends StatelessWidget {
  const _Rotulo(this.texto);

  final String texto;

  @override
  Widget build(BuildContext context) {
    return Text(
      texto.toUpperCase(),
      style: TextStyle(
        fontSize: 10.5,
        fontWeight: FontWeight.w700,
        letterSpacing: .6,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
  }
}

/// Una línea de dato con ícono. Hasta dos líneas: una alergia cortada con
/// puntos suspensivos es justo la que no se ve.
class _LineaDato extends StatelessWidget {
  const _LineaDato({
    required this.icon,
    required this.texto,
    required this.color,
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
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(icon, size: 15, color: color),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              texto,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12.5,
                height: 1.3,
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
        color: color.withValues(alpha: .10),
        borderRadius: BorderRadius.circular(AgeRadius.full),
      ),
      child: Text(texto,
          style: TextStyle(
              fontSize: 11, fontWeight: FontWeight.w700, color: color)),
    );
  }
}

/// Los últimos valores del paciente dentro de su tarjeta.
///
/// El semáforo dice que algo pasa, pero no qué. Con esto el médico compara a
/// sus pacientes de un vistazo en vez de entrar a una ficha, mirar, salir y
/// entrar a la siguiente.
///
/// Los signos clínicos (presión, pulso, SpO2, temperatura, glucosa) van
/// primero y destacados; los de actividad (sueño, pasos) debajo y más tenues,
/// porque informan pero no deciden un triage.
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

    // La lectura más reciente de todas: un valor sin hora no sirve para
    // decidir (un pulso de hace 3 días no dice cómo está hoy).
    final ultima = conDatos
        .map((v) => v.measuredAt)
        .reduce((a, b) => a.isAfter(b) ? a : b);
    // Más de un día sin lecturas se marca: el número ya no es "cómo está".
    final antigua = DateTime.now().difference(ultima).inHours >= 24;

    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              const _Rotulo('Vitales'),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Última lectura ${_hace(ultima)}',
                  textAlign: TextAlign.end,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: antigua ? FontWeight.w700 : FontWeight.w500,
                    color: antigua
                        ? AgeColors.warn700
                        : Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
          if (clinicos.isNotEmpty) ...[
            const SizedBox(height: 6),
            Wrap(
              spacing: 14,
              runSpacing: 6,
              children: [for (final v in clinicos) _ValorSuelto(vital: v)],
            ),
          ],
          if (actividad.isNotEmpty) ...[
            const SizedBox(height: 6),
            Wrap(
              spacing: 14,
              runSpacing: 4,
              children: [
                for (final v in actividad) _ValorSuelto(vital: v, tenue: true),
              ],
            ),
          ],
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
          Text(
            texto,
            style: TextStyle(
              fontSize: tenue ? 12 : 13.5,
              fontWeight: fuera
                  ? FontWeight.w800
                  : (tenue ? FontWeight.w500 : FontWeight.w700),
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
