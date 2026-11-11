import 'package:exa_mobile/agent/evaluation/evaluation_scorer.dart';
import 'package:exa_mobile/agent/evaluation/models/evaluation_scenario.dart';
import 'package:exa_mobile/agent/evaluation/models/replay_trace.dart';
import 'package:exa_mobile/agent/evaluation/regression_case_builder.dart';
import 'package:exa_mobile/agent/evaluation/replay_redaction_service.dart';
import 'package:exa_mobile/agent/evaluation/replay_tool_registry.dart';
import 'package:exa_mobile/agent/models/turn_contract.dart';
import 'package:flutter_test/flutter_test.dart';

ReplayTrace trace({
  String userRequest = 'Digest my emails from amy@example.com',
  List<Map<String, dynamic>> toolExecutions = const [],
  Map<String, dynamic> contract = const {},
  Map<String, dynamic> finalResponse = const {},
  Map<String, dynamic> verificationResult = const {'passed': true},
  Map<String, dynamic>? skillExecution,
}) =>
    ReplayTrace(
      id: 'trace_1',
      agentTurnId: 'turn_1',
      createdAt: DateTime(2026, 7, 25),
      userRequest: userRequest,
      routingResult: const {'domains': ['email', 'tasks']},
      contract: contract,
      memoriesProvided: const [],
      activeEntities: const [],
      toolExecutions: toolExecutions,
      executionReport: const {},
      finalResponse: finalResponse,
      verificationResult: verificationResult,
      modelConfiguration: const {'provider': 'remote', 'model': 'test'},
      skillExecution: skillExecution,
    );

