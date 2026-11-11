import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show SystemChannels;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/chat_message.dart';
import '../../services/overlay/overlay_panel_channel.dart';
import '../../shared/theme/exa_theme.dart';
import 'overlay_chat_controller.dart';
import 'voice_input_controller.dart';
import 'voice_mic_button.dart';

/// The mini chat inside the overlay window: recent history, live streaming
/// bubble, inline confirmation strip for gated tools, and a text input that
/// toggles the window's focusability so the keyboard can attach.
class OverlayChatPanel extends ConsumerStatefulWidget {
  const OverlayChatPanel({
    super.key,
    this.onLookAtScreen,
    this.looking = false,
    this.lookError,
    this.voiceRequest = 0,
    this.onVoiceConsumed,
    this.locked = false,
  });

  /// Grabs the whole screen behind the overlay and moves to the compose step.
  /// Null when the host has no capture route to offer.
  final VoidCallback? onLookAtScreen;

  /// A capture is in flight (or its consent dialog is up).
  final bool looking;

  /// Why the last capture attempt produced nothing.
  final String? lookError;

  /// Non-zero when this panel was opened by the Voice action; each new
  /// request (a higher number) starts the mic again and arms auto-send:
  /// the message goes as soon as the recognizer stops with words, unless
  /// the user touches the field or the mic first. Zero = the ordinary chat
  /// panel, mic on request.
  final int voiceRequest;

  /// Called once the mic has been started for [voiceRequest], so the host
  /// can retire the token: a panel rebuilt later must not start listening
  /// again on its own.
  final VoidCallback? onVoiceConsumed;

  /// Opened from the lock screen: turns run read/local-write only, and the
  /// panel says so when something is refused.
  final bool locked;

  @override
  ConsumerState<OverlayChatPanel> createState() => _OverlayChatPanelState();
}

class _OverlayChatPanelState extends ConsumerState<OverlayChatPanel> {
  final _input = TextEditingController();
  final _focusNode = FocusNode();
  final _scroll = ScrollController();

  /// Auto-send is live for the current voice request. Cleared by the first
  /// touch on the field or the mic, and by the send itself.
  bool _autoSendArmed = false;

  /// The mic failed to start for a voice request (almost always the
  /// permission the overlay cannot ask for) - shown inline, since nobody
  /// tapped the mic to receive the dialog.
  String? _voiceError;

  OverlayPanelChannel get _channel => ref.read(overlayPanelChannelProvider);

  @override
  void initState() {
    super.initState();
    // Overlay windows are non-focusable by default; the IME can only attach
    // once the native window becomes focusable. Flip it with field focus.
    _focusNode.addListener(() {
      _channel.setFocusable(_focusNode.hasFocus);
      if (_focusNode.hasFocus) {
        // The window-flag change can race the IME request on first tap;
        // nudge the keyboard once the flag has landed. TextInput.show is a
        // no-op when no field is focused.
        Future.delayed(const Duration(milliseconds: 80), () {
          if (_focusNode.hasFocus && mounted) {
            SystemChannels.textInput.invokeMethod('TextInput.show');
          }
        });
      }
    });
    // The voice -> send edge. Registered once here rather than in build so
    // it cannot fire twice for one stop.
    ref.listenManual<VoiceInputState>(voiceInputControllerProvider,
        (previous, next) {
      if (VoiceAutoSend.shouldSend(
          previous: previous, next: next, armed: _autoSendArmed)) {
        _autoSendArmed = false;
        // Send what the recognizer heard, not the text field: the field is
        // filled by a separate listener whose timing relative to this edge
        // is not guaranteed, so it can still be empty right now.
        _sendVoice(next.text);
      }
    });
    if (widget.voiceRequest > 0) _startVoice();
  }

