import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:speech_to_text/speech_to_text.dart';

import '../../agent/services/tool_labels.dart';
import '../../data/models/chat_message.dart';
import '../../services/files/file_service.dart';
import '../../services/messaging/messaging_bridge.dart';
import '../../shared/providers.dart';
import '../../shared/theme/exa_theme.dart';
import '../../shared/widgets/exa_orb.dart';
import 'chat_controller.dart';
import 'clear_conversation_dialog.dart';
import 'today_panel.dart';

class AssistantScreen extends ConsumerStatefulWidget {
  const AssistantScreen({super.key});

  @override
  ConsumerState<AssistantScreen> createState() => _AssistantScreenState();
}

class _AssistantScreenState extends ConsumerState<AssistantScreen> {
  final _inputController = TextEditingController();
  final _scrollController = ScrollController();
  final _speech = SpeechToText();
  final List<Attachment> _pending = [];
  bool _speechReady = false;
  bool _listening = false;
  late final AppLifecycleListener _lifecycle;

  /// Whatever was already in the composer when recognition started, plus every
  /// utterance finalized since. The recognizer's `recognizedWords` only covers
  /// the current session and resets on each pause/restart, so results are
  /// appended to this instead of replacing the field - otherwise a second
  /// utterance wipes everything said before it.
  String _speechBase = '';

  /// User intent to keep dictating. The engine stops on its own after a silence
  /// pause or a max-duration cap; this survives those stops so the done/error
  /// callbacks know to restart rather than end the recording. Cleared only by
  /// the stop button, [_send], or [dispose].
  bool _wantListening = false;
  bool _restartScheduled = false;

  /// A one-shot "voice message" session (from the bubble Voice action or the
  /// lock-screen notification): dictate, then send when the speaker stops -
  /// unlike the mic button, which dictates continuously and leaves sending to
  /// the user. Kept separate so the mic button's auto-restart is untouched.
  bool _voiceMessageMode = false;

  /// Empty listening windows left before a voice message gives up. The
  /// recognizer reports "no speech" after only a few seconds of silence, and
  /// a Voice tap from the lock screen spends the first of those on unlocking
  /// and opening - so a session that heard nothing yet is restarted rather
  /// than abandoned. Once words arrive this stops mattering: the next stop
  /// sends them.
  int _voiceSilenceRetries = 0;
  static const _voiceSilenceRetryLimit = 2;

  /// Fires shortly after the recognizer finalizes an utterance, and is what
  /// actually sends a voice message.
  ///
  /// The engine's own "session finished" signals cannot be relied on for
  /// this: `onStatus('done')` and `onError(NO_SPEECH_DETECTED)` arrive in
  /// either order, sometimes long after the words did (ambient noise keeps a
  /// session open), and sometimes not at all. Waiting for them left the
  /// transcript sitting in the composer, unsent - the bug this timer fixes.
  /// A new partial result cancels it, so a pause mid-sentence does not send
  /// half a message.
  Timer? _voiceSendTimer;

  /// How long to wait after the last final result before sending.
  static const _voiceSendGrace = Duration(milliseconds: 1200);

