import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/config/app_config.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/common.dart';
import '../../patients/application/patients_providers.dart';

/// Hub de comunicación: chat humano con el equipo de cuidado y asistente IA.
class CommsScreen extends ConsumerWidget {
  const CommsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final patient = ref.watch(selectedPatientProvider);

    if (patient == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Comunicación')),
        body: const EmptyView(
          icon: Icons.forum_rounded,
          title: 'Sin paciente seleccionado',
          subtitle:
              'Selecciona a un paciente para abrir el chat del equipo de '
              'cuidado o hablar con el asistente.',
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Comunicación')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          Text(
            'Sobre ${patient.fullName}',
            style: const TextStyle(color: AppColors.textSecondary),
          ),
          const SizedBox(height: 12),
          _HubCard(
            icon: Icons.groups_rounded,
            iconColor: AppColors.primary,
            title: 'Chat con el equipo de cuidado',
            description:
                'Conversa en tiempo real con la familia y la cuidadora. '
                'Envía texto, fotos y notas de voz.',
            // Backend aún no implementa el chat: deshabilitado fuera de demo.
            comingSoon: !AppConfig.hasComms,
            onTap: () =>
                context.push('/chat?patient=${patient.patientId}'),
          ),
          const SizedBox(height: 12),
          _HubCard(
            icon: Icons.smart_toy_rounded,
            iconColor: AppColors.secondary,
            title: 'Asistente IA',
            description:
                'Pregunta sobre el expediente: sueño, medicamentos, signos '
                'vitales y más. Responde con referencias al expediente.',
            // Backend aún no implementa el asistente IA.
            comingSoon: !AppConfig.hasComms,
            onTap: () =>
                context.push('/assistant?patient=${patient.patientId}'),
          ),
        ],
      ),
    );
  }
}

class _HubCard extends StatelessWidget {
  const _HubCard({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.description,
    required this.onTap,
    this.comingSoon = false,
  });

  final IconData icon;
  final Color iconColor;
  final String title;
  final String description;
  final VoidCallback onTap;

  /// Si es true, la tarjeta se muestra atenuada con una etiqueta
  /// "Próximamente" y no navega (la función aún no existe en el backend).
  final bool comingSoon;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: comingSoon ? 0.6 : 1,
      child: AppCard(
        onTap: comingSoon
            ? () => showAppSnackBar(
                  context,
                  'Esta función estará disponible próximamente.',
                )
            : onTap,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: iconColor.withOpacity(.12),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Icon(icon, size: 30, color: iconColor),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          title,
                          style: const TextStyle(
                              fontSize: 17, fontWeight: FontWeight.w700),
                        ),
                      ),
                      if (comingSoon) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: AppColors.divider,
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: const Text(
                            'Próximamente',
                            style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: AppColors.textSecondary),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    description,
                    style: const TextStyle(color: AppColors.textSecondary),
                  ),
                ],
              ),
            ),
            if (!comingSoon)
              const Padding(
                padding: EdgeInsets.only(top: 4, left: 8),
                child: Icon(Icons.chevron_right_rounded,
                    color: AppColors.textSecondary),
              ),
          ],
        ),
      ),
    );
  }
}
