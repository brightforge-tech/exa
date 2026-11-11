import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../device/device_control.dart';
import '../../device/device_owner_backend.dart';
import '../../device/grant_catalog.dart';
import '../../services/push_watchdog/push_watchdog.dart';
import '../../shared/providers.dart';
import '../../shared/theme/exa_theme.dart';

/// Settings > Device control: Exa's standing on this phone, every grant it
/// needs with a way to fix each one, and what it can do right now.
///
/// The privilege stack on stock Android is a mix of things Exa can flip for
/// itself, things the user flips on a system page, and things only adb can
/// grant. This screen never pretends otherwise: an adb-only grant shows the
/// command to copy, not a button that does nothing.
class DeviceAdminScreen extends ConsumerStatefulWidget {
  const DeviceAdminScreen({super.key});

  @override
  ConsumerState<DeviceAdminScreen> createState() => _DeviceAdminScreenState();
}

class _DeviceAdminScreenState extends ConsumerState<DeviceAdminScreen>
    with WidgetsBindingObserver {
  DeviceAdminStatus? _status;
  DeviceCapabilities? _caps;
  PushHealthStatus? _push;
  Map<String, Object?>? _pushReport;
  bool _pushEnabled = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Coming back from a system settings page: show what changed.
    if (state == AppLifecycleState.resumed) _refresh();
  }

  AdminControl get _admin => ref.read(deviceControlProvider).admin;

  Future<void> _refresh() async {
    final status = await _admin.status();
    final watchdog = ref.read(pushWatchdogProvider);
    final push = await ref.read(deviceControlProvider).push.status();
    final report = await watchdog.lastReport();
    final enabled = await watchdog.isEnabled();
    if (!mounted) return;
    setState(() {
      _status = status;
      _caps = DeviceCapabilities.fromStatus(status);
      _push = push;
      _pushReport = report;
      _pushEnabled = enabled;
    });
  }

  Future<void> _setPushWatchdog(bool enabled) async {
    await ref.read(pushWatchdogProvider).setEnabled(enabled);
    await _refresh();
  }

  Future<void> _checkPush() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final outcome = await ref.read(pushWatchdogProvider).check();
      _say(describePushOutcome(outcome));
    } finally {
      if (mounted) setState(() => _busy = false);
      await _refresh();
    }
  }

  Future<void> _restartPlayServices() async {
    if (_busy) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Restart Google Play services?'),
        content: const Text(
            'Teams, Outlook, Gmail and the Play Store lose it for a couple '
            'of seconds and reconnect on their own. This is what Force stop '
            'in Settings does, and what the watchdog does by itself once '
            'push has been dead for ten minutes.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Restart')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    try {
      final result =
          await ref.read(deviceControlProvider).push.restartPlayServices();
      _say(result.ok
          ? 'Play services restarted.'
          : (result.error ?? 'Could not restart Play services.'));
    } finally {
      if (mounted) setState(() => _busy = false);
      await _refresh();
    }
  }

  void _say(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _fix(GrantSpec spec) async {
    final status = _status;
    if (status == null || _busy) return;
    setState(() => _busy = true);
    try {
      switch (spec.effectiveFix(status)) {
        case GrantFix.self:
          final result = await _selfFix(spec.id);
          if (!result.ok) _say(result.error ?? 'That did not work.');
        case GrantFix.hand:
          final screen = spec.settingsScreen ?? 'app_details';
          final result = await _admin.openSystemSettings(screen);
          if (!result.ok) _say(result.error ?? 'Could not open settings.');
        case GrantFix.adb:
          await _showAdbDialog(spec);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
      await _refresh();
    }
  }

  Future<DeviceActionResult> _selfFix(String id) => switch (id) {
        DeviceGrants.notificationListener =>
          _admin.enableNotificationListener(),
        DeviceGrants.accessibility => _admin.enableAccessibility(),
        DeviceGrants.batteryUnrestricted => _admin.requestBatteryExemption(),
        _ => Future.value(const DeviceActionResult(
            ok: false, error: 'Exa cannot grant this one itself.')),
      };

  Future<void> _showAdbDialog(GrantSpec spec) async {
    final command = spec.adbCommand ?? '';
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(spec.title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
                'Only adb can grant this. With the phone plugged in and USB '
                'debugging on, run:'),
            const SizedBox(height: 12),
            SelectableText(command,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
            const SizedBox(height: 12),
            const Text(
                'It survives reboots and in-place updates; only uninstalling '
                'Exa loses it.',
                style: TextStyle(color: ExaColors.textSecondary)),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: command));
              if (context.mounted) Navigator.pop(context);
              _say('Copied');
            },
            child: const Text('Copy'),
          ),
          FilledButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Done')),
        ],
      ),
    );
  }

  Future<void> _grantAllRuntime() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final outcome = await _admin.grantSelfRuntimePermissions();
      final refused = [
        for (final entry in outcome.entries)
          if (!entry.value) _shortPermission(entry.key)
      ];
      if (outcome.isEmpty) {
        _say('Exa is not the device owner, so it cannot grant these itself.');
      } else if (refused.isEmpty) {
        _say('All permissions granted.');
      } else {
        _say('Not granted: ${refused.join(', ')}');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
      await _refresh();
    }
  }

  Future<void> _confirmClearOwner() async {
    final controller = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove device owner?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
                'Exa keeps running and keeps your data, but loses every '
                'device-control power until you provision it again with adb '
                '(which means removing all accounts again). Type REMOVE to '
                'confirm.'),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              decoration: const InputDecoration(hintText: 'REMOVE'),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: ExaColors.warning),
            onPressed: () =>
                Navigator.pop(context, controller.text.trim() == 'REMOVE'),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final result = await _admin.clearDeviceOwner();
    _say(result.ok
        ? 'Exa is no longer the device owner.'
        : (result.error ?? 'Could not remove device owner.'));
    await _refresh();
  }

  static String _shortPermission(String permission) =>
      permission.split('.').last.replaceAll('_', ' ').toLowerCase();

  @override
  Widget build(BuildContext context) {
    final status = _status;
    final caps = _caps;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Device control'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: _refresh,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: status == null || caps == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
                  child: Text(
                    'Exa v3 manages this phone for you: apps, settings, the '
                    'screen, notifications, calls and texts. On a stock phone '
                    'that takes a one-time setup over adb (see '
                    'docs/PROVISION_DEVICE.md), then a few switches Exa can flip '
                    'itself. Nothing here touches your apps or data.',
                    style:
                        TextStyle(color: ExaColors.textSecondary, height: 1.4),
                  ),
                ),
                _BackendCard(status: status),
                const _SectionLabel('Grants'),
                for (final spec in GrantCatalog.entries)
                  _GrantTile(
                    spec: spec,
                    status: status,
                    busy: _busy,
                    onFix: () => _fix(spec),
                  ),
                const _SectionLabel("Exa's own permissions"),
                _RuntimeTile(
                  status: status,
                  busy: _busy,
                  onGrantAll: _grantAllRuntime,
                  onOpenSettings: () => _admin.openSystemSettings('app_details'),
                ),
                const _SectionLabel('What Exa can do now'),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final entry in caps.toMap().entries)
                        Chip(
                          avatar: Icon(
                            entry.value ? Icons.check : Icons.close,
                            size: 16,
                            color: entry.value
                                ? ExaColors.success
                                : ExaColors.textSecondary,
                          ),
                          label: Text(entry.key.replaceAll('_', ' ')),
                        ),
                    ],
                  ),
                ),
                const _SectionLabel('Push notifications'),
                _PushTile(
                  health: _push,
                  report: _pushReport,
                  enabled: _pushEnabled,
                  busy: _busy,
                  onToggle: _setPushWatchdog,
                  onCheck: _checkPush,
                  onRestart: _restartPlayServices,
                ),
                if (status.deviceOwner) ...[
                  const Divider(),
                  ListTile(
                    leading:
                        const Icon(Icons.remove_moderator_outlined,
                            color: ExaColors.warning),
                    title: const Text('Remove device owner'),
                    subtitle: const Text(
                        'Keeps Exa and its data; drops every device power'),
                    onTap: _busy ? null : _confirmClearOwner,
                  ),
                ],
                const SizedBox(height: 24),
              ],
            ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: Text(text, style: Theme.of(context).textTheme.titleSmall),
      );
}