  @override
  void initState() {
    super.initState();
    // When the app returns to the foreground (e.g. tapping a morning-brief
    // notification), reload so any brief a background job posted appears.
    _lifecycle = AppLifecycleListener(
      onResume: () {
        ref.read(chatControllerProvider.notifier).refresh();
        // Pick up anything that changed while away (e.g. a brief that digested
        // emails, a reminder that fired).
        ref.invalidate(todayDashboardProvider);
        _consumeShared();
      },
    );
    // A share that cold-starts the app is waiting natively before this screen
    // exists, so it is collected once the first frame is up as well as on
    // every resume - sharing into an already-open Exa takes the second path.
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _consumeShared());
  }

  /// Takes whatever the user shared into Exa and puts the question in the
  /// composer.
  ///
  /// The point of sharing a message to an assistant is to ask about it, so
  /// this does not stop at filing it: the outcome seeds the input box. Text
  /// already typed is kept and appended to — a share arriving mid-sentence
  /// must not delete what the user was writing.
  Future<void> _consumeShared() async {
    final item = await ref.read(messagingBridgeProvider).consumeSharedItem();
    if (item == null || !mounted) return;

    final outcome = await ref.read(sharedIntakeServiceProvider).accept(item);
    if (!mounted) return;

    ref.invalidate(conversationsProvider);
    ref.invalidate(todayDashboardProvider);

    final prefill = outcome.promptPrefill;
    if (prefill.isNotEmpty) {
      final existing = _inputController.text.trimRight();
      final combined = existing.isEmpty ? prefill : '$existing\n\n$prefill';
      _inputController.value = TextEditingValue(
        text: combined,
        selection: TextSelection.collapsed(offset: combined.length),
      );
    }
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(outcome.banner)));
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    // Clear the intent first so the engine's done/error callbacks don't try to
    // restart a session (or send a voice message) for a screen going away.
    _wantListening = false;
    _voiceMessageMode = false;
    _voiceSendTimer?.cancel();
    _speech.stop();
    _speech.cancel();
    _inputController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  /// Initializes the recognizer once, with the handlers BOTH modes share.
  ///
  /// One place on purpose: the callbacks are registered once per process, by
  /// whichever path used speech first, so a per-path closure meant a voice
  /// message started after the mic button had initialized ended up in the mic
  /// button's error handler - which knows nothing about sending, and left the
  /// transcript stranded in the composer.
  Future<bool> _ensureSpeechReady() async {
    if (_speechReady) return true;
    // Triggers the microphone permission prompt on first use.
    _speechReady = await _speech.initialize(
      onStatus: _onSpeechStatus,
      onError: (_) {
        // An error usually just means the session ended oddly (silence, a
        // brief audio-focus loss).
        if (_voiceMessageMode) {
          _finishVoiceMessage();
        } else if (_wantListening) {
          _restartListening();
        } else if (mounted) {
          setState(() => _listening = false);
        }
      },
    );
    if (!_speechReady && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Voice input is unavailable - check the '
              'microphone permission.')));
    }
    return _speechReady;
  }

  Future<void> _toggleListening() async {
    if (_listening) {
      await _stopListening();
      return;
    }
    if (!await _ensureSpeechReady()) return;
    // Adopt the current composer text (typed or previously dictated) so the
    // recording appends after it.
    _speechBase = _inputController.text.trim();
    _wantListening = true;
    setState(() => _listening = true);
    await _listenOnce();
  }

  Future<void> _listenOnce() async {
    await _speech.listen(
      onResult: (result) {
        if (!mounted) return;
        final text = _withSpeech(result.recognizedWords);
        _inputController.value = TextEditingValue(
          text: text,
          selection: TextSelection.collapsed(offset: text.length),
        );
        // Bank each finished utterance so the next one - in this session or in
        // the one that replaces it after a pause - appends instead of
        // overwriting. Recording continues either way; only the stop button
        // ends it.
        if (result.finalResult) _speechBase = text;
      },
      listenOptions: SpeechListenOptions(
        partialResults: true,
        listenMode: ListenMode.dictation,
        // Generous pause; we auto-restart anyway, so this just reduces churn.
        // No listenFor cap - the recording runs until the user stops it.
        pauseFor: const Duration(seconds: 8),
      ),
    );
  }

  void _onSpeechStatus(String status) {
    if (status != 'done' && status != 'notListening') return;
    // A voice message ends when the speaker stops: send what was heard.
    if (_voiceMessageMode) {
      _finishVoiceMessage();
      return;
    }
    if (_wantListening) {
      _restartListening();
    } else if (mounted) {
      setState(() => _listening = false);
    }
  }

  /// Starts a single dictate-then-send session and starts listening now.
  /// Reuses the same recognizer and composer as the mic button; the only
  /// difference is that stopping sends instead of waiting for the user.
  Future<void> _startVoiceMessage() async {
    if (_listening) return;
    if (!await _ensureSpeechReady()) return;
    _speechBase = _inputController.text.trim();
    _voiceMessageMode = true;
    _voiceSilenceRetries = _voiceSilenceRetryLimit;
    _wantListening = false; // one session; the status callback sends, not restarts
    setState(() => _listening = true);
    await _listenForVoiceMessage();
  }

  Future<void> _listenForVoiceMessage() => _speech.listen(
        onResult: (result) {
          if (!mounted) return;
          final text = _withSpeech(result.recognizedWords);
          _inputController.value = TextEditingValue(
            text: text,
            selection: TextSelection.collapsed(offset: text.length),
          );
          // Still talking: whatever send was pending is premature.
          _voiceSendTimer?.cancel();
          if (result.finalResult) {
            _speechBase = text;
            if (text.trim().isNotEmpty) {
              _voiceSendTimer =
                  Timer(_voiceSendGrace, _completeVoiceMessage);
            }
          }
        },
        listenOptions: SpeechListenOptions(
          partialResults: true,
          listenMode: ListenMode.dictation,
          // Send shortly after they stop talking.
          pauseFor: const Duration(seconds: 3),
          listenFor: const Duration(seconds: 60),
        ),
      );

  /// Ends a voice-message session and sends what was dictated (once). A
  /// session that heard nothing at all gets another window first - see
  /// [_voiceSilenceRetries].
  void _finishVoiceMessage() {
    if (!_voiceMessageMode) return;
    final text = _inputController.text.trim();
    if (text.isEmpty && _voiceSilenceRetries > 0 && mounted) {
      _voiceSilenceRetries--;
      _restartVoiceMessage();
      return;
    }
    _completeVoiceMessage();
  }

  /// Ends the voice message for good and sends what was heard. Safe to call
  /// from either the grace timer or an engine callback - whichever gets here
  /// first wins, and the other finds [_voiceMessageMode] already false.
  void _completeVoiceMessage() {
    if (!_voiceMessageMode) return;
    _voiceMessageMode = false;
    _voiceSendTimer?.cancel();
    _voiceSendTimer = null;
    _speech.stop();
    if (mounted) setState(() => _listening = false);
    if (_inputController.text.trim().isNotEmpty) _send();
  }

  /// Reopens the microphone for a voice message that has not heard anything
  /// yet. The plugin needs the previous session fully closed before
  /// `listen()` is called again, hence the short delay.
  Future<void> _restartVoiceMessage() async {
    await Future<void>.delayed(const Duration(milliseconds: 250));
    if (!mounted || !_voiceMessageMode || _speech.isListening) return;
    try {
      await _listenForVoiceMessage();
    } catch (_) {
      _voiceMessageMode = false;
      if (mounted) setState(() => _listening = false);
    }
  }

  /// The plugin must fully finish the previous session before `listen()` is
  /// called again, or it throws. A short debounce plus [_restartScheduled]
  /// prevents overlapping sessions and tight error loops.
  Future<void> _restartListening() async {
    if (_restartScheduled || !_wantListening) return;
    _restartScheduled = true;
    await Future<void>.delayed(const Duration(milliseconds: 250));
    _restartScheduled = false;
    if (!_wantListening || !mounted || _speech.isListening) return;
    try {
      await _listenOnce();
    } catch (_) {
      if (_wantListening) _restartListening();
    }
  }

  Future<void> _stopListening() async {
    _wantListening = false;
    // A deliberate stop is not a "voice message stopped talking" - leave the
    // words in the composer to review rather than firing them off.
    _voiceMessageMode = false;
    _voiceSendTimer?.cancel();
    await _speech.stop();
    // Keep a trailing partial that never got a final result.
    _speechBase = _inputController.text.trim();
    if (mounted) setState(() => _listening = false);
  }

  /// Joins [words] from the recognizer onto the text banked in [_speechBase].
  String _withSpeech(String words) {
    final spoken = words.trim();
    if (spoken.isEmpty) return _speechBase;
    if (_speechBase.isEmpty) return spoken;
    return '$_speechBase $spoken';
  }

  Future<void> _send([String? quickText]) async {
    // Sending ends the recording; otherwise the mic would keep appending into
    // the composer we are about to clear.
    if (_listening) await _stopListening();
    final text = quickText ?? _inputController.text;
    if (text.trim().isEmpty && _pending.isEmpty) return;
    _inputController.clear();
    _speechBase = '';
    final attachments = List<Attachment>.from(_pending);
    setState(() => _pending.clear());

    final result = await ref.read(chatControllerProvider.notifier).send(
          text,
          attachments: attachments,
          onConfirm: _confirmToolCall,
        );
    // The turn may have changed today's items (new task/reminder/event, a
    // digested email), so refresh the panel.
    ref.invalidate(todayDashboardProvider);
    _scrollToBottom();

    if (result != null && result.navigationTargets.isNotEmpty && mounted) {
      context.push(result.navigationTargets.last);
    }
  }

  /// Handles a tap on a message quick-action chip: open a screen or send a
  /// canned follow-up prompt.
  void _onMessageAction(Map action) {
    final value = action['value'] as String?;
    if (value == null) return;
    if (action['type'] == 'open') {
      if (mounted) context.push(value);
    } else if (action['type'] == 'prompt') {
      _send(value);
    }
  }

  Future<void> _pickFiles() async {
    try {
      final picked = await ref.read(fileServiceProvider).pick();
      if (picked.isEmpty || !mounted) return;
      setState(() => _pending.addAll(picked));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Could not pick a file: $e')));
      }
    }
  }

  static IconData _attachmentIcon(Attachment a) => switch (a.kind) {
        'image' => Icons.image_outlined,
        'pdf' => Icons.picture_as_pdf_outlined,
        'office' => Icons.description_outlined,
        _ => Icons.text_snippet_outlined,
      };

  Future<bool> _confirmToolCall(
      String toolName, Map<String, Object?> input) async {
    final approved = await showDialog<bool>(
      context: context,
      // Use the root navigator so the prompt appears over whatever screen the
      // user is on. Otherwise, if they switched tabs mid-turn, the dialog
      // would be pushed onto the offstage Exa navigator - invisible - and the
      // turn would hang forever waiting for an answer.
      useRootNavigator: true,
      builder: (context) => AlertDialog(
        title: const Text('Exa wants to run a sensitive action'),
        content: Text(
            'Tool: $toolName\n\n${_describeInput(input)}\n\nAllow this?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Deny'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Allow'),
          ),
        ],
      ),
    );
    return approved ?? false;
  }

  static String _describeInput(Map<String, Object?> input) => input.entries
      .map((entry) => '${entry.key}: ${entry.value}')
      .join('\n');

  void _scrollToBottom() {
    // The message list is built with reverse: true, so scroll offset 0 is
    // the bottom (newest message). Jumping there re-pins to the latest.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(0);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final chatState = ref.watch(chatControllerProvider);
    // Re-entering the Exa tab: reload (pick up briefs added while away)
    // and pin to the latest message. This listener stays active even
    // while the screen is offstage in the nav IndexedStack.
    ref.listen<int>(assistantVisitTickProvider, (_, _) {
      ref.read(chatControllerProvider.notifier).refresh();
      ref.invalidate(todayDashboardProvider);
      _scrollToBottom();
    });
    // Opened via a Voice request (bubble Voice action, or the lock-screen
    // notification's Voice): start listening straight away, and send when the
    // speaker stops.
    ref.listen<int>(assistantVoiceRequestProvider, (previous, next) {
      if (next > (previous ?? 0)) _startVoiceMessage();
    });

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 16,
        title: Row(
          children: [
            ExaOrb(size: 26, thinking: chatState.sending),
            const SizedBox(width: 10),
            const Text('Exa'),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Clear conversation',
            icon: const Icon(Icons.delete_sweep_outlined),
            onPressed: chatState.messages.isEmpty
                ? null
                : () async {
                    if (!await confirmClearConversation(context)) return;
                    await ref
                        .read(chatControllerProvider.notifier)
                        .clearHistory();
                  },
          ),
        ],
      ),
      body: Column(
        children: [
          TodayPanel(
            onOpenRoute: (route) {
              if (mounted) context.push(route);
            },
            onDigestEmails: () => _send(
                'Digest my new emails: pull out any tasks, meetings, and '
                'deadlines, give me a short rundown, and mark them digested.'),
          ),
          Expanded(
            child: chatState.messages.isEmpty
                ? _EmptyChat(onQuickAction: _send)
                : ListView.builder(
                    controller: _scrollController,
                    // Reversed so the list loads pinned to the bottom (the
                    // latest message) without scroll-position hacking, even
                    // while messages load asynchronously. Index 0 is newest.
                    reverse: true,
                    padding: const EdgeInsets.all(12),
                    itemCount: chatState.messages.length,
                    itemBuilder: (context, index) => _MessageBubble(
                        message: chatState
                            .messages[chatState.messages.length - 1 - index],
                        onAction: _onMessageAction),
                  ),
          ),
          if (chatState.sending)
            chatState.streamingText.isEmpty
                // No tokens yet: the breathing orb stands in for the reply.
                ? Padding(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const ExaOrb(size: 20, thinking: true),
                        const SizedBox(width: 10),
                        Text('Exa is thinking...',
                            style: Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.copyWith(color: ExaColors.textSecondary)),
                      ],
                    ),
                  )
                // Live reply streaming in; replaced by the saved message when
                // the turn finishes and the history reloads.
                : Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: _MessageBubble(
                      message: ChatMessage(
                        id: 'streaming',
                        role: 'assistant',
                        content: chatState.streamingText,
                        createdAt: DateTime.now(),
                      ),
                    ),
                  ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_pending.isNotEmpty) _buildPendingStrip(),
                  Container(
                    padding: const EdgeInsets.fromLTRB(6, 4, 6, 4),
                    decoration: BoxDecoration(
                      color: ExaColors.surfaceHigh,
                      borderRadius: BorderRadius.circular(26),
                      border: Border.all(color: ExaColors.outline),
                    ),
                    child: Row(
                      children: [
                        IconButton(
                          tooltip: 'Attach a file',
                          onPressed: chatState.sending ? null : _pickFiles,
                          icon: const Icon(Icons.attach_file),
                        ),
                        IconButton(
                          tooltip: _listening
                              ? 'Stop listening'
                              : 'Speak to Exa',
                          onPressed:
                              chatState.sending ? null : _toggleListening,
                          icon: Icon(
                            _listening ? Icons.mic : Icons.mic_none,
                            color: _listening ? ExaColors.error : null,
                          ),
                        ),
                    Expanded(
                      child: TextField(
                        controller: _inputController,
                        decoration: InputDecoration(
                          hintText: _listening
                              ? 'Listening...'
                              : 'Ask Exa anything...',
                          filled: false,
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          isDense: true,
                          contentPadding:
                              const EdgeInsets.symmetric(vertical: 10),
                        ),
                        textInputAction: TextInputAction.send,
                        onSubmitted: (_) => _send(),
                        enabled: !chatState.sending,
                        minLines: 1,
                        maxLines: 4,
                      ),
                    ),
                    const SizedBox(width: 4),
                    GestureDetector(
                      onTap: chatState.sending ? null : () => _send(),
                      child: Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          gradient: ExaColors.accentGradient,
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: ExaColors.accent.withValues(alpha: 0.45),
                              blurRadius: 12,
                            ),
                          ],
                        ),
                        child: const Icon(Icons.arrow_upward,
                            color: Colors.white, size: 20),
                      ),
                    ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPendingStrip() {
    return Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 6, left: 4, right: 4),
        child: Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (var i = 0; i < _pending.length; i++)
              Chip(
                avatar: Icon(_attachmentIcon(_pending[i]), size: 18),
                label: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 160),
                  child: Text(_pending[i].name,
                      overflow: TextOverflow.ellipsis, maxLines: 1),
                ),
                onDeleted: () => setState(() => _pending.removeAt(i)),
              ),
          ],
        ),
      ),
    );
  }
}

