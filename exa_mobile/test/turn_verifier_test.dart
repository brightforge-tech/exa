import 'package:exa_mobile/agent/models/agent_execution_report.dart';
import 'package:exa_mobile/agent/models/synthesized_response.dart';
import 'package:exa_mobile/agent/models/tool_execution_record.dart';
import 'package:exa_mobile/agent/models/turn_contract.dart';
import 'package:exa_mobile/agent/models/verification_result.dart';
import 'package:exa_mobile/agent/services/turn_verifier.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/test_contracts.dart';

AgentExecutionReport report({
  List<String> actionsCompleted = const ['did the thing'],
  List<String> actionsFailed = const [],
  List<Map<String, dynamic>> tasksCreated = const [],
  List<Map<String, dynamic>> eventsCreated = const [],
}) =>
    AgentExecutionReport(
      originalRequest: 'request',
      toolsCalled: const ['create_task'],
      actionsCompleted: actionsCompleted,
      actionsFailed: actionsFailed,
      tasksCreated: tasksCreated,
      eventsCreated: eventsCreated,
      eventsModified: const [],
      emailDigestItems: const [],
      filesAffected: const [],
      screensCreated: const [],
      rulesChanged: const [],
      warnings: const [],
      uncertainItems: const [],
      partialFailures: const [],
    );

ToolExecutionRecord record(
  String toolName, {
  ToolExecutionStatus status = ToolExecutionStatus.success,
  String? idempotencyKey,
  bool wasDeduplicated = false,
}) =>
    ToolExecutionRecord(
      toolCallId: 'call_$toolName',
      toolName: toolName,
      domain: 'tasks',
      arguments: const {},
      status: status,
      startedAt: DateTime(2026),
      completedAt: DateTime(2026),
      idempotencyKey: idempotencyKey,
      wasDeduplicated: wasDeduplicated,
    );

void main() {
  const verifier = TurnVerifier();

  test('complete response passes', () {
    final result = verifier.verify(
      contract: testContract(
        actions: const [
          ContractAction(
              id: 'a1',
              description: 'create task',
              status: ContractItemStatus.completed),
        ],
        requiredOutputs: {ResponseOutputType.confirmation},
      ),
      report: report(tasksCreated: [
        {'id': 't1', 'title': 'Send invoice'}
      ]),
      response: const SynthesizedResponse(
        message: 'Created the task.',
        includedOutputs: {ResponseOutputType.confirmation},
        claims: [
          ResponseClaim(type: 'task_created', description: 'Send invoice'),
        ],
      ),
    );
    expect(result.passed, isTrue);
    expect(result.requiresRepair, isFalse);
    expect(result.score, 1.0);
  });

  test('missing rundown is detected and demands repair', () {
    final result = verifier.verify(
      contract: testContract(
          requiredOutputs: {ResponseOutputType.rundown}),
      report: report(),
      response: const SynthesizedResponse(
        message: 'Done!',
        includedOutputs: {},
      ),
    );
    expect(result.passed, isFalse);
    expect(result.missingOutputs, {ResponseOutputType.rundown});
    expect(result.requiresRepair, isTrue);
    expect(result.issues.map((i) => i.code), contains('missing_output'));
  });

  test('unsupported success claim is detected', () {
    final result = verifier.verify(
      contract: testContract(),
      report: report(tasksCreated: const []),
      response: const SynthesizedResponse(
        message: 'I created a task for that.',
        includedOutputs: {},
        claims: [
          ResponseClaim(type: 'task_created', description: 'phantom task'),
        ],
      ),
    );
    expect(result.unsupportedClaims, isNotEmpty);
    expect(result.requiresUserAttention, isTrue);
    expect(result.issues.map((i) => i.code), contains('unsupported_claim'));
  });

  test('claimed count above the evidence is detected', () {
    final result = verifier.verify(
      contract: testContract(),
      report: report(tasksCreated: [
        {'id': 't1', 'title': 'One'},
        {'id': 't2', 'title': 'Two'},
      ]),
      response: const SynthesizedResponse(
        message: 'I created three tasks.',
        includedOutputs: {},
        claims: [
          ResponseClaim(type: 'task_created', description: 'One'),
          ResponseClaim(type: 'task_created', description: 'Two'),
          ResponseClaim(type: 'task_created', description: 'Three'),
        ],
      ),
    );
    expect(result.issues.map((i) => i.code),
        contains('claim_count_mismatch'));
    expect(result.passed, isFalse);
  });

  test('undisclosed failure is critical', () {
    final result = verifier.verify(
      contract: testContract(),
      report: report(actionsFailed: ['send_email did not complete']),
      response: const SynthesizedResponse(
        message: 'All done, everything went great!',
        includedOutputs: {},
        includesFailureReport: false,
      ),
    );
    expect(result.passed, isFalse);
    expect(result.requiresUserAttention, isTrue);
    expect(result.issues.map((i) => i.code), contains('undisclosed_failure'));
  });

  test('disclosed failure passes the failure check', () {
    final result = verifier.verify(
      contract: testContract(),
      report: report(actionsFailed: ['send_email did not complete']),
      response: const SynthesizedResponse(
        message: 'I could not send the email - SMTP rejected the login.',
        includedOutputs: {},
        includesFailureReport: true,
      ),
    );
    expect(result.issues.map((i) => i.code),
        isNot(contains('undisclosed_failure')));
  });

  test('unresolved required action is an error', () {
    final result = verifier.verify(
      contract: testContract(
        actions: const [
          ContractAction(id: 'a1', description: 'create tasks'),
        ],
      ),
      report: report(),
      response: const SynthesizedResponse(
        message: 'Here you go.',
        includedOutputs: {},
      ),
    );
    expect(result.issues.map((i) => i.code), contains('unresolved_action'));
    expect(result.passed, isFalse);
  });

  test('duplicate idempotency key executed twice is detected', () {
    final result = verifier.verify(
      contract: testContract(),
      report: report(),
      response: const SynthesizedResponse(
        message: 'Done.',
        includedOutputs: {},
      ),
      records: [
        record('create_task', idempotencyKey: 'k1'),
        record('create_task', idempotencyKey: 'k1'),
      ],
    );
    expect(result.issues.map((i) => i.code), contains('duplicate_action'));
    expect(result.requiresUserAttention, isTrue);
  });

  test('a deduplicated repeat is NOT a duplicate action', () {
    final result = verifier.verify(
      contract: testContract(),
      report: report(),
      response: const SynthesizedResponse(
        message: 'Done.',
        includedOutputs: {},
      ),
      records: [
        record('create_task', idempotencyKey: 'k1'),
        record('create_task', idempotencyKey: 'k1', wasDeduplicated: true),
      ],
    );
    expect(
        result.issues.map((i) => i.code), isNot(contains('duplicate_action')));
  });

  test('empty response is an error', () {
    final result = verifier.verify(
      contract: testContract(),
      report: report(),
      response: const SynthesizedResponse(message: '  ', includedOutputs: {}),
    );
    expect(result.issues.map((i) => i.code), contains('empty_response'));
  });

  test('skipped verification reports itself as not performed', () {
    const skipped = VerificationResult.skipped();
    expect(skipped.performed, isFalse);
    expect(skipped.passed, isTrue);
  });
}
