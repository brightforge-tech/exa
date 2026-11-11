/// What Exa can do to the phone itself, behind one interface.
///
/// Two backends implement this: a Device Owner backend on stock Android (the
/// Galaxy S25, now) and a platform-signed privileged-app backend on an AOSP
/// build (a Pixel, later). Tools never see which one they are talking to;
/// they ask [DeviceControl.capabilities] what is possible and degrade
/// honestly ("this needs the AOSP build") instead of throwing.
///
/// Every backend reports rather than throws: a missing grant is an answer.
library;

/// Which backend is behind the interface.
enum DeviceBackendKind {
  /// No admin standing at all (tests, desktop, a phone that has not been
  /// provisioned yet).
  none,

  /// A plain device admin, not the owner. Very little works.
  deviceAdmin,

  /// Device Owner on stock Android.
  deviceOwner,

  /// A platform-signed privileged app on our own AOSP build.
  platform;

  static DeviceBackendKind fromWire(String? name) => switch (name) {
        'device_owner' => DeviceBackendKind.deviceOwner,
        'device_admin' => DeviceBackendKind.deviceAdmin,
        'platform' => DeviceBackendKind.platform,
        _ => DeviceBackendKind.none,
      };

  String get label => switch (this) {
        DeviceBackendKind.none => 'Not set up',
        DeviceBackendKind.deviceAdmin => 'Device admin only',
        DeviceBackendKind.deviceOwner => 'Device owner',
        DeviceBackendKind.platform => 'System app',
      };
}

/// The outcome of an admin action.
class DeviceActionResult {
  const DeviceActionResult({required this.ok, this.error, this.already = false});

  final bool ok;
  final String? error;

  /// True when there was nothing to do (the grant was already in place).
  final bool already;

  static const unavailable = DeviceActionResult(
    ok: false,
    error: 'Device control is only available on the phone.',
  );

  static DeviceActionResult fromMap(Map<Object?, Object?>? map) {
    if (map == null) return unavailable;
    return DeviceActionResult(
      ok: map['ok'] == true,
      error: map['error'] as String?,
      already: map['already'] == true,
    );
  }
}

/// Exa's administrative standing, as reported by the backend.
class DeviceAdminStatus {
  const DeviceAdminStatus({
    this.backend = DeviceBackendKind.none,
    this.deviceOwner = false,
    this.adminActive = false,
    this.sdk = 0,
    this.manufacturer = '',
    this.model = '',
    this.grants = const {},
    this.runtime = const {},
  });

  final DeviceBackendKind backend;
  final bool deviceOwner;
  final bool adminActive;

  /// Android API level (0 off-device).
  final int sdk;
  final String manufacturer;
  final String model;

  /// Grant id (see [DeviceGrants]) → held.
  final Map<String, bool> grants;

  /// Runtime permission name → granted, for every dangerous permission the
  /// app's manifest requests.
  final Map<String, bool> runtime;

  static const unavailable = DeviceAdminStatus();

  bool has(String grant) => grants[grant] == true;

  bool runtimeGranted(String permission) => runtime[permission] == true;

  static DeviceAdminStatus fromMap(Map<Object?, Object?>? map) {
    if (map == null) return unavailable;
    Map<String, bool> bools(Object? raw) => {
          if (raw is Map)
            for (final entry in raw.entries)
              if (entry.key is String) entry.key as String: entry.value == true,
        };
    return DeviceAdminStatus(
      backend: DeviceBackendKind.fromWire(map['backend'] as String?),
      deviceOwner: map['device_owner'] == true,
      adminActive: map['admin_active'] == true,
      sdk: map['sdk'] as int? ?? 0,
      manufacturer: map['manufacturer'] as String? ?? '',
      model: map['model'] as String? ?? '',
      grants: bools(map['grants']),
      runtime: bools(map['runtime']),
    );
  }

  Map<String, Object?> toJson() => {
        'backend': backend.name,
        'device_owner': deviceOwner,
        'sdk': sdk,
        'model': model,
        'grants': grants,
        'runtime': runtime,
      };
}

/// The grant ids a backend reports, with what each one is for.
class DeviceGrants {
  DeviceGrants._();

  static const deviceOwner = 'device_owner';
  static const deviceAdmin = 'device_admin';
  static const writeSecureSettings = 'write_secure_settings';
  static const readLogs = 'read_logs';
  static const dump = 'dump';
  static const usageStats = 'usage_stats';
  static const overlay = 'overlay';
  static const exactAlarm = 'exact_alarm';
  static const batteryUnrestricted = 'battery_unrestricted';
  static const notificationListener = 'notification_listener';
  static const notificationPolicy = 'notification_policy';
  static const accessibility = 'accessibility';
  static const assistantRole = 'assistant_role';
  static const callScreeningRole = 'call_screening_role';

