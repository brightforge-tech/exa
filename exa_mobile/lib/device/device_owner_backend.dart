import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'device_bridge.dart';
import 'device_control.dart';

/// [DeviceControl] on stock Android, where Exa's standing is Device Owner
/// plus a few one-time adb grants. Talks to `ExaDevicePlugin.kt` through
/// [DeviceBridge].
///
/// The app's own component names are decided here, not in the plugin: the
/// plugin module cannot see the app's classes, and the notification listener
/// lives in the app (it is also the chat-capture listener).
class DeviceOwnerBackend implements DeviceControl {
  DeviceOwnerBackend(this._bridge);

  final DeviceBridge _bridge;

  /// Exa's package; the component names below are relative to it.
  static const packageName = 'com.brightforge.exa';

  /// The chat-capture listener in the app module; in v3 it also serves the
  /// all-apps notification tools.
  static const notificationListenerClass =
      'com.brightforge.exa.messaging.ExaNotificationListener';

  /// The accessibility service in the device plugin (added in the screen
  /// stage; reported as absent until then).
  static const accessibilityServiceClass =
      'com.brightforge.exa.device.ExaAccessibilityService';

  static String component(String className) => '$packageName/$className';

  late final AdminControl _admin = _DeviceOwnerAdmin(_bridge);
  late final ScreenControl _screen = _DeviceOwnerScreen(_bridge);
  late final PushControl _push = _DeviceOwnerPush(_bridge);

  @override
  AdminControl get admin => _admin;

  @override
  ScreenControl get screen => _screen;

  @override
  PushControl get push => _push;

  @override
  Future<DeviceCapabilities> capabilities() async =>
      DeviceCapabilities.fromStatus(await _admin.status());
}

class _DeviceOwnerPush implements PushControl {
  _DeviceOwnerPush(this._bridge);

  final DeviceBridge _bridge;

  @override
  Future<PushHealthStatus> status() async =>
      PushHealthStatus.fromMap(await _bridge.callMap('push.status'));

  @override
  Future<DeviceActionResult> restartPlayServices() async =>
      DeviceActionResult.fromMap(
          await _bridge.callMap('push.restartPlayServices'));

  @override
  Future<DeviceActionResult> reboot() async =>
      DeviceActionResult.fromMap(await _bridge.callMap('push.reboot'));
}

class _DeviceOwnerScreen implements ScreenControl {
  _DeviceOwnerScreen(this._bridge);

  final DeviceBridge _bridge;

  @override
  Future<ScreenSnapshot> read() async =>
      ScreenSnapshot.fromMap(await _bridge.callMap('screen.read'));

  @override
  Future<DeviceActionResult> tap({int? id, int? x, int? y}) async =>
      DeviceActionResult.fromMap(await _bridge.callMap('screen.tap', {
        'id': ?id,
        'x': ?x,
        'y': ?y,
      }));

  @override
  Future<DeviceActionResult> swipe({
    String direction = 'up',
    int? x1,
    int? y1,
    int? x2,
    int? y2,
  }) async =>
      DeviceActionResult.fromMap(await _bridge.callMap('screen.swipe', {
        'direction': direction,
        'x1': ?x1,
        'y1': ?y1,
        'x2': ?x2,
        'y2': ?y2,
      }));

  @override
  Future<DeviceActionResult> setText({
    required int id,
    required String text,
  }) async =>
      DeviceActionResult.fromMap(await _bridge
          .callMap('screen.setText', {'id': id, 'text': text}));

  @override
  Future<DeviceActionResult> globalAction(String action) async =>
      DeviceActionResult.fromMap(
          await _bridge.callMap('screen.global', {'action': action}));

  @override
  Future<DeviceActionResult> openApp(String packageName) async =>
      DeviceActionResult.fromMap(
          await _bridge.callMap('screen.openApp', {'package': packageName}));

  @override
  Future<ScreenshotResult> screenshot() async {
    final m = await _bridge.callMap('screen.screenshot');
    if (m == null || m['ok'] != true) {
      return ScreenshotResult(
        error: m?['error'] as String? ?? ScreenshotResult.unavailable.error,
      );
    }
    final data = m['bytes'];
    return ScreenshotResult(
      ok: true,
      bytes: data is List<int>
          ? data
          : (data as List?)?.map((e) => (e as num).toInt()).toList(),
      mediaType: m['media_type'] as String? ?? 'image/png',
      width: (m['width'] as num?)?.toInt() ?? 0,
      height: (m['height'] as num?)?.toInt() ?? 0,
    );
  }
}

class _DeviceOwnerAdmin implements AdminControl {
  _DeviceOwnerAdmin(this._bridge);

  final DeviceBridge _bridge;

  @override
  Future<DeviceAdminStatus> status() async =>
      DeviceAdminStatus.fromMap(await _bridge.callMap('admin.status', {
        'listener': DeviceOwnerBackend.notificationListenerClass,
        'accessibility': DeviceOwnerBackend.accessibilityServiceClass,
      }));

  @override
  Future<Map<String, bool>> grantSelfRuntimePermissions() async {
    final map = await _bridge.callMap('admin.grantSelfRuntime');
    final granted = map?['granted'];
    return {
      if (granted is Map)
        for (final entry in granted.entries)
          if (entry.key is String) entry.key as String: entry.value == true,
    };
  }

  @override
  Future<DeviceActionResult> enableNotificationListener() async =>
      DeviceActionResult.fromMap(
          await _bridge.callMap('admin.enableNotificationListener', {
        'component': DeviceOwnerBackend.component(
            DeviceOwnerBackend.notificationListenerClass),
      }));

  @override
  Future<DeviceActionResult> enableAccessibility() async =>
      DeviceActionResult.fromMap(
          await _bridge.callMap('admin.enableAccessibility', {
        'component': DeviceOwnerBackend.component(
            DeviceOwnerBackend.accessibilityServiceClass),
      }));

  @override
  Future<DeviceActionResult> openSystemSettings(String screen) async =>
      DeviceActionResult.fromMap(
          await _bridge.callMap('admin.openSettings', {'screen': screen}));

  @override
  Future<DeviceActionResult> requestBatteryExemption() async =>
      DeviceActionResult.fromMap(
          await _bridge.callMap('admin.requestBatteryExemption'));

  @override
  Future<DeviceActionResult> clearDeviceOwner() async =>
      DeviceActionResult.fromMap(
          await _bridge.callMap('admin.clearDeviceOwner'));
}

final deviceBridgeProvider =
    Provider<DeviceBridge>((ref) => const DeviceBridge());

/// The device backend the app runs against. Stock Android now; the AOSP
/// platform backend swaps in here when that build exists.
final deviceControlProvider = Provider<DeviceControl>(
    (ref) => DeviceOwnerBackend(ref.watch(deviceBridgeProvider)));
