import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../data/models/agent_behavior.dart';
import '../../shared/providers.dart';

final behaviorsProvider = FutureProvider.autoDispose<List<AgentBehavior>>(
    (ref) => ref.watch(behaviorRepositoryProvider).listAll());
final pendingRequestsProvider =
    FutureProvider.autoDispose<List<BehaviorChangeRequest>>(
        (ref) => ref.watch(behaviorRepositoryProvider).listPendingRequests());

/// The user's window into the self-writing behavior layer: review pending
/// proposals, pause/resume/delete rules, and inspect version history.
class BehaviorsScreen extends ConsumerWidget {
  const BehaviorsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final behaviors = ref.watch(behaviorsProvider).value ?? const [];
    final pending = ref.watch(pendingRequestsProvider).value ?? const [];

    return Scaffold(
      appBar: AppBar(title: const Text('Agent behaviors')),
      body: behaviors.isEmpty && pending.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'Exa has not learned any behaviors yet.\n\nAs you chat, '
                  'Exa can save rules about how you like things done. '
                  'They will appear here for review.',
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : ListView(
              children: [
                if (pending.isNotEmpty) ...[
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
                    child: Text('Waiting for your approval'),
                  ),
                  for (final request in pending)
                    Card(
                      margin: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 4),
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(request.proposedTitle,
                                      style: Theme.of(context)
                                          .textTheme
                                          .titleMedium),
                                ),
                                Chip(
                                  label: Text(request.riskLevel),
                                  visualDensity: VisualDensity.compact,
                                ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            Text(request.proposedRuleText),
                            if (request.reason != null) ...[
                              const SizedBox(height: 4),
                              Text('Why: ${request.reason}',
                                  style: Theme.of(context)
                                      .textTheme
                                      .bodySmall),
                            ],
                            const SizedBox(height: 8),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.end,
                              children: [
                                TextButton(
                                  onPressed: () async {
                                    await ref
                                        .read(behaviorRepositoryProvider)
                                        .rejectChangeRequest(request.id);
                                    ref.invalidate(
                                        pendingRequestsProvider);
                                  },
                                  child: const Text('Reject'),
                                ),
                                const SizedBox(width: 8),
                                FilledButton(
                                  onPressed: () async {
                                    await ref
                                        .read(behaviorRepositoryProvider)
                                        .approveChangeRequest(request.id);
                                    ref
                                      ..invalidate(pendingRequestsProvider)
                                      ..invalidate(behaviorsProvider);
                                  },
                                  child: const Text('Approve'),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
                if (behaviors.isNotEmpty)
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
                    child: Text('Saved rules'),
                  ),
                for (final behavior in behaviors)
                  _BehaviorTile(behavior: behavior),
              ],
            ),
    );
  }
}

class _BehaviorTile extends ConsumerWidget {
  const _BehaviorTile({required this.behavior});

