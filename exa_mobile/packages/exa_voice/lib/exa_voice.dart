import 'dart:async';

import 'package:flutter/services.dart';

/// How a voice session was opened.
class VoiceLaunch {
  const VoiceLaunch({
    required this.mode,
    this.prompt,
    this.speak,
    this.followUpId,
  });

  /// [listen]: the user called Exa (side button, "Hey Exa").
  /// [followUp]: Exa has something to say first ([speak]) and something to
  /// talk through ([prompt]).
  final String mode;
  final String? prompt;
  final String? speak;
  final String? followUpId;

  static const listen = 'listen';
  static const followUp = 'follow_up';

  bool get isFollowUp => mode == followUp;

  static VoiceLaunch? fromMap(Object? raw) {
    if (raw is! Map) return null;
    return VoiceLaunch(
      mode: raw['mode'] as String? ?? listen,
      prompt: raw['prompt'] as String?,
      speak: raw['speak'] as String?,
      followUpId: raw['follow_up_id'] as String?,
    );
  }
}

/// Where the assistant role and the wake word stand.
class VoiceStatus {
  const VoiceStatus(this._raw);

  final Map<Object?, Object?> _raw;

  bool _flag(String key) => _raw[key] == true;

  bool get isAssistant => _flag('is_assistant');
  bool get wakeEnabled => _flag('wake_enabled');
  bool get wakeConfigured => _flag('wake_configured');
  bool get wakeRunning => _flag('wake_running');
  bool get wakeListening => _flag('wake_listening');
  bool get canFullScreen => _flag('can_full_screen');
  bool get canOpenFromBackground => _flag('can_open_from_background');
  bool get locked => _flag('locked');
  String? get wakeError => _raw['wake_error'] as String?;
  String get wakePhrase => _raw['wake_phrase'] as String? ?? 'Hey Exa';

  /// The spotter keywords stored for [wakePhrase]; null when the service
  /// still uses its built-in "Hey Exa".
  String? get wakeKeywords => _raw['wake_keywords'] as String?;

  /// How often the wake phrase has been heard, and when last.
  int get wakeDetections => (_raw['wake_detections'] as num?)?.toInt() ?? 0;
  DateTime? get wakeLastDetection {
    final ms = (_raw['wake_last_detection'] as num?)?.toInt() ?? 0;
    return ms <= 0 ? null : DateTime.fromMillisecondsSinceEpoch(ms);
  }

  /// The spotter's threshold: lower hears more readily.
  double get wakeThreshold =>
      (_raw['wake_threshold'] as num?)?.toDouble() ?? 0.15;

  static const unavailable = VoiceStatus({});
}

/// Dart side of `com.brightforge.exa/voice`. Every call is best-effort:
/// off Android (tests, desktop) it reports "unavailable" instead of
/// throwing, because a follow-up that cannot be voiced must never cost the
/// job that raised it.
class ExaVoice {
  const ExaVoice();

  static const _channel = MethodChannel('com.brightforge.exa/voice');

  static final _launches = StreamController<VoiceLaunch>.broadcast();
  static bool _listening = false;

  /// Launches that arrive while a session is already on screen.
  Stream<VoiceLaunch> get launches {
    if (!_listening) {
      _listening = true;
      _channel.setMethodCallHandler((call) async {
        if (call.method == 'launch') {
          final launch = VoiceLaunch.fromMap(call.arguments);
          if (launch != null) _launches.add(launch);
        }
        return null;
      });
    }
    return _launches.stream;
  }

  Future<T?> _call<T>(String method, [Map<String, Object?>? args]) async {
    try {
      return await _channel.invokeMethod<T>(method, args);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  Future<VoiceStatus> status() async {
    final raw = await _call<Map<Object?, Object?>>('status');
    return raw == null ? VoiceStatus.unavailable : VoiceStatus(raw);
  }

  Future<VoiceLaunch?> consumeLaunch() async =>
      VoiceLaunch.fromMap(await _call<Object?>('consumeLaunch'));

  Future<bool> isLocked() async => await _call<bool>('isLocked') ?? false;

  Future<void> finishSession() => _call<void>('finishSession');

  Future<bool> openSession({
    String mode = VoiceLaunch.listen,
    String? prompt,
    String? speak,
    String? followUpId,
  }) async =>
      await _call<bool>('openSession', {
        'mode': mode,
        'prompt': prompt,
        'speak': speak,
        'follow_up_id': followUpId,
      }) ??
      false;

  /// Posts a follow-up notification; [ring] also opens the voice session so
  /// Exa says it out loud. Returns how it went out: 'spoken',
  /// 'full_screen', 'notified' - or null off Android.
  Future<String?> postFollowUp({
    required int notificationId,
    required String title,
    required String body,
    required String prompt,
    String? speak,
    String? followUpId,
    bool ring = false,
  }) =>
      _call<String>('postFollowUp', {
        'notification_id': notificationId,
        'title': title,
        'body': body,
        'prompt': prompt,
        'speak': speak,
        'follow_up_id': followUpId,
        'ring': ring,
      });

  Future<void> cancelFollowUp(int notificationId) =>
      _call<void>('cancelFollowUp', {'notification_id': notificationId});

  /// Sets the wake phrase - [keywords] is its spotter form, from
  /// `WakePhrase` - and/or the detection [threshold].
  Future<VoiceStatus> configureWakeWord({
    String? phrase,
    String? keywords,
    double? threshold,
  }) async {
    final raw = await _call<Map<Object?, Object?>>('configureWakeWord', {
      'phrase': phrase,
      'keywords': keywords,
      'threshold': threshold,
    });
    return raw == null ? VoiceStatus.unavailable : VoiceStatus(raw);
  }

  Future<VoiceStatus> setWakeWordEnabled(bool enabled) async {
    final raw = await _call<Map<Object?, Object?>>(
        'setWakeWordEnabled', {'enabled': enabled});
    return raw == null ? VoiceStatus.unavailable : VoiceStatus(raw);
  }

  Future<void> ensureWakeWord() => _call<void>('ensureWakeWord');
  Future<void> pauseWakeWord() => _call<void>('pauseWakeWord');
  Future<void> resumeWakeWord() => _call<void>('resumeWakeWord');
  Future<void> openAssistantSettings() => _call<void>('openAssistantSettings');
  Future<void> openFullScreenSettings() =>
      _call<void>('openFullScreenSettings');
  Future<void> openOverlaySettings() => _call<void>('openOverlaySettings');
}
