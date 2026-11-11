import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// One chat app the device has installed and Exa knows how to read.
class SupportedChatApp {
  const SupportedChatApp({
    required this.packageName,
    required this.channel,
    required this.label,
    required this.allowed,
  });

  final String packageName;
  final String channel;
  final String label;
  final bool allowed;

  static SupportedChatApp fromMap(Map<Object?, Object?> map) => SupportedChatApp(
        packageName: map['package'] as String? ?? '',
        channel: map['channel'] as String? ?? '',
        label: map['label'] as String? ?? '',
        allowed: map['allowed'] == true,
      );
}

/// One recorded attempt by the notification listener to open a chat app's
/// message media - see `NotificationMedia.kt` on the Kotlin side.
///
/// The field names are the shared wire contract with `mediaProbeReport` in
/// MessagingChannel.kt and `KEY_MEDIA_PROBE_REPORT` in ChatPackages.kt
/// (pinned by media_probe_report_test.dart). Note what no field is: a URI.
/// Content URIs carry signed, sometimes expiring tokens, so the probe only
/// ever reports *about* the URI - its scheme, never the URI itself.
class MediaProbeRecord {
  const MediaProbeRecord({
    required this.packageName,
    required this.origin,
    this.scheme,
    this.mimeType,
    required this.bytesRead,
    required this.failure,
    required this.at,
    this.deviceRelease = '',
    this.deviceManufacturer = '',
    this.deviceModel = '',
    this.deviceApi = 0,
  });

  /// The chat app whose notification carried the media.
  final String packageName;

  /// `'message_attachment'` (the message's own data URI) or
  /// `'notification_picture'` (`Notification.EXTRA_PICTURE`, usually the
  /// conversation avatar - probed for the record, never a message's media).
  final String origin;

  /// The URI's scheme - normally `content`, or null when there was no URI.
  final String? scheme;

  /// The mime type the notification declared, when it declared one.
  final String? mimeType;

  /// Bytes actually read before the probe's cap; 0 for every failure.
  final int bytesRead;

  /// One of `ok | security | not_found | empty_stream | null_uri |
  /// unsupported_scheme` - the enum in NotificationMedia.kt, lowercased.
  final String failure;

  /// When the probe ran.
  final int at;

  /// The device the matrix was probed on, repeated on every row: URI
  /// readability varies per Android release and OEM, so the matrix without
  /// its tested surface is a number without units.
  final String deviceRelease;
  final String deviceManufacturer;
  final String deviceModel;
  final int deviceApi;

  /// Human naming of the tested surface, for the Settings tile's header.
  String get deviceLabel {
    final model = deviceModel.trim();
    final maker = deviceManufacturer.trim();
    final who = [
      if (maker.isNotEmpty &&
          !model.toLowerCase().contains(maker.toLowerCase()))
        maker,
      if (model.isNotEmpty) model,
    ].join(' ');
    final parts = <String>[
      if (deviceRelease.trim().isNotEmpty) 'Android ${deviceRelease.trim()}',
      if (who.isNotEmpty) who,
      if (deviceApi > 0) 'API $deviceApi',
    ];
    return parts.isEmpty ? 'an unreported device' : parts.join(' ');
  }

  static MediaProbeRecord fromMap(Map<Object?, Object?> map) =>
      MediaProbeRecord(
        packageName: map['package'] as String? ?? '',
        origin: map['origin'] as String? ?? '',
        scheme: map['scheme'] as String?,
        mimeType: map['mime_type'] as String?,
        bytesRead: (map['bytes'] as num?)?.toInt() ?? 0,
        failure: map['failure'] as String? ?? '',
        at: (map['at'] as num?)?.toInt() ?? 0,
        deviceRelease: map['device_release'] as String? ?? '',
        deviceManufacturer: map['device_manufacturer'] as String? ?? '',
        deviceModel: map['device_model'] as String? ?? '',
        deviceApi: (map['device_api'] as num?)?.toInt() ?? 0,
      );
}

/// Something the user shared or selected and handed to Exa.
class SharedItem {
  const SharedItem({
    required this.action,
    this.text,
    this.subject,
    this.fileName,
    this.fileText,
    this.sourcePackage,
  });

  /// `send` (shared into Exa) or `process_text` (selected in another app).
  final String action;
  final String? text;

  /// Present when a mail client shared a message: its subject line.
  final String? subject;

  /// Set when a file came with it — a WhatsApp chat export, typically.
  final String? fileName;
  final String? fileText;

  /// Who shared it, when the OS was willing to say.
  final String? sourcePackage;

  bool get hasFile => (fileText ?? '').trim().isNotEmpty;
  bool get hasText => (text ?? '').trim().isNotEmpty;

  static SharedItem? fromMap(Map<Object?, Object?>? map) {
    if (map == null) return null;
    return SharedItem(
      action: map['action'] as String? ?? 'send',
      text: map['text'] as String?,
      subject: map['subject'] as String?,
      fileName: map['file_name'] as String?,
      fileText: map['file_text'] as String?,
      sourcePackage: map['source_package'] as String?,
    );
  }
}