  final AgentBehavior behavior;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isActive = behavior.status == 'Active';
    final isExpired = behavior.isExpired;
    return ExpansionTile(
      leading: Icon(
        isExpired
            ? Icons.timer_off_outlined
            : (isActive
                ? Icons.play_circle_outline
                : Icons.pause_circle_outline),
        color: isExpired
            ? Colors.orange
            : (isActive ? Colors.green : Colors.grey),
      ),
      title: Text(behavior.title),
      subtitle: Text([
        behavior.behaviorType,
        isExpired ? 'Expired' : behavior.status,
        // Where a rule came from decides how much it is trusted when two
        // rules disagree, so it is worth showing.
        if (behavior.source == 'inferred') 'learned from your habits',
        if (behavior.source == 'explicit') 'you asked for this',
        if (behavior.expiresAt != null && !isExpired)
          'until ${DateFormat('MMM d').format(behavior.expiresAt!)}',
      ].join(' - ')),
      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      expandedCrossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(behavior.ruleText),
        // Rules with parameters are enforced by the app itself, not just
        // followed by the agent - worth saying, since the difference is
        // invisible in the rule text.
        if (behavior.params.isNotEmpty) ...[
          const SizedBox(height: 6),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.lock_outline, size: 14),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Enforced by Exa: ${_describeParams(behavior.params)}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ],
          ),
        ],
        const SizedBox(height: 8),
        Row(
          children: [
            TextButton.icon(
              icon: Icon(isActive ? Icons.pause : Icons.play_arrow,
                  size: 18),
              label: Text(isActive ? 'Pause' : 'Activate'),
              onPressed: () async {
                await ref
                    .read(behaviorRepositoryProvider)
                    .setStatus(behavior.id, isActive ? 'Paused' : 'Active');
                ref.invalidate(behaviorsProvider);
              },
            ),
            TextButton.icon(
              icon: const Icon(Icons.edit_outlined, size: 18),
              label: const Text('Edit'),
              onPressed: () => _editRule(context, ref),
            ),
            TextButton.icon(
              icon: const Icon(Icons.history, size: 18),
              label: const Text('History'),
              onPressed: () => _showHistory(context, ref),
            ),
            TextButton.icon(
              icon: const Icon(Icons.delete_outline, size: 18),
              label: const Text('Delete'),
              onPressed: () async {
                final confirmed = await showDialog<bool>(
                      context: context,
                      builder: (dialogContext) => AlertDialog(
                        title: const Text('Delete behavior?'),
                        content: Text(behavior.title),
                        actions: [
                          TextButton(
                              onPressed: () =>
                                  Navigator.pop(dialogContext, false),
                              child: const Text('Cancel')),
                          FilledButton(
                              onPressed: () =>
                                  Navigator.pop(dialogContext, true),
                              child: const Text('Delete')),
                        ],
                      ),
                    ) ??
                    false;
                if (!confirmed) return;
                await ref
                    .read(behaviorRepositoryProvider)
                    .delete(behavior.id);
                ref.invalidate(behaviorsProvider);
              },
            ),
          ],
        ),
      ],
    );
  }

  /// Plain-language summary of the settings the app acts on, so the user can
  /// see what a typed rule actually does. Unknown keys are listed as-is
  /// rather than hidden.
  static String _describeParams(Map<String, Object?> params) {
    final parts = <String>[];
    for (final entry in params.entries) {
      switch (entry.key) {
        case 'trigger':
          final trigger = entry.value;
          if (trigger is Map) {
            final on = switch (trigger['on']) {
              'new_mail' => 'when new mail arrives',
              _ => 'on ${trigger['on']}',
            };
            final action = switch (trigger['action']) {
              'digest' => 'digest it',
              _ => '${trigger['action']}',
            };
            final every = trigger['min_interval_minutes'];
            parts.add('$on, $action'
                '${every == null ? '' : ' (at most every $every min)'}');
          }
        case 'quiet_hours':
          final quiet = entry.value;
          if (quiet is Map) {
            final scope = quiet['include_timed_alerts'] == true
                ? 'all alerts'
                : 'briefings';
            parts.add('quiet hours ${quiet['from']}-${quiet['to']} '
                '($scope)');
          }
        case 'default_lead_minutes':
          parts.add('new events notify ${entry.value} min ahead');
        case 'default_duration_minutes':
          parts.add('new events last ${entry.value} min');
        default:
          parts.add('${entry.key}: ${entry.value}');
      }
    }
    return parts.join(' · ');
  }

  Future<void> _editRule(BuildContext context, WidgetRef ref) async {
    final controller = TextEditingController(text: behavior.ruleText);
    final newText = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Edit: ${behavior.title}'),
        content: TextField(
          controller: controller,
          maxLines: 6,
          decoration: const InputDecoration(border: OutlineInputBorder()),
          autofocus: true,
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () =>
                  Navigator.pop(dialogContext, controller.text.trim()),
              child: const Text('Save')),
        ],
      ),
    );
    if (newText == null ||
        newText.isEmpty ||
        newText == behavior.ruleText) {
      return;
    }
    await ref.read(behaviorRepositoryProvider).updateRuleText(
          behavior.id,
          newText,
          changeReason: 'Edited by user',
          changedBy: 'user',
        );
    ref.invalidate(behaviorsProvider);
  }

  Future<void> _showHistory(BuildContext context, WidgetRef ref) async {
    final versions = await ref
        .read(behaviorRepositoryProvider)
        .listVersions(behavior.id);
    if (!context.mounted) return;
    await showModalBottomSheet(
      context: context,
      builder: (sheetContext) => ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Version history',
              style: Theme.of(sheetContext).textTheme.titleLarge),
          const SizedBox(height: 8),
          for (final version in versions.reversed)
            ListTile(
              leading: CircleAvatar(
                radius: 14,
                child: Text('${version['version_number']}'),
              ),
              title: Text(version['rule_text'] as String),
              subtitle: Text([
                if (version['change_reason'] != null)
                  version['change_reason'] as String,
                'by ${version['changed_by']}',
              ].join(' - ')),
              trailing: version == versions.last
                  ? null
                  : TextButton(
                      child: const Text('Restore'),
                      onPressed: () async {
                        await ref
                            .read(behaviorRepositoryProvider)
                            .rollbackToVersion(
                              behavior.id,
                              version['version_number'] as int,
                            );
                        ref.invalidate(behaviorsProvider);
                        if (sheetContext.mounted) {
                          Navigator.pop(sheetContext);
                        }
                      },
                    ),
            ),
        ],
      ),
    );
  }
}
