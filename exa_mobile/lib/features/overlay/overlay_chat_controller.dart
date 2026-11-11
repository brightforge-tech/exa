import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../agent/models/tool_execution_record.dart';
import '../../agent/orchestrator/agent_orchestrator.dart';
import '../../agent/security/capability_policy.dart';
import '../../data/models/chat_message.dart';
import '../../services/files/file_service.dart';
import '../../services/overlay/overlay_agent_stack.dart';

/// A confirmation-gated tool call waiting for the user's approval in the
/// overlay panel (the overlay equivalent of the in-app confirm dialog -
/// without an answer the orchestrator denies the call).
class OverlayPendingConfirm {
  OverlayPendingConfirm(this.toolName, this.input)
      : completer = Completer<bool>();

  final String toolName;
  final Map<String, Object?> input;
  final Completer<bool> completer;
}

class OverlayChatState {
  const OverlayChatState({
    this.messages = const [],
    this.sending = false,
    this.streamingText = '',
    this.pendingConfirm,
  });

  final List<ChatMessage> messages;
  final bool sending;

  /// Assistant text accumulated live during the current turn.
  final String streamingText;

  final OverlayPendingConfirm? pendingConfirm;

  OverlayChatState copyWith({
    List<ChatMessage>? messages,
    bool? sending,
    String? streamingText,
    OverlayPendingConfirm? pendingConfirm,
    bool clearPendingConfirm = false,
  }) =>
      OverlayChatState(
        messages: messages ?? this.messages,
        sending: sending ?? this.sending,
        streamingText: streamingText ?? this.streamingText,
        pendingConfirm: clearPendingConfirm
            ? null
            : (pendingConfirm ?? this.pendingConfirm),
      );
}

/// Chat controller for the overlay panel. Same shape as the in-app
/// `ChatController` (same conversation, same DB rows, same orchestrator
/// pipeline) but scoped to the overlay engine's providers and with snippet
/// support. Turns run through the FULL intelligence pipeline - snippets are
/// never a raw model call.
class OverlayChatController extends StateNotifier<OverlayChatState> {
  OverlayChatController(this._ref) : super(const OverlayChatState()) {
    _load();
  }

  final Ref _ref;

  /// Narrows every turn this controller runs. Set to
  /// [CapabilityPolicy.lockScreen] by the shell when this engine is hosted
  /// on the lock screen: the user is present (so turns stay interactive and
  /// can confirm), but nothing outbound or destructive runs until the phone
  /// is unlocked. Null is the ordinary overlay.
  CapabilityPolicy? policy;

  Future<void> _load() async {
    final messages =
        await _ref.read(overlayChatRepositoryProvider).recent(limit: 50);
    state = state.copyWith(messages: messages);
  }

  Future<AgentTurnResult?> send(
    String text, {
    List<Attachment> attachments = const [],
    Map<String, Object?>? userMeta,
    bool requireVision = false,
  }) async {
    final trimmed = text.trim();
    if ((trimmed.isEmpty && attachments.isEmpty) || state.sending) return null;

    state = state.copyWith(sending: true, streamingText: '');
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
      final orchestrator = _ref.read(overlayOrchestratorProvider);
      final result = await orchestrator.run(
        trimmed,
        attachments: attachments,
        userMeta: userMeta,
        requireVision: requireVision,
        onConfirm: _confirm,
        policy: policy,
        onDelta: (delta) => state =
            state.copyWith(streamingText: state.streamingText + delta),
      );
      await _load();
      return result;
    } catch (e) {
      try {
        await _ref
            .read(overlayChatRepositoryProvider)
            .append('assistant', 'Something went wrong: $e');
      } catch (_) {}
      await _load();
      return null;
    } finally {
      state = state.copyWith(
          sending: false, streamingText: '', clearPendingConfirm: true);
    }
  }

  /// Opening words of every snippet turn. This exact wording is a trigger
  /// example of the `analyze_snippet` skill, so it must lead the message for
  /// the intelligence layer's contract to demand a summary AND a proactive
  /// follow-up question. The user's own instruction is appended, never
  /// substituted, so routing survives whatever they type.
  static const _snippetPrompt =
      'Analyze this screenshot snippet I captured from my screen.';

  /// Tells the model the image is everything on screen, not a chosen region.
  /// Appended after [_snippetPrompt] rather than replacing it, for the same
  /// reason: the trigger sentence has to lead.
  static const _fullScreenNote = 'This is my entire screen.';

  /// The message a capture turn sends. Pure and public so the ordering rule -
  /// trigger sentence first, then the framing, then whatever the user said -
  /// is pinned by a test rather than by careful reading.
  static String composeCaptureMessage({
    required bool fullScreen,
    required String instruction,
  }) {
    final trimmed = instruction.trim();
    return [
      _snippetPrompt,
      if (fullScreen) _fullScreenNote,
      if (trimmed.isNotEmpty) trimmed,
    ].join(' ');
  }

  /// Sends a capture through the agent, optionally with the [instruction] the
  /// user spoke or typed on the compose step ("what's the total?", "save this
  /// link for later") so the model knows what to do with the image rather
  /// than just describing it.
  ///
  /// [fullScreen] distinguishes the chat sheet's whole-screen grab from a
  /// cropped snippet; it changes the framing sentence and the stored source,
  /// nothing about how the turn runs.
  Future<void> sendSnippet(
    Uint8List png, {
    String instruction = '',
    bool fullScreen = false,
  }) async {
    final stamp = DateTime.now();
    final source = fullScreen ? 'overlay_screen' : 'overlay_snippet';
    final attachment = Attachment(
      name: '${fullScreen ? 'screen' : 'snippet'}_'
          '${stamp.millisecondsSinceEpoch}.png',
      mimeType: 'image/png',
      sizeBytes: png.length,
      bytes: png,
      kind: 'image',
    );
    final trimmed = instruction.trim();
    final result = await send(
      composeCaptureMessage(fullScreen: fullScreen, instruction: trimmed),
      attachments: [attachment],
      requireVision: true,
      userMeta: {
        'source': source,
        if (trimmed.isNotEmpty) 'snippet_instruction': trimmed,
      },
    );
    // Safety net: the skill stores the snippet via store_file so later turns
    // ("remind me about that") can reference it. If the turn failed to, store
    // it directly - the image must never be lost.
    final stored = result?.executionRecords.any((record) =>
            record.toolName == 'store_file' &&
            record.status == ToolExecutionStatus.success) ??
        false;
    if (!stored) {
      try {
        await _ref.read(overlayAttachmentRepositoryProvider).store(
              name: attachment.name,
              bytes: png,
              mimeType: 'image/png',
              kind: 'image',
              source: source,
            );
      } catch (_) {
        // Best-effort; the analysis text itself is already in chat history.
      }
    }
  }

  Future<bool> _confirm(String toolName, Map<String, Object?> input) {
    final pending = OverlayPendingConfirm(toolName, input);
    state = state.copyWith(pendingConfirm: pending);
    return pending.completer.future;
  }

  void resolveConfirm(bool approved) {
    final pending = state.pendingConfirm;
    if (pending == null) return;
    if (!pending.completer.isCompleted) pending.completer.complete(approved);
    state = state.copyWith(clearPendingConfirm: true);
  }
}

final overlayChatControllerProvider =
    StateNotifierProvider<OverlayChatController, OverlayChatState>(
        (ref) => OverlayChatController(ref));
