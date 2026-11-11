import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../shared/providers.dart';

class _PrivacyStats {
  final int toolCalls;
  final int behaviors;
  final int sharedPages;
  final int emails;
  final int accounts;
  final int auditEntries;
  const _PrivacyStats({
    required this.toolCalls,
    required this.behaviors,
    required this.sharedPages,
    required this.emails,
    required this.accounts,
    required this.auditEntries,
  });
}

final _statsProvider =
    FutureProvider.autoDispose<_PrivacyStats>((ref) async {
  final db = ref.watch(appDatabaseProvider).db;
  Future<int> count(String table) async =>
      ((await db.rawQuery('SELECT COUNT(*) AS c FROM $table'))
          .first['c'] as int?) ??
      0;
  return _PrivacyStats(
    toolCalls: await count('tool_calls'),
    behaviors: await count('agent_behaviors'),
    sharedPages: await count('browser_context_items'),
    emails: await count('email_items'),
    accounts: await count('connected_accounts'),
    auditEntries: await count('audit_logs'),
  );
});

/// Privacy dashboard (Phase 7): what Exa can see, what it has done, and
/// the controls to export or erase everything.
class PrivacyScreen extends ConsumerWidget {
  const PrivacyScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stats = ref.watch(_statsProvider).value;

    return Scaffold(
      appBar: AppBar(title: const Text('Privacy dashboard')),
      body: ListView(
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Text('What Exa can access'),
          ),
          const ListTile(
            leading: Icon(Icons.storage),
            title: Text('Local data only'),
            subtitle: Text(
                'Tasks, reminders, schedule, and chat live in an on-device '
                'SQLite database. Nothing syncs to a server.'),
          ),
          const ListTile(
            leading: Icon(Icons.cloud_upload_outlined),
            title: Text('What leaves the device'),
            subtitle: Text(
                'Your chat messages, task/reminder/schedule data the agent '
                'reads, emails you added for digestion, and browser pages '
                'you explicitly shared are sent to api.anthropic.com when '
                'you talk to Exa. The API key is stored in secure '
                'storage.'),
          ),
          if (stats != null)
            ListTile(
              leading: const Icon(Icons.insights),
              title: const Text('Current footprint'),
              subtitle: Text(
                  '${stats.toolCalls} tool calls logged - '
                  '${stats.behaviors} behavior rules - '
                  '${stats.sharedPages} shared pages - '
                  '${stats.emails} added emails - '
                  '${stats.accounts} connected accounts - '
                  '${stats.auditEntries} audit entries'),
            ),
          const Divider(),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text('Controls'),
          ),
          ListTile(
            leading: const Icon(Icons.shield_outlined),
            title: const Text('Agent permissions'),
            onTap: () => context.go('/settings/permissions'),
          ),
          ListTile(
            leading: const Icon(Icons.receipt_long),
            title: const Text('Tool activity log'),
            onTap: () => context.go('/settings/activity'),
          ),
          ListTile(
            leading: const Icon(Icons.history_edu),
            title: const Text('Audit log'),
            onTap: () => context.go('/settings/audit'),
          ),
          ListTile(
            leading: const Icon(Icons.public),
            title: const Text('Shared browser pages'),
            onTap: () => context.go('/settings/browser-context'),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.download),
            title: const Text('Export my data'),
            subtitle: const Text('Everything as a JSON file you can keep'),
            onTap: () => _exportData(context, ref),
          ),
        ],
      ),
    );
  }

  Future<void> _exportData(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    final db = ref.read(appDatabaseProvider).db;
    const tables = [
      'tasks',
      'reminders',
      'schedule_items',
      'dynamic_screens',
      'scheduled_jobs',
      'job_runs',
      'tool_calls',
      'browser_context_items',
      'email_items',
      'connected_accounts',
      'agent_behaviors',
      'agent_behavior_versions',
      'behavior_change_requests',
      'chat_messages',
      'audit_logs',
    ];
    final export = <String, Object?>{
      'app': 'Exa Mobile Assistant',
      'exported_at': DateTime.now().toIso8601String(),
    };
    for (final table in tables) {
      export[table] = await db.query(table);
    }

    final directory = await getTemporaryDirectory();
    final stamp =
        DateFormat('yyyyMMdd-HHmmss').format(DateTime.now());
    final file = File('${directory.path}/exa-export-$stamp.json');
    await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert(export));

    await ref
        .read(auditRepositoryProvider)
        .log('user', 'data_exported', detail: {'file': file.path});

    final result = await Share.shareXFiles(
      [XFile(file.path, mimeType: 'application/json')],
      subject: 'Exa data export',
    );
    if (result.status == ShareResultStatus.dismissed) {
      messenger.showSnackBar(
          SnackBar(content: Text('Export saved to ${file.path}')));
    }
  }
}
