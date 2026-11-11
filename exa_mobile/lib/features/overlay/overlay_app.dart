import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../agent/security/capability_policy.dart';
import '../../services/overlay/overlay_panel_channel.dart';
import '../../shared/theme/exa_theme.dart';
import 'capture_compose_panel.dart';
import 'overlay_chat_controller.dart';
import 'overlay_chat_panel.dart';
import 'quick_task_panel.dart';
import 'snippet_crop_screen.dart';

/// Root of the overlay FlutterEngine: a transparent Material app whose only
/// screen is the panel shell. The native side sizes the window (bottom panel
/// for chat/task, fullscreen for snippet crop).
class OverlayApp extends StatelessWidget {
  const OverlayApp({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = buildExaDarkTheme();
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: theme.copyWith(scaffoldBackgroundColor: Colors.transparent),
      darkTheme: theme.copyWith(scaffoldBackgroundColor: Colors.transparent),
      themeMode: ThemeMode.dark,
      home: const OverlayShell(),
    );
  }
}

class OverlayShell extends ConsumerStatefulWidget {
  const OverlayShell({super.key});

  @override
  ConsumerState<OverlayShell> createState() => _OverlayShellState();
}

class _OverlayShellState extends ConsumerState<OverlayShell>
    with WidgetsBindingObserver {
  String _panel = 'chat';
  String? _snippetError;
  bool _snippetCapturing = false;

  /// The capture awaiting the user's instruction on the compose step. Held
  /// here (not sent) until they tap Send.
  Uint8List? _pendingCapture;

  /// Whether [_pendingCapture] is the whole screen (the chat sheet's "look at
  /// my screen") rather than a cropped region.
  bool _pendingIsFullScreen = false;

  /// A full-screen grab is in flight, including the time the consent dialog
  /// is up - during which this engine's window is detached and Dart keeps
  /// running, so the flag has to be cleared when the panel comes back.
  bool _looking = false;
  String? _lookError;

  /// Whether the window has been grown for an open keyboard. See
  /// [didChangeMetrics].
  bool _grownForKeyboard = false;

  /// Who is hosting this engine: the bubble service's window, or
  /// `LockScreenActivity` over the keyguard. Decides the sheet layout (an
  /// activity window is the whole screen, so the sheet is drawn here), what
  /// to say when capture is off (no consent dialog can show over the
  /// keyguard), and the capability policy every turn runs under.
  String _host = OverlayPanelChannel.hostOverlay;

  /// A one-shot token for the Voice action: non-zero asks the chat panel to
  /// start listening, and the panel hands it back (`onVoiceConsumed`) once it
  /// has, so a panel rebuilt later - after a snippet, say - does not start
  /// the mic again on its own.
  int _voiceRequest = 0;

  static const _maxLongEdge = 1568;

  static const _lockedCaptureMessage =
      'Screen capture is off. Unlock your phone, then turn on Screen '
      'snippets in Exa (Settings > Exa bubble) to snip from here.';

  OverlayPanelChannel get _channel => ref.read(overlayPanelChannelProvider);

  bool get _isLockScreen => _host == OverlayPanelChannel.hostLockScreen;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _channel.listen(
      onPanelRequested: _showPanel,
      onCaptureLost: _onCaptureLost,
    );
    _boot();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// The bottom sheet is a fixed 62% of the screen pinned to the bottom, so an
  /// open keyboard covers most of it - including the text field being typed
  /// into. The window can't shrink out of the way (it's already at the bottom),
  /// so grow it to full height instead and let [_PanelChrome] inset the content
  /// above the IME. Applies to every text panel, not just compose.
  @override
  void didChangeMetrics() {
    super.didChangeMetrics();
    if (!mounted || _panel == 'snippet') return;
    final open = MediaQueryData.fromView(View.of(context)).viewInsets.bottom > 0;
    if (open == _grownForKeyboard) return;
    _grownForKeyboard = open;
    _channel.setWindowMode(open ? 'fullscreen' : 'panel');
  }

  Future<void> _boot() async {
    final launch = await _channel.getLaunchPanel();
    _host = launch.host;
    if (_isLockScreen) {
      // Every turn from the lock screen: reads and local writes only. The
      // user is present and can confirm, but has not unlocked anything.
      ref.read(overlayChatControllerProvider.notifier).policy =
          CapabilityPolicy.lockScreen;
    }
    await _showPanel(launch.panel, captureState: launch.captureState);
  }

  Future<void> _showPanel(String panel, {String? captureState}) async {
    // The native side has just sized the window for this panel, so any
    // keyboard growth we had applied is gone.
    _grownForKeyboard = false;
    if (panel == OverlayPanelChannel.panelSnippet) {
      // Over the keyguard the consent dialog cannot be shown, so a selector
      // with no session behind it would be a dead end: say why instead.
      final state = _isLockScreen
          ? (captureState ?? await _channel.captureState())
          : 'ready';
      if (!mounted) return;
      setState(() {
        _panel = 'snippet';
        _snippetError = state == 'ready' ? null : _lockedCaptureMessage;
      });
      return;
    }
    if (panel == OverlayPanelChannel.panelScreen) {
      // Reached either from this panel's own button (via consent) or as the
      // launch panel of a cold engine. Either way it is the chat sheet, with
      // a capture starting immediately.
      setState(() {
        _panel = 'chat';
        _looking = false;
        _lookError = null;
      });
      await _lookAtScreen();
      return;
    }
    if (panel == OverlayPanelChannel.panelVoice) {
      // The chat panel, already listening. A fresh token per request so a
      // second Voice tap on a warm panel starts the mic again.
      setState(() {
        _panel = 'chat';
        _looking = false;
        _voiceRequest++;
      });
      return;
    }
    setState(() {
      _panel = panel;
      _looking = false;
    });
  }

  /// Grabs the whole screen behind the overlay, then moves to the compose
  /// step so the user can say what it is for.
  ///
  /// Consent is per capture - the session is released after every frame - so
  /// the common path here is: ask, get sent back to this panel by the
  /// service, and capture on the way in.
  Future<void> _lookAtScreen() async {
    if (_looking) return;
    setState(() {
      _looking = true;
      _lookError = null;
    });
    var reopening = false;
    try {
      if (await _channel.captureState() != 'ready') {
        if (_isLockScreen) {
          // No consent dialog over the keyguard; the session has to have
          // been started while unlocked.
          if (mounted) setState(() => _lookError = _lockedCaptureMessage);
          return;
        }
        reopening = true;
        await _channel.requestCaptureConsent(
            then: OverlayPanelChannel.panelScreen);
        return;
      }
      final frame = await _channel.captureCurrentFrame();
      if (!mounted) return;
      if (frame == null) {
        setState(() => _lookError =
            'Could not grab the screen. Try again, or use Snippet on the '
            'bubble.');
        return;
      }
      setState(() {
        _panel = 'compose';
        _pendingCapture = frame.png;
        _pendingIsFullScreen = true;
      });
    } on CaptureFailure catch (e) {
      if (mounted) setState(() => _lookError = e.userMessage);
    } finally {
      // Left true while the consent dialog is up so the button stays busy;
      // _showPanel clears it when the service brings this panel back.
      if (mounted && !reopening) setState(() => _looking = false);
    }
  }

  void _onCaptureLost() {
    if (_panel == 'snippet' && !_snippetCapturing) {
      setState(() {
        _snippetError = 'Screen capture permission ended. Close and try again.';
      });
    }
  }

  Future<void> _close() async {
    await _channel.setFocusable(false);
    await _channel.closePanel();
  }

  Future<void> _openInApp() async {
    await _channel.setFocusable(false);
    await _channel.openMainApp(route: '/');
  }

  /// Crop done - drop to the bottom sheet and let the user say what the
  /// snippet is for. Nothing is sent to the model until [_sendPendingCapture].
  Future<void> _onCropConfirmed(Uint8List croppedPng) async {
    await _channel.setWindowMode('panel');
    _grownForKeyboard = false;
    if (!mounted) return;
    setState(() {
      _panel = 'compose';
      _pendingCapture = croppedPng;
      _pendingIsFullScreen = false;
      _snippetError = null;
    });
  }

  void _sendPendingCapture(String instruction) {
    final png = _pendingCapture;
    if (png == null) return;
    final fullScreen = _pendingIsFullScreen;
    setState(() {
      _panel = 'chat';
      _pendingCapture = null;
    });
    // Fire the analysis turn; the chat panel streams the response.
    ref.read(overlayChatControllerProvider.notifier).sendSnippet(
          png,
          instruction: instruction,
          fullScreen: fullScreen,
        );
  }

  /// Capture again. Both kinds are one-shot - the session is released after
  /// every frame - so this needs fresh consent, and the service reopens the
  /// right panel once it is granted.
  Future<void> _retakeCapture() async {
    final fullScreen = _pendingIsFullScreen;
    setState(() => _pendingCapture = null);
    if (fullScreen) {
      await _lookAtScreen();
      return;
    }
    await _retrySnippet();
  }

  Future<void> _discardCapture() async {
    setState(() => _pendingCapture = null);
    await _close();
  }

  Future<void> _retrySnippet() async {
    if (_isLockScreen) {
      // Consent cannot be asked for here; the selector stays up with the
      // reason, and Close is the way out.
      setState(() {
        _panel = 'snippet';
        _snippetError = _lockedCaptureMessage;
      });
      return;
    }
    await _channel
        .requestCaptureConsent(then: OverlayPanelChannel.panelSnippet);
    await _close();
  }

  @override
  Widget build(BuildContext context) {
    if (_panel == 'snippet') return _buildSnippet();
    final pending = _pendingCapture;
    final sheet = _PanelChrome(
      onOpenInApp: _openInApp,
      onClose: _close,
      locked: _isLockScreen,
      child: switch (_panel) {
        'task' => QuickTaskPanel(onDone: _close),
        'compose' when pending != null => CaptureComposePanel(
            png: pending,
            fullScreen: _pendingIsFullScreen,
            onSend: _sendPendingCapture,
            onRetake: _retakeCapture,
            onCancel: _discardCapture,
          ),
        _ => OverlayChatPanel(
            onLookAtScreen: _lookAtScreen,
            looking: _looking,
            lookError: _lookError,
            voiceRequest: _voiceRequest,
            onVoiceConsumed: () => _voiceRequest = 0,
            locked: _isLockScreen,
          ),
      },
    );
    if (!_isLockScreen) {
      return Material(type: MaterialType.transparency, child: sheet);
    }
    // The lock-screen host is a full-screen activity window, so the sheet
    // is laid out here: bottom 62% like the service's panel window, grown to
    // the full height while the keyboard is up (the same growth the service
    // applies natively). Tapping the see-through area above it closes.
    final size = MediaQuery.sizeOf(context);
    final keyboard = MediaQuery.viewInsetsOf(context).bottom > 0;
    final height = keyboard ? size.height : size.height * 0.62;
    return Material(
      type: MaterialType.transparency,
      child: Column(
        children: [
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _close,
              child: const SizedBox.expand(),
            ),
          ),
          SizedBox(height: height, child: sheet),
        ],
      ),
    );
  }

  Widget _buildSnippet() {
    return Material(
      type: MaterialType.transparency,
      child: SnippetSelectionScreen(
        errorText: _snippetError,
        onCancel: _close,
        onRetryPermission: _retrySnippet,
        onSnap: _onSnippetSelection,
      ),
    );
  }

  Future<void> _onSnippetSelection(Rect selection, Size panelSize) async {
    setState(() {
      _snippetCapturing = true;
      _snippetError = null;
    });
    try {
      final frame = await _channel.captureCurrentFrame();
      if (frame == null) {
        if (mounted) {
          setState(() => _snippetError = 'Snippet failed. Try again.');
        }
        return;
      }
      final cropped = await _cropFrame(frame, selection, panelSize);
      if (cropped == null) {
        if (mounted) {
          setState(() => _snippetError = 'Select a larger area.');
        }
        return;
      }
      await _onCropConfirmed(cropped);
    } on CaptureFailure catch (e) {
      if (mounted) setState(() => _snippetError = e.userMessage);
    } finally {
      if (mounted) setState(() => _snippetCapturing = false);
    }
  }

  /// Cuts [selection] - in the selector's own logical coordinates, [panelSize]
  /// being the selector's size - out of a captured frame.
  ///
  /// The frame covers the whole display while the selector window may not, so
  /// the selection-to-pixel mapping belongs to the frame (which carries the
  /// geometry native measured) rather than being guessed from sizes here.
  Future<Uint8List?> _cropFrame(
    CapturedFrame frame,
    Rect selection,
    Size panelSize,
  ) async {
    if (panelSize.width <= 0 || panelSize.height <= 0) return null;
    final codec = await ui.instantiateImageCodec(frame.png);
    final decoded = await codec.getNextFrame();
    final image = decoded.image;
    try {
      final source = frame.mapSelectionToImage(
        selection,
        panelSize,
        imageSize: Size(image.width.toDouble(), image.height.toDouble()),
      );
      if (source.width < 8 || source.height < 8) return null;

      var outWidth = source.width.round();
      var outHeight = source.height.round();
      final longEdge = math.max(outWidth, outHeight);
      if (longEdge > _maxLongEdge) {
        final shrink = _maxLongEdge / longEdge;
        outWidth = (outWidth * shrink).round();
        outHeight = (outHeight * shrink).round();
      }

      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawImageRect(
        image,
        source,
        Rect.fromLTWH(0, 0, outWidth.toDouble(), outHeight.toDouble()),
        Paint()..filterQuality = FilterQuality.high,
      );
      final output = await recorder.endRecording().toImage(outWidth, outHeight);
      try {
        final data = await output.toByteData(format: ui.ImageByteFormat.png);
        return data?.buffer.asUint8List();
      } finally {
        output.dispose();
      }
    } finally {
      image.dispose();
    }
  }
}

