import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Main-engine bridge to the native Exa bubble
/// (`ExaOverlayService` / `MainActivity` on the Kotlin side).
///
/// The bubble itself is pure native UI; this controller only enables /
/// disables it, tracks screen-capture readiness, and receives the deep-link
/// route when an overlay panel hands off to the full app.
class OverlayController {
  static const _channel = MethodChannel('com.brightforge.exa/overlay');
  static const _events = EventChannel('com.brightforge.exa/overlay_events');

  static const eventBubbleEnabled = 'bubbleEnabled';
  static const eventBubbleDisabled = 'bubbleDisabled';
  static const eventCaptureReady = 'captureReady';
  static const eventCaptureLost = 'captureLost';

  Future<bool> hasOverlayPermission() async =>
      await _channel.invokeMethod<bool>('hasOverlayPermission') ?? false;

  /// Opens the system "Display over other apps" page when not yet granted;
  /// resolves with the final grant state once the user returns.
  Future<bool> requestOverlayPermission() async =>
      await _channel.invokeMethod<bool>('requestOverlayPermission') ?? false;

  Future<bool> isBubbleEnabled() async =>
      await _channel.invokeMethod<bool>('isBubbleEnabled') ?? false;

  /// Starts the bubble foreground service. Returns false when the overlay
  /// permission is missing.
  Future<bool> enableBubble() async =>
      await _channel.invokeMethod<bool>('enableBubble') ?? false;

  Future<void> disableBubble() => _channel.invokeMethod('disableBubble');

  /// `ready` when the persistent capture session is live, else `inactive`.
  Future<String> captureState() async =>
      await _channel.invokeMethod<String>('captureState') ?? 'inactive';

  /// Shows the system screen-capture consent dialog (bubble must be on).
  /// Resolution of the session arrives via [events] (`captureReady`).
  Future<bool> requestCaptureConsent() async {
    try {
      return await _channel.invokeMethod<bool>('requestCaptureConsent') ??
          false;
    } on PlatformException {
      return false;
    }
  }

  Future<void> resetBubblePosition() =>
      _channel.invokeMethod('resetBubblePosition');

  /// Whether the bubble notification carries Chat / Voice / Snippet actions
  /// that open Exa over the lock screen.
  Future<bool> isLockScreenEnabled() async =>
      await _channel.invokeMethod<bool>('isLockScreenEnabled') ?? false;

  Future<void> setLockScreenEnabled(bool enabled) =>
      _channel.invokeMethod('setLockScreenEnabled', {'enabled': enabled});

  /// Route requested by an overlay panel's "open in app" action, delivered
  /// via the launch intent. Null when there is nothing pending; consuming
  /// clears it.
  Future<String?> consumeLaunchRoute() =>
      _channel.invokeMethod<String>('consumeLaunchRoute');

  /// A feature to start on open - `voice`, `chat`, or `snippet` - set when Exa
  /// was launched from the bubble's Voice action or a lock-screen
  /// notification button. Null when there is nothing pending; consuming
  /// clears it.
  Future<String?> consumeLaunchAction() =>
      _channel.invokeMethod<String>('consumeLaunchAction');

  /// Opens one of the bubble's overlay panels (`chat`/`voice`/`snippet`)
  /// through the running bubble service - used for Snippet, which needs the
  /// overlay's screen capture rather than a screen in the app.
  Future<void> openOverlayPanel(String panel) =>
      _channel.invokeMethod('openOverlayPanel', {'panel': panel});

  /// Called when a launch action arrives at an app that is already running.
  /// Native pushes it because tapping a notification over a foreground Exa
  /// does not reliably produce a resume for the poll to hang off.
  void onLaunchActionPushed(void Function() onPushed) {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'launchActionPushed') onPushed();
      return null;
    });
  }

  /// Live bubble/capture state changes (see the event constants above).
  Stream<String> events() =>
      _events.receiveBroadcastStream().map((event) => event as String);
}

final overlayControllerProvider =
    Provider<OverlayController>((ref) => OverlayController());
