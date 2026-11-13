import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/network/api_client.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/util/save_pdf.dart';
import '../../../core/validation/identity_validators.dart';
import '../../../core/widgets/common.dart';
import '../../auth/application/auth_controller.dart';
import '../../auth/domain/models.dart';
import '../application/patients_providers.dart';
import '../data/patients_repository.dart';
import '../data/reports_repository.dart';
import '../domain/models.dart';

/// Ficha completa del adulto mayor: identidad, ficha social, enfermedades,
/// alergias, contactos y la hoja de emergencia en PDF.
///
/// La ven todos los que lo cuidan: el médico desde su ficha clínica, y la
/// familia y la cuidadora en su pestaña "Ficha" ([embedded]). Los botones de
/// edición siguen los permisos del servidor: identidad, ficha social,
/// enfermedades y contactos los cambia el familiar; alergias, vacunas y
/// mediciones las registra también la cuidadora o el médico, que son quienes
/// las descubren.
class PatientProfileScreen extends ConsumerWidget {
  const PatientProfileScreen(
      {super.key, required this.patientId, this.embedded = false});

  final String patientId;

  /// Dentro de una pestaña: sin AppBar propio (lo pone el shell).
  final bool embedded;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detail = ref.watch(selectedPatientDetailProvider);
    final rol = _rolSobre(ref, patientId);
    final editaFicha = rol == RoleType.family;
    final registraClinico = rol == RoleType.family ||
        rol == RoleType.caregiver ||
        rol == RoleType.doctor;

