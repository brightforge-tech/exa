import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../services/overlay/overlay_controller.dart';
import '../../shared/theme/exa_theme.dart';

/// Enables the floating Exa bubble and walks through the permissions it
/// needs: draw-over-apps, notifications (for the persistent service
/// notification), unrestricted battery (Samsung kills restricted foreground
/// services), and - optionally, up front - screen-capture consent for
/// instant snippets.
class OverlaySettingsScreen extends ConsumerStatefulWidget {
  const OverlaySettingsScreen({super.key});

  @override
  ConsumerState<OverlaySettingsScreen> createState() =>
      _OverlaySettingsScreenState();
}

class _OverlaySettingsScreenState extends ConsumerState<OverlaySettingsScreen> {
  bool _enabled = false;
  bool _lockScreen = false;
  String _captureState = 'inactive';
  bool _batteryUnrestricted = true;
  bool _busy = false;
  StreamSubscription<String>? _events;

  @override
  void initState() {
    super.initState();
    _refresh();
    _events =
        ref.read(overlayControllerProvider).events().listen((_) => _refresh());
  }

  @override
  void dispose() {
    _events?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    final controller = ref.read(overlayControllerProvider);
    final enabled = await controller.isBubbleEnabled();
    final lockScreen = await controller.isLockScreenEnabled();
    final capture = await controller.captureState();
    final battery = await Permission.ignoreBatteryOptimizations.isGranted;
    if (!mounted) return;
    setState(() {
      _enabled = enabled;
      _lockScreen = lockScreen;
      _captureState = capture;
      _batteryUnrestricted = battery;
    });
  }

  Future<void> _toggleLockScreen(bool value) async {
    await ref.read(overlayControllerProvider).setLockScreenEnabled(value);
    await _refresh();
  }

  Future<void> _toggleBubble(bool value) async {
    if (_busy) return;
    setState(() => _busy = true);
    final controller = ref.read(overlayControllerProvider);
    final messenger = ScaffoldMessenger.of(context);
    try {
      if (!value) {
        await controller.disableBubble();
        return;
      }
      // Step 1: draw over other apps (hard requirement).
      var canDraw = await controller.hasOverlayPermission();
      canDraw = canDraw || await controller.requestOverlayPermission();
      if (!canDraw) {
        messenger.showSnackBar(const SnackBar(
            content: Text('Exa needs "Display over other apps" to show '
                'the bubble. Please allow it and try again.')));
        return;
      }
      // Step 2: notifications - the bubble runs as a foreground service
      // with a (minimized) persistent notification.
      await Permission.notification.request();
      final started = await controller.enableBubble();
      if (!started) {
        messenger.showSnackBar(const SnackBar(
            content: Text('Could not start the bubble - check the overlay '
                'permission and try again.')));
      }
    } finally {
      setState(() => _busy = false);
      await _refresh();
    }
  }

  Future<void> _enableSnippets() async {
    final ok =
        await ref.read(overlayControllerProvider).requestCaptureConsent();
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Turn the bubble on first, then enable snippets.')));
    }
    // captureReady arrives via the event stream and refreshes the screen.
  }

  @override
  Widget build(BuildContext context) {
    final captureReady = _captureState == 'ready';
    return Scaffold(
      appBar: AppBar(title: const Text('Exa bubble')),
      body: ListView(
        children: [
          SwitchListTile(
            secondary: const Icon(Icons.blur_on),
            title: const Text('Floating bubble'),
            subtitle: const Text(
                'Keep Exa on screen over other apps: snip the screen, '
                'chat, or add a task from anywhere'),
            value: _enabled,
            onChanged: _busy ? null : _toggleBubble,
          ),
          if (_enabled) ...[
            const Divider(),
            ListTile(
              leading: Icon(Icons.cut,
                  color: captureReady ? ExaColors.success : null),
              title: const Text('Screen snippets'),
              subtitle: Text(captureReady
                  ? 'Ready - captures are instant'
                  : 'Off - Android asks for screen-capture permission per '
                      'session. Enable now or on your first Snippet.'),
              trailing: captureReady
                  ? null
                  : FilledButton.tonal(
                      onPressed: _enableSnippets,
                      child: const Text('Enable'),
                    ),
            ),
            ListTile(
              leading: const Icon(Icons.control_camera),
              title: const Text('Reset bubble position'),
              onTap: () =>
                  ref.read(overlayControllerProvider).resetBubblePosition(),
            ),
            const Divider(),
            SwitchListTile(
              secondary: const Icon(Icons.lock_open_outlined),
              title: const Text('Lock screen access'),
              subtitle: const Text(
                  'Puts Chat, Voice and Snippet buttons on the Exa '
                  'notification, which shows on your lock screen. Tapping '
                  'one unlocks the phone (your normal PIN or face) and '
                  'opens Exa on that feature - Voice starts listening '
                  'straight away and sends when you stop talking.'),
              value: _lockScreen,
              onChanged: _toggleLockScreen,
            ),
          ],
          if (!_batteryUnrestricted) ...[
            const Divider(),
            ListTile(
              leading:
                  const Icon(Icons.battery_alert, color: ExaColors.warning),
              title: const Text('Allow unrestricted battery'),
              subtitle: const Text(
                  'Samsung pauses restricted apps, which kills the bubble '
                  'within hours. Set Exa\'s battery use to Unrestricted.'),
              trailing: FilledButton.tonal(
                onPressed: () async {
                  await Permission.ignoreBatteryOptimizations.request();
                  await _refresh();
                },
                child: const Text('Allow'),
              ),
            ),
          ],
          const Divider(),
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              'Tap the bubble to fan out four quick actions:\n\n'
              '  ✂  Snippet - capture part of the screen. Exa analyzes '
              'it right away and asks a useful follow-up, e.g. to set a '
              'reminder about what it sees.\n'
              '  \u{1F4AC}  Chat - ask Exa anything without leaving the app '
              'you\'re in.\n'
              '  \u{1F3A4}  Voice - opens Exa already listening: say it and '
              'it sends when you stop talking (tap stop to edit first).\n'
              '  ✓  Task - jot a task down in two taps.\n\n'
              'With lock screen access on, the same Chat, Voice and Snippet '
              'buttons sit on the Exa notification on your lock screen '
              '(expand the notification to see them); tapping one unlocks '
              'and opens Exa on that feature. After a reboot the bubble '
              'comes back on its own; screen capture re-asks for permission '
              'once per session (an Android requirement).',
              style: TextStyle(color: ExaColors.textSecondary, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}