  /// Every id [DeviceAdminStatus.grants] can carry.
  static const all = [
    deviceOwner,
    deviceAdmin,
    writeSecureSettings,
    readLogs,
    dump,
    usageStats,
    overlay,
    exactAlarm,
    batteryUnrestricted,
    notificationListener,
    notificationPolicy,
    accessibility,
    assistantRole,
    callScreeningRole,
  ];
}

/// What Exa can do on this phone right now, derived from [DeviceAdminStatus].
///
/// Tools read this before acting; the settings screen shows it. Fields are
/// booleans on purpose - a capability is either available or it is not, and
/// "partly" is what `false` plus an honest tool message is for.
class DeviceCapabilities {
  const DeviceCapabilities({
    this.backend = DeviceBackendKind.none,
    this.installApps = false,
    this.uninstallApps = false,
    this.hideApps = false,
    this.suspendApps = false,
    this.grantOwnPermissions = false,
    this.lockDevice = false,
    this.rebootDevice = false,
    this.writeSecureSettings = false,
    this.readLogs = false,
    this.dumpServices = false,
    this.usageStats = false,
    this.screenRead = false,
    this.screenshot = false,
    this.gestures = false,
    this.notificationsAll = false,
    this.doNotDisturb = false,
    this.sms = false,
    this.calls = false,
    this.callScreening = false,
    this.assistantRole = false,
    this.overlay = false,
    this.exactAlarms = false,
    this.batteryUnrestricted = false,
    this.readOtherAppData = false,
    this.persistentProcess = false,
  });

  final DeviceBackendKind backend;

  // Device Owner powers.
  final bool installApps;
  final bool uninstallApps;
  final bool hideApps;
  final bool suspendApps;
  final bool grantOwnPermissions;
  final bool lockDevice;
  final bool rebootDevice;

  // One-time adb grants.
  final bool writeSecureSettings;
  final bool readLogs;
  final bool dumpServices;
  final bool usageStats;

  // Accessibility service.
  final bool screenRead;
  final bool screenshot;
  final bool gestures;

  // Special access.
  final bool notificationsAll;
  final bool doNotDisturb;
  final bool sms;
  final bool calls;
  final bool callScreening;
  final bool assistantRole;
  final bool overlay;
  final bool exactAlarms;
  final bool batteryUnrestricted;

  // Only a platform build can do these.
  final bool readOtherAppData;
  final bool persistentProcess;

  static const none = DeviceCapabilities();

  /// Derives capabilities from a status report. Pure, so it is testable
  /// without a phone, and the one place the "what does this grant unlock"
  /// knowledge lives.
  factory DeviceCapabilities.fromStatus(DeviceAdminStatus status) {
    final owner = status.deviceOwner;
    final platform = status.backend == DeviceBackendKind.platform;
    final accessibility = status.has(DeviceGrants.accessibility);
    return DeviceCapabilities(
      backend: status.backend,
      installApps: owner || platform,
      uninstallApps: owner || platform,
      hideApps: owner || platform,
      suspendApps: owner || platform,
      grantOwnPermissions: owner || platform,
      lockDevice: owner || status.adminActive || platform,
      rebootDevice: owner || platform,
      writeSecureSettings:
          status.has(DeviceGrants.writeSecureSettings) || platform,
      readLogs: status.has(DeviceGrants.readLogs) || platform,
      dumpServices: status.has(DeviceGrants.dump) || platform,
      usageStats: status.has(DeviceGrants.usageStats) || platform,
      screenRead: accessibility || platform,
      // AccessibilityService.takeScreenshot() arrived in Android 11.
      screenshot: (accessibility && status.sdk >= 30) || platform,
      gestures: accessibility || platform,
      notificationsAll: status.has(DeviceGrants.notificationListener) || platform,
      doNotDisturb: status.has(DeviceGrants.notificationPolicy) || platform,
      sms: status.runtimeGranted('android.permission.SEND_SMS'),
      calls: status.runtimeGranted('android.permission.CALL_PHONE'),
      callScreening: status.has(DeviceGrants.callScreeningRole),
      assistantRole: status.has(DeviceGrants.assistantRole),
      overlay: status.has(DeviceGrants.overlay) || platform,
      exactAlarms: status.has(DeviceGrants.exactAlarm) || platform,
      batteryUnrestricted:
          status.has(DeviceGrants.batteryUnrestricted) || platform,
      readOtherAppData: platform,
      persistentProcess: platform,
    );
  }