    return Scaffold(
      appBar: embedded
          ? null
          : AppBar(title: const Text('Ficha del adulto mayor')),
      body: detail.when(
        loading: () => const LoadingView(),
        error: (e, _) => ErrorView(
          message: 'No se pudo cargar el perfil.',
          onRetry: () => ref.invalidate(selectedPatientDetailProvider),
        ),
        data: (p) {
          if (p == null) {
            return const EmptyView(
              icon: Icons.person_off_rounded,
              title: 'Sin adulto mayor',
              subtitle: 'Elige a un adulto mayor para ver su ficha.',
            );
          }
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
            children: [
              _Cabecera(patient: p),
              // Arriba y no al final: en una urgencia es lo primero que se
              // busca, y lo usan todos los que cuidan al adulto mayor.
              const _SectionLabel('Hoja de emergencia'),
              _HojaEmergenciaCard(patientId: patientId, nombre: p.fullName),
              Row(
                children: [
                  const Expanded(child: _SectionLabel('Identidad')),
                  if (editaFicha)
                  TextButton.icon(
                    onPressed: () => _editarNombre(context, ref, p),
                    icon: const Icon(Icons.edit_outlined, size: 18),
                    label: const Text('Editar nombre'),
                  ),
                ],
              ),
              AppCard(
                padding: EdgeInsets.zero,
                child: Column(
                  children: [
                    // Nombres y apellidos por separado: así se identifica a
                    // una persona en Chile (Elena Rosa / Rosales Riquelme).
                    _DataRow(
                        icon: Icons.person_outline_rounded,
                        label: 'Nombres',
                        value:
                            p.givenNames.isEmpty ? p.fullName : p.givenNames),
                    const Divider(height: 1),
                    _DataRow(
                        icon: Icons.people_outline_rounded,
                        label: 'Apellidos',
                        value: p.surnames.isEmpty ? '—' : p.surnames),
                    const Divider(height: 1),
                    if ((p.rut ?? '').isNotEmpty) ...[
                      _DataRow(
                          icon: Icons.badge_outlined,
                          label: 'RUT',
                          value: p.rut!),
                      const Divider(height: 1),
                    ],
                    _DataRow(
                        icon: Icons.cake_outlined,
                        label: 'Edad',
                        value: '${p.age} años'),
                    const Divider(height: 1),
                    _DataRow(
                        icon: Icons.wc_outlined,
                        label: 'Sexo',
                        value: _sexo(p.sex)),
                    const Divider(height: 1),
                    _DataRow(
                        icon: Icons.event_outlined,
                        label: 'Nacimiento',
                        value: _fecha(p.birthDate)),
                    if (p.lastSeenBy != null) ...[
                      const Divider(height: 1),
                      _DataRow(
                          icon: Icons.medical_services_outlined,
                          label: 'Último médico',
                          value: _ultimoMedico(p.lastSeenBy!)),
                    ],
                  ],
                ),
              ),
              Row(
                children: [
                  const Expanded(child: _SectionLabel('Ficha social y riesgo')),
                  if (editaFicha)
                  TextButton.icon(
                    onPressed: () => _editarPerfil(context, ref, p),
                    icon: const Icon(Icons.edit_outlined, size: 18),
                    label: const Text('Editar'),
                  ),
                ],
              ),
              AppCard(
                padding: EdgeInsets.zero,
                child: Column(
                  children: [
                    _DataRow(
                        icon: Icons.home_outlined,
                        label: 'Domicilio',
                        value: (p.address ?? '').isEmpty ? '—' : p.address!),
                    const Divider(height: 1),
                    _DataRow(
                        icon: Icons.favorite_border,
                        label: 'Estado civil',
                        value: _civil(p.maritalStatus)),
                    const Divider(height: 1),
                    _DataRow(
                        icon: Icons.verified_user_outlined,
                        label: 'Previsión',
                        value: _prev(p.insurance)),
                    const Divider(height: 1),
                    _RcvRow(level: p.rcvLevel),
                    const Divider(height: 1),
                    _NivelRow(
                      icon: Icons.layers_outlined,
                      label: 'Complejidad',
                      value: p.complexity,
                      textos: _complejidadTextos,
                      colores: _complejidadColores,
                    ),
                    const Divider(height: 1),
                    _NivelRow(
                      icon: Icons.priority_high_rounded,
                      label: 'Prioridad',
                      value: p.priority,
                      textos: _prioridadTextos,
                      colores: _prioridadColores,
                    ),
                  ],
                ),
              ),
              Row(
                children: [
                  const Expanded(child: _SectionLabel('Antropometría')),
                  if (registraClinico)
                  TextButton.icon(
                    onPressed: () => _agregarMedicion(context, ref, p),
                    icon: const Icon(Icons.add_rounded, size: 18),
                    label: const Text('Registrar'),
                  ),
                ],
              ),
              AppCard(
                child: p.latestMeasurement == null
                    ? const Text('Sin mediciones registradas.',
                        style: TextStyle(color: AppColors.textSecondary))
                    : _MeasurementView(m: p.latestMeasurement!),
              ),
              Row(
                children: [
                  const Expanded(child: _SectionLabel('Enfermedades')),
                  if (editaFicha)
                  TextButton.icon(
                    onPressed: () => _editarEnfermedades(context, ref, p),
                    icon: const Icon(Icons.edit_outlined, size: 18),
                    label: const Text('Editar'),
                  ),
                ],
              ),
              if (p.conditionsDetail.isEmpty)
                const AppCard(
                  child: Text('Sin enfermedades registradas.',
                      style: TextStyle(color: AppColors.textSecondary)),
                )
              else
                AppCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final entry in _agruparPorSistema(p.conditionsDetail)
                          .entries) ...[
                        Padding(
                          padding: const EdgeInsets.only(top: 8, bottom: 6),
                          child: Text(systemLabel(entry.key),
                              style: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                  color: AppColors.textSecondary)),
                        ),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (final c in entry.value)
                              Chip(
                                label: Text(c.label),
                                backgroundColor:
                                    AppColors.primary.withValues(alpha: .10),
                                labelStyle: const TextStyle(
                                    color: AppColors.primary,
                                    fontWeight: FontWeight.w600),
                              ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              Row(
                children: [
                  const Expanded(child: _SectionLabel('Alergias')),
                  if (registraClinico)
                  TextButton.icon(
                    onPressed: () => _editarAlergias(context, ref, p),
                    icon: const Icon(Icons.edit_outlined, size: 18),
                    label: const Text('Editar'),
                  ),
                ],
              ),
              _AlergiasCard(allergies: p.allergies),
              Row(
                children: [
                  const Expanded(child: _SectionLabel('Vacunas')),
                  if (registraClinico)
                  TextButton.icon(
                    onPressed: () => _editarVacunas(context, ref, p),
                    icon: const Icon(Icons.edit_outlined, size: 18),
                    label: const Text('Editar'),
                  ),
                ],
              ),
              _VacunasCard(immunizations: p.immunizations),
              const _SectionLabel('Monitoreo'),
              AppCard(
                child: Row(
                  children: [
                    Icon(
                      p.wearable?.isLinked == true
                          ? Icons.watch_rounded
                          : Icons.watch_off_rounded,
                      color: p.wearable?.isLinked == true
                          ? AppColors.statusOk
                          : AppColors.textSecondary,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        p.wearable?.isLinked == true
                            ? 'Wearable vinculado'
                                '${p.wearable?.batteryPct != null ? ' · batería ${p.wearable!.batteryPct}%' : ''}'
                            : 'Sin wearable vinculado',
                        style: const TextStyle(fontSize: 13),
                      ),
                    ),
                  ],
                ),
              ),
              const _SectionLabel('Equipo de cuidado'),
              _EquipoCard(patientId: patientId),
              Row(
                children: [
                  const Expanded(
                      child: _SectionLabel('Contactos de emergencia')),
                  if (editaFicha)
                  TextButton.icon(
                    onPressed: () => _editarContactos(context, ref, p),
                    icon: const Icon(Icons.edit_outlined, size: 18),
                    label: const Text('Gestionar'),
                  ),
                ],
              ),
              _ContactosEmergenciaCard(patientId: patientId),
              const _SectionLabel('Teléfonos de emergencia'),
              const _TelefonosEmergencia(),
              const _SectionLabel('Expediente'),
              AppCard(
                padding: EdgeInsets.zero,
                child: Column(
                  children: [
                    ListTile(
                      leading: const Icon(Icons.folder_outlined,
                          color: AppColors.primary),
                      title: const Text('Documentos y exámenes'),
                      trailing: const Icon(Icons.chevron_right_rounded,
                          color: AppColors.textSecondary),
                      onTap: () =>
                          context.push('/documents?patient=$patientId'),
                    ),
                    const Divider(height: 1),
                    ListTile(
                      leading: const Icon(Icons.history_rounded,
                          color: AppColors.primary),
                      title: const Text('Historial de tratamientos'),
                      trailing: const Icon(Icons.chevron_right_rounded,
                          color: AppColors.textSecondary),
                      onTap: () =>
                          context.push('/treatment/history?patient=$patientId'),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  static String _especialidad(String code) => switch (code) {
        'general' => 'Medicina general',
        'cardiologia' => 'Cardiología',
        'traumatologia' => 'Traumatología',
        'neurologia' => 'Neurología',
        'geriatria' => 'Geriatría',
        'endocrinologia' => 'Endocrinología',
        'psiquiatria' => 'Psiquiatría',
        'nefrologia' => 'Nefrología',
        'broncopulmonar' => 'Broncopulmonar',
        _ => code,
      };

  static String _ultimoMedico(LastSeenBy l) {
    final buf = StringBuffer('Médico: ${l.name}');
    if (l.specialty != null && l.specialty!.isNotEmpty) {
      buf.write(' · ${_especialidad(l.specialty!)}');
    }
    if (l.date != null) {
      buf.write(' · ${l.date!.day.toString().padLeft(2, '0')}/'
          '${l.date!.month.toString().padLeft(2, '0')}/${l.date!.year}');
    }
    return buf.toString();
  }

  /// La API manda `female`/`male`/`other`, pero hay datos con una sola letra
  /// (la base guarda F, M u O). Se mira la inicial para aceptar ambas.
  static String _sexo(String? s) {
    if (s == null || s.isEmpty) return '—';
    return switch (s[0].toUpperCase()) {
      'M' => 'Masculino',
      'F' => 'Femenino',
      _ => 'Otro',
    };
  }

  static String _civil(String? s) => switch (s) {
        'soltero' => 'Soltero(a)',
        'casado' => 'Casado(a)',
        'viudo' => 'Viudo(a)',
        'divorciado' => 'Divorciado(a)',
        'conviviente' => 'Conviviente',
        'separado' => 'Separado(a)',
        _ => '—',
      };

  static String _prev(String? s) => switch (s) {
        'fonasa' => 'Fonasa',
        'isapre' => 'Isapre',
        'particular' => 'Particular',
        'otra' => 'Otra',
        _ => '—',
      };

  /// Agrupa las condiciones por sistema, preservando un orden clínico estable.
  static Map<String, List<ConditionDetail>> _agruparPorSistema(
      List<ConditionDetail> items) {
    const orden = [
      'cardiovascular',
      'metabolico',
      'respiratorio',
      'neuropsiquiatrico',
      'osteomuscular',
      'sensorial',
      'geriatrico',
      'otras',
    ];
    final mapa = <String, List<ConditionDetail>>{};
    for (final c in items) {
      mapa.putIfAbsent(c.system, () => []).add(c);
    }
    return {
      for (final s in orden)
        if (mapa.containsKey(s)) s: mapa[s]!,
    };
  }

  static String _fecha(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';
}

/// Diálogo para editar la lista de enfermedades: quitar las que remitieron y
/// agregar las nuevas que se descubran. Guarda con PATCH /patients (baja lógica
/// en el backend, conserva el histórico clínico).
Future<void> _editarEnfermedades(
    BuildContext context, WidgetRef ref, Patient p) async {
  final lista = List<String>.from(p.conditions);
  final nueva = TextEditingController();

  final guardado = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setLocal) => AlertDialog(
        title: const Text('Enfermedades'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (lista.isEmpty)
                const Text('Sin enfermedades. Agrega la primera abajo.',
                    style: TextStyle(color: AppColors.textSecondary)),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final c in lista)
                    Chip(
                      label: Text(c.replaceAll('_', ' ')),
                      onDeleted: () => setLocal(() => lista.remove(c)),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: nueva,
                      decoration: const InputDecoration(
                        labelText: 'Nueva enfermedad',
                        hintText: 'Ej: artrosis',
                      ),
                      onSubmitted: (_) {
                        final v = nueva.text.trim();
                        if (v.length >= 2 && !lista.contains(v)) {
                          setLocal(() {
                            lista.add(v);
                            nueva.clear();
                          });
                        }
                      },
                    ),
                  ),
                  IconButton(
                    icon:
                        const Icon(Icons.add_rounded, color: AppColors.primary),
                    onPressed: () {
                      final v = nueva.text.trim();
                      if (v.length >= 2 && !lista.contains(v)) {
                        setLocal(() {
                          lista.add(v);
                          nueva.clear();
                        });
                      }
                    },
                  ),
                ],
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancelar')),
          FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Guardar')),
        ],
      ),
    ),
  );

  if (guardado != true) return;
  try {
    await ref
        .read(patientsRepositoryProvider)
        .updateConditions(p.patientId, lista);
    ref.invalidate(selectedPatientDetailProvider);
    ref.invalidate(myPatientsProvider);
    if (context.mounted) showAppSnackBar(context, 'Enfermedades actualizadas.');
  } on Object catch (e) {
    if (context.mounted) showAppSnackBar(context, e.toString(), error: true);
  }
}

/// Fila de riesgo cardiovascular con color según el nivel (bajo/moderado/alto).
/// Equipo de cuidado: lista los miembros con su rol clínico (médico general,
/// kinesiólogo, enfermera, cuidadora, familiar...).
///
/// El familiar administrador ve ademas un boton para quitar a cada miembro
/// (RF-14). Nunca en su propia fila: al administrador no se le puede quitar.
class _EquipoCard extends ConsumerWidget {
  const _EquipoCard({required this.patientId});
  final String patientId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final equipo = ref.watch(careTeamProvider);
    final yo = ref.watch(currentUserProvider)?.userId;
    return equipo.when(
      loading: () =>
          const AppCard(child: SizedBox(height: 50, child: LoadingView())),
      error: (_, __) => const AppCard(
        child: Text('No se pudo cargar el equipo.',
            style: TextStyle(color: AppColors.textSecondary)),
      ),
      data: (miembros) {
        if (miembros.isEmpty) {
          return const AppCard(
            child: Text('Sin miembros en el círculo de cuidado.',
                style: TextStyle(color: AppColors.textSecondary)),
          );
        }
        // Solo el administrador gestiona el circulo.
        final soyAdmin =
            miembros.any((m) => m.isOwner && m.userId == yo);
        return AppCard(
          padding: EdgeInsets.zero,
          child: Column(
            children: [
              for (var i = 0; i < miembros.length; i++) ...[
                if (i != 0) const Divider(height: 1),
                ListTile(
                  leading: Icon(_icono(miembros[i]), color: AppColors.primary),
                  title: Text(miembros[i].fullName),
                  subtitle: Text(
                      miembros[i].relationship != null
                          ? '${miembros[i].label} · ${relationshipLabel(miembros[i].relationship!)}'
                          : miembros[i].label,
                      style: const TextStyle(
                          fontSize: 12, color: AppColors.textSecondary)),
                  trailing: miembros[i].isOwner
                      ? const Text('Admin',
                          style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: AppColors.primary))
                      : soyAdmin
                          ? IconButton(
                              tooltip: 'Quitar del círculo',
                              icon: const Icon(Icons.person_remove_outlined,
                                  color: AppColors.critical),
                              onPressed: () =>
                                  _quitar(context, ref, miembros[i]),
                            )
                          : null,
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  /// Pide confirmacion y quita al miembro. Quitar a alguien le corta el
  /// acceso a la ficha clinica de inmediato, por eso se pregunta antes.
  Future<void> _quitar(
      BuildContext context, WidgetRef ref, CareMember m) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('¿Quitar del círculo de cuidado?'),
        content: Text(
            '${m.fullName} (${m.label}) dejará de ver la información del '
            'adulto mayor. Si después lo necesitas, puedes volver a '
            'invitarlo con un código.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.critical,
              minimumSize: const Size(48, 48),
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Quitar'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ref.read(patientsRepositoryProvider).removeMember(patientId, m.userId);
      ref.invalidate(careTeamProvider);
      if (context.mounted) {
        showAppSnackBar(context, '${m.fullName} ya no está en el círculo.');
      }
    } on ApiException catch (e) {
      if (context.mounted) showAppSnackBar(context, e.message, error: true);
    }
  }

  IconData _icono(CareMember m) {
    if (m.role == 'caregiver' || m.profession == 'cuidadora') {
      return Icons.volunteer_activism_outlined;
    }
    if (m.role == 'family') return Icons.family_restroom_outlined;
    if (m.role == 'elder') return Icons.elderly_outlined;
    return Icons.medical_services_outlined; // profesionales de salud
  }
}

/// Teléfonos de emergencia fijos del sistema chileno. Constantes de la app
/// (SAMU, Carabineros, Bomberos), visibles para marcar rápido.
class _TelefonosEmergencia extends StatelessWidget {
  const _TelefonosEmergencia();

  static const _fijos = <(String, String, IconData)>[
    ('SAMU', '131', Icons.local_hospital_outlined),
    ('Carabineros', '133', Icons.local_police_outlined),
    ('Bomberos', '132', Icons.local_fire_department_outlined),
    (
      'Ambulancia / Salud Responde',
      '600 360 7777',
      Icons.phone_in_talk_outlined
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return AppCard(
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          for (var i = 0; i < _fijos.length; i++) ...[
            if (i != 0) const Divider(height: 1),
            ListTile(
              leading: Icon(_fijos[i].$3, color: AppColors.critical),
              title: Text(_fijos[i].$1),
              trailing: Text(_fijos[i].$2,
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w800)),
            ),
          ],
        ],
      ),
    );
  }
}

class _RcvRow extends StatelessWidget {
  const _RcvRow({required this.level});
  final String? level;

  @override
  Widget build(BuildContext context) {
    final (texto, color) = switch (level) {
      'bajo' => ('Bajo', AppColors.statusOk),
      'moderado' => ('Moderado', AppColors.statusWarning),
      'alto' => ('Alto', AppColors.statusAttention),
      _ => ('No evaluado', AppColors.textSecondary),
    };
    return ListTile(
      leading:
          const Icon(Icons.monitor_heart_outlined, color: AppColors.primary),
      title: const Text('Riesgo cardiovascular',
          style: TextStyle(fontSize: 13, color: AppColors.textSecondary)),
      trailing: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: color.withValues(alpha: .15),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(texto,
            style: TextStyle(
                color: color, fontWeight: FontWeight.w700, fontSize: 13)),
      ),
    );
  }
}

// Textos y colores de complejidad y prioridad (chips de la ficha social).
const _complejidadTextos = {
  'baja': 'Baja',
  'moderada': 'Moderada',
  'alta': 'Alta',
};
const _complejidadColores = {
  'baja': AppColors.statusOk,
  'moderada': AppColors.statusWarning,
  'alta': AppColors.statusAttention,
};
const _prioridadTextos = {'baja': 'Baja', 'media': 'Media', 'alta': 'Alta'};
const _prioridadColores = {
  'baja': AppColors.statusOk,
  'media': AppColors.statusWarning,
  'alta': AppColors.statusAttention,
};

/// Fila genérica de nivel (complejidad/prioridad) con chip de color. Mismo
/// estilo que el RCV: "No evaluado" en gris si viene null.
class _NivelRow extends StatelessWidget {
  const _NivelRow({
    required this.icon,
    required this.label,
    required this.value,
    required this.textos,
    required this.colores,
  });

  final IconData icon;
  final String label;
  final String? value;
  final Map<String, String> textos;
  final Map<String, Color> colores;

  @override
  Widget build(BuildContext context) {
    final texto = textos[value] ?? 'No evaluado';
    final color = colores[value] ?? AppColors.textSecondary;
    return ListTile(
      leading: Icon(icon, color: AppColors.primary),
      title: Text(label,
          style: const TextStyle(fontSize: 13, color: AppColors.textSecondary)),
      trailing: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: color.withValues(alpha: .15),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(texto,
            style: TextStyle(
                color: color, fontWeight: FontWeight.w700, fontSize: 13)),
      ),
    );
  }
}

/// Muestra la última medición: peso, altura e IMC con su clasificación.
class _MeasurementView extends StatelessWidget {
  const _MeasurementView({required this.m});
  final PatientMeasurement m;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        if (m.weightKg != null)
          _metric('Peso', '${m.weightKg!.toStringAsFixed(1)} kg'),
        if (m.heightCm != null)
          _metric('Altura', '${m.heightCm!.toStringAsFixed(0)} cm'),
        if (m.bmi != null) _metric('IMC', '${m.bmi}  ${_imcLabel(m.bmi!)}'),
      ],
    );
  }

