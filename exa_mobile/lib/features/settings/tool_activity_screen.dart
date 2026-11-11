import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../data/models/tool_call_log.dart';
import '../../shared/providers.dart';

final toolActivityProvider = FutureProvider.autoDispose<List<ToolCallLog>>(
    (ref) => ref.watch(toolCallRepositoryProvider).recent());

/// Audit trail: every tool call the agent has made, with inputs and results.
class ToolActivityScreen extends ConsumerWidget {
  const ToolActivityScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final logsAsync = ref.watch(toolActivityProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Tool activity')),
      body: logsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(child: Text('Error: $error')),
        data: (logs) {
          if (logs.isEmpty) {
            return const Center(
                child: Text('No agent activity yet.'));
          }
          return ListView.builder(
            itemCount: logs.length,
            itemBuilder: (context, index) {
              final log = logs[index];
              final success = log.status == 'success';
              if (log.toolName == 'agent_turn') {
                return _AgentTurnTile(log: log, success: success);
              }
              return ExpansionTile(
                leading: Icon(
                  success ? Icons.check_circle : Icons.error,
                  color: success ? Colors.green : Colors.red,
                ),
                title: Text(log.toolName),
                subtitle: Text(
                    '${DateFormat('MMM d, HH:mm:ss').format(log.createdAt)}'
                    ' - ${log.status}'),
                childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                expandedCrossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (log.inputJson != null) ...[
                    Text('Input',
                        style: Theme.of(context).textTheme.labelLarge),
                    SelectableText(log.inputJson!,
                        style: Theme.of(context).textTheme.bodySmall),
                    const SizedBox(height: 8),
                  ],
                  if (log.outputJson != null) ...[
                    Text('Output',
                        style: Theme.of(context).textTheme.labelLarge),
                    SelectableText(log.outputJson!,
                        style: Theme.of(context).textTheme.bodySmall),
                  ],
                  if (log.errorMessage != null) ...[
                    Text('Error',
                        style: Theme.of(context).textTheme.labelLarge),
                    SelectableText(log.errorMessage!,
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(color: Colors.red)),
                  ],
                ],
              );
            },
          );
        },
      ),
    );
  }
}

/// A readable summary of one agent turn: domains routed, required outputs,
/// synthesis/repair status, and tool counters. Operational metadata only -
/// never reasoning or chain-of-thought.
class _AgentTurnTile extends StatelessWidget {
  const _AgentTurnTile({required this.log, required this.success});

  final ToolCallLog log;
  final bool success;

  @override
  Widget build(BuildContext context) {
    Map<String, Object?> turn = const {};
    try {
      turn = (jsonDecode(log.outputJson ?? '{}') as Map)
          .cast<String, Object?>();
    } catch (_) {
      // Fall through to an empty summary.
    }
    String listOf(String key) {
      final value = turn[key];
      if (value is! List || value.isEmpty) return 'none';
      return value.join(', ');
    }

    // A turn answered by a deterministic renderer owed the user a written
    // reply and produced one - it simply did not need a model to write it.
    // Reporting that as a synthesis *failure* is both wrong and worse than
    // useless: it would hide a real failure among the routine ones.
    final rendered = turn['deterministic_render'];
    final synthesis = turn['draft_delivered'] == true
        ? 'Not needed - first answer passed its checks'
        : turn['synthesis_required'] != true
        ? 'Not required'
        : rendered is String
            ? 'Rendered in code ($rendered)'
            : (turn['synthesis_performed'] == true ? 'Completed' : 'Failed');
    final repair = turn['repair_discarded'] == true
        ? 'Set aside - the first message checked out better'
        : turn['repair_performed'] == true
        ? ((turn['missing_outputs_after_repair'] as List?)?.isEmpty ?? true
            ? 'Completed'
            : 'Incomplete')
        : 'Not required';

    final labelStyle = Theme.of(context).textTheme.labelLarge;
    final bodyStyle = Theme.of(context).textTheme.bodySmall;
    Widget line(String label, String value) => Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Text.rich(TextSpan(children: [
            TextSpan(text: '$label: ', style: labelStyle),
            TextSpan(text: value, style: bodyStyle),
          ])),
        );