  Map<String, bool> toMap() => {
        'install_apps': installApps,
        'uninstall_apps': uninstallApps,
        'hide_apps': hideApps,
        'suspend_apps': suspendApps,
        'grant_own_permissions': grantOwnPermissions,
        'lock_device': lockDevice,
        'reboot_device': rebootDevice,
        'write_secure_settings': writeSecureSettings,
        'read_logs': readLogs,
        'dump_services': dumpServices,
        'usage_stats': usageStats,
        'screen_read': screenRead,
        'screenshot': screenshot,
        'gestures': gestures,
        'notifications_all': notificationsAll,
        'do_not_disturb': doNotDisturb,
        'sms': sms,
        'calls': calls,
        'call_screening': callScreening,
        'assistant_role': assistantRole,
        'overlay': overlay,
        'exact_alarms': exactAlarms,
        'battery_unrestricted': batteryUnrestricted,
        'read_other_app_data': readOtherAppData,
        'persistent_process': persistentProcess,
      };

  /// What the agent sees: the backend plus only the capabilities that hold,
  /// so a small model is not handed twenty-five `false`s to reason about.
  Map<String, Object?> toAgentJson() => {
        'backend': backend.name,
        'available': [
          for (final entry in toMap().entries)
            if (entry.value) entry.key,
        ],
      };

  /// Capability names that do not hold.
  List<String> get missing => [
        for (final entry in toMap().entries)
          if (!entry.value) entry.key,
      ];
}

/// The health of the phone's push connection (Google Play services' socket
/// to mtalk.google.com), as the backend can observe it.
///
/// Every FCM-driven app - Teams, Outlook, Gmail - is silent while that
/// socket is down, and on the LineageOS S8+ Play services stops reconnecting
/// after one failure until it is restarted. [PushControl] is how Exa notices
/// and repairs that; this is what it decides on.
class PushHealthStatus {
  const PushHealthStatus({
    this.available = false,
    this.reason,
    this.connected,
    this.networkValidated = false,
    this.screenOn = false,
    this.deviceOwner = false,
    this.connects,
    this.endpoint,
    this.activeNetwork,
    this.viaVpn = false,
    this.vpnApp,
    this.recent = const [],
    this.checkedAt,
  });

  /// False when the state cannot be read at all (no DUMP grant, no Play
  /// services); [reason] says why.
  final bool available;
  final String? reason;

  /// Whether Play services reports its push client connected. Null when the
  /// dump was readable but said nothing recognisable - never act on null.
  final bool? connected;

  /// The active network has internet and passed validation. A dead socket
  /// with no network is not Play services' fault.
  final bool networkValidated;
  final bool screenOn;
  final bool deviceOwner;

  /// Connections made since Play services last started.
  final int? connects;
  final String? endpoint;
  final String? activeNetwork;

  /// Play services is binding its socket to a VPN network. A split-tunnel
  /// VPN (Tailscale without an exit node) has no route to Google, so every
  /// attempt fails and a restart only rebinds to the same VPN.
  final bool viaVpn;

  /// The VPN app, when the backend can name it.
  final String? vpnApp;

  /// Play services' own last connection-log lines, for diagnostics.
  final List<String> recent;
  final DateTime? checkedAt;

  static const unavailable = PushHealthStatus(
    reason: 'Push health is only readable on the phone.',
  );

  static PushHealthStatus fromMap(Map<Object?, Object?>? m) {
    if (m == null) return unavailable;
    final checked = m['checked_at'];
    return PushHealthStatus(
      available: m['available'] == true,
      reason: m['reason'] as String?,
      connected: m['connected'] is bool ? m['connected'] as bool : null,
      networkValidated: m['network_validated'] == true,
      screenOn: m['screen_on'] == true,
      deviceOwner: m['device_owner'] == true,
      connects: (m['connects'] as num?)?.toInt(),
      endpoint: m['endpoint'] as String?,
      activeNetwork: m['active_network'] as String?,
      viaVpn: m['via_vpn'] == true,
      vpnApp: m['vpn_app'] as String?,
      recent:
          (m['recent'] as List?)?.whereType<String>().toList() ?? const [],
      checkedAt: checked is num
          ? DateTime.fromMillisecondsSinceEpoch(checked.toInt())
          : null,
    );
  }