  Widget _metric(String label, String value) => Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label,
                style: const TextStyle(
                    fontSize: 12, color: AppColors.textSecondary)),
            const SizedBox(height: 2),
            Text(value,
                style:
                    const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
          ],
        ),
      );

  static String _imcLabel(double bmi) {
    if (bmi < 18.5) return '(bajo)';
    if (bmi < 25) return '(normal)';
    if (bmi < 30) return '(sobrepeso)';
    return '(obesidad)';
  }
}

/// Diálogo para corregir las cuatro partes del nombre. Solo el familiar
/// administrador puede guardarlo (lo controla el backend).
Future<void> _editarNombre(
    BuildContext context, WidgetRef ref, Patient p) async {
  // Datos antiguos que solo traen el nombre completo: se ofrece partido por
  // el primer espacio como punto de partida, para corregir a mano.
  final partes = p.fullName.trim().split(RegExp(r'\s+'));
  final primer = TextEditingController(
      text: p.firstName ?? (partes.isNotEmpty ? partes.first : ''));
  final segundo = TextEditingController(text: p.secondName ?? '');
  final apellido = TextEditingController(
      text: p.lastName ?? (partes.length > 1 ? partes[1] : ''));
  final segundoApellido = TextEditingController(text: p.secondLastName ?? '');
  final formKey = GlobalKey<FormState>();

  Widget campo(
          TextEditingController c, String label, String? Function(String?) v) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: TextFormField(
          controller: c,
          textCapitalization: TextCapitalization.words,
          decoration: InputDecoration(labelText: label),
          validator: v,
        ),
      );

  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Nombre del adulto mayor'),
      content: SingleChildScrollView(
        child: Form(
          key: formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              campo(primer, 'Primer nombre *',
                  (v) => validatePersonName(v, campo: 'el primer nombre')),
              campo(segundo, 'Segundo nombre',
                  (v) => validatePersonName(v, required: false)),
              campo(apellido, 'Primer apellido *',
                  (v) => validatePersonName(v, campo: 'el primer apellido')),
              campo(segundoApellido, 'Segundo apellido',
                  (v) => validatePersonName(v, required: false)),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancelar')),
        FilledButton(
            onPressed: () {
              if (formKey.currentState!.validate()) {
                Navigator.of(ctx).pop(true);
              }
            },
            child: const Text('Guardar')),
      ],
    ),
  );
  if (ok != true) return;
  try {
    await ref.read(patientsRepositoryProvider).updateProfile(p.patientId, {
      'first_name': primer.text.trim(),
      // Vacío borra el segundo nombre o el segundo apellido.
      'second_name': segundo.text.trim(),
      'last_name': apellido.text.trim(),
      'second_last_name': segundoApellido.text.trim(),
    });
    ref.invalidate(selectedPatientDetailProvider);
    ref.invalidate(myPatientsProvider);
    if (context.mounted) showAppSnackBar(context, 'Nombre actualizado.');
  } on ApiException catch (e) {
    if (context.mounted) {
      showAppSnackBar(context, e.detailedMessage, error: true);
    }
  }
}

