import 'device_control.dart';

/// A phone that records what it was asked to do.
///
/// Tests set [status] to whatever standing they want Exa to have and then
/// assert on the recorded calls; the self-fix methods mutate [status] the
/// way the real phone would, so a screen or tool that "fixes then
/// re-reads" behaves the same against the fake.
class FakeDeviceBackend implements DeviceControl {
  FakeDeviceBackend({DeviceAdminStatus? status})
      : status = status ?? const DeviceAdminStatus();

  DeviceAdminStatus status;

  /// When set, self-fix actions fail with this message instead of applying.
  String? failWith;

  final openedSettings = <String>[];
  final calls = <String>[];

  late final AdminControl _admin = _FakeAdmin(this);
  final FakeScreenControl screenControl = FakeScreenControl();
  final FakePushControl pushControl = FakePushControl();

  @override
  AdminControl get admin => _admin;

  @override
  ScreenControl get screen => screenControl;

  @override
  PushControl get push => pushControl;

  @override
  Future<DeviceCapabilities> capabilities() async =>
      DeviceCapabilities.fromStatus(status);

  void _setGrant(String grant, bool value) {
    status = DeviceAdminStatus(
      backend: status.backend,
      deviceOwner: status.deviceOwner,
      adminActive: status.adminActive,
      sdk: status.sdk,
      manufacturer: status.manufacturer,
      model: status.model,
      grants: {...status.grants, grant: value},
      runtime: status.runtime,
    );
  }
}

class _FakeAdmin implements AdminControl {
  _FakeAdmin(this.fake);

  final FakeDeviceBackend fake;

  DeviceActionResult _apply(String call, void Function() change) {
    fake.calls.add(call);
    final failure = fake.failWith;
    if (failure != null) return DeviceActionResult(ok: false, error: failure);
    change();
    return const DeviceActionResult(ok: true);
  }

  @override
  Future<DeviceAdminStatus> status() async => fake.status;

  @override
  Future<Map<String, bool>> grantSelfRuntimePermissions() async {
    fake.calls.add('grantSelfRuntime');
    if (!fake.status.deviceOwner || fake.failWith != null) {
      return {for (final p in fake.status.runtime.keys) p: false};
    }
    final granted = {for (final p in fake.status.runtime.keys) p: true};
    fake.status = DeviceAdminStatus(
      backend: fake.status.backend,
      deviceOwner: fake.status.deviceOwner,
      adminActive: fake.status.adminActive,
      sdk: fake.status.sdk,
      manufacturer: fake.status.manufacturer,
      model: fake.status.model,
      grants: fake.status.grants,
      runtime: granted,
    );
    return granted;
  }

  @override
  Future<DeviceActionResult> enableNotificationListener() async => _apply(
      'enableNotificationListener',
      () => fake._setGrant(DeviceGrants.notificationListener, true));

  @override
  Future<DeviceActionResult> enableAccessibility() async => _apply(
      'enableAccessibility',
      () => fake._setGrant(DeviceGrants.accessibility, true));

  @override
  Future<DeviceActionResult> openSystemSettings(String screen) async {
    fake.openedSettings.add(screen);
    return const DeviceActionResult(ok: true);
  }

  @override
  Future<DeviceActionResult> requestBatteryExemption() async => _apply(
      'requestBatteryExemption',
      () => fake._setGrant(DeviceGrants.batteryUnrestricted, true));

  @override
  Future<DeviceActionResult> clearDeviceOwner() async =>
      _apply('clearDeviceOwner', () {
        fake.status = DeviceAdminStatus(
          backend: DeviceBackendKind.none,
          deviceOwner: false,
          adminActive: fake.status.adminActive,
          sdk: fake.status.sdk,
          manufacturer: fake.status.manufacturer,
          model: fake.status.model,
          grants: {...fake.status.grants, DeviceGrants.deviceOwner: false},
          runtime: fake.status.runtime,
        );
      });
}

/// A screen that a test can pre-load with elements and then assert on the
/// gestures Exa asked for.
class FakeScreenControl implements ScreenControl {
  ScreenSnapshot snapshot = const ScreenSnapshot(
    packageName: 'com.example.app',
    appLabel: 'Example',
    elements: [],
  );

  /// When set, screen reads report unavailable (accessibility off).
  String? unavailableReason;

  final taps = <({int? id, int? x, int? y})>[];
  final swipes = <String>[];
  final typed = <({int id, String text})>[];
  final globals = <String>[];
  final openedApps = <String>[];
  int screenshots = 0;

  @override
  Future<ScreenSnapshot> read() async {
    final reason = unavailableReason;
    if (reason != null) {
      return ScreenSnapshot(available: false, unavailableReason: reason);
    }
    return snapshot;
  }

  @override
  Future<DeviceActionResult> tap({int? id, int? x, int? y}) async {
    taps.add((id: id, x: x, y: y));
    return const DeviceActionResult(ok: true);
  }

  @override
  Future<DeviceActionResult> swipe({
    String direction = 'up',
    int? x1,
    int? y1,
    int? x2,
    int? y2,
  }) async {
    swipes.add(direction);
    return const DeviceActionResult(ok: true);
  }

  @override
  Future<DeviceActionResult> setText({
    required int id,
    required String text,
  }) async {
    typed.add((id: id, text: text));
    return const DeviceActionResult(ok: true);
  }

  @override
  Future<DeviceActionResult> globalAction(String action) async {
    globals.add(action);
    return const DeviceActionResult(ok: true);
  }

  @override
  Future<DeviceActionResult> openApp(String packageName) async {
    openedApps.add(packageName);
    return const DeviceActionResult(ok: true);
  }

  @override
  Future<ScreenshotResult> screenshot() async {
    screenshots++;
    return const ScreenshotResult(
      ok: true,
      bytes: [137, 80, 78, 71],
      width: 1080,
      height: 2220,
    );
  }
}

/// A push connection a test can script: set [health] to what the phone
/// would report, then assert on the repairs asked for.
class FakePushControl implements PushControl {
  PushHealthStatus health = PushHealthStatus.unavailable;

  /// When set, repairs fail with this message instead of applying.
  String? failWith;

  int restarts = 0;
  int reboots = 0;

  /// What a restart does to [health]. By default the socket comes back,
  /// which is what a working Play services does within seconds.
  PushHealthStatus Function(PushHealthStatus before)? onRestart;

  @override
  Future<PushHealthStatus> status() async => health;

  @override
  Future<DeviceActionResult> restartPlayServices() async {
    restarts++;
    final failure = failWith;
    if (failure != null) return DeviceActionResult(ok: false, error: failure);
    final after = onRestart;
    health = after != null
        ? after(health)
        : PushHealthStatus(
            available: true,
            connected: true,
            networkValidated: health.networkValidated,
            screenOn: health.screenOn,
            deviceOwner: health.deviceOwner,
            connects: (health.connects ?? 0) + 1,
          );
    return const DeviceActionResult(ok: true);
  }

  @override
  Future<DeviceActionResult> reboot() async {
    reboots++;
    final failure = failWith;
    if (failure != null) return DeviceActionResult(ok: false, error: failure);
    return const DeviceActionResult(ok: true);
  }
}