  @override
  void didUpdateWidget(covariant OverlayChatPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.voiceRequest != oldWidget.voiceRequest &&
        widget.voiceRequest > 0) {
      _startVoice();
    }
  }

  /// Opened by Voice: start listening as soon as the panel is up.
  void _startVoice() {
    _autoSendArmed = true;
    _voiceError = null;
    widget.onVoiceConsumed?.call();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final controller = ref.read(voiceInputControllerProvider.notifier);
      await controller.start(seed: _input.text);
      final failure = ref.read(voiceInputControllerProvider).error;
      if (failure != null && mounted) {
        setState(() {
          _autoSendArmed = false;
          _voiceError = failure;
        });
      }
    });
  }

  /// The user has taken over: whatever the mic heard is theirs to edit.
  void _disarmAutoSend() => _autoSendArmed = false;

  @override
  void dispose() {
    _input.dispose();
    _focusNode.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    _autoSendArmed = false;
    // Anything still being dictated is part of this message.
    await ref.read(voiceInputControllerProvider.notifier).stop();
    final text = _input.text.trim();
    if (text.isEmpty) return;
    _input.clear();
    ref.read(voiceInputControllerProvider.notifier).reset();
    await ref.read(overlayChatControllerProvider.notifier).send(text);
  }

  /// Auto-send from the Voice action, using the recognizer's own final text.
  Future<void> _sendVoice(String heard) async {
    final text = heard.trim();
    await ref.read(voiceInputControllerProvider.notifier).stop();
    ref.read(voiceInputControllerProvider.notifier).reset();
    _input.clear();
    if (text.isEmpty) return;
    await ref.read(overlayChatControllerProvider.notifier).send(text);
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(overlayChatControllerProvider);
    final items = state.messages.reversed.toList();
    final voice = ref.watch(voiceInputControllerProvider);

    return Column(
      children: [
        Expanded(
          child: ListView.builder(
            controller: _scroll,
            reverse: true,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            // Streaming bubble (or typing dots) rides at index 0 while a
            // turn is in flight.
            itemCount: items.length + (state.sending ? 1 : 0),
            itemBuilder: (context, index) {
              if (state.sending && index == 0) {
                return _AssistantBubble(
                  text: state.streamingText.isEmpty
                      ? '…'
                      : state.streamingText,
                );
              }
              final message = items[index - (state.sending ? 1 : 0)];
              return message.role == 'user'
                  ? _UserBubble(message: message)
                  : _AssistantBubble(text: message.content);
            },
          ),
        ),
        if (state.pendingConfirm != null)
          _ConfirmStrip(
            confirm: state.pendingConfirm!,
            onResolve: (approved) => ref
                .read(overlayChatControllerProvider.notifier)
                .resolveConfirm(approved),
          ),
        if (widget.lookError != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: Text(widget.lookError!,
                style: const TextStyle(fontSize: 12, color: ExaColors.warning)),
          ),
        if (_voiceError != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: Text(_voiceError!,
                style: const TextStyle(fontSize: 12, color: ExaColors.warning)),
          )
        else if (voice.listening && _autoSendArmed)
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: Text('Listening - sends when you stop talking',
                style:
                    TextStyle(fontSize: 12, color: ExaColors.textSecondary)),
          ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(4, 4, 8, 8),
            child: Row(
              children: [
                // Whole screen, minus Exa's own windows - the native side
                // hides the bubble and this sheet before grabbing the frame.
                IconButton(
                  icon: widget.looking
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.center_focus_strong_outlined,
                          color: ExaColors.textSecondary),
                  tooltip: 'Look at my screen',
                  onPressed: widget.looking ? null : widget.onLookAtScreen,
                ),
                Expanded(
                  child: GestureDetector(
                    // Make the window focusable BEFORE the tap reaches the
                    // field, so the very first IME request can succeed.
                    onTapDown: (_) {
                      _disarmAutoSend();
                      _channel.setFocusable(true);
                    },
                    child: TextField(
                      controller: _input,
                      focusNode: _focusNode,
                      minLines: 1,
                      maxLines: 4,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _send(),
                      decoration: InputDecoration(
                        hintText: widget.locked
                            ? 'Ask Exa… (locked: no sending or deleting)'
                            : 'Ask Exa…',
                        isDense: true,
                        filled: true,
                        fillColor: ExaColors.surfaceHigh,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(22),
                          borderSide: BorderSide.none,
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 10),
                      ),
                    ),
                  ),
                ),
                VoiceMicButton(input: _input, onTap: _disarmAutoSend),
                IconButton(
                  icon: Icon(Icons.send,
                      color: state.sending
                          ? ExaColors.textTertiary
                          : ExaColors.accent),
                  onPressed: state.sending ? null : _send,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _UserBubble extends StatelessWidget {
  const _UserBubble({required this.message});

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final attachments =
        (message.meta?['attachments'] as List?)?.cast<String>() ?? const [];
    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 3),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        constraints: const BoxConstraints(maxWidth: 300),
        decoration: BoxDecoration(
          color: ExaColors.accentContainer,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (attachments.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.attach_file,
                        size: 13, color: ExaColors.onAccentContainer),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(
                        attachments.join(', '),
                        style: const TextStyle(
                            fontSize: 11,
                            color: ExaColors.onAccentContainer),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            if (message.content.isNotEmpty)
              Text(message.content,
                  style:
                      const TextStyle(color: ExaColors.onAccentContainer)),
          ],
        ),
      ),
    );
  }
}

class _AssistantBubble extends StatelessWidget {
  const _AssistantBubble({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 3),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        constraints: const BoxConstraints(maxWidth: 320),
        decoration: BoxDecoration(
          color: ExaColors.surfaceHigh,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Text(text,
            style: const TextStyle(color: ExaColors.textPrimary)),
      ),
    );
  }
}

/// Inline approval for tools marked `requiresConfirmation` (the overlay
/// counterpart of the in-app confirm dialog).
class _ConfirmStrip extends StatelessWidget {
  const _ConfirmStrip({required this.confirm, required this.onResolve});

  final OverlayPendingConfirm confirm;
  final void Function(bool approved) onResolve;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: ExaColors.surfaceHighest,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          const Icon(Icons.shield_outlined,
              size: 18, color: ExaColors.warning),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Allow ${confirm.toolName.replaceAll('_', ' ')}?',
              style: const TextStyle(fontSize: 13),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          TextButton(
              onPressed: () => onResolve(false), child: const Text('Deny')),
          FilledButton(
              onPressed: () => onResolve(true), child: const Text('Allow')),
        ],
      ),
    );
  }
}