/// Diálogo para editar la ficha social y el nivel de RCV.
Future<void> _editarPerfil(
    BuildContext context, WidgetRef ref, Patient p) async {
  final address = TextEditingController(text: p.address ?? '');
  String? civil = p.maritalStatus;
  String? prev = p.insurance;
  String? rcv = p.rcvLevel;
  String? complejidad = p.complexity;
  String? prioridad = p.priority;

  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setLocal) => AlertDialog(
        title: const Text('Ficha social y riesgo'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: address,
                decoration: const InputDecoration(labelText: 'Domicilio'),
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                initialValue: civil,
                decoration: const InputDecoration(labelText: 'Estado civil'),
                items: const [
                  DropdownMenuItem(value: 'soltero', child: Text('Soltero(a)')),
                  DropdownMenuItem(value: 'casado', child: Text('Casado(a)')),
                  DropdownMenuItem(value: 'viudo', child: Text('Viudo(a)')),
                  DropdownMenuItem(
                      value: 'divorciado', child: Text('Divorciado(a)')),
                  DropdownMenuItem(
                      value: 'conviviente', child: Text('Conviviente')),
                  DropdownMenuItem(
                      value: 'separado', child: Text('Separado(a)')),
                ],
                onChanged: (v) => setLocal(() => civil = v),
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                initialValue: prev,
                decoration: const InputDecoration(labelText: 'Previsión'),
                items: const [
                  DropdownMenuItem(value: 'fonasa', child: Text('Fonasa')),
                  DropdownMenuItem(value: 'isapre', child: Text('Isapre')),
                  DropdownMenuItem(
                      value: 'particular', child: Text('Particular')),
                  DropdownMenuItem(value: 'otra', child: Text('Otra')),
                ],
                onChanged: (v) => setLocal(() => prev = v),
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                initialValue: rcv,
                decoration: const InputDecoration(
                    labelText: 'Riesgo cardiovascular (MINSAL)'),
                items: const [
                  DropdownMenuItem(value: 'bajo', child: Text('Bajo')),
                  DropdownMenuItem(value: 'moderado', child: Text('Moderado')),
                  DropdownMenuItem(value: 'alto', child: Text('Alto')),
                ],
                onChanged: (v) => setLocal(() => rcv = v),
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                initialValue: complejidad,
                decoration: const InputDecoration(
                    labelText: 'Complejidad (carga clínica)'),
                items: const [
                  DropdownMenuItem(value: 'baja', child: Text('Baja')),
                  DropdownMenuItem(value: 'moderada', child: Text('Moderada')),
                  DropdownMenuItem(value: 'alta', child: Text('Alta')),
                ],
                onChanged: (v) => setLocal(() => complejidad = v),
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                initialValue: prioridad,
                decoration:
                    const InputDecoration(labelText: 'Prioridad de atención'),
                items: const [
                  DropdownMenuItem(value: 'baja', child: Text('Baja')),
                  DropdownMenuItem(value: 'media', child: Text('Media')),
                  DropdownMenuItem(value: 'alta', child: Text('Alta')),
                ],
                onChanged: (v) => setLocal(() => prioridad = v),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancelar')),
          FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Guardar')),
        ],
      ),
    ),
  );
  if (ok != true) return;
  try {
    await ref.read(patientsRepositoryProvider).updateProfile(p.patientId, {
      'address': address.text.trim(),
      if (civil != null) 'marital_status': civil,
      if (prev != null) 'insurance': prev,
      if (rcv != null) 'rcv_level': rcv,
      if (complejidad != null) 'complexity': complejidad,
      if (prioridad != null) 'priority': prioridad,
    });
    ref.invalidate(selectedPatientDetailProvider);
    if (context.mounted) showAppSnackBar(context, 'Perfil actualizado.');
  } on Object catch (e) {
    if (context.mounted) showAppSnackBar(context, e.toString(), error: true);
  }
}

