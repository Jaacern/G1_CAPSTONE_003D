import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/bloques.dart';
import '../../../core/widgets/common.dart';
import '../application/treatments_providers.dart';
import '../domain/treatment.dart';

/// Línea de tiempo del tratamiento (Hito 3, DEF-011).
///
/// Muestra, por fármaco, cómo evolucionó su dosis a lo largo del año
/// ("losartán 50 → 100 → 80"), reconstruido desde la cadena de tratamientos.
/// Es lo que el médico mira para tomar una decisión.
class TreatmentHistoryScreen extends ConsumerWidget {
  const TreatmentHistoryScreen({super.key, required this.patientId});

  final String patientId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bundle = ref.watch(treatmentsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Historial de tratamiento')),
      body: bundle.when(
        loading: () => const LoadingView(),
        error: (e, _) => ErrorView(
          message: e.toString(),
          onRetry: () => ref.invalidate(treatmentsProvider),
        ),
        data: (b) {
          if (b.bySpecialty.isEmpty) {
            return const EmptyView(
              icon: Icons.history_rounded,
              title: 'Sin historial',
              subtitle: 'Aún no hay tratamientos registrados para este paciente.',
            );
          }
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
            children: [
              for (final g in b.bySpecialty) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 16, 4, 8),
                  child: Row(
                    children: [
                      const Icon(Icons.local_hospital_rounded,
                          size: 18, color: AppColors.primary),
                      const SizedBox(width: 8),
                      Text(specialtyLabel(g.specialty),
                          style: const TextStyle(
                              fontSize: 15, fontWeight: FontWeight.w700)),
                    ],
                  ),
                ),
                for (final entry in _porFarmaco(g).entries)
                  _FarmacoTimeline(nombre: entry.key, versiones: entry.value),
              ],
            ],
          );
        },
      ),
    );
  }

  /// Agrupa las versiones de los fármacos de UNA especialidad (vigente +
  /// histórico) por nombre, ordenadas de más reciente a más antigua.
  Map<String, List<_Version>> _porFarmaco(SpecialtyGroup g) {
    final mapa = <String, List<_Version>>{};
    void agregar(Treatment? t) {
      if (t == null) return;
      for (final it in t.items) {
        mapa.putIfAbsent(it.name, () => []).add(_Version(
              dose: it.dose,
              times: it.times,
              action: it.action,
              status: t.status,
              desde: t.effectiveFrom,
              hasta: t.effectiveTo,
            ));
      }
    }

    agregar(g.current);
    for (final h in g.history) {
      agregar(h);
    }
    for (final lista in mapa.values) {
      lista.sort((a, z) => z.desde.compareTo(a.desde));
    }
    return mapa;
  }
}

class _Version {
  _Version({
    required this.dose,
    required this.times,
    required this.action,
    required this.status,
    required this.desde,
    this.hasta,
  });
  final String dose;
  final List<String> times;
  final String action;
  final String status;
  final DateTime desde;
  final DateTime? hasta;

  bool get vigente => status == 'vigente';
}

class _FarmacoTimeline extends StatelessWidget {
  const _FarmacoTimeline({required this.nombre, required this.versiones});

  final String nombre;
  final List<_Version> versiones;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.medication_rounded, color: AppColors.primary),
              const SizedBox(width: 8),
              Text(nombre,
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w700)),
            ],
          ),
          const SizedBox(height: 12),
          for (var i = 0; i < versiones.length; i++)
            _VersionRow(
              version: versiones[i],
              esUltima: i == versiones.length - 1,
            ),
        ],
      ),
    );
  }
}

class _VersionRow extends StatelessWidget {
  const _VersionRow({required this.version, required this.esUltima});

  final _Version version;
  final bool esUltima;

  @override
  Widget build(BuildContext context) {
    final color = version.vigente ? AppColors.statusOk : AppColors.textSecondary;
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Column(
            children: [
              Container(
                width: 12,
                height: 12,
                margin: const EdgeInsets.only(top: 4),
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
              if (!esUltima)
                Expanded(
                  child: Container(width: 2, color: AppColors.divider),
                ),
            ],
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(version.dose,
                          style: const TextStyle(
                              fontWeight: FontWeight.w700, fontSize: 15)),
                      const SizedBox(width: 8),
                      if (version.vigente)
                        const Etiqueta('Vigente', tono: AgeColors.ok700),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(version.times.join(' · '),
                      style: const TextStyle(
                          color: AppColors.textSecondary, fontSize: 13)),
                  Text(
                    _rango(version),
                    style: const TextStyle(
                        color: AppColors.textSecondary, fontSize: 12),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _rango(_Version v) {
    final d = _fecha(v.desde);
    if (v.vigente) return 'Desde $d';
    return v.hasta != null ? '$d — ${_fecha(v.hasta!)}' : 'Desde $d';
  }

  String _fecha(DateTime dt) =>
      '${dt.day.toString().padLeft(2, '0')}/${dt.month.toString().padLeft(2, '0')}/${dt.year}';
}

