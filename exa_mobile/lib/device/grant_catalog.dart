import 'device_control.dart';
import 'device_owner_backend.dart';

/// How a missing grant gets fixed.
enum GrantFix {
  /// Exa can flip it itself (a policy call, or a secure-settings write once
  /// it holds WRITE_SECURE_SETTINGS).
  self,

  /// The user flips it on a system page Exa can open.
  hand,

  /// Only adb can grant it. Done once; survives reboots and in-place
  /// updates.
  adb,
}

/// One grant, what it is for, and how to get it.
class GrantSpec {
  const GrantSpec({
    required this.id,
    required this.title,
    required this.why,
    required this.fix,
    this.requires,
    this.settingsScreen,
    this.adbCommand,
    this.handHint,
  });

  final String id;
  final String title;

  /// What Exa can do once it holds this.
  final String why;
  final GrantFix fix;

  /// A grant [fix] depends on; without it the fix degrades to [hand] (or
  /// [adb] if there is no page).
  final String? requires;

  /// For [GrantFix.hand]: the `AdminControl.openSystemSettings` screen.
  final String? settingsScreen;

  /// For [GrantFix.adb] (and as a hint elsewhere): the one-line command.
  final String? adbCommand;

  /// Where to find the switch, for pages that vary by phone.
  final String? handHint;

  /// The fix that applies given what Exa already holds.
  GrantFix effectiveFix(DeviceAdminStatus status) {
    final needed = requires;
    if (fix == GrantFix.self && needed != null && !status.has(needed)) {
      return settingsScreen != null ? GrantFix.hand : GrantFix.adb;
    }
    return fix;
  }
}

/// The grants the settings screen walks through, in the order they matter.
/// Grants for services that do not exist yet (accessibility, call
/// screening) are added to this list by the stage that adds the service.
class GrantCatalog {
  GrantCatalog._();

  static const _pkg = DeviceOwnerBackend.packageName;

  static const entries = <GrantSpec>[
    GrantSpec(
      id: DeviceGrants.deviceOwner,
      title: 'Device owner',
      why: 'Install, remove, hide and suspend apps; grant Exa its own '
          'permissions; lock and reboot the phone. Set once over adb.',
      fix: GrantFix.adb,
      adbCommand: 'tools\\provision_device.ps1  (or: adb shell dpm '
          'set-device-owner $_pkg/com.brightforge.exa.device.ExaDeviceAdminReceiver)',
    ),
    GrantSpec(
      id: DeviceGrants.writeSecureSettings,
      title: 'Write secure settings',
      why: 'Lets Exa switch on its own notification access and screen '
          'reading, and change system settings.',
      fix: GrantFix.adb,
      adbCommand:
          'adb shell pm grant $_pkg android.permission.WRITE_SECURE_SETTINGS',
    ),
    GrantSpec(
      id: DeviceGrants.readLogs,
      title: 'Read system logs',
      why: 'Answers "why did that fail?" from the phone\'s own log.',
      fix: GrantFix.adb,
      adbCommand: 'adb shell pm grant $_pkg android.permission.READ_LOGS',
    ),
    GrantSpec(
      id: DeviceGrants.dump,
      title: 'Read service state',
      why: 'Battery, alarms and job diagnostics straight from the system.',
      fix: GrantFix.adb,
      adbCommand: 'adb shell pm grant $_pkg android.permission.DUMP',
    ),
    GrantSpec(
      id: DeviceGrants.usageStats,
      title: 'Usage access',
      why: 'Which apps you use and for how long.',
      fix: GrantFix.hand,
      settingsScreen: 'usage_access',
      adbCommand: 'adb shell appops set $_pkg GET_USAGE_STATS allow',
      handHint: 'Find Exa in the list and allow usage access.',
    ),
    GrantSpec(
      id: DeviceGrants.overlay,
      title: 'Draw over other apps',
      why: 'The floating Exa bubble.',
      fix: GrantFix.hand,
      settingsScreen: 'overlay',
      adbCommand: 'adb shell appops set $_pkg SYSTEM_ALERT_WINDOW allow',
    ),
    GrantSpec(
      id: DeviceGrants.exactAlarm,
      title: 'Alarms and reminders',
      why: 'Reminders and briefs fire at the exact time, even in deep '
          'sleep.',
      fix: GrantFix.hand,
      settingsScreen: 'exact_alarm',
      adbCommand: 'adb shell appops set $_pkg SCHEDULE_EXACT_ALARM allow',
    ),
    GrantSpec(
      id: DeviceGrants.batteryUnrestricted,
      title: 'Battery: unrestricted',
      why: 'Android stops freezing Exa in the background. On Samsung also '
          'keep Exa out of "Sleeping apps".',
      fix: GrantFix.self,
      adbCommand: 'adb shell dumpsys deviceidle whitelist +$_pkg',
      handHint: 'Settings > Apps > Exa > Battery > Unrestricted.',
    ),
    GrantSpec(
      id: DeviceGrants.accessibility,
      title: 'Screen access (accessibility)',
      why: 'Read what is on screen and tap, type and swipe in any app - '
          'Outlook, WhatsApp, a banking app - the way you do.',
      fix: GrantFix.self,
      requires: DeviceGrants.writeSecureSettings,
      settingsScreen: 'accessibility',
      handHint: 'Settings > Accessibility > Exa > On. On Android 13+ you may '
          'first tap the 3-dot menu > Allow restricted settings.',
    ),
    GrantSpec(
      id: DeviceGrants.notificationListener,
      title: 'Notification access',
      why: 'Read, dismiss and reply to notifications from any app; capture '
          'chat messages.',
      fix: GrantFix.self,
      requires: DeviceGrants.writeSecureSettings,
      settingsScreen: 'notification_listener',
      adbCommand: 'adb shell cmd notification allow_listener '
          '$_pkg/${DeviceOwnerBackend.notificationListenerClass}',
    ),
    GrantSpec(
      id: DeviceGrants.notificationPolicy,
      title: 'Do Not Disturb access',
      why: 'Turn Do Not Disturb on and off.',
      fix: GrantFix.hand,
      settingsScreen: 'notification_policy',
      adbCommand: 'adb shell cmd notification allow_dnd $_pkg',
    ),
    GrantSpec(
      id: DeviceGrants.assistantRole,
      title: 'Default digital assistant',
      why: 'The assist gesture and side key open Exa with what is on '
          'screen.',
      fix: GrantFix.hand,
      settingsScreen: 'assistant',
      handHint: 'Settings > Apps > Default apps > Digital assistant app > '
          'Exa. Bixby or Gemini may hold it now.',
    ),
  ];

  static GrantSpec? byId(String id) {
    for (final spec in entries) {
      if (spec.id == id) return spec;
    }
    return null;
  }
}
