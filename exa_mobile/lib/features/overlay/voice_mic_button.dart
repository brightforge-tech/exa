import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/overlay/overlay_panel_channel.dart';
import '../../shared/theme/exa_theme.dart';
import 'voice_input_controller.dart';

/// Mic toggle that speaks into [input].
///
/// It owns the wiring both places need: recognized words replace the field's
/// text as they arrive (so the user watches it being heard), and stopping
/// leaves that text there to edit rather than sending it. The one shared
/// [voiceInputControllerProvider] means the mic can never be live in two
/// composers at once.
class VoiceMicButton extends ConsumerStatefulWidget {
  const VoiceMicButton({super.key, required this.input, this.onTap});

  final TextEditingController input;

  /// Called before the mic toggles on a tap. The chat panel uses it to
  /// withdraw auto-send: once the user has touched the mic themselves, the
  /// words are theirs to check and send.
  final VoidCallback? onTap;

  @override
  ConsumerState<VoiceMicButton> createState() => _VoiceMicButtonState();
}

class _VoiceMicButtonState extends ConsumerState<VoiceMicButton> {
  @override
  Widget build(BuildContext context) {
    ref.listen<VoiceInputState>(voiceInputControllerProvider, (previous, next) {
      if (next.text == previous?.text) return;
      widget.input.value = TextEditingValue(
        text: next.text,
        selection: TextSelection.collapsed(offset: next.text.length),
      );
    });
    final state = ref.watch(voiceInputControllerProvider);
    final error = state.error;

    return IconButton(
      icon: Icon(state.listening ? Icons.stop_circle : Icons.mic_none,
          color: state.listening ? ExaColors.warning : ExaColors.textSecondary),
      tooltip: state.listening ? 'Stop listening' : 'Speak',
      onPressed: () async {
        widget.onTap?.call();
        final controller = ref.read(voiceInputControllerProvider.notifier);
        await controller.toggle(seed: widget.input.text);
        final failure = ref.read(voiceInputControllerProvider).error;
        if (failure != null && context.mounted) _showError(context, failure);
      },
      // A tap that produced an error already reported it; this covers an
      // error arriving mid-session.
      onLongPress: error == null ? null : () => _showError(context, error),
    );
  }

  /// The overlay engine has no Scaffold, so this is a dialog rather than a
  /// SnackBar. When the problem is the permission the overlay cannot request,
  /// the dialog carries the one action that fixes it.
  void _showError(BuildContext context, String message) {
    final fixable = message == VoiceInputController.micPermissionMessage;
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(fixable ? 'Not now' : 'OK'),
          ),
          if (fixable)
            FilledButton(
              onPressed: () async {
                Navigator.pop(dialogContext);
                final channel = ref.read(overlayPanelChannelProvider);
                await channel.setFocusable(false);
                await channel.openMainApp(route: '/transcribe');
              },
              child: const Text('Open Exa'),
            ),
        ],
      ),
    );
  }
}
