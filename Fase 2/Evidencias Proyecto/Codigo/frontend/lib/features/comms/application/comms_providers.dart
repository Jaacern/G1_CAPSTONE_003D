import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../patients/application/patients_providers.dart';
import '../data/assistant_repository.dart';
import '../data/chat_repository.dart';
import '../domain/models.dart';

/// Resuelve el id de paciente a usar: el explícito o el seleccionado.
String? resolvePatientId(Ref ref, String? explicit) {
  if (explicit != null && explicit.isNotEmpty) return explicit;
  return ref.watch(selectedPatientProvider)?.patientId;
}

/// Historial del chat de un paciente. autoDispose para recargar al reentrar.
final chatMessagesProvider = FutureProvider.autoDispose
    .family<List<ChatMessage>, String>((ref, patientId) {
  return ref.watch(chatRepositoryProvider).fetchMessages(patientId);
});

/// Historial del chat del paciente seleccionado (atajo cómodo para la UI).
final selectedChatMessagesProvider =
    FutureProvider.autoDispose<List<ChatMessage>>((ref) {
  final patient = ref.watch(selectedPatientProvider);
  if (patient == null) return Future.value(const <ChatMessage>[]);
  return ref.watch(chatMessagesProvider(patient.patientId).future);
});

/// Suscripción en tiempo real (WebSocket) a mensajes nuevos del chat.
final chatStreamProvider =
    StreamProvider.autoDispose.family<ChatMessage, String>((ref, patientId) {
  return ref.watch(chatRepositoryProvider).connect(patientId);
});

/// Conversaciones del asistente IA para un paciente.
final assistantConversationsProvider = FutureProvider.autoDispose
    .family<List<AssistantConversation>, String>((ref, patientId) {
  return ref.watch(assistantRepositoryProvider).listConversations(patientId);
});

/// Mensajes de una conversación concreta del asistente IA.
final assistantMessagesProvider = FutureProvider.autoDispose
    .family<List<AssistantMessage>, String>((ref, conversationId) {
  return ref.watch(assistantRepositoryProvider).fetchMessages(conversationId);
});
