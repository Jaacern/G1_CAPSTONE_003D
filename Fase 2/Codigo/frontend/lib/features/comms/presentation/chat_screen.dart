import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../../core/config/app_config.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/upload_service.dart';
import '../../../core/speech/speech_service.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/common.dart';
import '../../auth/application/auth_controller.dart';
import '../../patients/application/patients_providers.dart';
import '../application/comms_providers.dart';
import '../data/assistant_repository.dart';
import '../data/chat_repository.dart';
import '../domain/models.dart';

/// Chat en tiempo real del equipo de cuidado (familia + cuidadora).
class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({super.key, this.patientId});

  final String? patientId;

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final _textController = TextEditingController();
  final _scrollController = ScrollController();
  final _picker = ImagePicker();

  String? _patientId;
  final List<ChatMessage> _messages = [];
  final Set<String> _ids = {};

  bool _loading = true;
  String? _error;
  bool _sending = false;
  bool _recording = false;
  bool _busyMedia = false;
  String? _playingUrl;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _init());
  }

  @override
  void dispose() {
    _textController.dispose();
    _scrollController.dispose();
    ref.read(speechServiceProvider).stopPlayback();
    super.dispose();
  }

  Future<void> _init() async {
    // Sin backend de chat: no se realizan llamadas (la UI muestra
    // "Próximamente"). Evita peticiones a endpoints inexistentes.
    if (!AppConfig.hasComms) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    final patient = widget.patientId ??
        ref.read(selectedPatientProvider)?.patientId;
    if (patient == null) {
      setState(() {
        _loading = false;
        _error = 'No hay un paciente seleccionado.';
      });
      return;
    }
    _patientId = patient;
    await _load();
    // Marca como leídos los mensajes al abrir el chat.
    unawaited(ref.read(chatRepositoryProvider).markRead(patient));
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list =
          await ref.read(chatRepositoryProvider).fetchMessages(_patientId!);
      _messages
        ..clear()
        ..addAll(list);
      _ids
        ..clear()
        ..addAll(list.map((m) => m.id));
      _sortMessages();
    } on ApiException catch (e) {
      _error = e.message;
    } catch (e) {
      _error = 'No se pudo cargar el chat.';
    } finally {
      if (mounted) {
        setState(() => _loading = false);
        _scrollToBottom();
      }
    }
  }

  void _sortMessages() =>
      _messages.sort((a, b) => a.createdAt.compareTo(b.createdAt));

  void _addMessage(ChatMessage msg) {
    if (_ids.contains(msg.id)) return;
    _ids.add(msg.id);
    setState(() {
      _messages.add(msg);
      _sortMessages();
    });
    _scrollToBottom();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  bool _isOwn(ChatMessage m) {
    final me = ref.read(currentUserProvider)?.userId;
    return m.senderId == me || m.senderId == 'u-me';
  }

  // --- Envío de texto ---
  Future<void> _sendText() async {
    final raw = _textController.text.trim();
    if (raw.isEmpty || _sending || _patientId == null) return;

    final mentionsAssistant = raw.toLowerCase().contains('@asistente');
    _textController.clear();
    setState(() => _sending = true);
    try {
      final sent = await ref.read(chatRepositoryProvider).sendMessage(
            _patientId!,
            type: MessageType.text,
            text: raw,
          );
      _addMessage(sent);

      if (mentionsAssistant) {
        await _askAssistantInline(raw);
      }
    } on ApiException catch (e) {
      if (mounted) showAppSnackBar(context, e.message, error: true);
    } catch (_) {
      if (mounted) {
        showAppSnackBar(context, 'No se pudo enviar el mensaje.', error: true);
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  /// Detecta @asistente: enruta la pregunta al asistente IA y muestra su
  /// respuesta como mensaje del sistema dentro del chat.
  Future<void> _askAssistantInline(String raw) async {
    final question =
        raw.replaceAll(RegExp(r'@asistente', caseSensitive: false), '').trim();
    if (question.isEmpty) return;
    try {
      final reply = await ref
          .read(assistantRepositoryProvider)
          .ask(_patientId!, text: question);
      _addMessage(ChatMessage(
        id: 'assist-${reply.message.id}',
        patientId: _patientId!,
        senderId: 'assistant',
        senderName: 'Asistente IA',
        senderRole: 'assistant',
        type: MessageType.system,
        text: reply.message.text,
        createdAt: reply.message.createdAt,
      ));
    } catch (_) {
      if (mounted) {
        showAppSnackBar(context,
            'El asistente no pudo responder ahora. Intenta más tarde.',
            error: true);
      }
    }
  }

  // --- Envío de foto ---
  Future<void> _sendPhoto() async {
    if (_busyMedia || _patientId == null) return;
    try {
      final picked = await _picker.pickImage(
          source: ImageSource.gallery, imageQuality: 85, maxWidth: 2000);
      if (picked == null) return;
      setState(() => _busyMedia = true);
      final uploaded = await ref
          .read(uploadServiceProvider)
          .uploadFile(File(picked.path), kind: 'photo', patientId: _patientId!);
      final sent = await ref.read(chatRepositoryProvider).sendMessage(
            _patientId!,
            type: MessageType.photo,
            mediaUrl: uploaded.fileUrl,
          );
      _addMessage(sent);
    } on ApiException catch (e) {
      if (mounted) showAppSnackBar(context, e.message, error: true);
    } catch (_) {
      if (mounted) {
        showAppSnackBar(context, 'No se pudo enviar la foto.', error: true);
      }
    } finally {
      if (mounted) setState(() => _busyMedia = false);
    }
  }

  // --- Nota de voz (mantener para grabar) ---
  Future<void> _startRecording() async {
    if (_busyMedia || _patientId == null) return;
    try {
      await ref.read(speechServiceProvider).startRecording();
      setState(() => _recording = true);
    } catch (_) {
      if (mounted) {
        showAppSnackBar(
            context, 'No se pudo iniciar la grabación. Revisa el permiso del '
                'micrófono.',
            error: true);
      }
    }
  }

  Future<void> _stopAndSendVoice() async {
    if (!_recording) return;
    setState(() {
      _recording = false;
      _busyMedia = true;
    });
    try {
      final speech = ref.read(speechServiceProvider);
      final file = await speech.stopRecording();
      if (file == null) return;
      final url = await speech.uploadVoiceNote(file, patientId: _patientId!);
      final sent = await ref.read(chatRepositoryProvider).sendMessage(
            _patientId!,
            type: MessageType.voice,
            mediaUrl: url,
          );
      _addMessage(sent);
    } on ApiException catch (e) {
      if (mounted) showAppSnackBar(context, e.message, error: true);
    } catch (_) {
      if (mounted) {
        showAppSnackBar(
            context, 'No se pudo enviar la nota de voz.', error: true);
      }
    } finally {
      if (mounted) setState(() => _busyMedia = false);
    }
  }

  Future<void> _togglePlay(String url) async {
    final speech = ref.read(speechServiceProvider);
    if (_playingUrl == url) {
      await speech.stopPlayback();
      setState(() => _playingUrl = null);
      return;
    }
    setState(() => _playingUrl = url);
    try {
      await speech.playUrl(url);
    } catch (_) {
      if (mounted) {
        showAppSnackBar(context, 'No se pudo reproducir la nota de voz.',
            error: true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // Módulo en desarrollo: el backend aún no expone el chat del equipo de
    // cuidado. En modo backend real se muestra "Próximamente" en lugar de
    // llamar a endpoints inexistentes.
    if (!AppConfig.hasComms) {
      return Scaffold(
        appBar: AppBar(title: const Text('Equipo de cuidado')),
        body: const ComingSoonView(
          icon: Icons.forum_rounded,
          title: 'Chat del equipo de cuidado',
          subtitle:
              'Pronto podrás conversar con la familia y la cuidadora desde aquí.',
        ),
      );
    }

    // Suscripción en tiempo real: agrega los mensajes nuevos que lleguen.
    if (_patientId != null) {
      ref.listen<AsyncValue<ChatMessage>>(
        chatStreamProvider(_patientId!),
        (prev, next) {
          next.whenData(_addMessage);
        },
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Equipo de cuidado'),
        bottom: const PreferredSize(
          preferredSize: Size.fromHeight(1),
          child: Divider(height: 1),
        ),
      ),
      body: Column(
        children: [
          Expanded(child: _buildBody()),
          _Composer(
            controller: _textController,
            sending: _sending,
            recording: _recording,
            busyMedia: _busyMedia,
            enabled: !_loading && _error == null,
            onSend: _sendText,
            onPhoto: _sendPhoto,
            onStartRecording: _startRecording,
            onStopRecording: _stopAndSendVoice,
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) return const LoadingView();
    if (_error != null) {
      return ErrorView(
          message: _error!,
          onRetry: _patientId == null ? null : _load);
    }
    if (_messages.isEmpty) {
      return const EmptyView(
        icon: Icons.forum_rounded,
        title: 'Aún no hay mensajes',
        subtitle:
            'Escribe el primer mensaje para el equipo de cuidado. '
            'Consejo: menciona @asistente para preguntarle a la IA.',
      );
    }
    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.fromLTRB(12, 16, 12, 16),
      itemCount: _messages.length,
      itemBuilder: (_, i) {
        final m = _messages[i];
        if (m.isSystem) return _SystemBubble(message: m);
        return _MessageBubble(
          message: m,
          own: _isOwn(m),
          playing: m.mediaUrl != null && _playingUrl == m.mediaUrl,
          onPlayVoice:
              m.mediaUrl != null ? () => _togglePlay(m.mediaUrl!) : null,
        );
      },
    );
  }
}

/// Espera un future sin bloquear (evita el warning de unawaited_futures).
void unawaited(Future<void> future) {}

// ---------------------------------------------------------------------------
// Burbuja de mensaje humano
// ---------------------------------------------------------------------------
class _MessageBubble extends StatelessWidget {
  const _MessageBubble({
    required this.message,
    required this.own,
    required this.playing,
    this.onPlayVoice,
  });

  final ChatMessage message;
  final bool own;
  final bool playing;
  final VoidCallback? onPlayVoice;

  @override
  Widget build(BuildContext context) {
    final bg = own ? AppColors.primary : AppColors.surface;
    final fg = own ? Colors.white : AppColors.textPrimary;
    final align = own ? CrossAxisAlignment.end : CrossAxisAlignment.start;

    final bubble = Container(
      constraints: BoxConstraints(
        maxWidth: MediaQuery.of(context).size.width * .72,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(16),
          topRight: const Radius.circular(16),
          bottomLeft: Radius.circular(own ? 16 : 4),
          bottomRight: Radius.circular(own ? 4 : 16),
        ),
        border: own ? null : Border.all(color: AppColors.divider),
      ),
      child: _content(fg),
    );

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        mainAxisAlignment:
            own ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (!own) ...[
            InitialsAvatar(name: message.senderName, radius: 16),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: Column(
              crossAxisAlignment: align,
              children: [
                if (!own)
                  Padding(
                    padding: const EdgeInsets.only(left: 4, bottom: 2),
                    child: Text(
                      message.senderName,
                      style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: AppColors.textSecondary),
                    ),
                  ),
                bubble,
                Padding(
                  padding: const EdgeInsets.only(top: 2, left: 4, right: 4),
                  child: Text(
                    _hhmm(message.createdAt),
                    style: const TextStyle(
                        fontSize: 11, color: AppColors.textSecondary),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _content(Color fg) {
    switch (message.type) {
      case MessageType.photo:
        return ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: message.mediaUrl != null
              ? Image.network(
                  message.mediaUrl!,
                  width: 200,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => _photoFallback(fg),
                )
              : _photoFallback(fg),
        );
      case MessageType.voice:
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            InkWell(
              onTap: onPlayVoice,
              customBorder: const CircleBorder(),
              child: Icon(
                playing
                    ? Icons.stop_circle_rounded
                    : Icons.play_circle_fill_rounded,
                color: fg,
                size: 34,
              ),
            ),
            const SizedBox(width: 8),
            Text('Nota de voz',
                style: TextStyle(color: fg, fontWeight: FontWeight.w600)),
          ],
        );
      case MessageType.text:
      case MessageType.system:
        return Text(message.text ?? '', style: TextStyle(color: fg));
    }
  }

  Widget _photoFallback(Color fg) => Container(
        width: 200,
        height: 120,
        color: Colors.black12,
        alignment: Alignment.center,
        child: Icon(Icons.broken_image_rounded, color: fg),
      );
}

// ---------------------------------------------------------------------------
// Burbuja del asistente IA dentro del chat (@asistente)
// ---------------------------------------------------------------------------
class _SystemBubble extends StatelessWidget {
  const _SystemBubble({required this.message});

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Center(
        child: Container(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * .82,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: AppColors.secondary.withOpacity(.12),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppColors.secondary.withOpacity(.4)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.smart_toy_rounded,
                      size: 18, color: AppColors.primaryDark),
                  const SizedBox(width: 6),
                  Text(message.senderName,
                      style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          color: AppColors.primaryDark)),
                ],
              ),
              const SizedBox(height: 6),
              Text(message.text ?? '',
                  style: const TextStyle(color: AppColors.textPrimary)),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Barra de composición
// ---------------------------------------------------------------------------
class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.sending,
    required this.recording,
    required this.busyMedia,
    required this.enabled,
    required this.onSend,
    required this.onPhoto,
    required this.onStartRecording,
    required this.onStopRecording,
  });

  final TextEditingController controller;
  final bool sending;
  final bool recording;
  final bool busyMedia;
  final bool enabled;
  final VoidCallback onSend;
  final VoidCallback onPhoto;
  final VoidCallback onStartRecording;
  final VoidCallback onStopRecording;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Container(
        decoration: const BoxDecoration(
          color: AppColors.surface,
          border: Border(top: BorderSide(color: AppColors.divider)),
        ),
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (recording)
              const Padding(
                padding: EdgeInsets.only(bottom: 6),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.mic_rounded,
                        color: AppColors.critical, size: 18),
                    SizedBox(width: 6),
                    Text('Grabando… suelta para enviar',
                        style: TextStyle(
                            color: AppColors.critical,
                            fontWeight: FontWeight.w600)),
                  ],
                ),
              ),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                IconButton(
                  onPressed: enabled && !busyMedia && !sending ? onPhoto : null,
                  icon: busyMedia && !recording
                      ? const SizedBox(
                          height: 22,
                          width: 22,
                          child:
                              CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.photo_camera_rounded),
                  color: AppColors.primary,
                  tooltip: 'Enviar foto',
                ),
                Expanded(
                  child: TextField(
                    controller: controller,
                    enabled: enabled && !recording,
                    minLines: 1,
                    maxLines: 4,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => onSend(),
                    decoration: const InputDecoration(
                      hintText: 'Escribe un mensaje… (@asistente)',
                      contentPadding:
                          EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                // Mantener presionado para grabar una nota de voz.
                Tooltip(
                  message: 'Mantén para grabar una nota de voz',
                  child: GestureDetector(
                    onLongPressStart: (_) {
                      if (enabled && !busyMedia) onStartRecording();
                    },
                    onLongPressEnd: (_) => onStopRecording(),
                    child: Container(
                      padding: const EdgeInsets.all(12),
                      child: Icon(
                        recording ? Icons.mic_rounded : Icons.mic_none_rounded,
                        color: recording
                            ? AppColors.critical
                            : AppColors.primary,
                      ),
                    ),
                  ),
                ),
                sending
                    ? const Padding(
                        padding: EdgeInsets.all(12),
                        child: SizedBox(
                          height: 22,
                          width: 22,
                          child:
                              CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    : IconButton.filled(
                        onPressed: enabled ? onSend : null,
                        icon: const Icon(Icons.send_rounded),
                        tooltip: 'Enviar',
                      ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Hora en formato HH:mm (sin dependencia de intl).
String _hhmm(DateTime dt) {
  final l = dt.toLocal();
  final h = l.hour.toString().padLeft(2, '0');
  final m = l.minute.toString().padLeft(2, '0');
  return '$h:$m';
}