    return ExpansionTile(
      leading: Icon(
        success ? Icons.route : Icons.warning_amber,
        color: success ? Colors.blueGrey : Colors.orange,
      ),
      title: const Text('Agent turn'),
      subtitle: Text(
          '${DateFormat('MMM d, HH:mm:ss').format(log.createdAt)}'
          ' - synthesis: ${synthesis.toLowerCase()}'),
      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      expandedCrossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (turn['route_source'] == 'cache')
          line('Route', 'remembered from an earlier run'),
        if (turn['route_source'] == 'given_up')
          line('Route', 'not asked for - it has failed too often lately'),
        line('Domains selected', listOf('routed_domains')),
        line('Required outputs', listOf('required_outputs')),
        line('Planned actions', listOf('planned_actions')),
        line('Tool calls',
            '${turn['user_action_tool_calls'] ?? 0} action, '
            '${turn['scope_expansion_calls'] ?? 0} expansion'),
        line('Synthesis', synthesis),
        if (turn['draft_rewritten_because'] case final String reason)
          line('First answer rewritten', _rewriteReasons[reason] ?? reason),
        line('Repair', repair),
        if (turn['repair_reasons'] case final List reasons
            when reasons.isNotEmpty)
          line(
              'Repair ran because',
              {
                for (final reason in reasons)
                  _repairReasons['$reason'] ?? '$reason',
              }.join('; ')),
        if (turn['rejected_claims'] case final List claims
            when claims.isNotEmpty)
          line('Claims with nothing behind them', claims.join('; ')),
        // Absent on turns recorded before the frame existed, so old history
        // stays readable rather than showing a row of "unknown".
        if (turn['turn_frame'] case final Map frame) ...[
          if (frame['risk'] != null)
            line('Risk', '${frame['risk']}'
                '${turn['execution_path'] == null ? '' : ' - '
                    '${turn['execution_path']} path'}'),
          if (turn['escalated'] == true)
            line('Escalated', listOf('escalation_signals')),
        ],
        if (turn['relevance'] case final Map relevance)
          line('Response relevance',
              '${relevance['supported']}/${relevance['sections']} sections '
              'on topic'),
        if (turn['memories_used'] != null)
          line('Memory',
              '${turn['memories_used']} retrieved, '
              '${turn['memories_cited'] ?? 0} used'),
        if (turn['injection_attempts_neutralized'] != null)
          line('Untrusted content',
              '${turn['injection_attempts_neutralized']} directive(s) '
              'quoted, not obeyed'),
        if (turn['scoped_writes_blocked'] != null)
          line('Writes blocked by scope', '${turn['scoped_writes_blocked']}'),
        if (log.errorMessage != null)
          Text(log.errorMessage!,
              style: bodyStyle?.copyWith(color: Colors.red)),
      ],
    );
  }
}

/// Why a turn's first answer was written again, in words.
const _rewriteReasons = {
  'too_short': 'it was too short to be the answer',
  'not_prose': 'it was not plain text',
  'escalated': 'the turn was flagged for a closer check',
  'tool_failed': 'a step failed',
  'changed_something': 'the turn changed something',
  'read_nothing': 'nothing was read',
  'has_failures': 'the turn had failures or warnings',
  'unresolved_action': 'planned work was not carried out',
  'names_a_tool': 'it named internal tools',
  'unsupported_date': 'it stated a date the turn never saw',
  'breaks_a_rule': 'it broke one of your writing rules',
};

/// What was wrong with a message that was sent for repair, in words.
const _repairReasons = {
  'missing_output': 'a required part was left out',
  'empty_response': 'the message was empty',
  'unresolved_action': 'planned work was not carried out or mentioned',
  'undisclosed_action_failure': 'a failed step was not mentioned',
  'undisclosed_failure': 'a failure was not mentioned',
  'action_claimed_without_execution': 'it claimed work that never ran',
  'duplicate_action': 'a step ran twice',
  'unsupported_claim': 'it claimed something that did not happen',
  'claim_count_mismatch': 'it claimed more than was done',
  'unsupported_date': 'it stated a date the turn never saw',
  'breaks_a_rule': 'it broke one of your writing rules',
  'off_topic': 'most of it did not answer the request',
};