void main() {
  group('ReplayRedactionService', () {
    const redaction = ReplayRedactionService();

    test('removes email addresses, secrets, and message bodies', () {
      final redacted = redaction.redact(trace(
        toolExecutions: [
          {
            'tool_name': 'read_email_context',
            'status': 'success',
            'raw_result': {
              'from': 'amy@example.com',
              'subject': 'Reports',
              'body': 'A very long private email body here.',
              'note': 'my key is sk-supersecret1234',
            },
          },
        ],
      ));
      expect(redacted.userRequest, isNot(contains('amy@example.com')));
      expect(redacted.userRequest, contains('[email]'));
      final raw =
          redacted.toolExecutions.single['raw_result'] as Map<String, dynamic>;
      expect(raw['from'], '[email]');
      expect(raw['body'], startsWith('[redacted'));
      expect('${raw['note']}', isNot(contains('sk-supersecret1234')));
      expect(redacted.containsSensitiveData, isFalse);
    });

    test('keeps structure, ids, and statuses intact', () {
      final redacted = redaction.redact(trace(
        toolExecutions: [
          {'tool_name': 'create_task', 'status': 'success'},
        ],
      ));
      expect(redacted.toolExecutions.single['tool_name'], 'create_task');
      expect(redacted.toolExecutions.single['status'], 'success');
    });
  });

  group('ReplayToolRegistry', () {
    test('serves mock responses in order and never touches real tools',
        () async {
      final registry = ReplayToolRegistry({
        'list_tasks': [
          {'count': 1},
          {'count': 2},
        ],
      });
      final first = await registry.execute('list_tasks', {});
      final second = await registry.execute('list_tasks', {});
      expect((first.data as Map)['count'], 1);
      expect((second.data as Map)['count'], 2);
      expect(registry.calls, hasLength(2));
      expect(registry.allConsumed, isTrue);
    });

    test('throws when a tool has no queued response', () {
      final registry = ReplayToolRegistry(const {});
      expect(() => registry.execute('create_task', {}),
          throwsA(isA<ReplayToolResponseMissing>()));
    });

    test('queued error responses become failed results', () async {
      final registry = ReplayToolRegistry({
        'sync_emails': [
          {'__error__': 'IMAP unreachable'},
        ],
      });
      final result = await registry.execute('sync_emails', {});
      expect(result.success, isFalse);
      expect(result.error, 'IMAP unreachable');
    });
  });

  group('EvaluationScorer', () {
    const scorer = EvaluationScorer();

    EvaluationScenario scenario({
      Set<String> requiredTools = const {'read_email_context'},
      Set<String> forbiddenTools = const {'delete_email'},
      Set<ResponseOutputType> requiredOutputs = const {
        ResponseOutputType.rundown,
      },
      int maximumToolCalls = 8,
      String? expectedSkill,
    }) =>
        EvaluationScenario(
          id: 'eval_1',
          name: 'digest scenario',
          userRequest: 'digest my emails',
          mockState: const {},
          expectedDomains: const {'email', 'tasks'},
          requiredTools: requiredTools,
          forbiddenTools: forbiddenTools,
          requiredOutputs: requiredOutputs,
          maximumToolCalls: maximumToolCalls,
          expectedSkill: expectedSkill,
          createdAt: DateTime(2026),
        );

    test('a compliant turn passes', () {
      final result = scorer.score(
        scenario: scenario(),
        trace: trace(
          toolExecutions: [
            {'tool_name': 'read_email_context', 'status': 'success'},
          ],
          contract: const {
            'domains': ['email', 'tasks'],
            'actions': [
              {'description': 'review', 'required': true, 'status': 'completed'},
            ],
          },
          finalResponse: const {
            'included_outputs': ['rundown'],
          },
        ),
      );
      expect(result.passed, isTrue, reason: result.failures.join('; '));
      expect(result.metrics['forbidden_tool_violations'], 0);
      expect(result.metrics['required_output_completion'], 1.0);
    });

    test('forbidden tool usage fails hard', () {
      final result = scorer.score(
        scenario: scenario(),
        trace: trace(
          toolExecutions: [
            {'tool_name': 'read_email_context', 'status': 'success'},
            {'tool_name': 'delete_email', 'status': 'success'},
          ],
          contract: const {'domains': ['email', 'tasks'], 'actions': []},
          finalResponse: const {
            'included_outputs': ['rundown'],
          },
        ),
      );
      expect(result.passed, isFalse);
      expect(result.metrics['forbidden_tool_violations'], 1);
    });

    test('missing required output is scored and reported', () {
      final result = scorer.score(
        scenario: scenario(),
        trace: trace(
          toolExecutions: [
            {'tool_name': 'read_email_context', 'status': 'success'},
          ],
          contract: const {'domains': ['email', 'tasks'], 'actions': []},
          finalResponse: const {'included_outputs': <String>[]},
        ),
      );
      expect(result.passed, isFalse);
      expect(result.metrics['required_output_completion'], 0.0);
      expect(result.failures.join(' '), contains('rundown'));
    });

    test('duplicate side-effecting calls fail the duplicate metric', () {
      final result = scorer.score(
        scenario: scenario(requiredTools: {'create_task'}),
        trace: trace(
          toolExecutions: [
            {
              'tool_name': 'create_task',
              'status': 'success',
              'idempotency_key': 'k1',
            },
            {
              'tool_name': 'create_task',
              'status': 'success',
              'idempotency_key': 'k1',
            },
          ],
          contract: const {'domains': ['email', 'tasks'], 'actions': []},
          finalResponse: const {
            'included_outputs': ['rundown'],
          },
        ),
      );
      expect(result.passed, isFalse);
      expect(result.metrics['duplicate_action_rate'], greaterThan(0));
    });

    test('skill selection is scored when expected', () {
      final result = scorer.score(
        scenario: scenario(expectedSkill: 'digest_emails'),
        trace: trace(
          toolExecutions: [
            {'tool_name': 'read_email_context', 'status': 'success'},
          ],
          contract: const {'domains': ['email', 'tasks'], 'actions': []},
          finalResponse: const {
            'included_outputs': ['rundown'],
          },
          skillExecution: const {'skill_name': 'digest_emails'},
        ),
      );
      expect(result.metrics['skill_selection'], 1.0);
    });
  });

  group('RegressionCaseBuilder', () {
    const builder = RegressionCaseBuilder();

    test('a user correction becomes a scenario with the trace\'s mocked '
        'tools and the missing output pinned', () {
      final scenario = builder.build(
        trace: trace(
          toolExecutions: [
            {
              'tool_name': 'create_task',
              'status': 'success',
              'raw_result': {'id': 't1', 'title': 'Send update'},
            },
          ],
          contract: const {
            'domains': ['email', 'tasks'],
            'required_outputs': ['task_list'],
          },
        ),
        userCorrection:
            'You created the task but did not give me the summary.',
        failureType: 'missing_required_output',
        missingOutputWireName: 'rundown',
      );
      expect(scenario.userRequest, contains('Digest my emails'));
      expect(scenario.requiredTools, contains('create_task'));
      expect(scenario.requiredOutputs,
          containsAll({ResponseOutputType.rundown, ResponseOutputType.taskList}));
      expect(scenario.mockState['create_task'], hasLength(1));
      expect(scenario.tags, contains('regression'));
      expect(scenario.sourceTraceId, 'trace_1');
    });

    test('duplicate-action corrections tighten the tool budget below the '
        'observed count', () {
      final scenario = builder.build(
        trace: trace(
          toolExecutions: [
            {'tool_name': 'create_task', 'status': 'success'},
            {'tool_name': 'create_task', 'status': 'success'},
          ],
          contract: const {'domains': ['tasks']},
        ),
        userCorrection: 'You created the task twice.',
        failureType: 'duplicate_action',
      );
      expect(scenario.maximumToolCalls, 1);
      expect(scenario.tags, contains('duplicate_action'));
    });

    test('feedback payload matches the spec shape', () {
      final payload = builder.feedbackPayload(
        failureType: 'missing_required_output',
        userCorrection: 'You forgot the summary.',
        originalTurnId: 'turn_123',
        missingOutputWireName: 'rundown',
      );
      expect(payload, {
        'failure_type': 'missing_required_output',
        'missing_output': 'rundown',
        'original_turn_id': 'turn_123',
        'user_correction': 'You forgot the summary.',
      });
    });
  });
}
