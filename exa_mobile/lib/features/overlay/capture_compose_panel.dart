import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show SystemChannels;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/overlay/overlay_panel_channel.dart';
import '../../shared/theme/exa_theme.dart';
import 'voice_input_controller.dart';
import 'voice_mic_button.dart';

/// The step between capturing and sending: a preview of what Exa is about to
/// look at, plus what it should do with it - spoken or typed.
///
/// Nothing reaches the model until Send, so the user always gets to say what
/// the image is *for* instead of only ever getting a description back. Used
/// for both captures: a cropped region ([fullScreen] false) and the whole
/// screen grabbed from the chat sheet.
class CaptureComposePanel extends ConsumerStatefulWidget {
  const CaptureComposePanel({
    super.key,
    required this.png,
    required this.fullScreen,
    required this.onSend,
    required this.onRetake,
    required this.onCancel,
  });

  final Uint8List png;

  /// Whole screen vs a cropped region - changes the wording and what Retake
  /// does, nothing else.
  final bool fullScreen;

  /// Fires with the instruction, empty when the user just hits Send.
  final void Function(String instruction) onSend;

  final VoidCallback onRetake;
  final VoidCallback onCancel;

  @override
  ConsumerState<CaptureComposePanel> createState() =>
      _CaptureComposePanelState();
}

class _CaptureComposePanelState extends ConsumerState<CaptureComposePanel> {
  final _input = TextEditingController();
  final _focusNode = FocusNode();

  OverlayPanelChannel get _channel => ref.read(overlayPanelChannelProvider);

  @override
  void initState() {
    super.initState();
    // Same dance as the chat panel: an overlay window is non-focusable by
    // default, so the IME can only attach once the native flag flips.
    _focusNode.addListener(() {
      _channel.setFocusable(_focusNode.hasFocus);
      if (_focusNode.hasFocus) {
        Future.delayed(const Duration(milliseconds: 80), () {
          if (_focusNode.hasFocus && mounted) {
            SystemChannels.textInput.invokeMethod('TextInput.show');
          }
        });
      }
    });
  }

  @override
  void dispose() {
    _input.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    // Whatever is still being heard belongs in the message, so close the mic
    // session before reading the field.
    await ref.read(voiceInputControllerProvider.notifier).stop();
    if (!mounted) return;
    final instruction = _input.text;
    ref.read(voiceInputControllerProvider.notifier).reset();
    // Drop focus first so the window stops being focusable before the panel
    // switches to the streaming chat view.
    _focusNode.unfocus();
    await _channel.setFocusable(false);
    widget.onSend(instruction);
  }

  void _leave(VoidCallback action) {
    ref.read(voiceInputControllerProvider.notifier)
      ..stop()
      ..reset();
    action();
  }

  @override
  Widget build(BuildContext context) {
    final listening = ref.watch(voiceInputControllerProvider).listening;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Container(
                width: double.infinity,
                color: ExaColors.surfaceHigh,
                child: Image.memory(
                  widget.png,
                  fit: BoxFit.contain,
                  filterQuality: FilterQuality.medium,
                ),
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Row(
            children: [
              TextButton.icon(
                icon: Icon(widget.fullScreen ? Icons.refresh : Icons.crop,
                    size: 16),
                label: Text(widget.fullScreen ? 'Grab again' : 'Retake'),
                onPressed: () => _leave(widget.onRetake),
              ),
              const Spacer(),
              if (listening)
                const Padding(
                  padding: EdgeInsets.only(right: 8),
                  child: Text('Listening…',
                      style:
                          TextStyle(fontSize: 12, color: ExaColors.warning)),
                ),
              TextButton(
                onPressed: () => _leave(widget.onCancel),
                child: const Text('Discard'),
              ),
            ],
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 8, 8),
            child: Row(
              children: [
                Expanded(
                  child: GestureDetector(
                    onTapDown: (_) => _channel.setFocusable(true),
                    child: TextField(
                      controller: _input,
                      focusNode: _focusNode,
                      minLines: 1,
                      maxLines: 3,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _send(),
                      decoration: InputDecoration(
                        hintText: widget.fullScreen
                            ? 'Ask about this screen…'
                            : 'What should Exa do with this?',
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
                VoiceMicButton(input: _input),
                IconButton(
                  icon: const Icon(Icons.send, color: ExaColors.accent),
                  tooltip: 'Send to Exa',
                  onPressed: _send,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