/// Diálogo para registrar una medición de peso/altura.
Future<void> _agregarMedicion(
    BuildContext context, WidgetRef ref, Patient p) async {
  final peso = TextEditingController(
      text: p.latestMeasurement?.weightKg?.toStringAsFixed(1) ?? '');
  final altura = TextEditingController(
      text: p.latestMeasurement?.heightCm?.toStringAsFixed(0) ?? '');

  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Nueva medición'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: peso,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'Peso (kg)'),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: altura,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'Altura (cm)'),
          ),
        ],
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancelar')),
        FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Guardar')),
      ],
    ),
  );
  if (ok != true) return;
  final w = double.tryParse(peso.text.trim().replaceAll(',', '.'));
  final h = double.tryParse(altura.text.trim().replaceAll(',', '.'));
  if (w == null && h == null) {
    if (context.mounted) {
      showAppSnackBar(context, 'Indica al menos peso o altura.', error: true);
    }
    return;
  }
  try {
    await ref
        .read(patientsRepositoryProvider)
        .addMeasurement(p.patientId, weightKg: w, heightCm: h);
    ref.invalidate(selectedPatientDetailProvider);
    if (context.mounted) showAppSnackBar(context, 'Medición registrada.');
  } on Object catch (e) {
    if (context.mounted) showAppSnackBar(context, e.toString(), error: true);
  }
}

class _Cabecera extends StatelessWidget {
  const _Cabecera({required this.patient});
  final Patient patient;

  @override
  Widget build(BuildContext context) => AppCard(
        child: Row(
          children: [
            InitialsAvatar(
                name: patient.fullName, photoUrl: patient.photoUrl, radius: 30),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(patient.fullName,
                      style: const TextStyle(
                          fontSize: 18, fontWeight: FontWeight.w800)),
                  // La edad ya está en Identidad, con su rótulo. Aquí va el
                  // RUT, que es lo que distingue a dos personas homónimas.
                  if ((patient.rut ?? '').isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text('RUT ${patient.rut}',
                        style: const TextStyle(
                            fontSize: 14, color: AppColors.textSecondary)),
                  ],
                ],
              ),
            ),
          ],
        ),
      );
}

/// Tarjeta de alergias. Las graves (severa/anafilaxia) se destacan en rojo para
/// que salten a la vista; una alergia no vista puede ser fatal en una urgencia.
class _AlergiasCard extends StatelessWidget {
  const _AlergiasCard({required this.allergies});
  final List<AllergyDetail> allergies;

  @override
  Widget build(BuildContext context) {
    if (allergies.isEmpty) {
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

    // Agrupadas por categoría, con las graves arriba (ya vienen ordenadas).
    final porCat = <String, List<AllergyDetail>>{};
    for (final a in allergies) {
      porCat.putIfAbsent(a.category, () => []).add(a);
    }
    const orden = ['medicamento', 'alimento', 'ambiental', 'otra'];
    final cats = porCat.keys.toList()
      ..sort((a, b) => orden.indexOf(a).compareTo(orden.indexOf(b)));

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final cat in cats) ...[
            Padding(
              padding: const EdgeInsets.only(top: 8, bottom: 6),
              child: Text(allergyCategoryLabel(cat),
                  style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textSecondary)),
            ),
            for (final a in porCat[cat]!) _AlergiaTile(allergy: a),
          ],
        ],
      ),
    );
  }
}

class _AlergiaTile extends StatelessWidget {
  const _AlergiaTile({required this.allergy});
  final AllergyDetail allergy;