class _BackendCard extends StatelessWidget {
  const _BackendCard({required this.status});
  final DeviceAdminStatus status;

  @override
  Widget build(BuildContext context) {
    final owner = status.deviceOwner;
    final device = [
      if (status.manufacturer.isNotEmpty) status.manufacturer,
      if (status.model.isNotEmpty) status.model,
      if (status.sdk > 0) 'API ${status.sdk}',
    ].join(' · ');
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: ListTile(
        leading: Icon(
          owner ? Icons.verified_user : Icons.gpp_maybe_outlined,
          color: owner ? ExaColors.success : ExaColors.warning,
          size: 32,
        ),
        title: Text(status.backend.label),
        subtitle: Text(owner
            ? (device.isEmpty ? 'Exa is the device owner' : device)
            : status.backend == DeviceBackendKind.none && status.sdk == 0
                ? 'Not on a phone'
                : 'Run tools/provision_device.ps1 to make Exa the device owner'),
      ),
    );
  }
}

class _GrantTile extends StatelessWidget {
  const _GrantTile({
    required this.spec,
    required this.status,
    required this.busy,
    required this.onFix,
  });

  final GrantSpec spec;
  final DeviceAdminStatus status;
  final bool busy;
  final VoidCallback onFix;

  @override
  Widget build(BuildContext context) {
    final granted = status.has(spec.id);
    final fix = spec.effectiveFix(status);
    final hint = !granted && fix == GrantFix.hand && spec.handHint != null
        ? '\n${spec.handHint}'
        : '';
    return ListTile(
      leading: Icon(
        granted ? Icons.check_circle : Icons.radio_button_unchecked,
        color: granted ? ExaColors.success : null,
      ),
      title: Text(spec.title),
      subtitle: Text('${spec.why}$hint'),
      isThreeLine: hint.isNotEmpty,
      trailing: granted
          ? null
          : FilledButton.tonal(
              onPressed: busy ? null : onFix,
              child: Text(switch (fix) {
                GrantFix.self => 'Enable',
                GrantFix.hand => 'Open',
                GrantFix.adb => 'adb',
              }),
            ),
    );
  }
}

