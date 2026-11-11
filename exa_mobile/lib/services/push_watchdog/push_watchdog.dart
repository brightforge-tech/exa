import 'dart:convert';

import '../../agent/behaviors/notification_policy.dart';
import '../../data/repositories/diagnostics_repository.dart';
import '../../data/repositories/settings_repository.dart';
import '../../device/device_control.dart';
import '../notifications/notification_service.dart';

/// What one watchdog check concluded.
enum PushWatchdogOutcome {
  /// The switch in Settings is off.
  disabled,

  /// The state could not be read (no DUMP grant, no Play services).
  unavailable,

  /// Play services reports its push client connected.
  connected,

  /// Not connected, but there is no validated network to blame it on.
  noNetwork,

  /// Dead with a network, but not for long enough (or too soon after the
  /// last repair) to act.
  waiting,

  /// Play services was restarted.
  restarted,

  /// A restart was attempted and refused.
  restartFailed,

  /// Restarts are used up and the reboot window has not opened.
  exhausted,

  /// The phone was asked to reboot.
  rebooted,

  /// Dead because Play services is routing through a split-tunnel VPN. A
  /// restart cannot help (it rebinds to the VPN), so the watchdog explains
  /// instead - the VPN app's settings are where this gets fixed.
  blockedByVpn,
}