  @override
  Widget build(BuildContext context) {
    final color =
        allergy.esGrave ? AppColors.critical : AppColors.statusWarning;
    final detalle = <String>[
      allergySeverityLabel(allergy.severity),
      if (allergy.reaction != null && allergy.reaction!.trim().isNotEmpty)
        allergy.reaction!.trim(),
      if (allergy.source != null) allergySourceLabel(allergy.source!),
    ].join(' · ');

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            allergy.esGrave
                ? Icons.warning_rounded
                : Icons.info_outline_rounded,
            color: color,
            size: 20,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(allergy.label,
                    style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: color,
                        fontSize: 14)),
                if (detalle.isNotEmpty)
                  Text(detalle,
                      style: const TextStyle(
                          fontSize: 12, color: AppColors.textSecondary)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Diálogo para gestionar alergias: ver las vigentes, quitar una (baja lógica)
/// y agregar una nueva descubierta (con severidad, reacción y origen). Las
/// alergias se descubren en el tiempo: al diagnosticar, por test, o por una
/// reacción durante un tratamiento.
Future<void> _editarAlergias(
    BuildContext context, WidgetRef ref, Patient p) async {
  final repo = ref.read(patientsRepositoryProvider);
  final catalogo = await repo.allergenCatalog();
  var lista = List<AllergyDetail>.from(p.allergies);

  // Campos del formulario de nueva alergia.
  AllergenCatalogItem? elegido;
  final libreCtrl = TextEditingController();
  final reaccionCtrl = TextEditingController();
  var severidad = 'moderada';
  var origen = 'reportada';
  var categoria = 'otra';

  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setLocal) {
        Future<void> agregar() async {
          if (elegido == null) {
            final error = validateAllergenName(libreCtrl.text);
            if (error != null) {
              showAppSnackBar(ctx, error, error: true);
              return;
            }
          }
          final code = elegido?.code ??
              libreCtrl.text.trim().replaceAll(RegExp(r'\s+'), ' ');
          final cat = elegido?.category ?? categoria;
          final nueva = AllergyDetail(
            substance: code,
            label: elegido?.label ?? code,
            category: cat,
            severity: severidad,
            reaction: reaccionCtrl.text,
            source: origen,
          );
          try {
            final actualizada = await repo.addAllergy(p.patientId, nueva);
            setLocal(() {
              lista = actualizada;
              elegido = null;
              libreCtrl.clear();
              reaccionCtrl.clear();
              severidad = 'moderada';
              origen = 'reportada';
              categoria = 'otra';
            });
          } on Object catch (e) {
            if (ctx.mounted) showAppSnackBar(ctx, e.toString(), error: true);
          }
        }

        Future<void> quitar(AllergyDetail a) async {
          try {
            final actualizada =
                await repo.removeAllergy(p.patientId, a.substance);
            setLocal(() => lista = actualizada);
          } on Object catch (e) {
            if (ctx.mounted) showAppSnackBar(ctx, e.toString(), error: true);
          }
        }

        return AlertDialog(
          title: const Text('Alergias'),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (lista.isEmpty)
                    const Text('Sin alergias. Agrega la primera abajo.',
                        style: TextStyle(color: AppColors.textSecondary))
                  else
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final a in lista)
                          Chip(
                            label: Text(
                                '${a.label} (${allergySeverityLabel(a.severity)})'),
                            backgroundColor: a.esGrave
                                ? AppColors.critical.withValues(alpha: .10)
                                : AppColors.statusWarning
                                    .withValues(alpha: .12),
                            onDeleted: () => quitar(a),
                          ),
                      ],
                    ),
                  const Divider(height: 24),
                  const Text('Agregar alergia',
                      style: TextStyle(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 8),
                  // Selector del catálogo (hereda categoría) o texto libre.
                  DropdownButtonFormField<AllergenCatalogItem?>(
                    initialValue: elegido,
                    isExpanded: true,
                    decoration: const InputDecoration(
                        labelText: 'Alérgeno (del catálogo)'),
                    items: [
                      const DropdownMenuItem(
                          value: null, child: Text('Otra (escribir)')),
                      for (final c in catalogo)
                        DropdownMenuItem(
                            value: c,
                            child: Text(
                                '${c.label} · ${allergyCategoryLabel(c.category)}')),
                    ],
                    onChanged: (v) => setLocal(() => elegido = v),
                  ),
                  if (elegido == null) ...[
                    const SizedBox(height: 8),
                    TextField(
                      controller: libreCtrl,
                      textCapitalization: TextCapitalization.sentences,
                      decoration: const InputDecoration(
                        labelText: '¿A qué es alérgico?',
                        hintText: 'Ej: Kiwi, Contraste yodado',
                      ),
                    ),
                    const SizedBox(height: 8),
                    DropdownButtonFormField<String>(
                      initialValue: categoria,
                      decoration: const InputDecoration(labelText: 'Categoría'),
                      items: const [
                        DropdownMenuItem(
                            value: 'medicamento', child: Text('Medicamento')),
                        DropdownMenuItem(
                            value: 'alimento', child: Text('Alimento')),
                        DropdownMenuItem(
                            value: 'ambiental', child: Text('Ambiental')),
                        DropdownMenuItem(value: 'otra', child: Text('Otra')),
                      ],
                      onChanged: (v) => setLocal(() => categoria = v ?? 'otra'),
                    ),
                  ],
                  const SizedBox(height: 8),
                  DropdownButtonFormField<String>(
                    initialValue: severidad,
                    decoration: const InputDecoration(labelText: 'Severidad'),
                    items: const [
                      DropdownMenuItem(value: 'leve', child: Text('Leve')),
                      DropdownMenuItem(
                          value: 'moderada', child: Text('Moderada')),
                      DropdownMenuItem(value: 'severa', child: Text('Severa')),
                      DropdownMenuItem(
                          value: 'anafilaxia', child: Text('Anafilaxia')),
                    ],
                    onChanged: (v) =>
                        setLocal(() => severidad = v ?? 'moderada'),
                  ),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<String>(
                    initialValue: origen,
                    decoration:
                        const InputDecoration(labelText: 'Cómo se supo'),
                    items: const [
                      DropdownMenuItem(
                          value: 'reportada', child: Text('Reportada')),
                      DropdownMenuItem(
                          value: 'test', child: Text('Test de alergias')),
                      DropdownMenuItem(
                          value: 'reaccion_tratamiento',
                          child: Text('Reacción en tratamiento')),
                    ],
                    onChanged: (v) => setLocal(() => origen = v ?? 'reportada'),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: reaccionCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Reacción (opcional)',
                      hintText: 'Ej: urticaria, edema',
                    ),
                  ),
                  const SizedBox(height: 10),
                  Align(
                    alignment: Alignment.centerRight,
                    child: FilledButton.icon(
                      onPressed: agregar,
                      icon: const Icon(Icons.add_rounded, size: 18),
                      label: const Text('Agregar'),
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Listo')),
          ],
        );
      },
    ),
  );

  ref.invalidate(selectedPatientDetailProvider);
  ref.invalidate(myPatientsProvider);
}

/// Tarjeta del carnet de vacunas. Separa las preventivas (con próxima dosis,
/// que avisa si está vencida) de las de post-exposición (evento fechado).
class _VacunasCard extends StatelessWidget {
  const _VacunasCard({required this.immunizations});
  final List<Immunization> immunizations;

  @override
  Widget build(BuildContext context) {
    if (immunizations.isEmpty) {
      return const AppCard(
        child: Row(
          children: [
            Icon(Icons.vaccines_outlined,
                color: AppColors.textSecondary, size: 20),
            SizedBox(width: 10),
            Expanded(
              child: Text('Sin vacunas registradas.',
                  style: TextStyle(color: AppColors.textSecondary)),
            ),
          ],
        ),
      );
    }
    final preventivas =
        immunizations.where((v) => !v.esPostExposicion).toList();
    final postExp = immunizations.where((v) => v.esPostExposicion).toList();

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (preventivas.isNotEmpty) ...[
            const Padding(
              padding: EdgeInsets.only(top: 8, bottom: 6),
              child: Text('Preventivas',
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textSecondary)),
            ),
            for (final v in preventivas) _VacunaTile(vaccine: v),
          ],
          if (postExp.isNotEmpty) ...[
            const Padding(
              padding: EdgeInsets.only(top: 8, bottom: 6),
              child: Text('Post-exposición',
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textSecondary)),
            ),
            for (final v in postExp) _VacunaTile(vaccine: v),
          ],
        ],
      ),
    );
  }
}

class _VacunaTile extends StatelessWidget {
  const _VacunaTile({required this.vaccine});
  final Immunization vaccine;

