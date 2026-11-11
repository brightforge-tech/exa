import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../shared/providers.dart';

final _auditProvider =
    FutureProvider.autoDispose<List<Map<String, Object?>>>(
        (ref) => ref.watch(auditRepositoryProvider).recent());

/// App-level audit trail: permission toggles, behavior decisions, data
/// operations, browser sharing, account changes.
class AuditScreen extends ConsumerWidget {
  const AuditScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entriesAsync = ref.watch(_auditProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Audit log')),
      body: entriesAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(child: Text('Error: $error')),
        data: (entries) {
          if (entries.isEmpty) {
            return const Center(child: Text('No audit entries yet.'));
          }
          return ListView.builder(
            itemCount: entries.length,
            itemBuilder: (context, index) {
              final entry = entries[index];
              final createdAt = DateTime.tryParse(
                      entry['created_at'] as String? ?? '') ??
                  DateTime.now();
              return ListTile(
                dense: true,
                leading: Icon(
                  switch (entry['action']) {
                    'permission_disabled' => Icons.block,
                    'permission_enabled' => Icons.check_circle_outline,
                    'browser_page_shared' => Icons.public,
                    'data_exported' => Icons.download,
                    'browser_context_cleared' ||
                    'data_cleared' =>
                      Icons.delete_outline,
                    _ => Icons.history,
                  },
                  size: 20,
                ),
                title: Text(entry['action'] as String? ?? ''),
                subtitle: Text([
                  DateFormat('MMM d, HH:mm:ss').format(createdAt),
                  'by ${entry['actor']}',
                  if (entry['detail_json'] != null)
                    entry['detail_json'] as String,
                ].join(' - ')),
              );
            },
          );
        },
      ),
    );
  }
}