  Map<String, Object?> toJson() => {
        'available': available,
        if (reason != null) 'reason': reason,
        'connected': connected,
        'network_validated': networkValidated,
        'screen_on': screenOn,
        if (connects != null) 'connects': connects,
        if (endpoint != null) 'endpoint': endpoint,
        if (activeNetwork != null) 'active_network': activeNetwork,
        'via_vpn': viaVpn,
        if (vpnApp != null) 'vpn_app': vpnApp,
        if (recent.isNotEmpty) 'recent': recent,
        if (checkedAt != null) 'checked_at': checkedAt!.toIso8601String(),
      };
}

/// Observing and repairing the phone's push connection.
abstract class PushControl {
  Future<PushHealthStatus> status();

  /// Restarts Google Play services - the "Force stop" a person would do,
  /// done by the Device Owner. Disruptive for a second or two, so the
  /// watchdog only does it when the socket has been dead with a working
  /// network for a while.
  Future<DeviceActionResult> restartPlayServices();

  /// Reboots the phone. The watchdog's last resort: only at night, with the
  /// screen off, and at most once a day.
  Future<DeviceActionResult> reboot();
}

/// Administrative standing and the fixes Exa can apply to it by itself.
abstract class AdminControl {
  Future<DeviceAdminStatus> status();

  /// Grants Exa every runtime permission its manifest requests (Device
  /// Owner only). Returns permission → whether the grant took.
  Future<Map<String, bool>> grantSelfRuntimePermissions();

  /// Switches Exa's notification listener on (needs WRITE_SECURE_SETTINGS).
  Future<DeviceActionResult> enableNotificationListener();

  /// Switches Exa's accessibility service on (needs WRITE_SECURE_SETTINGS).
  Future<DeviceActionResult> enableAccessibility();

  /// Opens the system page for a grant Exa cannot flip itself. [screen] is
  /// one of `assistant`, `default_apps`, `battery`, `notification_policy`,
  /// `notification_listener`, `accessibility`, `overlay`, `usage_access`,
  /// `exact_alarm`, `app_details`, `device_admin`.
  Future<DeviceActionResult> openSystemSettings(String screen);

  /// The system "ignore battery optimisations?" dialog.
  Future<DeviceActionResult> requestBatteryExemption();

  /// Gives up device ownership. The one destructive admin action; the
  /// settings screen asks for a typed confirmation before calling it.
  Future<DeviceActionResult> clearDeviceOwner();
}

/// One element in the on-screen view tree, flattened.
///
/// [id] is a per-snapshot index, not a stable platform id: it means "the
/// element at this position in the read I just did", which is exactly what a
/// follow-up tap needs and all a model can act on. Coordinates are absolute
/// screen pixels.
class ScreenElement {
  const ScreenElement({
    required this.id,
    this.text = '',
    this.desc = '',
    this.role = '',
    this.clickable = false,
    this.editable = false,
    this.scrollable = false,
    this.checked,
    this.bounds = const [0, 0, 0, 0],
  });

  final int id;

  /// The visible text of the element.
  final String text;

  /// The content description (accessibility label) when there is no text.
  final String desc;

  /// A short role, from the widget class ("Button", "EditText", "TextView").
  final String role;

  final bool clickable;
  final bool editable;
  final bool scrollable;

  /// For a checkbox/switch/toggle: its state. Null when not checkable.
  final bool? checked;

  /// Absolute screen bounds [left, top, right, bottom].
  final List<int> bounds;

  /// The centre point, for a coordinate tap.
  (int, int) get center =>
      ((bounds[0] + bounds[2]) ~/ 2, (bounds[1] + bounds[3]) ~/ 2);

  static ScreenElement fromMap(Map<Object?, Object?> m) => ScreenElement(
        id: (m['id'] as num?)?.toInt() ?? 0,
        text: m['text'] as String? ?? '',
        desc: m['desc'] as String? ?? '',
        role: m['role'] as String? ?? '',
        clickable: m['clickable'] == true,
        editable: m['editable'] == true,
        scrollable: m['scrollable'] == true,
        checked: m['checked'] is bool ? m['checked'] as bool : null,
        bounds: (m['bounds'] as List?)
                ?.map((e) => (e as num).toInt())
                .toList() ??
            const [0, 0, 0, 0],
      );

