import 'package:flutter_gemma/flutter_gemma.dart';

/// One-time setup of flutter_gemma's model registry, run on first use of the
/// on-device provider rather than at app startup.
///
/// Deliberately NOT called from `main()`. `FlutterGemma.initialize()` reaches
/// into MediaPipe, which probes the device's native GPU/OpenCL delegates. On
/// hardware without a usable driver that probe can take the whole process
/// down - and a native crash is not something a Dart `try`/`catch` around the
/// call can intercept, so wrapping it there bought nothing. On-device AI is an
/// optional, experimental feature; it must not be able to stop the app
/// launching for someone who never turns it on.
///
/// Every entry point that touches `FlutterGemma` awaits [ensureInitialized]
/// first. It is idempotent, concurrent calls share one attempt, and a failed
/// attempt is not cached - the user can retry by trying again.
class OnDeviceRuntime {
  const OnDeviceRuntime._();

  static Future<void>? _pending;
  static bool _ready = false;

  /// Whether initialization has completed successfully at least once.
  static bool get isReady => _ready;

  static Future<void> ensureInitialized() {
    if (_ready) return Future.value();
    return _pending ??= _initialize();
  }

  static Future<void> _initialize() async {
    try {
      await FlutterGemma.initialize();
      _ready = true;
    } catch (_) {
      // Not cached as a permanent failure: a later attempt gets a fresh try.
      // Swallowed rather than rethrown so callers behave exactly as they did
      // when this ran (best-effort) at startup - the FlutterGemma call that
      // follows reports the real problem in terms the user can act on.
      _pending = null;
    }
  }
}
