import 'dart:io';

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../../../core/network/upload_service.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/validation/identity_validators.dart';
import '../../../core/widgets/common.dart';
import '../../auth/application/auth_controller.dart';
import '../../auth/domain/models.dart';
import '../data/profile_repository.dart';

/// Perfil y ajustes del usuario: edición de nombre, teléfono y avatar,
/// acceso a preferencias de notificaciones y cierre de sesión.
class ProfileScreen extends ConsumerStatefulWidget {
  const ProfileScreen({super.key});

  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen> {
  final _picker = ImagePicker();
  final _formKey = GlobalKey<FormState>();
  final _firstCtrl = TextEditingController();
  final _secondCtrl = TextEditingController();
  final _lastCtrl = TextEditingController();
  final _secondLastCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();

  bool _initialized = false;
  bool _saving = false;
  bool _uploadingAvatar = false;

  @override
  void dispose() {
    _firstCtrl.dispose();
    _secondCtrl.dispose();
    _lastCtrl.dispose();
    _secondLastCtrl.dispose();
    _phoneCtrl.dispose();
    super.dispose();
  }

  void _hydrate() {
    if (_initialized) return;
    final user = ref.read(currentUserProvider);
    if (user != null) {
      _firstCtrl.text = user.firstName;
      _secondCtrl.text = user.secondName ?? '';
      _lastCtrl.text = user.lastName;
      _secondLastCtrl.text = user.secondLastName ?? '';
      _phoneCtrl.text = user.phone ?? '';
      _initialized = true;
    }
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    try {
      // Cada parte del nombre va en su campo: adivinar dónde termina el
      // nombre y empieza el apellido parte mal "María José Pérez".
      final phone = _phoneCtrl.text.trim();
      await ref.read(profileRepositoryProvider).updateProfile(
            firstName: _firstCtrl.text.trim(),
            secondName: _secondCtrl.text.trim(),
            lastName: _lastCtrl.text.trim(),
            secondLastName: _secondLastCtrl.text.trim(),
            phone: phone.isEmpty ? null : normalizePhone(phone),
          );
      await ref.read(authControllerProvider.notifier).refreshProfile();
      if (mounted) showAppSnackBar(context, 'Perfil actualizado.');
    } catch (e) {
      if (mounted) showAppSnackBar(context, e.toString(), error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _changeAvatar() async {
    try {
      final picked = await _picker.pickImage(
          source: ImageSource.gallery, imageQuality: 85, maxWidth: 800);
      if (picked == null) return;
      setState(() => _uploadingAvatar = true);
      final uploaded = await ref
          .read(uploadServiceProvider)
          .uploadFile(File(picked.path), kind: 'avatar');
      await ref
          .read(profileRepositoryProvider)
          .updateProfile(avatarUrl: uploaded.fileUrl);
      await ref.read(authControllerProvider.notifier).refreshProfile();
      if (mounted) showAppSnackBar(context, 'Foto actualizada.');
    } catch (e) {
      if (mounted) showAppSnackBar(context, e.toString(), error: true);
    } finally {
      if (mounted) setState(() => _uploadingAvatar = false);
    }
  }

  Future<void> _logout() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Cerrar sesión'),
        content: const Text('¿Seguro que quieres cerrar sesión?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            style:
                FilledButton.styleFrom(backgroundColor: AppColors.critical),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Cerrar sesión'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    await ref.read(authControllerProvider.notifier).logout();
  }

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(currentUserProvider);
    _hydrate();

    return Scaffold(
      appBar: AppBar(title: const Text('Perfil')),
      body: user == null
          ? const LoadingView()
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
              children: [
                Center(
                  child: Stack(
                    children: [
                      InitialsAvatar(
                        name: user.fullName,
                        photoUrl: user.avatarUrl,
                        radius: 48,
                      ),
                      Positioned(
                        right: 0,
                        bottom: 0,
                        child: Material(
                          color: AppColors.primary,
                          shape: const CircleBorder(),
                          child: InkWell(
                            customBorder: const CircleBorder(),
                            onTap:
                                _uploadingAvatar ? null : _changeAvatar,
                            child: Padding(
                              padding: const EdgeInsets.all(8),
                              child: _uploadingAvatar
                                  ? const SizedBox(
                                      height: 18,
                                      width: 18,
                                      child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          color: Colors.white))
                                  : const Icon(Icons.camera_alt_rounded,
                                      size: 18, color: Colors.white),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                AppCard(
                  child: Form(
                    key: _formKey,
                    child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _FilaNombre(
                        izquierda: _CampoNombre(
                            controller: _firstCtrl, label: 'Nombre'),
                        derecha: _CampoNombre(
                            controller: _secondCtrl,
                            label: 'Segundo nombre',
                            opcional: true),
                      ),
                      const SizedBox(height: 12),
                      _FilaNombre(
                        izquierda: _CampoNombre(
                            controller: _lastCtrl, label: 'Apellido'),
                        derecha: _CampoNombre(
                            controller: _secondLastCtrl,
                            label: 'Segundo apellido',
                            opcional: true),
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _phoneCtrl,
                        keyboardType: TextInputType.phone,
                        decoration: const InputDecoration(
                          labelText: 'Teléfono',
                          prefixIcon: Icon(Icons.phone_outlined),
                        ),
                        validator: (v) => validatePhone(v,
                            required: user.accountType == RoleType.caregiver),
                      ),
                      if (user.rut != null) ...[
                        const SizedBox(height: 12),
                        InputDecorator(
                          decoration: const InputDecoration(
                            labelText: 'RUT',
                            prefixIcon: Icon(Icons.badge_outlined),
                          ),
                          child: Text(user.rut!,
                              style: const TextStyle(
                                  color: AppColors.textSecondary)),
                        ),
                      ],
                      const SizedBox(height: 12),
                      InputDecorator(
                        decoration: const InputDecoration(
                          labelText: 'Correo',
                          prefixIcon: Icon(Icons.email_outlined),
                        ),
                        child: Text(user.email,
                            style: const TextStyle(
                                color: AppColors.textSecondary)),
                      ),
                    ],
                  ),
                  ),
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: _saving ? null : _save,
                  icon: _saving
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.save_rounded),
                  label: const Text('Guardar cambios'),
                ),
                const SizedBox(height: 24),
                AppCard(
                  padding: EdgeInsets.zero,
                  child: Column(
                    children: [
                      // La cuidadora se publica para que las familias la
                      // encuentren (RF-72, RF-75) y ve ofertas de trabajo.
                      if (user.accountType == RoleType.caregiver) ...[
                        ListTile(
                          leading: const Icon(Icons.badge_outlined,
                              color: AppColors.primary),
                          title: const Text('Mi perfil profesional'),
                          subtitle: const Text(
                              'Experiencia, comunas, tarifa y publicación'),
                          trailing: const Icon(Icons.chevron_right_rounded),
                          onTap: () => context.push('/cg/profile'),
                        ),
                        const Divider(height: 1),
                        ListTile(
                          leading: const Icon(Icons.work_outline_rounded,
                              color: AppColors.primary),
                          title: const Text('Ofertas de trabajo'),
                          trailing: const Icon(Icons.chevron_right_rounded),
                          onTap: () => context.push('/marketplace'),
                        ),
                        const Divider(height: 1),
                      ],
                      ListTile(
                        leading: const Icon(Icons.notifications_outlined,
                            color: AppColors.primary),
                        title: const Text('Notificaciones'),
                        trailing:
                            const Icon(Icons.chevron_right_rounded),
                        onTap: () =>
                            context.push('/profile/notifications'),
                      ),
                      if (kDebugMode) ...[
                        const Divider(height: 1),
                        ListTile(
                          leading: const Icon(Icons.palette_outlined,
                              color: AppColors.primary),
                          title: const Text('Design system'),
                          subtitle: const Text('Solo visible en modo debug'),
                          trailing:
                              const Icon(Icons.chevron_right_rounded),
                          onTap: () => context.push('/dev/gallery'),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 24),
                OutlinedButton.icon(
                  onPressed: _logout,
                  icon: const Icon(Icons.logout_rounded,
                      color: AppColors.critical),
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

/// Dos campos del nombre lado a lado; en pantallas angostas, uno bajo otro.
class _FilaNombre extends StatelessWidget {
  const _FilaNombre({required this.izquierda, required this.derecha});

  final Widget izquierda;
  final Widget derecha;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      if (c.maxWidth < 360) {
        return Column(
            children: [izquierda, const SizedBox(height: 12), derecha]);
      }
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: izquierda),
          const SizedBox(width: 12),
          Expanded(child: derecha),
        ],
      );
    });
  }
}

class _CampoNombre extends StatelessWidget {
  const _CampoNombre({
    required this.controller,
    required this.label,
    this.opcional = false,
  });

  final TextEditingController controller;
  final String label;
  final bool opcional;

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: controller,
      textCapitalization: TextCapitalization.words,
      decoration: InputDecoration(
          labelText: opcional ? '$label (opcional)' : label),
      validator: (v) => validatePersonName(v,
          campo: label.toLowerCase(), required: !opcional),
    );
  }
}
