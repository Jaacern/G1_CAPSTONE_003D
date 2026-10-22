import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/app_config.dart';
import '../../../core/network/api_client.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/common.dart';
import '../../patients/application/patients_providers.dart';
import '../data/assistant_repository.dart';
import '../domain/models.dart';

/// Conversación con el asistente IA sobre el expediente del paciente.
class AssistantScreen extends ConsumerStatefulWidget {
  const AssistantScreen({super.key, this.patientId});

  final String? patientId;

  @override
  ConsumerState<AssistantScreen> createState() => _AssistantScreenState();
}

class _AssistantScreenState extends ConsumerState<AssistantScreen> {
  static const _suggestions = [
    '¿Cómo durmió anoche?',
    '¿Tomó sus medicamentos hoy?',
    '¿Cuál es su último ritmo cardíaco?',
    '¿Cuántos pasos ha dado hoy?',
  ];

  final _textController = TextEditingController();
  final _scrollController = ScrollController();

  String? _patientId;
  String? _conversationId;
  final List<AssistantMessage> _messages = [];

  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _patientId =
        widget.patientId ?? ref.read(selectedPatientProvider)?.patientId;
  }

  @override
  void dispose() {
    _textController.dispose();
    _scrollController.dispose();
    super.dispose();
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

  Future<void> _ask(String text) async {
    final question = text.trim();
    if (question.isEmpty || _sending || _patientId == null) return;

    _textController.clear();
    final now = DateTime.now();
    setState(() {
      _sending = true;
      _messages.add(AssistantMessage(
        id: 'local-${now.millisecondsSinceEpoch}',
        role: AssistantRole.user,
        text: question,
        createdAt: now,
      ));
    });
    _scrollToBottom();

    try {
      final reply = await ref.read(assistantRepositoryProvider).ask(
            _patientId!,
            conversationId: _conversationId,
            text: question,
          );
      _conversationId = reply.conversationId;
      setState(() => _messages.add(reply.message));
      _scrollToBottom();
    } on ApiException catch (e) {
      if (mounted) showAppSnackBar(context, e.message, error: true);
    } catch (_) {
      if (mounted) {
        showAppSnackBar(
            context, 'El asistente no pudo responder. Intenta más tarde.',
            error: true);
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!AppConfig.hasComms) {
      return Scaffold(
        appBar: AppBar(title: const Text('Asistente IA')),
        body: const ComingSoonView(
          icon: Icons.smart_toy_rounded,
          title: 'Asistente IA',
          subtitle: 'Pronto podrás hacer consultas al asistente de IA.',
        ),
      );
    }

    if (_patientId == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Asistente IA')),
        body: const EmptyView(
          icon: Icons.smart_toy_rounded,
          title: 'Sin paciente seleccionado',
          subtitle:
              'Selecciona a un paciente para preguntarle al asistente sobre '
              'su expediente.',
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Asistente IA'),
        bottom: const PreferredSize(
          preferredSize: Size.fromHeight(1),
          child: Divider(height: 1),
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: _messages.isEmpty ? _buildIntro() : _buildConversation(),
          ),
          _buildComposer(),
        ],
      ),
    );
  }

  Widget _buildIntro() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 16),
      children: [
        Container(
          width: 72,
          height: 72,
          decoration: BoxDecoration(
            color: AppColors.secondary.withOpacity(.15),
            borderRadius: BorderRadius.circular(20),
          ),
          child: const Icon(Icons.smart_toy_rounded,
              size: 40, color: AppColors.primaryDark),
        ),
        const SizedBox(height: 16),
        const Text(
          'Pregúntame sobre el expediente',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        const Text(
          'Puedo consultar el sueño, los medicamentos, los signos vitales y '
          'la actividad, y te doy referencias al expediente.',
          style: TextStyle(color: AppColors.textSecondary),
        ),
        const SizedBox(height: 20),
        const Text('Sugerencias',
            style: TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final s in _suggestions)
              ActionChip(
                label: Text(s),
                onPressed: _sending ? null : () => _ask(s),
                backgroundColor: AppColors.primary.withOpacity(.08),
                side: const BorderSide(color: AppColors.divider),
              ),
          ],
        ),
      ],
    );
  }

  Widget _buildConversation() {
    final itemCount = _messages.length + (_sending ? 1 : 0);
    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.fromLTRB(12, 16, 12, 16),
      itemCount: itemCount,
      itemBuilder: (_, i) {
        if (i >= _messages.length) return const _TypingIndicator();
        return _AssistantBubble(message: _messages[i]);
      },
    );
  }

  Widget _buildComposer() {
    return SafeArea(
      top: false,
      child: Container(
        decoration: const BoxDecoration(
          color: AppColors.surface,
          border: Border(top: BorderSide(color: AppColors.divider)),
        ),
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: TextField(
                controller: _textController,
                enabled: !_sending,
                minLines: 1,
                maxLines: 4,
                textInputAction: TextInputAction.send,
                onSubmitted: _ask,
                decoration: const InputDecoration(
                  hintText: 'Escribe tu pregunta…',
                  contentPadding:
                      EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                ),
              ),
            ),
            const SizedBox(width: 6),
            _sending
                ? const Padding(
                    padding: EdgeInsets.all(12),
                    child: SizedBox(
                      height: 22,
                      width: 22,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : IconButton.filled(
                    onPressed: () => _ask(_textController.text),
                    icon: const Icon(Icons.send_rounded),
                    tooltip: 'Enviar',
                  ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Burbuja usuario / asistente
// ---------------------------------------------------------------------------
class _AssistantBubble extends StatelessWidget {
  const _AssistantBubble({required this.message});

  final AssistantMessage message;

  @override
  Widget build(BuildContext context) {
    final own = message.isUser;
    final bg = own ? AppColors.primary : AppColors.surface;
    final fg = own ? Colors.white : AppColors.textPrimary;

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        mainAxisAlignment:
            own ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!own) ...[
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: AppColors.secondary.withOpacity(.18),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(Icons.smart_toy_rounded,
                  size: 20, color: AppColors.primaryDark),
            ),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: Container(
              constraints: BoxConstraints(
                maxWidth: MediaQuery.of(context).size.width * .74,
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
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(message.text, style: TextStyle(color: fg)),
                  if (message.citations != null &&
                      message.citations!.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (final c in message.citations!)
                          _CitationChip(citation: c),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CitationChip extends StatelessWidget {
  const _CitationChip({required this.citation});

  final Citation citation;

  @override
  Widget build(BuildContext context) {
    final label = citation.reference != null
        ? '${citation.label} · ${citation.reference}'
        : citation.label;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: AppColors.primary.withOpacity(.08),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: AppColors.primary.withOpacity(.2)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.description_rounded,
              size: 14, color: AppColors.primary),
          const SizedBox(width: 5),
          Flexible(
            child: Text(
              label,
              style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: AppColors.primaryDark),
            ),
          ),
        ],
      ),
    );
  }
}

class _TypingIndicator extends StatelessWidget {
  const _TypingIndicator();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: AppColors.secondary.withOpacity(.18),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(Icons.smart_toy_rounded,
                size: 20, color: AppColors.primaryDark),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: AppColors.divider),
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  height: 16,
                  width: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                SizedBox(width: 10),
                Text('Consultando el expediente…',
                    style: TextStyle(color: AppColors.textSecondary)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
