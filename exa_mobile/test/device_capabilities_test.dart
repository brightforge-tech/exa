import 'package:exa_mobile/device/device_control.dart';
import 'package:exa_mobile/device/fake_device_backend.dart';
import 'package:exa_mobile/device/platform_backend.dart';
import 'package:flutter_test/flutter_test.dart';

DeviceAdminStatus owner({
  Map<String, bool> grants = const {},
  Map<String, bool> runtime = const {},
  int sdk = 36,
}) =>
    DeviceAdminStatus(
      backend: DeviceBackendKind.deviceOwner,
      deviceOwner: true,
      adminActive: true,
      sdk: sdk,
      manufacturer: 'samsung',
      model: 'SM-S931B',
      grants: {DeviceGrants.deviceOwner: true, ...grants},
      runtime: runtime,
    );

void main() {
  group('DeviceCapabilities.fromStatus', () {
    test('nothing is possible with no backend', () {
      final caps = DeviceCapabilities.fromStatus(const DeviceAdminStatus());
      expect(caps.backend, DeviceBackendKind.none);
      expect(caps.toMap().values.any((v) => v), isFalse);
      expect(caps.toAgentJson()['available'], isEmpty);
    });

    test('device owner alone unlocks the app and power powers only', () {
      final caps = DeviceCapabilities.fromStatus(owner());
      expect(caps.installApps, isTrue);
      expect(caps.uninstallApps, isTrue);
      expect(caps.hideApps, isTrue);
      expect(caps.lockDevice, isTrue);
      expect(caps.rebootDevice, isTrue);
      expect(caps.grantOwnPermissions, isTrue);
      // Grants that need adb or a hand step are not implied by ownership.
      expect(caps.writeSecureSettings, isFalse);
      expect(caps.screenRead, isFalse);
      expect(caps.notificationsAll, isFalse);
      expect(caps.sms, isFalse);
      // Stock can never do these.
      expect(caps.readOtherAppData, isFalse);
      expect(caps.persistentProcess, isFalse);
    });

    test('each adb grant maps to its capability', () {
      final caps = DeviceCapabilities.fromStatus(owner(grants: {
        DeviceGrants.writeSecureSettings: true,
        DeviceGrants.readLogs: true,
        DeviceGrants.dump: true,
        DeviceGrants.usageStats: true,
        DeviceGrants.notificationListener: true,
        DeviceGrants.notificationPolicy: true,
        DeviceGrants.assistantRole: true,
        DeviceGrants.callScreeningRole: true,
        DeviceGrants.overlay: true,
        DeviceGrants.exactAlarm: true,
        DeviceGrants.batteryUnrestricted: true,
      }));
      expect(caps.writeSecureSettings, isTrue);
      expect(caps.readLogs, isTrue);
      expect(caps.dumpServices, isTrue);
      expect(caps.usageStats, isTrue);
      expect(caps.notificationsAll, isTrue);
      expect(caps.doNotDisturb, isTrue);
      expect(caps.assistantRole, isTrue);
      expect(caps.callScreening, isTrue);
      expect(caps.overlay, isTrue);
      expect(caps.exactAlarms, isTrue);
      expect(caps.batteryUnrestricted, isTrue);
    });

    test('screenshots need accessibility and Android 11+', () {
      final old = DeviceCapabilities.fromStatus(
          owner(grants: {DeviceGrants.accessibility: true}, sdk: 29));
      expect(old.screenRead, isTrue);
      expect(old.gestures, isTrue);
      expect(old.screenshot, isFalse);

      final current = DeviceCapabilities.fromStatus(
          owner(grants: {DeviceGrants.accessibility: true}, sdk: 30));
      expect(current.screenshot, isTrue);
    });

    test('sms and calls follow the runtime permissions', () {
      final caps = DeviceCapabilities.fromStatus(owner(runtime: {
        'android.permission.SEND_SMS': true,
        'android.permission.CALL_PHONE': false,
      }));
      expect(caps.sms, isTrue);
      expect(caps.calls, isFalse);
    });

    test('a platform backend holds everything, including the stock-only gaps',
        () {
      final caps = DeviceCapabilities.fromStatus(
          const DeviceAdminStatus(backend: DeviceBackendKind.platform));
      expect(caps.readOtherAppData, isTrue);
      expect(caps.persistentProcess, isTrue);
      expect(caps.screenshot, isTrue);
      expect(caps.installApps, isTrue);
    });

    test('the agent view lists only what holds', () {
      final caps = DeviceCapabilities.fromStatus(
          owner(grants: {DeviceGrants.readLogs: true}));
      final json = caps.toAgentJson();
      expect(json['backend'], 'deviceOwner');
      final available = json['available'] as List;
      expect(available, contains('read_logs'));
      expect(available, contains('install_apps'));
      expect(available, isNot(contains('screen_read')));
      expect(caps.missing, contains('screen_read'));
    });
  });

  group('DeviceAdminStatus.fromMap', () {
    test('reads the plugin wire format', () {
      final status = DeviceAdminStatus.fromMap({
        'backend': 'device_owner',
        'device_owner': true,
        'admin_active': true,
        'sdk': 36,
        'manufacturer': 'samsung',
        'model': 'SM-S931B',
        'grants': {'write_secure_settings': true, 'read_logs': false},
        'runtime': {'android.permission.SEND_SMS': true},
      });
      expect(status.backend, DeviceBackendKind.deviceOwner);
      expect(status.has(DeviceGrants.writeSecureSettings), isTrue);
      expect(status.has(DeviceGrants.readLogs), isFalse);
      expect(status.has('never_reported'), isFalse);
      expect(status.runtimeGranted('android.permission.SEND_SMS'), isTrue);
    });

    test('a missing plugin is "not set up", never an exception', () {
      final status = DeviceAdminStatus.fromMap(null);
      expect(status.backend, DeviceBackendKind.none);
      expect(status.grants, isEmpty);
    });

    test('every catalogued grant id round-trips', () {
      final status = DeviceAdminStatus.fromMap({
        'backend': 'device_owner',
        'grants': {for (final id in DeviceGrants.all) id: true},
      });
      for (final id in DeviceGrants.all) {
        expect(status.has(id), isTrue, reason: id);
      }
    });
  });

  group('FakeDeviceBackend', () {
    test('self-fixes change what the next status reports', () async {
      final fake = FakeDeviceBackend(status: owner());
      expect((await fake.capabilities()).notificationsAll, isFalse);

      final result = await fake.admin.enableNotificationListener();
      expect(result.ok, isTrue);
      expect((await fake.capabilities()).notificationsAll, isTrue);
      expect(fake.calls, ['enableNotificationListener']);
    });

    test('a failure leaves the status alone and says why', () async {
      final fake = FakeDeviceBackend(status: owner())
        ..failWith = 'WRITE_SECURE_SETTINGS missing';
      final result = await fake.admin.enableAccessibility();
      expect(result.ok, isFalse);
      expect(result.error, contains('WRITE_SECURE_SETTINGS'));
      expect((await fake.capabilities()).screenRead, isFalse);
    });

    test('runtime self-grant needs ownership', () async {
      final unowned = FakeDeviceBackend(
          status: const DeviceAdminStatus(
              runtime: {'android.permission.SEND_SMS': false}));
      expect(await unowned.admin.grantSelfRuntimePermissions(),
          {'android.permission.SEND_SMS': false});

      final owned = FakeDeviceBackend(
          status: owner(runtime: {'android.permission.SEND_SMS': false}));
      expect(await owned.admin.grantSelfRuntimePermissions(),
          {'android.permission.SEND_SMS': true});
      expect((await owned.capabilities()).sms, isTrue);
    });

    test('clearing ownership drops to no backend', () async {
      final fake = FakeDeviceBackend(status: owner());
      await fake.admin.clearDeviceOwner();
      expect(fake.status.backend, DeviceBackendKind.none);
      expect((await fake.capabilities()).installApps, isFalse);
    });
  });

  test('the platform stub answers without throwing', () async {
    const backend = PlatformBackend();
    final caps = await backend.capabilities();
    expect(caps.backend, DeviceBackendKind.none);
    final result = await backend.admin.enableAccessibility();
    expect(result.ok, isFalse);
    expect(result.error, contains('not built'));
  });
}
