import 'package:exa_mobile/data/database/app_database.dart';
import 'package:exa_mobile/data/repositories/diagnostics_repository.dart';
import 'package:exa_mobile/data/repositories/settings_repository.dart';
import 'package:exa_mobile/device/device_control.dart';
import 'package:exa_mobile/device/fake_device_backend.dart';
import 'package:exa_mobile/services/push_watchdog/push_watchdog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// The push watchdog's policy, against a scripted phone and a fake clock.
///
/// The rules it pins: nothing happens while the socket is up or the network
/// is down; a dead socket has to stay dead across two checks before Play
/// services is restarted; restarts are paced and capped; and the reboot
/// fallback fires only at night with the screen off, once a day.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late AppDatabase database;
  late SettingsRepository settings;
  late DiagnosticsRepository diagnostics;
  late FakePushControl push;
  late DateTime clock;

  PushWatchdog watchdog() => PushWatchdog(
        push: push,
        settings: settings,
        diagnostics: diagnostics,
        now: () => clock,
      );

  const dead = PushHealthStatus(
    available: true,
    connected: false,
    networkValidated: true,
    deviceOwner: true,
    connects: 1,
  );

  Future<List<String>> codes() async =>
      (await diagnostics.recent()).map((e) => e.code).toList();

  setUp(() async {
    database = AppDatabase();
    await database.open(overridePath: inMemoryDatabasePath);
    settings = SettingsRepository(database);
    diagnostics = DiagnosticsRepository(database);
    push = FakePushControl();
    // A daytime clock, well outside the reboot window.
    clock = DateTime(2026, 9, 16, 14, 0);
  });

  tearDown(() => database.close());

  test('a connected socket needs nothing', () async {
    push.health = const PushHealthStatus(
        available: true, connected: true, networkValidated: true);
    expect(await watchdog().check(), PushWatchdogOutcome.connected);
    expect(push.restarts, 0);
    expect(await codes(), isEmpty);
  });

  test('an unreadable state is reported, never acted on', () async {
    push.health = const PushHealthStatus(
        available: false, reason: 'Exa does not hold DUMP.');
    expect(await watchdog().check(), PushWatchdogOutcome.unavailable);
    expect(push.restarts, 0);
    final report = await watchdog().lastReport();
    expect(report?['note'], 'Exa does not hold DUMP.');
  });

  test('a dead socket with no network is not Play services\' fault',
      () async {
    push.health = const PushHealthStatus(
        available: true, connected: false, networkValidated: false);
    expect(await watchdog().check(), PushWatchdogOutcome.noNetwork);
    clock = clock.add(const Duration(minutes: 30));
    expect(await watchdog().check(), PushWatchdogOutcome.noNetwork);
    expect(push.restarts, 0);
  });

  test('a dead socket is watched first, then Play services is restarted',
      () async {
    push.health = dead;
    expect(await watchdog().check(), PushWatchdogOutcome.waiting);
    expect(push.restarts, 0);
    expect(await codes(), contains('PUSH_DEAD'));

    clock = clock.add(const Duration(minutes: 15));
    expect(await watchdog().check(), PushWatchdogOutcome.restarted);
    expect(push.restarts, 1);
    expect(await codes(), contains('PUSH_RESTARTED'));

    // The fake's restart brought the socket back; the next check says so.
    clock = clock.add(const Duration(minutes: 15));
    expect(await watchdog().check(), PushWatchdogOutcome.connected);
    expect(await codes(), contains('PUSH_RECOVERED'));
  });

  test('a socket that comes back on its own resets the clock', () async {
    push.health = dead;
    await watchdog().check();
    push.health = const PushHealthStatus(
        available: true, connected: true, networkValidated: true);
    clock = clock.add(const Duration(minutes: 15));
    expect(await watchdog().check(), PushWatchdogOutcome.connected);

    // Dead again: the 10-minute watch starts over, no restart yet.
    push.health = dead;
    clock = clock.add(const Duration(minutes: 15));
    expect(await watchdog().check(), PushWatchdogOutcome.waiting);
    expect(push.restarts, 0);
  });

  test('restarts are paced and capped, then it waits for the night',
      () async {
    push.health = dead;
    push.onRestart = (before) => before; // the restart never helps
    await watchdog().check(); // dead, watching
    for (var attempt = 1; attempt <= 3; attempt++) {
      clock = clock.add(const Duration(minutes: 15));
      expect(await watchdog().check(), PushWatchdogOutcome.restarted,
          reason: 'attempt $attempt');
      clock = clock.add(const Duration(minutes: 5));
      // Inside the cooldown: no second restart.
      expect(await watchdog().check(), PushWatchdogOutcome.waiting);
      clock = clock.add(const Duration(minutes: 10));
    }
    expect(push.restarts, 3);
    // Restarts used up, daytime: nothing more, no reboot.
    expect(await watchdog().check(), PushWatchdogOutcome.exhausted);
    expect(push.reboots, 0);
    expect((await watchdog().lastReport())?['note'],
        'waiting for the night window');
  });

  test('the reboot fallback fires at night with the screen off, once',
      () async {
    push.onRestart = (before) => before;
    // 03:00, after three restarts in the last two hours that never helped.
    clock = DateTime(2026, 9, 17, 3, 0);
    await settings.setValue(
      PushWatchdog.restartsKey,
      [
        clock.subtract(const Duration(minutes: 90)),
        clock.subtract(const Duration(minutes: 60)),
        clock.subtract(const Duration(minutes: 30)),
      ].map((t) => t.toIso8601String()).join(','),
    );
    await settings.setValue(PushWatchdog.deadSinceKey,
        clock.subtract(const Duration(hours: 2)).toIso8601String());

    // Screen on: still no.
    push.health = const PushHealthStatus(
        available: true,
        connected: false,
        networkValidated: true,
        deviceOwner: true,
        screenOn: true);
    expect(await watchdog().check(), PushWatchdogOutcome.exhausted);
    expect((await watchdog().lastReport())?['note'], 'screen is on');
    expect(push.reboots, 0);

    // 03:05, screen off: reboot.
    clock = clock.add(const Duration(minutes: 5));
    push.health = dead;
    expect(await watchdog().check(), PushWatchdogOutcome.rebooted);
    expect(push.reboots, 1);
    expect(await codes(), contains('PUSH_REBOOT'));

    // The same night again: already rebooted in the last 24 h.
    clock = clock.add(const Duration(minutes: 30));
    expect(await watchdog().check(), PushWatchdogOutcome.exhausted);
    expect(push.reboots, 1);
  });

  test('a refused restart is recorded and still counts towards the cap',
      () async {
    push.health = dead;
    push.failWith = 'Exa is not the device owner.';
    await watchdog().check();
    clock = clock.add(const Duration(minutes: 15));
    expect(await watchdog().check(), PushWatchdogOutcome.restartFailed);
    expect(await codes(), contains('PUSH_RESTART_FAILED'));
    clock = clock.add(const Duration(minutes: 5));
    expect(await watchdog().check(), PushWatchdogOutcome.waiting);
  });

  test('a socket dead through a VPN is explained once, never restarted',
      () async {
    push.health = const PushHealthStatus(
      available: true,
      connected: false,
      networkValidated: true,
      deviceOwner: true,
      viaVpn: true,
      vpnApp: 'Tailscale',
    );
    expect(await watchdog().check(), PushWatchdogOutcome.waiting);
    clock = clock.add(const Duration(minutes: 15));
    expect(await watchdog().check(), PushWatchdogOutcome.blockedByVpn);
    expect(push.restarts, 0);
    expect(await codes(), contains('PUSH_BLOCKED_BY_VPN'));
    expect((await watchdog().lastReport())?['note'], 'Tailscale');

    // Still blocked an hour later: no restart, no reboot, and said once.
    clock = clock.add(const Duration(hours: 1));
    expect(await watchdog().check(), PushWatchdogOutcome.blockedByVpn);
    expect(push.restarts, 0);
    expect(push.reboots, 0);
    expect((await codes()).where((c) => c == 'PUSH_BLOCKED_BY_VPN').length,
        1);

    // Connected again (the VPN was fixed), then blocked afresh: said again.
    push.health = const PushHealthStatus(
        available: true, connected: true, networkValidated: true);
    clock = clock.add(const Duration(minutes: 15));
    expect(await watchdog().check(), PushWatchdogOutcome.connected);
    push.health = const PushHealthStatus(
      available: true,
      connected: false,
      networkValidated: true,
      viaVpn: true,
    );
    await watchdog().check();
    clock = clock.add(const Duration(minutes: 15));
    expect(await watchdog().check(), PushWatchdogOutcome.blockedByVpn);
    expect((await codes()).where((c) => c == 'PUSH_BLOCKED_BY_VPN').length,
        2);
  });

  test('the switch in Settings turns it off entirely', () async {
    push.health = dead;
    await watchdog().setEnabled(false);
    expect(await watchdog().check(), PushWatchdogOutcome.disabled);
    clock = clock.add(const Duration(hours: 1));
    expect(await watchdog().check(), PushWatchdogOutcome.disabled);
    expect(push.restarts, 0);
    expect(await codes(), isEmpty);
  });
}