class _EmptyChat extends StatelessWidget {
  const _EmptyChat({required this.onQuickAction});

  final void Function(String) onQuickAction;

  static const _quickActions = [
    ('Add a task', 'Create a task: '),
    ('Remind me...', 'Remind me tomorrow at 8 AM to '),
    ("Today's schedule", 'Show me my schedule for today'),
    ('Overdue tasks', 'Create a screen where I can see all overdue tasks, '
        'then open it'),
  ];

  static String _greeting() {
    final hour = DateTime.now().hour;
    if (hour < 12) return 'Good morning';
    if (hour < 18) return 'Good afternoon';
    return 'Good evening';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const ExaOrb(size: 76),
            const SizedBox(height: 24),
            Text(_greeting(), style: theme.textTheme.headlineMedium),
            const SizedBox(height: 6),
            Text(
              'I can create tasks and reminders, show your schedule,\n'
              'digest your email, and build screens for you.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: ExaColors.textSecondary),
            ),
            const SizedBox(height: 28),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              alignment: WrapAlignment.center,
              children: [
                for (final (label, prompt) in _quickActions)
                  _QuickChip(
                      label: label,
                      onTap: () => onQuickAction(prompt)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _QuickChip extends StatelessWidget {
  const _QuickChip({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: ExaColors.surfaceHigh,
      borderRadius: BorderRadius.circular(ExaRadii.field),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(ExaRadii.field),
        child: Container(
          padding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(ExaRadii.field),
            border: Border.all(color: ExaColors.outline),
          ),
          child: Text(label,
              style: Theme.of(context)
                  .textTheme
                  .labelLarge
                  ?.copyWith(color: ExaColors.textPrimary)),
        ),
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({required this.message, this.onAction});

  final ChatMessage message;

  /// Invoked when the user taps a quick-action chip (open a screen / send a
  /// follow-up). Null on non-interactive bubbles (e.g. while streaming).
  final void Function(Map action)? onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isUser = message.role == 'user';
    final toolsUsed =
        (message.meta?['tools_used'] as List?)?.cast<String>() ?? const [];
    final quickActions =
        (message.meta?['quick_actions'] as List?)?.cast<Map>() ?? const [];
    final attachments =
        (message.meta?['attachments'] as List?)?.cast<String>() ?? const [];
    final isScheduled = message.meta?['source'] == 'scheduled_job';
    final jobTitle = message.meta?['job_title'] as String?;

    final bubble = Container(
      padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 11),
      constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.78),
      decoration: BoxDecoration(
        color:
            isUser ? ExaColors.accentContainer : ExaColors.surfaceHigh,
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(18),
          topRight: const Radius.circular(18),
          bottomLeft: Radius.circular(isUser ? 18 : 4),
          bottomRight: Radius.circular(isUser ? 4 : 18),
        ),
        border: isScheduled
            ? Border.all(
                color: ExaColors.accent.withValues(alpha: 0.45))
            : isUser
                ? null
                : Border.all(color: ExaColors.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (isScheduled) ...[
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.schedule,
                    size: 13, color: ExaColors.spark),
                const SizedBox(width: 5),
                Text(jobTitle ?? 'Scheduled',
                    style: theme.textTheme.labelSmall
                        ?.copyWith(color: ExaColors.spark)),
              ],
            ),
            const SizedBox(height: 6),
          ],
          if (attachments.isNotEmpty) ...[
            for (final name in attachments)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.attach_file,
                        size: 14,
                        color: isUser
                            ? ExaColors.onAccentContainer
                            : ExaColors.textSecondary),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(name,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelSmall?.copyWith(
                              color: isUser
                                  ? ExaColors.onAccentContainer
                                  : ExaColors.textSecondary)),
                    ),
                  ],
                ),
              ),
            if (message.content.isNotEmpty) const SizedBox(height: 4),
          ],
          if (message.content.isNotEmpty)
            Text(message.content,
                style: theme.textTheme.bodyMedium?.copyWith(
                color: isUser
                    ? ExaColors.onAccentContainer
                    : ExaColors.textPrimary,
                height: 1.35,
              )),
          if (toolsUsed.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final tool in toolsUsed.toSet()) _ToolPill(tool: tool),
              ],
            ),
          ],
          if (quickActions.isNotEmpty && onAction != null) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final action in quickActions)
                  _ActionChip(
                    label: action['label'] as String? ?? 'Open',
                    onTap: () => onAction!(action),
                  ),
              ],
            ),
          ],
        ],
      ),
    );

    return _RiseIn(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(
          mainAxisAlignment:
              isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!isUser) ...[
              const Padding(
                padding: EdgeInsets.only(top: 2),
                child: ExaOrb(size: 24),
              ),
              const SizedBox(width: 8),
            ],
            Flexible(child: bubble),
          ],
        ),
      ),
    );
  }
}

