import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/network/upload_service.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/common.dart';
import '../../auth/application/auth_controller.dart';
import '../../auth/domain/models.dart';
import '../application/documents_providers.dart';
import '../data/documents_repository.dart';
import '../domain/models.dart';

/// Expediente de un paciente, listo para usar dentro de cualquier pantalla:
/// buscador, filtro por categoría y documentos agrupados, con abrir, subir y
/// quitar según el rol.
///
/// Es la misma vista para todos los roles que ven documentos (familiar,
/// cuidadora y médico), así nadie tiene que pasar por un botón intermedio
/// para llegar a lo que busca. Los permisos son los del servidor: los tres
/// suben; solo familiar y cuidadora quitan (el médico lee el expediente pero
/// no lo edita).
class PatientDocumentsView extends ConsumerStatefulWidget {
  const PatientDocumentsView({super.key, required this.patientId});

  final String patientId;

  @override
  ConsumerState<PatientDocumentsView> createState() =>
      _PatientDocumentsViewState();
}

class _PatientDocumentsViewState extends ConsumerState<PatientDocumentsView> {
  final _buscar = TextEditingController();
  DocumentCategory? _categoria;

  @override
  void dispose() {
    _buscar.dispose();
    super.dispose();
  }

  /// Rol de la persona sobre ESTE paciente; sin membresía conocida, su tipo
  /// de cuenta.
  RoleType? _rol() {
    final user = ref.watch(currentUserProvider);
    if (user == null) return null;
    for (final m in user.memberships) {
      if (m.patientId == widget.patientId) return m.role;
    }
    return user.primaryRole;
  }

