import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../agent/orchestrator/agent_orchestrator.dart';
import '../../data/models/chat_message.dart';
import '../../services/files/file_service.dart';
import '../../shared/providers.dart';

class ChatState {
  final List<ChatMessage> messages;
  final bool sending;

  /// Assistant text accumulated live during the current turn (token streaming).
  /// Empty when idle or before the first token arrives.
  final String streamingText;

  const ChatState({
    this.messages = const [],
    this.sending = false,
    this.streamingText = '',
  });

  ChatState copyWith({
    List<ChatMessage>? messages,
    bool? sending,
    String? streamingText,
  }) =>
      ChatState(
        messages: messages ?? this.messages,
        sending: sending ?? this.sending,
        streamingText: streamingText ?? this.streamingText,
      );
}

class ChatController extends StateNotifier<ChatState> {
  ChatController(this._ref) : super(const ChatState()) {
    _load();
  }

  final Ref _ref;

  Future<void> _load() async {
    final messages =
        await _ref.read(chatRepositoryProvider).recent(limit: 200);
    state = state.copyWith(messages: messages);
  }

  /// Reload from the database - used on app resume / when re-entering the Exa
  /// tab so briefs posted by background scheduled jobs appear without
  /// restarting the app. Skipped while a turn is in flight: that turn reloads
  /// when it finishes, and a competing reload here could momentarily drop the
  /// pending message or the just-arrived reply.
  Future<void> refresh() async {
    if (state.sending) return;
    await _load();
  }

  /// Sends a user message through the agent. [onConfirm] is invoked when a
  /// sensitive tool needs approval; the returned result lets the UI navigate.
  Future<AgentTurnResult?> send(
    String text, {
    List<Attachment> attachments = const [],
    ConfirmToolCall? onConfirm,
  }) async {
    final trimmed = text.trim();
    // Allow an empty message when files are attached ("analyze this").
    if ((trimmed.isEmpty && attachments.isEmpty) || state.sending) return null;

    state = state.copyWith(sending: true, streamingText: '');
    // Optimistically show the user message while the agent works. Attachment
    // names go in meta so the bubble can show a paperclip line.
    state = state.copyWith(messages: [
      ...state.messages,
      ChatMessage(
        id: 'pending',
        role: 'user',
        content: trimmed,
        meta: attachments.isEmpty
            ? null
            : {'attachments': attachments.map((a) => a.name).toList()},
        createdAt: DateTime.now(),
      ),
    ]);

    try {
      final orchestrator = _ref.read(agentOrchestratorProvider);
      final result = await orchestrator.run(
        trimmed,
        attachments: attachments,
        onConfirm: onConfirm,
        // Stream assistant text into the live bubble as it arrives.
        onDelta: (delta) => state = state.copyWith(
            streamingText: state.streamingText + delta),
      );
      await _load();
      return result;
    } catch (e) {
      // Never hang silently: surface the failure as an assistant message.
      try {
        await _ref
            .read(chatRepositoryProvider)
            .append('assistant', 'Something went wrong: $e');
      } catch (_) {}
      await _load();
      return null;
    } finally {
      // _load() has swapped in the persisted message; drop the live buffer.
      state = state.copyWith(sending: false, streamingText: '');
    }
  }

  Future<void> clearHistory() async {
    await _ref.read(chatRepositoryProvider).clear();
    await _load();
  }
}

final chatControllerProvider =
    StateNotifierProvider<ChatController, ChatState>(
        (ref) => ChatController(ref));
