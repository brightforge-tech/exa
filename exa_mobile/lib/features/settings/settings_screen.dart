import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/repositories/browser_session_repository.dart';
import '../../data/repositories/settings_repository.dart';
import '../../shared/providers.dart';
import '../../shared/theme/exa_theme.dart';
import 'ai_provider_screen.dart';
import 'pending_approvals_screen.dart';

final hasApiKeyProvider = FutureProvider.autoDispose<bool>(
    (ref) => ref.watch(settingsRepositoryProvider).hasApiKey());
final modelProvider = FutureProvider.autoDispose<String>(
    (ref) => ref.watch(settingsRepositoryProvider).getModel());

/// (events, tasks) phone-calendar sync toggles.
final calendarSyncSettingsProvider =
    FutureProvider.autoDispose<(bool, bool)>((ref) async {
  final settings = ref.watch(settingsRepositoryProvider);
  return (
    await settings.isCalendarSyncEventsEnabled(),
    await settings.isCalendarSyncTasksEnabled(),
  );
});

/// Settings row for pending approvals, with a live count badge so the user
/// is nudged toward any high-risk action Exa queued (e.g. calendar writes).
class _PendingApprovalsTile extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = ref.watch(pendingApprovalCountProvider).value ?? 0;
    return ListTile(
      leading: const Icon(Icons.verified_user_outlined),
      title: const Text('Pending approvals'),
      subtitle: const Text('Actions Exa is waiting for you to approve'),
      trailing: count == 0
          ? null
          : Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
              decoration: const BoxDecoration(
                color: ExaColors.accent,
                shape: BoxShape.circle,
              ),
              child: Text('$count',
                  style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 12)),
            ),
      onTap: () => context.go('/settings/pending'),
    );
  }
}

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hasKey = ref.watch(hasApiKeyProvider).value ?? false;
    final model =
        ref.watch(modelProvider).value ?? SettingsRepository.defaultModel;
    final provider = ref.watch(aiProviderProvider).value ??
        SettingsRepository.defaultProvider;

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Text('AI'),
          ),
          ListTile(
            leading: const Icon(Icons.hub_outlined),
            title: const Text('AI provider'),
            subtitle: Text(aiProviderLabel(provider)),
            onTap: () => context.go('/settings/ai-provider'),
          ),
          ListTile(
            leading: Icon(
              hasKey ? Icons.key : Icons.key_off,
              color: hasKey ? Colors.green : Colors.orange,
            ),
            title: const Text('Anthropic API key'),
            // Only the Anthropic key is fatal when Anthropic is the selected
            // provider; on the others it is optional (it is what rescues an
            // image turn on a text-only backend).
            subtitle: Text(hasKey
                ? 'Configured (stored in secure storage)'
                : provider == SettingsRepository.providerRemote
                    ? 'Not set - Exa cannot think without it'
                    : 'Not set - optional while ${aiProviderLabel(provider)} '
                        'is selected'),
            onTap: () => _showApiKeyDialog(context, ref),
          ),
          ListTile(
            leading: const Icon(Icons.psychology_outlined),
            title: const Text('Model'),
            subtitle: Text(model),
            onTap: () => _showModelPicker(context, ref, model),
          ),
          const Divider(),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text('Agent'),
          ),
          ListTile(
            leading: const Icon(Icons.rule),
            title: const Text('Agent behaviors'),
            subtitle:
                const Text('Rules Exa has learned - review and approve'),
            onTap: () => context.go('/settings/behaviors'),
          ),
          ListTile(
            leading: const Icon(Icons.receipt_long),
            title: const Text('Tool activity log'),
            subtitle: const Text('Every action the agent performed'),
            onTap: () => context.go('/settings/activity'),
          ),
          ListTile(
            leading: const Icon(Icons.schedule),
            title: const Text('Scheduled jobs'),
            subtitle: const Text('Daily summaries and background work'),
            onTap: () => context.go('/settings/jobs'),
          ),
          ListTile(
            leading: const Icon(Icons.history),
            title: const Text('Job history'),
            subtitle:
                const Text('Past brief runs and results, with re-run'),
            onTap: () => context.go('/settings/job-history'),
          ),
          ListTile(
            leading: const Icon(Icons.blur_on),
            title: const Text('Exa bubble'),
            subtitle: const Text(
                'Floating assistant over other apps: screen snippets, '
                'chat, voice, quick tasks - and the lock screen'),
            onTap: () => context.go('/settings/overlay'),
          ),
          ListTile(
            leading: const Icon(Icons.phone_android_outlined),
            title: const Text('Phone access'),
            subtitle: const Text(
                'Let Exa text, call and WhatsApp people for you - always '
                'confirmed, or on a schedule you set up'),
            onTap: () => context.go('/settings/phone-access'),
          ),
          ListTile(
            leading: const Icon(Icons.admin_panel_settings_outlined),
            title: const Text('Device control'),
            subtitle: const Text(
                'Device owner status, the grants Exa needs, and what it '
                'can do to the phone right now'),
            onTap: () => context.go('/settings/device'),
          ),
          ListTile(
            leading: const Icon(Icons.bolt),
            title: const Text('Background reliability'),
            subtitle: const Text(
                'Make reminders and briefs fire on time when closed'),
            onTap: () => context.go('/settings/reliability'),
          ),
          ListTile(
            leading: const Icon(Icons.shield_outlined),
            title: const Text('Agent permissions'),
            subtitle: const Text('Control what Exa is allowed to do'),
            onTap: () => context.go('/settings/permissions'),
          ),
          ListTile(
            leading: const Icon(Icons.psychology_outlined),
            title: const Text('Memory'),
            subtitle:
                const Text('Review and delete what Exa has remembered'),
            onTap: () => context.go('/settings/memory'),
          ),
          _PendingApprovalsTile(),
          const Divider(),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text('Phone calendar'),
          ),
          Builder(builder: (context) {
            final (eventsSync, tasksSync) =
                ref.watch(calendarSyncSettingsProvider).value ??
                    (false, false);
            return Column(children: [
              SwitchListTile(
                secondary: const Icon(Icons.event_available_outlined),
                title: const Text('Add events to phone calendar'),
                subtitle: const Text(
                    'New events - added by you or by Exa - also go to '
                    'your phone calendar, and edits and deletes follow'),
                value: eventsSync,
                onChanged: (value) =>
                    _setCalendarSync(context, ref, events: value),
              ),
              SwitchListTile(
                secondary: const Icon(Icons.task_alt),
                title: const Text('Add tasks to phone calendar'),
                subtitle: const Text(
                    'Tasks with a due date appear as a 30-minute block; '
                    'completing a task removes it'),
                value: tasksSync,
                onChanged: (value) =>
                    _setCalendarSync(context, ref, tasks: value),
              ),
            ]);
          }),
          const Divider(),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text('Connections'),
          ),
          ListTile(
            leading: const Icon(Icons.folder_outlined),
            title: const Text('Files'),
            subtitle:
                const Text('Files you asked Exa to keep from chat'),
            onTap: () => context.push('/files'),
          ),
          ListTile(
            leading: const Icon(Icons.link),
            title: const Text('Connected accounts'),
            onTap: () => context.go('/settings/accounts'),
          ),
          ListTile(
            leading: const Icon(Icons.mail_outline),
            title: const Text('Emails for Exa'),
            subtitle:
                const Text('Paste emails for the agent to digest'),
            onTap: () => context.go('/settings/emails'),
          ),
          ListTile(
            leading: const Icon(Icons.alternate_email),
            title: const Text('Mail accounts'),
            subtitle: const Text(
                'IMAP/SMTP accounts Exa can fetch and send from'),
            onTap: () => context.go('/settings/mail-accounts'),
          ),
          ListTile(
            leading: const Icon(Icons.forum_outlined),
            title: const Text('Chat apps'),
            subtitle: const Text(
                'Let Exa read WhatsApp and other chat messages'),
            onTap: () => context.go('/settings/chat-apps'),
          ),
          ListTile(
            leading: const Icon(Icons.cleaning_services_outlined),
            title: const Text('Clear browser data'),
            subtitle: const Text(
                'Sign out of all sites: cookies, storage, and open tabs'),
            onTap: () => _confirmClearBrowserData(context, ref),
          ),
          ListTile(
            leading: const Icon(Icons.public),
            title: const Text('Shared browser pages'),
            subtitle: const Text('Pages you sent to Exa from the browser'),
            onTap: () => context.go('/settings/browser-context'),
          ),
          const Divider(),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text('Privacy'),
          ),
          ListTile(
            leading: const Icon(Icons.privacy_tip_outlined),
            title: const Text('Privacy dashboard'),
            subtitle: const Text(
                'What Exa can access, audit log, and data export'),
            onTap: () => context.go('/settings/privacy'),
          ),
          ListTile(
            leading: const Icon(Icons.delete_forever, color: Colors.red),
            title: const Text('Clear all data'),
            subtitle: const Text(
                'Deletes tasks, reminders, chat history, and behaviors'),
            onTap: () => _confirmClearData(context, ref),
          ),
          const Divider(),
          const AboutListTile(
            icon: Icon(Icons.info_outline),
            applicationName: 'Exa the Executive Assistant',
            applicationVersion: '0.1.0',
            applicationLegalese:
                '© 2025-2026 BrightForge Technologies Limited\n\n'
                'Free software under the GNU Affero General Public '
                'License v3.0. Source code: '
                'https://github.com/brightforge-tech/exa\n\n'
                'Commercial licences and support: info@brightforgett.com',
            aboutBoxChildren: [
              SizedBox(height: 12),
              Text('Not affiliated with Exa Labs (exa.ai).',
                  style: TextStyle(color: Colors.grey)),
            ],
            child: Text('About Exa and open-source licences'),
          ),
          const SizedBox(height: 24),
          const Center(
            child: Text('Exa the Executive Assistant - 0.1.0\n'
                'by BrightForge Technologies',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey)),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  /// Persists a phone-calendar sync toggle. Switching one ON also backfills
  /// existing upcoming items right away - which is where the OS asks for
  /// calendar permission the first time.
  Future<void> _setCalendarSync(BuildContext context, WidgetRef ref,
      {bool? events, bool? tasks}) async {
    final messenger = ScaffoldMessenger.of(context);
    final settings = ref.read(settingsRepositoryProvider);
    if (events != null) {
      await settings.setCalendarSyncEventsEnabled(events);
    }
    if (tasks != null) {
      await settings.setCalendarSyncTasksEnabled(tasks);
    }
    ref.invalidate(calendarSyncSettingsProvider);
    if (!((events ?? false) || (tasks ?? false))) return;

    final calendarSync = ref.read(calendarSyncServiceProvider);
    await calendarSync.syncPending(interactive: true);
    final granted = await calendarSync.deviceCalendar.hasPermission();
    messenger.showSnackBar(SnackBar(
        content: Text(granted
            ? 'Upcoming items were added to your phone calendar.'
            : 'Calendar permission was not granted - nothing was added.')));
  }

  Future<void> _showApiKeyDialog(BuildContext context, WidgetRef ref) async {
    final controller = TextEditingController();
    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Anthropic API key'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
                'The key is stored in your device\'s secure storage and '
                'only sent to api.anthropic.com.'),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              decoration: const InputDecoration(
                hintText: 'sk-ant-...',
                border: OutlineInputBorder(),
              ),
              obscureText: true,
              autofocus: true,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              await ref
                  .read(settingsRepositoryProvider)
                  .setApiKey(null);
              if (dialogContext.mounted) {
                Navigator.pop(dialogContext, true);
              }
            },
            child: const Text('Remove key'),
          ),
          FilledButton(
            onPressed: () async {
              final key = controller.text.trim();
              if (key.isNotEmpty) {
                await ref
                    .read(settingsRepositoryProvider)
                    .setApiKey(key);
              }
              if (dialogContext.mounted) {
                Navigator.pop(dialogContext, true);
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (saved == true) ref.invalidate(hasApiKeyProvider);
  }

  Future<void> _showModelPicker(
      BuildContext context, WidgetRef ref, String current) async {
    final selected = await showDialog<String>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: const Text('AI model'),
        children: [
          for (final model in SettingsRepository.availableModels)
            RadioListTile<String>(
              value: model,
              // ignore: deprecated_member_use
              groupValue: current,
              title: Text(model),
              // ignore: deprecated_member_use
              onChanged: (value) => Navigator.pop(dialogContext, value),
            ),
        ],
      ),
    );
    if (selected != null) {
      await ref.read(settingsRepositoryProvider).setModel(selected);
      ref.invalidate(modelProvider);
    }
  }

  /// Guide §11 acceptance: "User can clear browser data."
  Future<void> _confirmClearBrowserData(
      BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('Clear browser data?'),
            content: const Text(
                'Signs you out of every website in the in-app browser '
                '(cookies and site storage) and closes all tabs. Shared '
                'pages already sent to Exa are not affected - manage '
                'those under "Shared browser pages".'),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(dialogContext, false),
                  child: const Text('Cancel')),
              FilledButton(
                  onPressed: () => Navigator.pop(dialogContext, true),
                  child: const Text('Clear')),
            ],
          ),
        ) ??
        false;
    if (!confirmed) return;
    await CookieManager.instance().deleteAllCookies();
    await InAppWebViewController.clearAllCache();
    try {
      await WebStorageManager.instance().deleteAllData();
    } catch (_) {
      // Not supported on every platform; cookies are the critical part.
    }
    await BrowserSessionRepository(ref.read(appDatabaseProvider))
        .clearAll();
    await ref
        .read(auditRepositoryProvider)
        .log('user', 'browser_data_cleared');
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Browser data cleared. Restart the app to fully '
              'reset open tabs.')));
    }
  }

  Future<void> _confirmClearData(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('Clear all data?'),
            content: const Text(
                'This permanently deletes all tasks, reminders, schedule '
                'items, chat history, screens, and agent behaviors on this '
                'device. This cannot be undone.'),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(dialogContext, false),
                  child: const Text('Cancel')),
              FilledButton(
                style: FilledButton.styleFrom(
                    backgroundColor:
                        Theme.of(dialogContext).colorScheme.error),
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('Delete everything'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed) return;
    // Remove stored files from disk before wiping the rows that point to
    // them - captured photos and voice notes included: a media sidecar no
    // row references anymore is just someone else's chat history, still
    // sitting on the storage.
    await ref.read(attachmentRepositoryProvider).clearAll();
    await ref.read(inboundMediaRepositoryProvider).clearAll();
    await ref.read(appDatabaseProvider).clearAllData();
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('All local data cleared')),
      );
    }
  }
}
