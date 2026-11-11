import 'package:exa_mobile/agent/models/agent_execution_report.dart';
import 'package:exa_mobile/agent/models/synthesized_response.dart';
import 'package:exa_mobile/agent/models/tool_execution_record.dart';
import 'package:exa_mobile/agent/services/date_consistency.dart';
import 'package:exa_mobile/agent/services/turn_verifier.dart';
import 'package:exa_mobile/data/models/agent_datetime_label.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/test_contracts.dart';

/// A model whose sense of "today" is its training cutoff will treat a
/// correctly stored future date as a mistake and restate it in the past.
/// The tool calls stay right and only the sentence is wrong, so nothing
/// else in verification catches it.
void main() {
  group('date extraction', () {
    test('reads the formats a model actually writes', () {
      expect(DateConsistency.extractDates('due Friday, August 1, 2024 at '
          '23:59'), {'2024-08-01'});
      expect(DateConsistency.extractDates('due 1 August 2024'),
          {'2024-08-01'});
      expect(DateConsistency.extractDates('due 2024-08-01'), {'2024-08-01'});
      expect(DateConsistency.extractDates('due August 1st, 2024'),
          {'2024-08-01'});
    });

    test('the same day written three ways compares equal', () {
      final message = DateConsistency.extractDates('August 1, 2024');
      final evidence =
          DateConsistency.extractDates('2024-08-01 and 1 August 2024');
      expect(message.difference(evidence), isEmpty);
    });

    test('ignores dates with no explicit year', () {
      // "due Friday" and "next week" must never be flagged - the check is
      // only about years a model invents wholesale.
      expect(DateConsistency.extractDates('due Friday, end of this week'),
          isEmpty);
      expect(DateConsistency.extractDates('on August 1'), isEmpty);
    });

    test('flags only what the evidence lacks', () {
      final unsupported = DateConsistency.unsupportedDates(
        message: 'Stored for Friday, July 31, 2026, not August 1, 2024.',
        evidence: '{"due_at_label":"Friday, July 31, 2026 at 23:59"}',
      );
      expect(unsupported, ['2024-08-01']);
    });

    test('a date the user themselves mentioned is supported', () {
      final unsupported = DateConsistency.unsupportedDates(
        message: 'The invoice from March 3, 2024 is now a task.',
        evidence: 'user asked about the invoice from March 3, 2024',
      );
      expect(unsupported, isEmpty);
    });
  });

  group('verification', () {
    ToolExecutionRecord taskRecord(DateTime dueAt) => ToolExecutionRecord(
          toolCallId: 'toolu_1',
          toolName: 'create_task',
          domain: 'tasks',
          arguments: {'title': 'Deploy report', 'due_at': dueAt.toString()},
          status: ToolExecutionStatus.success,
          startedAt: DateTime(2026, 7, 27),
          completedAt: DateTime(2026, 7, 27),
          rawResult: {
            'id': 't1',
            'title': 'Deploy report',
            'due_at': dueAt.toIso8601String(),
            'due_at_label': agentDateTimeLabel(dueAt),
          },
        );

    AgentExecutionReport reportFor(DateTime dueAt) => AgentExecutionReport(
          originalRequest: 'schedule these tasks to be completed this week',
          toolsCalled: const ['create_task'],
          actionsCompleted: const ['Created task: Deploy report'],
          actionsFailed: const [],
          partialFailures: const [],
          tasksCreated: [
            {
              'id': 't1',
              'title': 'Deploy report',
              'due_at': dueAt.toIso8601String(),
              'due_at_label': agentDateTimeLabel(dueAt),
            },
          ],
          eventsCreated: const [],
          eventsModified: const [],
          emailDigestItems: const [],
          filesAffected: const [],
          screensCreated: const [],
          rulesChanged: const [],
          warnings: const [],
          uncertainItems: const [],
        );

    test('a response that rewrites a stored date fails verification', () {
      // The exact shape of the reported bug: stored 2026, announced 2024.
      final dueAt = DateTime(2026, 7, 31, 23, 59);
      final result = const TurnVerifier().verify(
        contract: testContract(
          originalRequest: 'schedule these tasks to be completed this week',
          actionLabels: const ['create_tasks'],
        ),
        report: reportFor(dueAt),
        records: [taskRecord(dueAt)],
        response: const SynthesizedResponse(
          message: 'Failure report: due dates were incorrectly set to '
              'Friday, July 31, 2026. Rescheduled to Friday, August 1, '
              '2024 at 23:59.',
          includedOutputs: {},
          claims: [
            ResponseClaim(type: 'task_created', description: 'Deploy report'),
          ],
        ),
      );

      expect(result.fabricatedDates, ['2024-08-01']);
      expect(result.requiresRepair, isTrue);
      expect(result.issues.map((i) => i.code), contains('unsupported_date'));
      // The repair is told what to say instead.
      expect(result.authoritativeDates,
          contains('Friday, July 31, 2026 at 23:59'));
    });

    test('quoting the stored label verbatim passes', () {
      final dueAt = DateTime(2026, 7, 31, 23, 59);
      final result = const TurnVerifier().verify(
        contract: testContract(
          originalRequest: 'schedule these tasks to be completed this week',
          actionLabels: const ['create_tasks'],
        ),
        report: reportFor(dueAt),
        records: [taskRecord(dueAt)],
        response: SynthesizedResponse(
          message: 'Created "Deploy report", due '
              '${agentDateTimeLabel(dueAt)}.',
          includedOutputs: const {},
          claims: const [
            ResponseClaim(type: 'task_created', description: 'Deploy report'),
          ],
        ),
      );

      expect(result.fabricatedDates, isEmpty);
      expect(result.issues.map((i) => i.code),
          isNot(contains('unsupported_date')));
    });

    test('a relative phrasing with no explicit date is left alone', () {
      final dueAt = DateTime(2026, 7, 31, 23, 59);
      final result = const TurnVerifier().verify(
        contract: testContract(
          originalRequest: 'schedule these this week',
          actionLabels: const ['create_tasks'],
        ),
        report: reportFor(dueAt),
        records: [taskRecord(dueAt)],
        response: const SynthesizedResponse(
          message: 'All three are due at the end of this week.',
          includedOutputs: {},
        ),
      );
      expect(result.fabricatedDates, isEmpty);
    });

    test('an ISO timestamp counts as evidence for the date inside it', () {
      // Every scheduling field Exa stores is a timestamp, so this is the
      // ordinary case rather than an edge one. A trailing `\b` matched nothing
      // after the day (T is a word character), which meant a *correctly*
      // stated date could be reported as invented - a critical verification
      // issue and a wasted repair on a turn that did everything right.
      expect(DateConsistency.extractDates('due_at: 2026-08-01T23:59:00'),
          contains('2026-08-01'));
      expect(
        DateConsistency.unsupportedDates(
          message: 'That is due on August 1, 2026.',
          evidence: '{"due_at":"2026-08-01T23:59:00","status":"Open"}',
        ),
        isEmpty,
      );
    });

    test('a longer digit run is still not read as a date', () {
      expect(DateConsistency.extractDates('ref 2026-08-011'), isEmpty);
    });
  });
}
