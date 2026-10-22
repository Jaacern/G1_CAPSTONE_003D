import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/config/app_config.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/theme_controller.dart';
import '../../core/widgets/common.dart';
import '../auth/application/auth_controller.dart';
import '../auth/domain/models.dart';
import '../patients/application/patients_providers.dart';

/// Pestaña "Más" (fiel al wireframe Familiar v1): perfil, lista de pacientes,
/// roles e invitaciones, y notificaciones/ajustes. Los accesos a módulos sin
/// backend (Marketplace, Documentos) solo aparecen en modo demo.
class MoreScreen extends ConsumerWidget {
  const MoreScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(currentUserProvider);
    final role = user?.primaryRole ?? RoleType.family;
    final patientsAsync = ref.watch(myPatientsProvider);
    final patient = ref.watch(selectedPatientProvider);
    final pq = patient != null ? '?patient=${patient.patientId}' : '';

    return Scaffold(
      appBar: AppBar(title: const Text('Más')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          // ---- Cuenta ----
          AppCard(
            onTap: () => context.push('/profile'),
            child: Row(
              children: [
                InitialsAvatar(
                  name: user?.fullName ?? '?',
                  photoUrl: user?.avatarUrl,
                  radius: 26,
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(user?.fullName ?? '',
                          style: const TextStyle(
                              fontWeight: FontWeight.w700, fontSize: 16)),
                      const SizedBox(height: 2),
                      Text(user?.email ?? '',
                          style: const TextStyle(
                              color: AppColors.textSecondary, fontSize: 13)),
                    ],
                  ),
                ),
                _RoleBadge(role: role),
                const SizedBox(width: 4),
                const Icon(Icons.chevron_right_rounded,
                    color: AppColors.textSecondary),
              ],
            ),
          ),

          // ---- Pacientes ----
          const _SectionLabel('Pacientes'),
          patientsAsync.when(
            loading: () => const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: LoadingView(),
            ),
            error: (_, __) => const SizedBox.shrink(),
            data: (patients) => _ListGroup(
              children: [
                for (final p in patients)
                  _MoreTile(
                    leading: Icon(p.wellbeingStatus.icon,
                        color: p.wellbeingStatus.color),
                    title: p.fullName,
                    subtitle: p.activeAlertsCount > 0
                        ? '${p.activeAlertsCount} alerta(s) activa(s)'
                        : p.role.label,
                    onTap: () => ref
                        .read(selectedPatientProvider.notifier)
                        .select(p),
                  ),
                if (role == RoleType.family)
                  _MoreTile(
                    leading: const Icon(Icons.add_rounded,
                        color: AppColors.primary),
                    title: 'Añadir paciente',
                    titleColor: AppColors.primary,
                    onTap: () => context.push('/patients/create'),
                  ),
              ],
            ),
          ),

          // ---- Roles e invitaciones ----
          const _SectionLabel('Roles e invitaciones'),
          _ListGroup(
            children: [
              if (role == RoleType.family)
                _MoreTile(
                  leading: const Icon(Icons.group_add_outlined,
                      color: AppColors.primary),
                  title: 'Invitar a alguien',
                  subtitle: 'Cuidadora, médico u otro familiar',
                  titleColor: AppColors.primary,
                  onTap: () => context.push('/invite'),
                )
              else
                _MoreTile(
                  leading:
                      const Icon(Icons.pin_outlined, color: AppColors.primary),
                  title: 'Unirme con un código',
                  titleColor: AppColors.primary,
                  onTap: () => context.push('/invite/accept'),
                ),
            ],
          ),

          // ---- Descubrir (solo módulos con soporte/demo) ----
          if (AppConfig.hasMarketplace || AppConfig.hasDocuments) ...[
            const _SectionLabel('Descubrir'),
            _ListGroup(
              children: [
                if (AppConfig.hasDocuments)
                  _MoreTile(
                    leading: const Icon(Icons.folder_outlined),
                    title: 'Expediente y documentos',
                    onTap: () => context.push('/documents$pq'),
                  ),
                if (AppConfig.hasMarketplace)
                  _MoreTile(
                    leading: const Icon(Icons.storefront_outlined),
                    title: 'Marketplace de cuidado',
                    onTap: () => context.push('/marketplace'),
                  ),
              ],
            ),
          ],

          // ---- Apariencia ----
          const _SectionLabel('Apariencia'),
          _ListGroup(
            children: [
              Consumer(
                builder: (context, ref, _) {
                  final mode = ref.watch(themeControllerProvider);
                  final isDark = mode == ThemeMode.dark;
                  return SwitchListTile(
                    secondary: Text(isDark ? '🌙' : '☀️',
                        style: const TextStyle(fontSize: 20)),
                    title: const Text('Modo oscuro',
                        style: TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: Text(isDark ? 'Activado' : 'Desactivado',
                        style: const TextStyle(
                            fontSize: 12, color: AppColors.textSecondary)),
                    value: isDark,
                    activeColor: AppColors.primary,
                    onChanged: (_) =>
                        ref.read(themeControllerProvider.notifier).toggle(),
                  );
                },
              ),
            ],
          ),

          // ---- Notificaciones y ajustes ----
          const _SectionLabel('Notificaciones y ajustes'),
          _ListGroup(
            children: [
              _MoreTile(
                leading: const Icon(Icons.notifications_outlined),
                title: 'Alertas y notificaciones',
                subtitle: 'Caídas, SpO₂, ritmo, medicación, SOS',
                onTap: () => context.push('/settings/notifications'),
              ),
              if (patient != null)
                _MoreTile(
                  leading: const Text('⌚', style: TextStyle(fontSize: 20)),
                  title: 'Dispositivos / wearables',
                  subtitle: 'Reloj real o datos de prueba',
                  onTap: () =>
                      context.push('/wearable/link/${patient.patientId}'),
                ),
              _MoreTile(
                leading: const Icon(Icons.manage_accounts_outlined),
                title: 'Cuenta y privacidad',
                onTap: () => context.push('/profile'),
              ),
            ],
          ),

          const SizedBox(height: 20),
          OutlinedButton.icon(
            onPressed: () =>
                ref.read(authControllerProvider.notifier).logout(),
            icon: const Icon(Icons.logout_rounded, color: AppColors.critical),
            label: const Text('Cerrar sesión',
                style: TextStyle(color: AppColors.critical)),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(52),
              side: const BorderSide(color: AppColors.critical),
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

class _ListGroup extends StatelessWidget {
  const _ListGroup({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    if (children.isEmpty) return const SizedBox.shrink();
    return AppCard(
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i != 0) const Divider(height: 1),
            children[i],
          ],
        ],
      ),
    );
  }
}

class _MoreTile extends StatelessWidget {
  const _MoreTile({
    required this.leading,
    required this.title,
    this.subtitle,
    this.titleColor,
    this.onTap,
  });

  final Widget leading;
  final String title;
  final String? subtitle;
  final Color? titleColor;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: leading,
      title: Text(title,
          style: TextStyle(
              fontWeight: FontWeight.w600,
              color: titleColor ?? AppColors.textPrimary)),
      subtitle: subtitle != null
          ? Text(subtitle!,
              style: const TextStyle(
                  fontSize: 12, color: AppColors.textSecondary))
          : null,
      trailing:
          const Icon(Icons.chevron_right_rounded, color: AppColors.textSecondary),
      onTap: onTap,
    );
  }
}

class _RoleBadge extends StatelessWidget {
  const _RoleBadge({required this.role});
  final RoleType role;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: AppColors.primary.withOpacity(.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(role.label,
          style: const TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w700,
              color: AppColors.primaryDark)),
    );
  }
}