/// Rounded dark sheet with the Exa header (orb, title, open-in-app, close)
/// framing the chat and task panels.
class _PanelChrome extends StatelessWidget {
  const _PanelChrome({
    required this.child,
    required this.onOpenInApp,
    required this.onClose,
    this.locked = false,
  });

  final Widget child;
  final VoidCallback onOpenInApp;
  final VoidCallback onClose;

  /// Hosted on the lock screen: a lock in the header says so, because the
  /// restriction it stands for (no sends, no deletes) is otherwise invisible
  /// until something is refused.
  final bool locked;

  @override
  Widget build(BuildContext context) {
    return Container(
      // Keep the content clear of the keyboard. Nothing else consumes
      // viewInsets here - there is no Scaffold in the overlay engine - so
      // without this the text field at the bottom sits underneath the IME.
      padding:
          EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      decoration: const BoxDecoration(
        color: ExaColors.bg,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        border: Border(
          top: BorderSide(color: ExaColors.outline),
          left: BorderSide(color: ExaColors.outline),
          right: BorderSide(color: ExaColors.outline),
        ),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 4, 4),
            child: Row(
              children: [
                Container(
                  width: 12,
                  height: 12,
                  decoration: const BoxDecoration(
                    gradient: ExaColors.accentGradient,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
                Text('Exa', style: Theme.of(context).textTheme.titleMedium),
                if (locked) ...[
                  const SizedBox(width: 8),
                  const Tooltip(
                    message: 'Phone locked: Exa can read and note things '
                        'down, but will not send, call or delete until you '
                        'unlock.',
                    child: Icon(Icons.lock_outline,
                        size: 16, color: ExaColors.textSecondary),
                  ),
                ],
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.open_in_new, size: 20),
                  tooltip: locked ? 'Unlock and open in app' : 'Open in app',
                  onPressed: onOpenInApp,
                ),
                IconButton(
                  icon: const Icon(Icons.close, size: 20),
                  tooltip: 'Close',
                  onPressed: onClose,
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(child: child),
        ],
      ),
    );
  }
}
