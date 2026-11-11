import 'device_control.dart';

/// The AOSP backend: Exa as a platform-signed privileged app on our own
/// Android build, where the powers stock cannot give (other apps' data, a
/// persistent process, screenshots without accessibility) come from the
/// platform itself over an AIDL service.
///
/// Not built yet. This stub exists so the interface is exercised by two
/// implementations from day one and nothing in the tools grows a
/// stock-only assumption. See `docs/AOSP_BACKEND.md` for what it will need.
class PlatformBackend implements DeviceControl {
  const PlatformBackend();

  static const _notBuilt = DeviceActionResult(
    ok: false,
    error: 'The AOSP system-app backend is not built yet.',
  );

  @override
  AdminControl get admin => const _PlatformAdmin();

  @override
  ScreenControl get screen => const _PlatformScreen();

  @override
  PushControl get push => const _PlatformPush();

  @override
  Future<DeviceCapabilities> capabilities() async =>
      DeviceCapabilities.fromStatus(await admin.status());
}

class _PlatformPush implements PushControl {
  const _PlatformPush();

  @override
  Future<PushHealthStatus> status() async => PushHealthStatus.unavailable;

  @override
  Future<DeviceActionResult> restartPlayServices() async =>
      PlatformBackend._notBuilt;

  @override
  Future<DeviceActionResult> reboot() async => PlatformBackend._notBuilt;
}

class _PlatformScreen implements ScreenControl {
  const _PlatformScreen();

  @override
  Future<ScreenSnapshot> read() async => ScreenSnapshot.unavailable;

  @override
  Future<DeviceActionResult> tap({int? id, int? x, int? y}) async =>
      PlatformBackend._notBuilt;

  @override
  Future<DeviceActionResult> swipe({
    String direction = 'up',
    int? x1,
    int? y1,
    int? x2,
    int? y2,
  }) async =>
      PlatformBackend._notBuilt;

  @override
  Future<DeviceActionResult> setText({
    required int id,
    required String text,
  }) async =>
      PlatformBackend._notBuilt;

  @override
  Future<DeviceActionResult> globalAction(String action) async =>
      PlatformBackend._notBuilt;

  @override
  Future<DeviceActionResult> openApp(String packageName) async =>
      PlatformBackend._notBuilt;

  @override
  Future<ScreenshotResult> screenshot() async => ScreenshotResult.unavailable;
}

class _PlatformAdmin implements AdminControl {
  const _PlatformAdmin();

  @override
  Future<DeviceAdminStatus> status() async => const DeviceAdminStatus();

  @override
  Future<Map<String, bool>> grantSelfRuntimePermissions() async => const {};

  @override
  Future<DeviceActionResult> enableNotificationListener() async =>
      PlatformBackend._notBuilt;

  @override
  Future<DeviceActionResult> enableAccessibility() async =>
      PlatformBackend._notBuilt;

  @override
  Future<DeviceActionResult> openSystemSettings(String screen) async =>
      PlatformBackend._notBuilt;

  @override
  Future<DeviceActionResult> requestBatteryExemption() async =>
      PlatformBackend._notBuilt;

  @override
  Future<DeviceActionResult> clearDeviceOwner() async =>
      PlatformBackend._notBuilt;
}