  /// One compact line for the model: the id, what it says, and only the
  /// flags that change what the model can do with it.
  Map<String, Object?> toAgentJson() => {
        'id': id,
        if (text.isNotEmpty) 'text': text,
        if (desc.isNotEmpty && desc != text) 'label': desc,
        if (role.isNotEmpty) 'role': role,
        if (clickable) 'clickable': true,
        if (editable) 'editable': true,
        if (scrollable) 'scrollable': true,
        if (checked != null) 'checked': checked,
      };
}

/// A read of what is on screen right now.
class ScreenSnapshot {
  const ScreenSnapshot({
    this.packageName = '',
    this.appLabel = '',
    this.elements = const [],
    this.available = true,
    this.unavailableReason,
  });

  /// The foreground app's package (`com.microsoft.office.outlook`).
  final String packageName;

  /// A human name for it when the backend could resolve one.
  final String appLabel;

  final List<ScreenElement> elements;

  /// False when the screen could not be read (accessibility off, secure
  /// window). Then [unavailableReason] says why.
  final bool available;
  final String? unavailableReason;

  static const unavailable = ScreenSnapshot(
    available: false,
    unavailableReason: 'Screen reading is only available on the phone with '
        "Exa's accessibility service enabled.",
  );

  static ScreenSnapshot fromMap(Map<Object?, Object?>? m) {
    if (m == null) return unavailable;
    if (m['available'] == false) {
      return ScreenSnapshot(
        available: false,
        unavailableReason: m['reason'] as String? ??
            'The screen could not be read.',
      );
    }
    return ScreenSnapshot(
      packageName: m['package'] as String? ?? '',
      appLabel: m['app'] as String? ?? '',
      elements: (m['elements'] as List?)
              ?.whereType<Map<Object?, Object?>>()
              .map(ScreenElement.fromMap)
              .toList() ??
          const [],
    );
  }

  Map<String, Object?> toAgentJson() => available
      ? {
          'app': appLabel.isNotEmpty ? appLabel : packageName,
          'package': packageName,
          'elements': [for (final e in elements) e.toAgentJson()],
        }
      : {'available': false, 'reason': unavailableReason};
}

/// A captured screen image.
class ScreenshotResult {
  const ScreenshotResult({
    this.ok = false,
    this.bytes,
    this.mediaType = 'image/png',
    this.width = 0,
    this.height = 0,
    this.error,
  });

  final bool ok;
  final List<int>? bytes;
  final String mediaType;
  final int width;
  final int height;
  final String? error;

  static const unavailable = ScreenshotResult(
    error: 'Screenshots are only available on the phone with the '
        'accessibility service enabled.',
  );
}

/// Reading and driving whatever app is on screen, through the accessibility
/// service. This is how Exa works with apps that have no API of their own -
/// Outlook, WhatsApp, a banking app: it reads the view tree as text and acts
/// through taps, swipes and typing, the same surface a person uses.
abstract class ScreenControl {
  /// The foreground app's on-screen elements as a flat, indexed list.
  Future<ScreenSnapshot> read();

  /// Taps an element from the last [read] by its id, or a raw coordinate.
  Future<DeviceActionResult> tap({int? id, int? x, int? y});

  /// A directional swipe (`up`, `down`, `left`, `right`) over the screen, or
  /// between two points when all four coordinates are given.
  Future<DeviceActionResult> swipe({
    String direction = 'up',
    int? x1,
    int? y1,
    int? x2,
    int? y2,
  });

  /// Types [text] into an editable element from the last [read].
  Future<DeviceActionResult> setText({required int id, required String text});

  /// A global action: `back`, `home`, `recents`, `notifications`,
  /// `quick_settings`, `lock`, `power`, `split_screen`.
  Future<DeviceActionResult> globalAction(String action);

  /// Brings [packageName] to the foreground (launches it if needed).
  Future<DeviceActionResult> openApp(String packageName);

  /// A PNG of the current screen.
  Future<ScreenshotResult> screenshot();
}

/// The whole device, one sub-API per area. Later stages add `apps`,
/// `settings`, `notifications`, `telephony`, `power` and `diagnostics` here;
/// each is implemented by every backend, and each tool checks [capabilities]
/// before it acts.
abstract class DeviceControl {
  AdminControl get admin;

  /// Reading and driving on-screen apps.
  ScreenControl get screen;

  /// The push connection every FCM app depends on.
  PushControl get push;

  /// What this backend can do right now. Derived from [AdminControl.status]
  /// so it reflects grants the user just made, not a cached guess.
  Future<DeviceCapabilities> capabilities();
}