  static String _fecha(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';

  @override
  Widget build(BuildContext context) {
    final sub = <String>[
      if (vaccine.administeredOn != null)
        'Aplicada ${_fecha(vaccine.administeredOn!)}',
      if (vaccine.doseNumber != null) 'dosis ${vaccine.doseNumber}',
      if (vaccine.exposureEvent != null &&
          vaccine.exposureEvent!.trim().isNotEmpty)
        vaccine.exposureEvent!.trim(),
    ].join(' · ');

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.vaccines_rounded,
              color: vaccine.vencida ? AppColors.critical : AppColors.statusOk,
              size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(vaccine.label,
                    style: const TextStyle(
                        fontWeight: FontWeight.w700, fontSize: 14)),
                if (sub.isNotEmpty)
                  Text(sub,
                      style: const TextStyle(
                          fontSize: 12, color: AppColors.textSecondary)),
                if (vaccine.nextDueOn != null)
                  Text(
                    vaccine.vencida
                        ? 'Próxima dosis vencida (${_fecha(vaccine.nextDueOn!)})'
                        : 'Próxima dosis: ${_fecha(vaccine.nextDueOn!)}',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: vaccine.vencida
                          ? AppColors.critical
                          : AppColors.statusWarning,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Diálogo para gestionar el carnet de vacunas: ver, quitar y registrar una
/// nueva (del catálogo). La próxima dosis de las preventivas recurrentes la
/// calcula el backend; las de post-exposición piden el evento que las gatilló.
Future<void> _editarVacunas(
    BuildContext context, WidgetRef ref, Patient p) async {
  final repo = ref.read(patientsRepositoryProvider);
  final catalogo = await repo.vaccineCatalog();
  var lista = List<Immunization>.from(p.immunizations);

  VaccineCatalogItem? elegido;
  DateTime? aplicada = DateTime.now();
  final eventoCtrl = TextEditingController();
  final notaCtrl = TextEditingController();
  final doseCtrl = TextEditingController();

  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setLocal) {
        final esPostExp = elegido?.kindDefault == 'post_exposicion';

        Future<void> agregar() async {
          if (elegido == null || aplicada == null) return;
          final nueva = Immunization(
            vaccine: elegido!.code,
            label: elegido!.label,
            kind: elegido!.kindDefault,
            administeredOn: aplicada,
            doseNumber: int.tryParse(doseCtrl.text.trim()),
            exposureEvent: esPostExp ? eventoCtrl.text : null,
            note: notaCtrl.text,
          );
          try {
            final actualizada = await repo.addImmunization(p.patientId, nueva);
            setLocal(() {
              lista = actualizada;
              elegido = null;
              aplicada = DateTime.now();
              eventoCtrl.clear();
              notaCtrl.clear();
              doseCtrl.clear();
            });
          } on Object catch (e) {
            if (ctx.mounted) showAppSnackBar(ctx, e.toString(), error: true);
          }
        }

        Future<void> quitar(Immunization v) async {
          try {
            final actualizada =
                await repo.removeImmunization(p.patientId, v.vaccine);
            setLocal(() => lista = actualizada);
          } on Object catch (e) {
            if (ctx.mounted) showAppSnackBar(ctx, e.toString(), error: true);
          }
        }

        return AlertDialog(
          title: const Text('Vacunas'),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (lista.isEmpty)
                    const Text('Sin vacunas. Registra la primera abajo.',
                        style: TextStyle(color: AppColors.textSecondary))
                  else
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final v in lista)
                          Chip(
                            label: Text(v.label),
                            onDeleted: () => quitar(v),
                          ),
                      ],
                    ),
                  const Divider(height: 24),
                  const Text('Registrar vacuna',
                      style: TextStyle(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<VaccineCatalogItem>(
                    initialValue: elegido,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Vacuna'),
                    items: [
                      for (final c in catalogo)
                        DropdownMenuItem(
                            value: c,
                            child: Text(
                                '${c.label} · ${vaccineKindLabel(c.kindDefault)}')),
                    ],
                    onChanged: (v) => setLocal(() => elegido = v),
                  ),
                  if (elegido?.targetGroup != null) ...[
                    const SizedBox(height: 6),
                    Text(elegido!.targetGroup!,
                        style: const TextStyle(
                            fontSize: 12, color: AppColors.textSecondary)),
                  ],
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: () async {
                      final hoy = DateTime.now();
                      final picked = await showDatePicker(
                        context: ctx,
                        initialDate: aplicada ?? hoy,
                        firstDate: DateTime(hoy.year - 30),
                        lastDate: hoy,
                      );
                      if (picked != null) setLocal(() => aplicada = picked);
                    },
                    icon: const Icon(Icons.event_rounded, size: 18),
                    label: Text(aplicada == null
                        ? 'Fecha de aplicación'
                        : 'Aplicada ${_VacunaTile._fecha(aplicada!)}'),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: doseCtrl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'N.º de dosis (opcional)',
                      hintText: 'Ej: 1',
                    ),
                  ),
                  if (esPostExp) ...[
                    const SizedBox(height: 8),
                    TextField(
                      controller: eventoCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Evento que la gatilló',
                        hintText: 'Ej: mordedura de perro',
                      ),
                    ),
                  ],
                  const SizedBox(height: 8),
                  TextField(
                    controller: notaCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Nota (opcional)',
                    ),
                  ),
                  const SizedBox(height: 10),
                  Align(
                    alignment: Alignment.centerRight,
                    child: FilledButton.icon(
                      onPressed: elegido == null ? null : agregar,
                      icon: const Icon(Icons.add_rounded, size: 18),
                      label: const Text('Registrar'),
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Listo')),
          ],
        );
      },
    ),
  );

  ref.invalidate(selectedPatientDetailProvider);
  ref.invalidate(myPatientsProvider);
}

/// Lista de contactos de emergencia del paciente (del grupo, rotativos). Los
/// activos primero, en orden de escalamiento; botón para llamar directo.
class _ContactosEmergenciaCard extends ConsumerWidget {
  const _ContactosEmergenciaCard({required this.patientId});
  final String patientId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(emergencyContactsProvider(patientId));
    return async.when(
      loading: () => const AppCard(child: LinearProgressIndicator()),
      error: (e, _) => const AppCard(
        child: Text('No se pudieron cargar los contactos.',
            style: TextStyle(color: AppColors.textSecondary)),
      ),
      data: (contactos) {
        if (contactos.isEmpty) {
          return const AppCard(
            child: Row(
              children: [
                Icon(Icons.contact_phone_outlined,
                    color: AppColors.textSecondary, size: 20),
                SizedBox(width: 10),
                Expanded(
                  child: Text(
                      'Sin contactos de emergencia. Agrégalos desde "Gestionar".',
                      style: TextStyle(color: AppColors.textSecondary)),
                ),
              ],
            ),
          );
        }
        final activos = contactos.where((c) => c.isActive).toList();
        final inactivos = contactos.where((c) => !c.isActive).toList();
        return AppCard(
          child: Column(
            children: [
              for (final c in activos) _ContactoTile(contacto: c, activo: true),
              if (inactivos.isNotEmpty) ...[
                const Divider(height: 18),
                const Align(
                  alignment: Alignment.centerLeft,
                  child: Text('No disponibles ahora',
                      style: TextStyle(
                          fontSize: 12, color: AppColors.textSecondary)),
                ),
                for (final c in inactivos)
                  _ContactoTile(contacto: c, activo: false),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _ContactoTile extends StatelessWidget {
  const _ContactoTile({required this.contacto, required this.activo});
  final EmergencyContact contacto;
  final bool activo;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          CircleAvatar(
            radius: 16,
            backgroundColor: activo
                ? AppColors.primary.withValues(alpha: .12)
                : Colors.black12,
            child: Icon(Icons.person_rounded,
                size: 18,
                color: activo ? AppColors.primary : AppColors.textSecondary),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(contacto.name,
                    style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: activo
                            ? AppColors.textPrimary
                            : AppColors.textSecondary)),
                if (contacto.phone != null)
                  Text(contacto.phone!,
                      style: const TextStyle(
                          fontSize: 12, color: AppColors.textSecondary)),
              ],
            ),
          ),
          if (activo && contacto.phone != null)
            IconButton(
              tooltip: 'Llamar',
              icon: const Icon(Icons.call_rounded, color: AppColors.statusOk),
              onPressed: () => launchUrl(Uri.parse('tel:${contacto.phone}')),
            ),
        ],
      ),
    );
  }
}