/// Main-engine bridge to chat capture (`MessagingChannel` on the Kotlin side).
///
/// Everything here needs either an Activity or the live notification service,
/// so none of it is available in a background isolate — which is why the
/// *drain* deliberately does not go through this class (see
/// `MessageSpoolReader`), and why [sendReply] being main-engine-only lines up
/// with replying being an interactive-only capability.
///
/// Every method degrades to a safe answer off-Android rather than throwing:
/// the settings screen and the tests both run where this channel has no
/// implementation.
class MessagingBridge {
  const MessagingBridge();

  static const _channel = MethodChannel('com.brightforge.exa/messaging');

  Future<T?> _call<T>(String method, [Map<String, Object?>? args]) async {
    try {
      return await _channel.invokeMethod<T>(method, args);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  /// Whether the device-wide notification-access grant is in place. Cannot be
  /// requested programmatically — the user has to make it in Settings.
  Future<bool> hasNotificationAccess() async =>
      await _call<bool>('hasNotificationAccess') ?? false;

  Future<void> openNotificationAccessSettings() =>
      _call<void>('openNotificationAccessSettings');

  /// Whether the system has actually bound the listener. Distinct from the
  /// grant: a fresh grant does not always bind immediately, and reporting
  /// "on" while nothing is listening is the confusing state to avoid.
  Future<bool> isListenerConnected() async =>
      await _call<bool>('isListenerConnected') ?? false;

  Future<void> rebindListener() => _call<void>('rebindListener');

  Future<bool> isCaptureEnabled() async =>
      await _call<bool>('isCaptureEnabled') ?? false;

  Future<bool> setCaptureEnabled(bool enabled) async =>
      await _call<bool>('setCaptureEnabled', {'enabled': enabled}) ?? false;

  Future<List<SupportedChatApp>> supportedApps() async {
    final raw = await _call<List<Object?>>('supportedApps');
    if (raw == null) return const [];
    return raw
        .whereType<Map<Object?, Object?>>()
        .map(SupportedChatApp.fromMap)
        .toList();
  }

  Future<List<String>> allowedPackages() async {
    final raw = await _call<List<Object?>>('allowedPackages');
    return raw?.whereType<String>().toList() ?? const [];
  }

  Future<List<String>> setAllowedPackages(List<String> packages) async {
    final raw =
        await _call<List<Object?>>('setAllowedPackages', {'packages': packages});
    return raw?.whereType<String>().toList() ?? const [];
  }

  /// Absolute path of the notification spool. Authoritative — see
  /// `MessageSpoolReader` for why it is asked for rather than derived.
  Future<String?> spoolPath() => _call<String>('spoolPath');

  Future<int> spoolPendingCount() async =>
      await _call<int>('spoolPendingCount') ?? 0;

  /// Messages the native spool discarded because it hit its size cap.
  Future<int> droppedCount() async => await _call<int>('droppedCount') ?? 0;

  Future<void> clearDroppedCount() => _call<void>('clearDroppedCount');

  Future<void> clearSpool() => _call<void>('clearSpool');

  /// The persisted media-probe matrix, as flat per-package rows.
  ///
  /// Read-only by design: the records are written by the notification
  /// listener in another process role, and Dart must not be able to forge
  /// or clear them from here. Empty (not null) when nothing has been
  /// probed yet or the channel has no implementation - the Settings tile
  /// hides itself on empty.
  Future<List<MediaProbeRecord>> mediaProbeReport() async {
    final raw = await _call<List<Object?>>('mediaProbeReport');
    if (raw == null) return const [];
    return raw
        .whereType<Map<Object?, Object?>>()
        .map(MediaProbeRecord.fromMap)
        .toList();
  }

  Future<bool> canReply({
    required String channel,
    required String conversationId,
  }) async =>
      await _call<bool>('canReply', {
        'channel': channel,
        'conversation_id': conversationId,
      }) ??
      false;

  /// Delivers [text] through the chat app's own notification reply action.
  /// Returns null on success, or the reason it could not be sent.
  ///
  /// Note the inverted convention (null = good): a reply that silently fails
  /// is the outcome worth designing against, so the success case is the one
  /// with nothing to say.
  Future<String?> sendReply({
    required String channel,
    required String conversationId,
    required String text,
  }) async {
    try {
      return await _channel.invokeMethod<String>('sendReply', {
        'channel': channel,
        'conversation_id': conversationId,
        'text': text,
      });
    } on MissingPluginException {
      return 'Replying is only available on the device.';
    } on PlatformException catch (e) {
      return e.message ?? 'The reply could not be sent.';
    }
  }

  /// Takes whatever the user last shared into Exa, clearing it.
  Future<SharedItem?> consumeSharedItem() async {
    final raw = await _call<Map<Object?, Object?>>('consumeSharedItem');
    return SharedItem.fromMap(raw);
  }
}

final messagingBridgeProvider =
    Provider<MessagingBridge>((ref) => const MessagingBridge());
