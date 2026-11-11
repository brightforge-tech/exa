import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/autonomy_level.dart';
import '../../shared/providers.dart';
import '../../shared/theme/exa_theme.dart';

/// Human-readable labels for each permission group used by tools.
const _permissionLabels = <String, String>{
  'tasks.read': 'Read your tasks',
  'tasks.write': 'Create and edit tasks',
  'reminders.read': 'Read your reminders',
  'reminders.write': 'Create and edit reminders',
  'schedule.read': 'Read your schedule',
  'schedule.write': 'Create and edit schedule events',
  'screens.open': 'Navigate you to screens',
  'screens.create': 'Create dynamic screens',
  'behaviors.read': 'Read its own behavior rules',
  'behaviors.write': 'Save and propose behavior rules',
  'jobs.read': 'Read scheduled jobs',
  'jobs.create': 'Create and manage scheduled jobs',
  'jobs.run': 'Run scheduled jobs on demand',
  'browser.read_context': 'Read pages you shared from the browser',
  'email.read': 'Read and fetch emails (added or via mail accounts)',
  'email.write': 'Mark added emails digested / delete them',
  'email.send': 'Send email through your mail account',
  'calendar.read': 'Import events from your device calendar',
  'calendar.write': 'Add events to your phone calendar',
  'messages.send': 'Reply in your chat apps and send WhatsApp messages',
  'phone.read': 'Look up numbers in your contacts',
  'phone.sms': 'Send text messages from your number',
  'phone.call': 'Make phone calls',
  'screen.read': 'Read what is on screen in any app',
  'screen.control': 'Tap, type and swipe in your apps for you',
};

final _permissionStateProvider =
    FutureProvider.autoDispose<Map<String, bool>>((ref) async {
  final settings = ref.watch(settingsRepositoryProvider);
  final registry = ref.watch(toolRegistryProvider);
  final permissions =
      registry.all.map((tool) => tool.permission).toSet().toList()..sort();
  return {
    for (final permission in permissions)
      permission: await settings.isPermissionEnabled(permission),
  };
});

final _autonomyProvider = FutureProvider.autoDispose<AutonomyLevel>(
    (ref) => ref.watch(settingsRepositoryProvider).getAutonomyLevel());

/// Autonomy level and per-group permission switches.
///
/// Full autonomy (the v3 default) means no confirmation prompts and the
/// group switches not applied - every action is still logged. Guarded is
/// v2's behaviour: consequential tools ask first, and a disabled group
/// blocks every tool in it at the registry level with the agent told why.
class PermissionsScreen extends ConsumerWidget {
  const PermissionsScreen({super.key});

  Future<void> _setAutonomy(WidgetRef ref, AutonomyLevel level) async {
    await ref.read(settingsRepositoryProvider).setAutonomyLevel(level);
    await ref.read(auditRepositoryProvider).log(
      'user',
      level.isFull ? 'autonomy_full' : 'autonomy_guarded',
    );
    ref.invalidate(_autonomyProvider);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stateAsync = ref.watch(_permissionStateProvider);
    final autonomy =
        ref.watch(_autonomyProvider).value ?? AutonomyLevel.full;
    final full = autonomy.isFull;

    return Scaffold(
      appBar: AppBar(title: const Text('Agent permissions')),
      body: stateAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(child: Text('Error: $error')),
        data: (permissions) => ListView(
          children: [
            SwitchListTile(
              secondary: Icon(
                full ? Icons.bolt : Icons.verified_user_outlined,
                color: full ? ExaColors.warning : ExaColors.success,
              ),
              title: const Text('Fully autonomous'),
              subtitle: Text(full
                  ? 'Exa acts without asking: no confirmation prompts, the '
                      'switches below not applied. Everything it does is in '
                      'the activity log.'
                  : 'Off: Exa asks before sending, deleting or changing its '
                      'own rules, scheduled runs stay to local work, and the '
                      'switches below are enforced.'),
              isThreeLine: true,
              value: full,
              onChanged: (enabled) => _setAutonomy(
                  ref, enabled ? AutonomyLevel.full : AutonomyLevel.guarded),
            ),
            const Divider(),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                full
                    ? 'These switches are kept but not applied while Exa is '
                        'fully autonomous. Turn that off to enforce them.'
                    : 'Switch off anything Exa should not be able to do. '
                        'Blocked tool calls are rejected and logged.',
                style: TextStyle(
                    color: full ? ExaColors.textSecondary : null),
              ),
            ),
            for (final entry in permissions.entries)
              SwitchListTile(
                title: Text(_permissionLabels[entry.key] ?? entry.key),
                subtitle: Text(entry.key),
                value: entry.value,
                onChanged: (enabled) async {
                  await ref
                      .read(settingsRepositoryProvider)
                      .setPermissionEnabled(entry.key, enabled);
                  await ref.read(auditRepositoryProvider).log(
                    'user',
                    enabled ? 'permission_enabled' : 'permission_disabled',
                    detail: {'permission': entry.key},
                  );
                  ref.invalidate(_permissionStateProvider);
                },
              ),
          ],
        ),
      ),
    );
  }
}