class _RuntimeTile extends StatelessWidget {
  const _RuntimeTile({
    required this.status,
    required this.busy,
    required this.onGrantAll,
    required this.onOpenSettings,
  });

  final DeviceAdminStatus status;
  final bool busy;
  final VoidCallback onGrantAll;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final runtime = status.runtime;
    final missing = [
      for (final entry in runtime.entries)
        if (!entry.value) entry.key.split('.').last.toLowerCase()
    ];
    final allGranted = runtime.isNotEmpty && missing.isEmpty;
    return ListTile(
      leading: Icon(
        allGranted ? Icons.check_circle : Icons.radio_button_unchecked,
        color: allGranted ? ExaColors.success : null,
      ),
      title: Text('${runtime.length} runtime permissions'),
      subtitle: Text(runtime.isEmpty
          ? 'Reported by the phone'
          : allGranted
              ? 'All granted'
              : 'Missing: ${missing.join(', ')}'),
      trailing: allGranted
          ? null
          : FilledButton.tonal(
              onPressed: busy
                  ? null
                  : status.deviceOwner
                      ? onGrantAll
                      : onOpenSettings,
              child: Text(status.deviceOwner ? 'Grant all' : 'Open'),
            ),
    );
  }
}

/// One line a person can read for each watchdog outcome.
String describePushOutcome(PushWatchdogOutcome outcome) => switch (outcome) {
      PushWatchdogOutcome.disabled => 'The push watchdog is switched off.',
      PushWatchdogOutcome.unavailable =>
        'Push health cannot be read on this phone.',
      PushWatchdogOutcome.connected => 'Push is connected.',
      PushWatchdogOutcome.noNetwork => 'Push is down, and so is the network.',
      PushWatchdogOutcome.waiting => 'Push is down; watching before acting.',
      PushWatchdogOutcome.restarted =>
        'Push was dead, so Play services was restarted.',
      PushWatchdogOutcome.restartFailed =>
        'Push is dead and the restart was refused.',
      PushWatchdogOutcome.exhausted =>
        'Restarts are used up; a reboot waits for the night.',
      PushWatchdogOutcome.rebooted => 'Rebooting the phone.',
      PushWatchdogOutcome.blockedByVpn =>
        'Push is blocked by the VPN; a restart would not help.',
    };