  @override
  Widget build(BuildContext context) {
    final docs = ref.watch(documentsProvider(widget.patientId));
    final rol = _rol();
    final puedeSubir = rol == RoleType.family ||
        rol == RoleType.caregiver ||
        rol == RoleType.doctor;
    final puedeQuitar = rol == RoleType.family || rol == RoleType.caregiver;

    return docs.when(
      loading: () => const LoadingView(),
      error: (e, _) => ErrorView(
        message: e.toString(),
        onRetry: () => ref.invalidate(documentsProvider(widget.patientId)),
      ),
      data: (todos) {
        if (todos.isEmpty) {
          return EmptyView(
            icon: Icons.folder_open_rounded,
            title: 'Expediente vacío',
            subtitle: 'Aquí quedan las recetas, exámenes, imágenes e '
                'informes del adulto mayor.',
            action: puedeSubir
                ? FilledButton.icon(
                    onPressed: () => _subir(context),
                    icon: const Icon(Icons.upload_file_rounded),
                    label: const Text('Subir documento'),
                  )
                : null,
          );
        }

        final visibles = filtrarDocumentos(todos,
            texto: _buscar.text, categoria: _categoria);
        // Conteo por categoría sobre lo que calza con el texto, para que
        // los chips digan cuánto hay de verdad en cada una.
        final porTexto = filtrarDocumentos(todos, texto: _buscar.text);
        final conteo = <DocumentCategory, int>{};
        for (final d in porTexto) {
          conteo[d.categoria] = (conteo[d.categoria] ?? 0) + 1;
        }
        // Solo las categorías que tienen algo: un chip en cero es ruido.
        final categorias = [
          for (final c in DocumentCategory.values)
            if ((conteo[c] ?? 0) > 0 || c == _categoria) c,
        ];

        return RefreshIndicator(
          onRefresh: () async =>
              ref.invalidate(documentsProvider(widget.patientId)),
          child: CustomScrollView(
            slivers: [
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                sliver: SliverToBoxAdapter(
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _buscar,
                          onChanged: (_) => setState(() {}),
                          textInputAction: TextInputAction.search,
                          decoration: InputDecoration(
                            hintText: 'Buscar por nombre, categoría o autor',
                            prefixIcon: const Icon(Icons.search_rounded),
                            isDense: true,
                            suffixIcon: _buscar.text.isEmpty
                                ? null
                                : IconButton(
                                    tooltip: 'Limpiar búsqueda',
                                    icon: const Icon(Icons.close_rounded),
                                    onPressed: () =>
                                        setState(() => _buscar.clear()),
                                  ),
                          ),
                        ),
                      ),
                      if (puedeSubir) ...[
                        const SizedBox(width: 8),
                        FilledButton.icon(
                          onPressed: () => _subir(context),
                          icon: const Icon(Icons.upload_file_rounded),
                          label: const Text('Subir'),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              // Fila desplazable: con muchas categorías no se corta ninguna.
              SliverToBoxAdapter(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 2),
                  child: Row(
                    children: [
                      _Chip(
                        label: 'Todos (${porTexto.length})',
                        selected: _categoria == null,
                        onTap: () => setState(() => _categoria = null),
                      ),
                      for (final c in categorias)
                        _Chip(
                          icon: c.icon,
                          label: '${c.plural} (${conteo[c] ?? 0})',
                          selected: _categoria == c,
                          onTap: () => setState(
                              () => _categoria = _categoria == c ? null : c),
                        ),
                    ],
                  ),
                ),
              ),
              if (visibles.isEmpty)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: EmptyView(
                    icon: Icons.search_off_rounded,
                    title: 'Sin resultados',
                    subtitle: 'Ningún documento calza con la búsqueda.',
                    action: TextButton(
                      onPressed: () => setState(() {
                        _buscar.clear();
                        _categoria = null;
                      }),
                      child: const Text('Ver todos'),
                    ),
                  ),
                )
              else
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                  sliver: SliverList.list(
                    children: _agrupados(visibles, puedeQuitar),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  /// Agrupa por categoría en el orden de [DocumentCategory]; dentro de cada
  /// grupo, lo más reciente primero.
  List<Widget> _agrupados(List<PatientDocument> docs, bool puedeQuitar) {
    final grupos = <DocumentCategory, List<PatientDocument>>{};
    for (final d in docs) {
      grupos.putIfAbsent(d.categoria, () => []).add(d);
    }
    return [
      for (final c in DocumentCategory.values)
        if (grupos[c] != null) ...[
          Padding(
            padding: const EdgeInsets.only(top: 8, bottom: 8),
            child: Semantics(
              header: true,
              child: Row(
                children: [
                  Icon(c.icon, size: 18, color: AppColors.primary),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text('${c.plural} · ${grupos[c]!.length}',
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleMedium),
                  ),
                ],
              ),
            ),
          ),
          for (final d in grupos[c]!
            ..sort((a, b) => b.createdAt.compareTo(a.createdAt)))
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _DocumentTile(
                patientId: widget.patientId,
                document: d,
                puedeQuitar: puedeQuitar,
              ),
            ),
        ],
    ];
  }

  Future<void> _subir(BuildContext context) => showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (_) => _UploadSheet(
          patientId: widget.patientId,
          categoriaInicial: _categoria ?? DocumentCategory.receta,
        ),
      );
}

class _Chip extends StatelessWidget {
  const _Chip({
    required this.label,
    required this.selected,
    required this.onTap,
    this.icon,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final IconData? icon;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(right: 8),
        child: ChoiceChip(
          avatar: icon == null ? null : Icon(icon, size: 16),
          label: Text(label),
          selected: selected,
          onSelected: (_) => onTap(),
        ),
      );
}

class _DocumentTile extends ConsumerStatefulWidget {
  const _DocumentTile({
    required this.patientId,
    required this.document,
    required this.puedeQuitar,
  });

  final String patientId;
  final PatientDocument document;
  final bool puedeQuitar;

  @override
  ConsumerState<_DocumentTile> createState() => _DocumentTileState();
}

class _DocumentTileState extends ConsumerState<_DocumentTile> {
  bool _busy = false;

  Future<void> _open() async {
    setState(() => _busy = true);
    try {
      final url = await ref
          .read(documentsRepositoryProvider)
          .downloadUrl(widget.document.id);
      final ok = await launchUrl(Uri.parse(url),
          mode: LaunchMode.externalApplication);
      if (!ok && mounted) {
        showAppSnackBar(context, 'No se pudo abrir el documento.',
            error: true);
      }
    } catch (e) {
      if (mounted) showAppSnackBar(context, e.toString(), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Quitar documento'),
        content: Text('¿Quitar "${widget.document.title}" del expediente?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            style:
                FilledButton.styleFrom(backgroundColor: AppColors.critical),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Quitar'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    setState(() => _busy = true);
    try {
      await ref
          .read(documentsRepositoryProvider)
          .deleteDocument(widget.document.id);
      ref.invalidate(documentsProvider(widget.patientId));
      if (mounted) showAppSnackBar(context, 'Documento quitado.');
    } catch (e) {
      if (mounted) showAppSnackBar(context, e.toString(), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.document;
    return AppCard(
      onTap: _busy ? null : _open,
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: AppColors.primary.withValues(alpha: .1),
              borderRadius: BorderRadius.circular(12),
            ),
            alignment: Alignment.center,
            child: _busy
                ? const SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : Icon(_fileIcon(d.fileUrl), color: AppColors.primary),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(d.title,
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Text(
                  '${DateFormat('d MMM yyyy', 'es').format(d.createdAt)}'
                  '${d.uploaderName != null ? ' · ${d.uploaderName}' : ''}',
                  style: const TextStyle(
                      fontSize: 12, color: AppColors.textSecondary),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Abrir',
            icon: const Icon(Icons.open_in_new_rounded,
                color: AppColors.textSecondary),
            onPressed: _busy ? null : _open,
          ),
          if (widget.puedeQuitar)
            IconButton(
              tooltip: 'Quitar del expediente',
              icon: const Icon(Icons.delete_outline_rounded,
                  color: AppColors.textSecondary),
              onPressed: _busy ? null : _delete,
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Hoja de subida
// ---------------------------------------------------------------------------
class _UploadSheet extends ConsumerStatefulWidget {
  const _UploadSheet({required this.patientId, required this.categoriaInicial});

  final String patientId;
  final DocumentCategory categoriaInicial;

  @override
  ConsumerState<_UploadSheet> createState() => _UploadSheetState();
}

class _UploadSheetState extends ConsumerState<_UploadSheet> {
  final _picker = ImagePicker();
  final _titleCtrl = TextEditingController();
  late DocumentCategory _categoria = widget.categoriaInicial;
  File? _file;
  bool _busy = false;

  @override
  void dispose() {
    _titleCtrl.dispose();
    super.dispose();
  }

  Future<void> _pick(ImageSource source) async {
    try {
      final picked = await _picker.pickImage(
          source: source, imageQuality: 90, maxWidth: 2400);
      if (picked == null) return;
      setState(() => _file = File(picked.path));
    } catch (_) {
      if (mounted) {
        showAppSnackBar(context, 'No se pudo obtener el archivo.',
            error: true);
      }
    }
  }

  Future<void> _save() async {
    if (_file == null) {
      showAppSnackBar(context, 'Selecciona un archivo primero.', error: true);
      return;
    }
    if (_titleCtrl.text.trim().isEmpty) {
      showAppSnackBar(context, 'Escribe un título.', error: true);
      return;
    }
    setState(() => _busy = true);
    try {
      final uploaded = await ref
          .read(uploadServiceProvider)
          .uploadFile(_file!, kind: 'document', patientId: widget.patientId);
      await ref.read(documentsRepositoryProvider).addDocument(
            widget.patientId,
            fileUrl: uploaded.fileUrl,
            title: _titleCtrl.text.trim(),
            category: _categoria.apiValue,
          );
      ref.invalidate(documentsProvider(widget.patientId));
      if (mounted) {
        Navigator.of(context).pop();
        showAppSnackBar(context, 'Documento agregado al expediente.');
      }
    } catch (e) {
      if (mounted) showAppSnackBar(context, e.toString(), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
          16, 0, 16, MediaQuery.of(context).viewInsets.bottom + 16),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Subir documento',
                style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 16),
            if (_file != null) ...[
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.file(_file!, height: 140, fit: BoxFit.cover),
              ),
              const SizedBox(height: 12),
            ],
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _busy ? null : () => _pick(ImageSource.camera),
                    icon: const Icon(Icons.photo_camera_rounded),
                    label: const Text('Cámara'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed:
                        _busy ? null : () => _pick(ImageSource.gallery),
                    icon: const Icon(Icons.photo_library_rounded),
                    label: const Text('Galería'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _titleCtrl,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                  labelText: 'Título',
                  hintText: 'Ej: Hemograma marzo, Receta cardiología'),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<DocumentCategory>(
              initialValue: _categoria,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Categoría'),
              items: [
                for (final c in DocumentCategory.values)
                  DropdownMenuItem(
                    value: c,
                    child: Row(children: [
                      Icon(c.icon, size: 18, color: AppColors.primary),
                      const SizedBox(width: 8),
                      Flexible(child: Text(c.singular)),
                    ]),
                  ),
              ],
              onChanged: (v) => setState(() => _categoria = v ?? _categoria),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _busy ? null : _save,
              icon: _busy
                  ? const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.check_rounded),
              label: const Text('Guardar'),
            ),
          ],
        ),
      ),
    );
  }
}

IconData _fileIcon(String url) {
  final lower = url.toLowerCase();
  if (lower.endsWith('.pdf')) return Icons.picture_as_pdf_rounded;
  if (lower.endsWith('.jpg') ||
      lower.endsWith('.jpeg') ||
      lower.endsWith('.png')) {
    return Icons.image_rounded;
  }
  return Icons.insert_drive_file_rounded;
}
