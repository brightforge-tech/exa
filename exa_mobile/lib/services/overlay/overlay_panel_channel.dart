import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// A full-screen frame grabbed by the native capture session (already
/// downscaled native-side).
class CapturedFrame {
  const CapturedFrame({
    required this.png,
    required this.width,
    required this.height,
    this.screenWidth = 0,
    this.screenHeight = 0,
    this.panelLeft = 0,
    this.panelTop = 0,
    this.panelWidth = 0,
    this.panelHeight = 0,
  });

  final Uint8List png;
  final int width;
  final int height;

  /// Size of the display this frame covers, in physical pixels, before the
  /// native downscale to [width]x[height].
  final int screenWidth;
  final int screenHeight;

  /// The overlay window's rect on that display, in physical pixels. The
  /// window is not always the whole screen - a display cutout, the status bar
  /// or gesture insets can inset it - so this is what makes a selection drawn
  /// in the window land on the right pixels of the frame.
  final int panelLeft;
  final int panelTop;
  final int panelWidth;
  final int panelHeight;

  /// Whether native reported enough geometry for the exact mapping.
  bool get hasGeometry =>
      screenWidth > 0 && screenHeight > 0 && panelWidth > 0 && panelHeight > 0;

  /// Maps [selection], expressed in the overlay window's own logical
  /// coordinates ([panelSize] being that window's logical size), onto pixel
  /// coordinates in this frame.
  ///
  /// Scaling the selection by `imageSize / panelSize` alone - the obvious
  /// mapping - silently assumes the window covers the display exactly. When it
  /// does not, every crop comes out shifted and slightly the wrong scale.
  /// [panelLeft]/[panelTop] and the panel's pixel size remove that assumption;
  /// without them (an older service, or a window not laid out yet) the old
  /// assumption is still the best guess available.
  /// [imageSize] defaults to the size native reported; the cropper passes the
  /// decoded PNG's real size so the two can never drift.
  Rect mapSelectionToImage(Rect selection, Size panelSize, {Size? imageSize}) {
    if (panelSize.width <= 0 || panelSize.height <= 0) return Rect.zero;
    final imageWidth = imageSize?.width ?? width.toDouble();
    final imageHeight = imageSize?.height ?? height.toDouble();

    final double scaleX;
    final double scaleY;
    final double originX;
    final double originY;
    if (hasGeometry) {
      // logical window units -> display pixels -> frame pixels
      scaleX = panelWidth / panelSize.width * (imageWidth / screenWidth);
      scaleY = panelHeight / panelSize.height * (imageHeight / screenHeight);
      originX = panelLeft * imageWidth / screenWidth;
      originY = panelTop * imageHeight / screenHeight;
    } else {
      scaleX = imageWidth / panelSize.width;
      scaleY = imageHeight / panelSize.height;
      originX = 0;
      originY = 0;
    }

    return Rect.fromLTRB(
      (originX + selection.left * scaleX).clamp(0, imageWidth),
      (originY + selection.top * scaleY).clamp(0, imageHeight),
      (originX + selection.right * scaleX).clamp(0, imageWidth),
      (originY + selection.bottom * scaleY).clamp(0, imageHeight),
    );
  }
}

/// Why a frame grab failed, as reported by the service.
///
/// The code is carried into what the user sees on purpose: "Snippet failed,
/// try again" makes a reproducible failure look random, and these three have
/// nothing to do with each other - a dead projection, a screen that produced
/// no frame, and an encode error need three different fixes.
class CaptureFailure implements Exception {
  const CaptureFailure(this.code, [this.detail]);

  /// `capture_inactive`, `capture_timeout` or `capture_failed`.
  final String code;
  final String? detail;

  String get userMessage => switch (code) {
        'capture_inactive' =>
          'Screen capture permission ended. Close and try again.',
        'capture_timeout' => 'The screen sent no frame in time. Try again.',
        _ => 'Snippet failed. Try again.',
      };

  @override
  String toString() => 'CaptureFailure($code)';
}

/// Overlay-engine bridge to `ExaOverlayService`. This channel only exists in
/// the overlay FlutterEngine (entry point `overlayMain`); the main app talks
/// to the service via `OverlayController` instead.
class OverlayPanelChannel {
  static const _channel = MethodChannel('com.brightforge.exa/overlay_panel');