/// The push watchdog's switch, its last reading, and the two manual actions.
class _PushTile extends StatelessWidget {
  const _PushTile({
    required this.health,
    required this.report,
    required this.enabled,
    required this.busy,
    required this.onToggle,
    required this.onCheck,
    required this.onRestart,
  });

  final PushHealthStatus? health;
  final Map<String, Object?>? report;
  final bool enabled;
  final bool busy;
  final ValueChanged<bool> onToggle;
  final VoidCallback onCheck;
  final VoidCallback onRestart;

  @override
  Widget build(BuildContext context) {
    final h = health;
    final (IconData icon, Color color, String line) = switch (h) {
      null => (Icons.hourglass_empty, ExaColors.textSecondary, 'Reading...'),
      PushHealthStatus(available: false) => (
          Icons.help_outline,
          ExaColors.textSecondary,
          h.reason ?? 'Push health cannot be read on this phone.',
        ),
      PushHealthStatus(connected: true) => (
          Icons.check_circle,
          ExaColors.success,
          'Google Play services is connected'
              '${h.connects == null ? '' : ' (${h.connects} connection'
                  '${h.connects == 1 ? '' : 's'} since it started)'}.',
        ),
      PushHealthStatus(connected: false, networkValidated: false) => (
          Icons.cloud_off,
          ExaColors.warning,
          'Not connected, and there is no working network.',
        ),
      PushHealthStatus(connected: false, viaVpn: true) => (
          Icons.vpn_lock,
          ExaColors.warning,
          'Not connected: Google Play services is routing through '
              '${h.vpnApp ?? 'a VPN'} and cannot reach Google. Restarting it '
              'does not help. In ${h.vpnApp ?? 'the VPN app'}, exclude Google '
              'Play services from the VPN, or use an exit node.',
        ),
      PushHealthStatus(connected: false) => (
          Icons.error,
          ExaColors.warning,
          'Not connected although the network is up. After ten minutes of '
              'this the watchdog restarts Play services.',
        ),
      _ => (
          Icons.help_outline,
          ExaColors.textSecondary,
          'Play services did not say whether it is connected.',
        ),
    };
    final last = _describeReport(report);
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SwitchListTile(
            secondary: Icon(icon, color: color),
            title: const Text('Push watchdog'),
            subtitle: Text(last == null ? line : '$line\n$last'),
            isThreeLine: last != null,
            value: enabled,
            onChanged: busy ? null : onToggle,
          ),
          OverflowBar(
            alignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: busy ? null : onCheck,
                child: const Text('Check now'),
              ),
              TextButton(
                onPressed: busy || h == null || !h.deviceOwner
                    ? null
                    : onRestart,
                child: const Text('Restart Play services'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  static String? _describeReport(Map<String, Object?>? r) {
    if (r == null) return null;
    final checked = DateTime.tryParse(r['checked_at'] as String? ?? '');
    final name = r['outcome'] as String?;
    if (checked == null || name == null) return null;
    final PushWatchdogOutcome outcome;
    try {
      outcome = PushWatchdogOutcome.values.byName(name);
    } catch (_) {
      return null;
    }
    final ago = DateTime.now().difference(checked);
    final when = ago.inMinutes < 1
        ? 'just now'
        : ago.inHours < 1
            ? '${ago.inMinutes} min ago'
            : ago.inDays < 1
                ? '${ago.inHours} h ago'
                : '${ago.inDays} d ago';
    final note = r['note'] as String?;
    return 'Last check $when: ${describePushOutcome(outcome)}'
        '${note == null ? '' : ' ($note)'}';
  }
}