/// Diálogo para gestionar contactos de emergencia: elegir del grupo, activar/
/// desactivar (rotación) y quitar. Sin prioridad: en un SOS se avisa a todos.
/// Solo el administrador.
Future<void> _editarContactos(
    BuildContext context, WidgetRef ref, Patient p) async {
  final repo = ref.read(patientsRepositoryProvider);
  final miembros = await repo.listMembers(p.patientId);
  var contactos = await repo.emergencyContacts(p.patientId);

  CareMember? elegido;

  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setLocal) {
        // Miembros que aún no son contacto vigente.
        final yaContacto =
            contactos.map((c) => c.memberUserId).whereType<String>().toSet();
        final disponibles =
            miembros.where((m) => !yaContacto.contains(m.userId)).toList();

        Future<void> agregar() async {
          if (elegido == null) return;
          try {
            contactos = await repo.addEmergencyContact(
              p.patientId,
              memberUserId: elegido!.userId,
            );
            setLocal(() => elegido = null);
          } on Object catch (e) {
            if (ctx.mounted) showAppSnackBar(ctx, e.toString(), error: true);
          }
        }

        Future<void> toggle(EmergencyContact c) async {
          try {
            contactos = await repo.updateEmergencyContact(p.patientId, c.id,
                isActive: !c.isActive);
            setLocal(() {});
          } on Object catch (e) {
            if (ctx.mounted) showAppSnackBar(ctx, e.toString(), error: true);
          }
        }

        Future<void> quitar(EmergencyContact c) async {
          try {
            contactos = await repo.removeEmergencyContact(p.patientId, c.id);
            setLocal(() {});
          } on Object catch (e) {
            if (ctx.mounted) showAppSnackBar(ctx, e.toString(), error: true);
          }
        }

        return AlertDialog(
          title: const Text('Contactos de emergencia'),
          content: SizedBox(
            width: 440,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Se eligen del grupo de cuidado. Activa quién está '
                    'disponible ahora; desactiva a quien no pueda responder.',
                    style:
                        TextStyle(fontSize: 12, color: AppColors.textSecondary),
                  ),
                  const SizedBox(height: 10),
                  if (contactos.isEmpty)
                    const Text('Sin contactos aún.',
                        style: TextStyle(color: AppColors.textSecondary))
                  else
                    for (final c in contactos)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        leading: const CircleAvatar(
                          radius: 14,
                          child: Icon(Icons.person_rounded, size: 16),
                        ),
                        title: Text(c.name,
                            style: TextStyle(
                                color: c.isActive
                                    ? AppColors.textPrimary
                                    : AppColors.textSecondary)),
                        subtitle: Text(c.isActive ? 'Activo' : 'No disponible',
                            style: const TextStyle(fontSize: 12)),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Switch(
                              value: c.isActive,
                              activeThumbColor: AppColors.primary,
                              onChanged: (_) => toggle(c),
                            ),
                            IconButton(
                              icon: const Icon(Icons.delete_outline_rounded,
                                  color: AppColors.critical, size: 20),
                              onPressed: () => quitar(c),
                            ),
                          ],
                        ),
                      ),
                  const Divider(height: 24),
                  const Text('Agregar contacto',
                      style: TextStyle(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 8),
                  if (disponibles.isEmpty)
                    const Text('Todos los miembros ya son contacto.',
                        style: TextStyle(
                            fontSize: 12, color: AppColors.textSecondary))
                  else ...[
                    DropdownButtonFormField<CareMember>(
                      initialValue: elegido,
                      isExpanded: true,
                      decoration:
                          const InputDecoration(labelText: 'Miembro del grupo'),
                      items: [
                        for (final m in disponibles)
                          DropdownMenuItem(
                              value: m,
                              child: Text('${m.fullName} · ${m.label}')),
                      ],
                      onChanged: (v) => setLocal(() => elegido = v),
                    ),
                    const SizedBox(height: 10),
                    Align(
                      alignment: Alignment.centerRight,
                      child: FilledButton.icon(
                        onPressed: elegido == null ? null : agregar,
                        icon: const Icon(Icons.add_rounded, size: 18),
                        label: const Text('Agregar'),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Listo')),
          ],
        );
      },
    ),
  );

  ref.invalidate(emergencyContactsProvider(p.patientId));
}

/// Acción para generar la hoja de emergencia en PDF: un resumen clínico que se
/// puede mostrar o enviar a un paramédico / doctor de turno en una urgencia.
/// Rol de quien mira sobre ESTE adulto mayor; sin membresía conocida, su
/// tipo de cuenta.
RoleType? _rolSobre(WidgetRef ref, String patientId) {
  final user = ref.watch(currentUserProvider);
  if (user == null) return null;
  for (final m in user.memberships) {
    if (m.patientId == patientId) return m.role;
  }
  return user.primaryRole;
}

class _HojaEmergenciaCard extends ConsumerStatefulWidget {
  const _HojaEmergenciaCard({required this.patientId, required this.nombre});
  final String patientId;
  final String nombre;

  @override
  ConsumerState<_HojaEmergenciaCard> createState() =>
      _HojaEmergenciaCardState();
}

class _HojaEmergenciaCardState extends ConsumerState<_HojaEmergenciaCard> {
  bool _generando = false;

  Future<void> _generar() async {
    setState(() => _generando = true);
    try {
      final bytes = await ref
          .read(reportsRepositoryProvider)
          .emergencySheet(widget.patientId);
      final safe = widget.nombre.replaceAll(RegExp(r'[^a-zA-Z0-9]+'), '_');
      final ok = await savePdf(bytes, 'hoja_emergencia_$safe.pdf');
      if (mounted && !ok) {
        showAppSnackBar(context, 'No se pudo abrir el PDF.', error: true);
      }
    } on Object catch (e) {
      if (mounted) showAppSnackBar(context, e.toString(), error: true);
    } finally {
      if (mounted) setState(() => _generando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Resumen clínico de 1 página para mostrar a un paramédico o médico '
            'de turno: identidad, alergias, tratamiento vigente, últimos signos '
            'vitales y contactos.',
            style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _generando ? null : _generar,
              icon: _generando
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.picture_as_pdf_rounded),
              label: Text(
                  _generando ? 'Generando…' : 'Generar hoja de emergencia'),
            ),
          ),
        ],
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
        child: Text(text.toUpperCase(),
            style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: AppColors.textSecondary,
                letterSpacing: .5)),
      );
}

class _DataRow extends StatelessWidget {
  const _DataRow(
      {required this.icon, required this.label, required this.value});
  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => ListTile(
        leading: Icon(icon, color: AppColors.primary),
        title: Text(label,
            style:
                const TextStyle(fontSize: 13, color: AppColors.textSecondary)),
        trailing: Text(value,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
      );
}