  /// Registers the Kotlin->Dart handlers. Call once from the overlay shell.
  void listen({
    required void Function(String panel) onPanelRequested,
    required void Function() onCaptureLost,
  }) {
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'panelRequested':
          final args = (call.arguments as Map?)?.cast<Object?, Object?>();
          onPanelRequested(args?['panel'] as String? ?? 'chat');
        case 'captureLost':
          onCaptureLost();
      }
      return null;
    });
  }

  /// Which panel the fan menu asked for when this engine started, and who is
  /// hosting it: [hostOverlay] (the bubble service's window) or
  /// [hostLockScreen] (`LockScreenActivity`, over the keyguard).
  Future<({String panel, String captureState, String host})>
      getLaunchPanel() async {
    final result = await _channel.invokeMapMethod<String, Object?>(
      'getLaunchPanel',
    );
    return (
      panel: result?['panel'] as String? ?? 'chat',
      captureState: result?['captureState'] as String? ?? 'inactive',
      host: result?['host'] as String? ?? hostOverlay,
    );
  }

  /// `ready` when a consented capture session is live right now, `inactive`
  /// otherwise. Worth asking before every capture: the session is released
  /// after each frame, so a previous grant says nothing about this one.
  Future<String> captureState() async {
    try {
      return await _channel.invokeMethod<String>('captureState') ?? 'inactive';
    } on PlatformException {
      return 'inactive';
    }
  }

  /// Requests one frame from the service. The native side hides Exa's overlay
  /// windows before capturing, then releases the projection session.
  ///
  /// Throws [CaptureFailure] when the service could not produce a frame.
  Future<CapturedFrame?> captureCurrentFrame() async {
    try {
      final result = await _channel.invokeMapMethod<String, Object?>(
        'captureFrame',
      );
      final png = result?['png'] as Uint8List?;
      if (png == null) return null;
      return CapturedFrame(
        png: png,
        width: result?['width'] as int? ?? 0,
        height: result?['height'] as int? ?? 0,
        screenWidth: result?['screenWidth'] as int? ?? 0,
        screenHeight: result?['screenHeight'] as int? ?? 0,
        panelLeft: result?['panelLeft'] as int? ?? 0,
        panelTop: result?['panelTop'] as int? ?? 0,
        panelWidth: result?['panelWidth'] as int? ?? 0,
        panelHeight: result?['panelHeight'] as int? ?? 0,
      );
    } on PlatformException catch (e) {
      throw CaptureFailure(e.code, e.message);
    }
  }

  /// `panel` (the bottom sheet) or `fullscreen` (the same sheet grown to full
  /// height for an open keyboard). The snippet selector's edge-to-edge window
  /// is chosen natively when that panel opens, not requested from here.
  Future<void> setWindowMode(String mode) =>
      _channel.invokeMethod('setWindowMode', {'mode': mode});

  /// Overlay windows are non-focusable by default (touches pass through
  /// outside them, no keyboard). Flip this on while a text field is focused
  /// so the IME can attach, and off again when it blurs.
  Future<void> setFocusable(bool focusable) =>
      _channel.invokeMethod('setFocusable', {'focusable': focusable});

  /// Collapses back to the bubble. The engine stays warm for a few minutes.
  Future<void> closePanel() => _channel.invokeMethod('closePanel');

  /// Re-runs the screen-capture consent flow (a session is released after
  /// every frame, so this is the normal path, not just error recovery).
  ///
  /// [then] names the panel the service reopens once the user approves -
  /// `snippet` for the region selector, `screen` for the chat sheet's
  /// look-at-my-screen grab - so one tap still ends in a capture. Null
  /// leaves the user at the bubble.
  Future<void> requestCaptureConsent({String? then}) async {
    try {
      await _channel.invokeMethod('requestCaptureConsent', {'then': then});
    } on PlatformException {
      // A host that cannot show the consent dialog (the lock screen) says so
      // through captureState; nothing to do here.
    }
  }

  /// Panel ids shared with the native service.
  static const panelChat = 'chat';
  static const panelSnippet = 'snippet';
  static const panelScreen = 'screen';

  /// The chat panel, opened already listening (the fan menu's Voice action
  /// and the lock-screen Voice button).
  static const panelVoice = 'voice';

  /// Hosts, as reported by [getLaunchPanel].
  static const hostOverlay = 'overlay';
  static const hostLockScreen = 'lock_screen';

  /// Hands off to the full app (optionally deep-linking [route]) and closes
  /// this panel.
  Future<void> openMainApp({String? route}) =>
      _channel.invokeMethod('openMainApp', {'route': route});
}

final overlayPanelChannelProvider = Provider<OverlayPanelChannel>(
  (ref) => OverlayPanelChannel(),
);