/// Keeps the phone's push connection alive.
///
/// Every FCM app is silent while Google Play services' socket is down, and
/// on the S8+ Play services stops trying to reconnect after one failure
/// until it is restarted (see `PushHealth.kt` for the evidence). Exa runs
/// this check from the background tick and at app start: when the socket
/// has been dead *with a working network* across two checks it restarts
/// Play services - the "Force stop" a person would do - and if that keeps
/// failing, reboots the phone once, at night, with the screen off.
///
/// Everything it decides on is persisted in `settings`, because the checks
/// run in separate background isolates that share no memory. Every action
/// and every change of state is recorded in diagnostics, so "why did my
/// phone restart Play services at 03:00" has an answer on the Reliability
/// screen.
class PushWatchdog {
  PushWatchdog({
    required this.push,
    required this.settings,
    required this.diagnostics,
    this.notifications,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final PushControl push;
  final SettingsRepository settings;
  final DiagnosticsRepository diagnostics;
  final NotificationService? notifications;
  final DateTime Function() _now;

  static const enabledKey = 'push_watchdog_enabled';
  static const deadSinceKey = 'push_watchdog_dead_since';
  static const restartsKey = 'push_watchdog_restarts';
  static const lastRebootKey = 'push_watchdog_last_reboot';
  static const lastOutcomeKey = 'push_watchdog_last_outcome';

  /// The dead episode (its `dead_since`) the VPN notice was already given
  /// for, so a persisting VPN block is said once, not every check.
  static const vpnNoticeKey = 'push_watchdog_vpn_notice';

  /// The socket must be dead with a network this long before a repair. The
  /// tick runs every 15 minutes awake (hourly asleep), so this means "dead
  /// at two consecutive checks" rather than a transient.
  static const deadThreshold = Duration(minutes: 10);

  /// Minimum gap between restarts: Play services needs a few minutes to come
  /// back and reconnect before it can be judged again.
  static const restartCooldown = Duration(minutes: 15);

  /// Restarts allowed per [restartWindow] before the reboot fallback.
  static const maxRestartsPerWindow = 3;
  static const restartWindow = Duration(hours: 6);

  /// The reboot fallback runs only in this local-time window, screen off,
  /// and at most once per [rebootCooldown].
  static const rebootWindowStartHour = 1;
  static const rebootWindowEndHour = 5;
  static const rebootCooldown = Duration(hours: 24);

  /// Own band, clear of job reports (901xx) and job health (903xx).
  static const notificationId = 90400;

  Future<bool> isEnabled() async =>
      (await settings.getValue(enabledKey)) != '0';

  Future<void> setEnabled(bool enabled) =>
      settings.setValue(enabledKey, enabled ? '1' : '0');

  /// The last check's outcome and reading, for the settings tile.
  Future<Map<String, Object?>?> lastReport() async {
    final raw = await settings.getValue(lastOutcomeKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map ? decoded.cast<String, Object?>() : null;
    } catch (_) {
      return null;
    }
  }

  /// One check. Never throws: this runs inside the background tick, whose
  /// contract is that nothing in it can fail the tick.
  Future<PushWatchdogOutcome> check() async {
    try {
      return await _check();
    } catch (e) {
      await diagnostics.warn(
        code: 'PUSH_WATCHDOG_FAILED',
        message: 'The push watchdog could not run: $e',
        error: e,
      );
      return PushWatchdogOutcome.unavailable;
    }
  }

  Future<PushWatchdogOutcome> _check() async {
    if (!await isEnabled()) return PushWatchdogOutcome.disabled;

    final now = _now();
    final health = await push.status();
    if (!health.available) {
      return _conclude(PushWatchdogOutcome.unavailable, health,
          note: health.reason);
    }

    if (health.connected != false) {
      // Connected, or unreadable (null): either way, nothing to repair.
      final deadSince = await _deadSince();
      if (deadSince != null && health.connected == true) {
        await diagnostics.record(
          code: 'PUSH_RECOVERED',
          message: 'Push notifications are connected again after '
              '${now.difference(deadSince).inMinutes} min.',
          context: health.toJson(),
        );
      }
      await settings.setValue(deadSinceKey, null);
      await settings.setValue(vpnNoticeKey, null);
      return _conclude(PushWatchdogOutcome.connected, health);
    }

    if (!health.networkValidated) {
      // Nothing to repair without a network, and it does not count as dead
      // time either: a phone out of Wi-Fi range is not a stuck socket.
      await settings.setValue(deadSinceKey, null);
      return _conclude(PushWatchdogOutcome.noNetwork, health);
    }

    var deadSince = await _deadSince();
    if (deadSince == null) {
      deadSince = now;
      await settings.setValue(deadSinceKey, deadSince.toIso8601String());
      await diagnostics.record(
        code: 'PUSH_DEAD',
        message: 'Push notifications are not connected although the network '
            'is up. Watching before acting.',
        context: health.toJson(),
      );
    }
    final deadFor = now.difference(deadSince);
    if (deadFor < deadThreshold) {
      return _conclude(PushWatchdogOutcome.waiting, health,
          note: 'dead for ${deadFor.inMinutes} min');
    }

    // Seen live on the S8+: Play services restarted, came back, bound to
    // the Tailscale VPN again and failed in 40 ms. Only the VPN's own
    // settings fix that, so say so instead of burning restarts and a reboot.
    if (health.viaVpn) {
      return _blockedByVpn(deadSince, health, deadFor);
    }

    final restarts = await _restartsWithin(now);
    final lastRestart = restarts.isEmpty ? null : restarts.last;
    if (lastRestart != null &&
        now.difference(lastRestart) < restartCooldown) {
      return _conclude(PushWatchdogOutcome.waiting, health,
          note: 'restarted ${now.difference(lastRestart).inMinutes} min ago');
    }

    if (restarts.length < maxRestartsPerWindow) {
      return _restart(now, health, deadFor, restarts);
    }
    return _maybeReboot(now, health, deadFor, restarts);
  }

  Future<PushWatchdogOutcome> _restart(
    DateTime now,
    PushHealthStatus health,
    Duration deadFor,
    List<DateTime> restarts,
  ) async {
    final result = await push.restartPlayServices();
    // Counted whether or not it took: a refused restart every 15 minutes
    // is not a plan, and the reboot fallback exists for exactly that.
    await settings.setValue(
      restartsKey,
      [...restarts, now].map((t) => t.toIso8601String()).join(','),
    );
    if (!result.ok) {
      await diagnostics.warn(
        code: 'PUSH_RESTART_FAILED',
        message: 'Push notifications have been dead for '
            '${deadFor.inMinutes} min and Play services could not be '
            'restarted: ${result.error ?? 'no reason given'}',
        context: health.toJson(),
      );
      return _conclude(PushWatchdogOutcome.restartFailed, health,
          note: result.error);
    }
    await diagnostics.warn(
      code: 'PUSH_RESTARTED',
      message: 'Push notifications had been dead for ${deadFor.inMinutes} '
          'min with the network up. Exa restarted Google Play services '
          '(attempt ${restarts.length + 1} of $maxRestartsPerWindow).',
      context: health.toJson(),
    );
    await notifications?.showNow(
      id: notificationId,
      title: 'Push notifications were stuck',
      body: 'Google Play services had lost its connection for '
          '${deadFor.inMinutes} minutes, so Exa restarted it. Teams, '
          'Outlook and the others should catch up now.',
      route: '/settings/reliability',
      channel: NotificationPolicy.channelSystemHealth,
    );
    return _conclude(PushWatchdogOutcome.restarted, health);
  }

  Future<PushWatchdogOutcome> _blockedByVpn(
    DateTime deadSince,
    PushHealthStatus health,
    Duration deadFor,
  ) async {
    final vpn = health.vpnApp ?? 'a VPN app';
    final episode = deadSince.toIso8601String();
    if (await settings.getValue(vpnNoticeKey) != episode) {
      await settings.setValue(vpnNoticeKey, episode);
      await diagnostics.warn(
        code: 'PUSH_BLOCKED_BY_VPN',
        message: 'Push notifications have been dead for ${deadFor.inMinutes} '
            'min: Google Play services is routing through $vpn and cannot '
            'reach Google. A restart would not help. Exclude Play services '
            'from the VPN or use an exit node.',
        context: health.toJson(),
      );
      await notifications?.showNow(
        id: notificationId,
        title: 'Push notifications are blocked by $vpn',
        body: 'Google Play services is trying to reach Google through the '
            'VPN and cannot, so Teams, Outlook and the others stay silent. '
            'Exa cannot fix this by restarting it: in $vpn, exclude Google '
            'Play services from the VPN (or use an exit node).',
        route: '/settings/device',
        channel: NotificationPolicy.channelSystemHealth,
      );
    }
    return _conclude(PushWatchdogOutcome.blockedByVpn, health, note: vpn);
  }

  Future<PushWatchdogOutcome> _maybeReboot(
    DateTime now,
    PushHealthStatus health,
    Duration deadFor,
    List<DateTime> restarts,
  ) async {
    final lastRebootRaw = await settings.getValue(lastRebootKey);
    final lastReboot =
        lastRebootRaw == null ? null : DateTime.tryParse(lastRebootRaw);
    final inWindow =
        now.hour >= rebootWindowStartHour && now.hour < rebootWindowEndHour;
    final rested =
        lastReboot == null || now.difference(lastReboot) >= rebootCooldown;
    if (!inWindow || health.screenOn || !rested || !health.deviceOwner) {
      return _conclude(PushWatchdogOutcome.exhausted, health,
          note: !inWindow
              ? 'waiting for the night window'
              : health.screenOn
                  ? 'screen is on'
                  : !rested
                      ? 'already rebooted in the last 24 h'
                      : 'not the device owner');
    }
    await settings.setValue(lastRebootKey, now.toIso8601String());
    await diagnostics.warn(
      code: 'PUSH_REBOOT',
      message: 'Push notifications stayed dead for ${deadFor.inMinutes} min '
          'through ${restarts.length} Play services restarts. Rebooting the '
          'phone.',
      context: health.toJson(),
    );
    final result = await push.reboot();
    if (!result.ok) {
      await diagnostics.warn(
        code: 'PUSH_REBOOT_FAILED',
        message:
            'The reboot was refused: ${result.error ?? 'no reason given'}',
        context: health.toJson(),
      );
      return _conclude(PushWatchdogOutcome.exhausted, health,
          note: result.error);
    }
    return _conclude(PushWatchdogOutcome.rebooted, health);
  }

  Future<DateTime?> _deadSince() async {
    final raw = await settings.getValue(deadSinceKey);
    return raw == null ? null : DateTime.tryParse(raw);
  }

  /// Restart times inside the current window, oldest first. Older ones are
  /// forgotten, which is what lets the count start over.
  Future<List<DateTime>> _restartsWithin(DateTime now) async {
    final raw = await settings.getValue(restartsKey);
    if (raw == null || raw.isEmpty) return const [];
    final cutoff = now.subtract(restartWindow);
    return raw
        .split(',')
        .map(DateTime.tryParse)
        .whereType<DateTime>()
        .where((t) => t.isAfter(cutoff))
        .toList()
      ..sort();
  }

  Future<PushWatchdogOutcome> _conclude(
    PushWatchdogOutcome outcome,
    PushHealthStatus health, {
    String? note,
  }) async {
    await settings.setValue(
      lastOutcomeKey,
      jsonEncode({
        'outcome': outcome.name,
        'checked_at': _now().toIso8601String(),
        'note': ?note,
        'connected': health.connected,
        'network_validated': health.networkValidated,
        if (health.connects != null) 'connects': health.connects,
      }),
    );
    return outcome;
  }
}