/// One-shot fade + rise as a message appears.
class _RiseIn extends StatefulWidget {
  const _RiseIn({required this.child});

  final Widget child;

  @override
  State<_RiseIn> createState() => _RiseInState();
}

class _RiseInState extends State<_RiseIn> {
  double _t = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _t = 1);
    });
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedSlide(
      offset: Offset(0, (1 - _t) * 0.12),
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
      child: AnimatedOpacity(
        opacity: _t,
        duration: const Duration(milliseconds: 260),
        child: widget.child,
      ),
    );
  }
}

/// A tappable follow-up chip under an assistant message (e.g. "View tasks").
class _ActionChip extends StatelessWidget {
  const _ActionChip({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: ExaColors.accent.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
                color: ExaColors.accent.withValues(alpha: 0.4)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.arrow_outward,
                  size: 13, color: ExaColors.spark),
              const SizedBox(width: 5),
              Text(label,
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: ExaColors.textPrimary,
                      fontWeight: FontWeight.w600)),
            ],
          ),
        ),
      ),
    );
  }
}

class _ToolPill extends StatelessWidget {
  const _ToolPill({required this.tool});

  final String tool;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: ExaColors.accent.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
            color: ExaColors.accent.withValues(alpha: 0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.bolt, size: 12, color: ExaColors.spark),
          const SizedBox(width: 4),
          // "Checked chats", not "sync_messages": the pill is read by the
          // same person the message is for. Raw names stay on the Tool
          // activity screen, which is where debugging happens.
          Text(ToolLabels.pill(tool),
              style: Theme.of(context)
                  .textTheme
                  .labelSmall
                  ?.copyWith(color: ExaColors.spark)),
        ],
      ),
    );
  }
}
