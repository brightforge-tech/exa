import 'package:exa_mobile/agent/models/agent_execution_report.dart';
import 'package:exa_mobile/agent/models/tool_execution_record.dart';
import 'package:exa_mobile/agent/models/turn_contract.dart';
import 'package:exa_mobile/agent/services/quiet_turn.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/test_contracts.dart';

ToolExecutionRecord record(
  String tool, {
  Object? result,
  ToolExecutionStatus status = ToolExecutionStatus.success,
  bool controlPlane = false,
}) =>
    ToolExecutionRecord(
      toolCallId: 'tc_$tool',
      toolName: tool,
      domain: 'email',
      arguments: const {},
      status: status,
      startedAt: DateTime(2026, 1, 1),
      completedAt: DateTime(2026, 1, 1),
      rawResult: result,
      isControlPlane: controlPlane,
    );

AgentExecutionReport reportFor(
  List<ToolExecutionRecord> records, {
  List<Map<String, dynamic>> tasksCreated = const [],
  List<String> failures = const [],
}) =>
    AgentExecutionReport(
      originalRequest: 'check my chats',
      toolsCalled: [
        for (final r in records)
          if (!r.isControlPlane) r.toolName,
      ],
      actionsCompleted: const ['Checked chats'],
      actionsFailed: failures,
      tasksCreated: tasksCreated,
      eventsCreated: const [],
      eventsModified: const [],
      emailDigestItems: const [],
      filesAffected: const [],
      screensCreated: const [],
      rulesChanged: const [],
      warnings: const [],
      uncertainItems: const [],
      partialFailures: const [],
    );

void main() {
  group('QuietTurn.settleUnneededActions', () {
    test('completes the actions a nothing-new run had no input for', () {
      final contract = testContract(actions: const [
        ContractAction(
            id: 'sync',
            description: 'check for new messages',
            status: ContractItemStatus.completed),
        ContractAction(id: 'extract', description: 'pull out any tasks'),
        ContractAction(id: 'mark', description: 'mark them handled'),
      ]);
      final settled = QuietTurn.settleUnneededActions(
        contract: contract,
        records: [
          record('sync_messages', result: {'new_messages': 0}),
          record('read_message_context', result: {'count': 0}),
        ],
      );
      expect(
          settled.actions
              .every((action) => action.status == ContractItemStatus.completed),
          isTrue);
    });

    test('leaves unresolved actions alone when something was read or failed',
        () {
      final contract = testContract(actions: const [
        ContractAction(id: 'extract', description: 'pull out any tasks'),
      ]);
      final readSomething = QuietTurn.settleUnneededActions(
        contract: contract,
        records: [record('read_message_context', result: {'count': 3})],
      );
      expect(readSomething.actions.single.status, ContractItemStatus.pending);

      final failed = QuietTurn.settleUnneededActions(
        contract: contract,
        records: [
          record('sync_messages', status: ToolExecutionStatus.failure),
        ],
      );
      expect(failed.actions.single.status, ContractItemStatus.pending);

      // No sync or read at all is not "nothing new" either.
      final noReads = QuietTurn.settleUnneededActions(
        contract: contract,
        records: [record('list_tasks', result: {'tasks': []})],
      );
      expect(noReads.actions.single.status, ContractItemStatus.pending);
    });
  });

  group('QuietTurn.nothingNewRead', () {
    test('every sync and read reporting zero is nothing new', () {
      expect(
        QuietTurn.nothingNewRead([
          record('sync_messages', result: {'result': 'ok', 'new_messages': 0}),
          record('read_message_context', result: {'count': 0, 'messages': []}),
          record('expand_tools', controlPlane: true),
        ]),
        isTrue,
      );
    });

    test('anything new anywhere is not quiet', () {
      expect(
        QuietTurn.nothingNewRead([
          record('sync_messages', result: {'result': 'ok', 'new_messages': 2}),
          record('read_message_context', result: {'count': 0}),
        ]),
        isFalse,
      );
      expect(
        QuietTurn.nothingNewRead([
          record('sync_emails', result: {'result': 'ok', 'new_emails': 0}),
          record('read_email_context', result: {'count': 1, 'emails': []}),
        ]),
        isFalse,
      );
    });

    test('a count the tool did not report is "we do not know", not quiet',
        () {
      // Older result shapes, or a tool outside the housekeeping set.
      expect(
        QuietTurn.nothingNewRead([
          record('sync_emails', result: {'result': 'Fetched nothing'}),
        ]),
        isFalse,
      );
      expect(
        QuietTurn.nothingNewRead([
          record('sync_messages', result: {'new_messages': 0}),
          record('list_tasks', result: {'count': 0}),
        ]),
        isFalse,
      );
    });

    test('a failed check is never quiet, and no records is not quiet', () {
      expect(
        QuietTurn.nothingNewRead([
          record('sync_messages',
              result: {'new_messages': 0},
              status: ToolExecutionStatus.failure),
        ]),
        isFalse,
      );
      expect(QuietTurn.nothingNewRead(const []), isFalse);
    });
  });

  group('QuietTurn.isQuiet', () {
    final checked = [
      record('sync_messages', result: {'result': 'ok', 'new_messages': 0}),
      record('read_message_context', result: {'count': 0, 'messages': []}),
    ];
    final contract = testContract(
      originalRequest: 'check my chats',
      actions: const [
        ContractAction(
          id: 'a1',
          description: 'sync_messages',
          status: ContractItemStatus.completed,
        ),
      ],
      requiredOutputs: {ResponseOutputType.confirmation},
    );

    test('checks that found nothing, made nothing and failed nothing', () {
      expect(
        QuietTurn.isQuiet(
          contract: contract,
          report: reportFor(checked),
          records: checked,
        ),
        isTrue,
      );
    });

    test('creating something, or a failure, or an unfinished required '
        'action, is not quiet', () {
      expect(
        QuietTurn.isQuiet(
          contract: contract,
          report: reportFor(checked, tasksCreated: const [
            {'id': 't1', 'title': 'Reply to Dana'},
          ]),
          records: checked,
        ),
        isFalse,
      );
      expect(
        QuietTurn.isQuiet(
          contract: contract,
          report: reportFor(checked, failures: const ['Could not sync']),
          records: checked,
        ),
        isFalse,
      );
      expect(
        QuietTurn.isQuiet(
          contract: testContract(
            actions: const [
              ContractAction(
                id: 'a1',
                description: 'mark_message_digested',
                status: ContractItemStatus.pending,
              ),
            ],
          ),
          report: reportFor(checked),
          records: checked,
        ),
        isFalse,
      );
    });
  });
}
