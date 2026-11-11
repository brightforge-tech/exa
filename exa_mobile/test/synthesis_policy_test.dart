import 'package:exa_mobile/agent/models/agent_execution_report.dart';
import 'package:exa_mobile/agent/models/turn_contract.dart';
import 'package:exa_mobile/agent/services/synthesis_policy.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/test_contracts.dart';

CompletionContract contract({
  Set<ResponseOutputType> outputs = const {},
  bool requiresSynthesis = false,
}) =>
    testContract(
      requiredOutputs: outputs,
      requiresSynthesis: requiresSynthesis,
    );

AgentExecutionReport report({
  List<String> actionsFailed = const [],
  List<Map<String, dynamic>> tasksCreated = const [],
  List<String> warnings = const [],
}) =>
    AgentExecutionReport(
      originalRequest: 'request',
      toolsCalled: const [],
      actionsCompleted: const [],
      actionsFailed: actionsFailed,
      tasksCreated: tasksCreated,
      eventsCreated: const [],
      eventsModified: const [],
      emailDigestItems: const [],
      filesAffected: const [],
      screensCreated: const [],
      rulesChanged: const [],
      warnings: warnings,
      uncertainItems: const [],
      partialFailures: const [],
    );

void main() {
  const policy = SynthesisPolicy();

  test('one navigation tool -> false', () {
    expect(
        policy.requiresSynthesis(
          contract: contract(),
          report: report(),
          toolCallCount: 1,
          domainCount: 1,
        ),
        isFalse);
  });

  test('one task creation -> true', () {
    expect(
        policy.requiresSynthesis(
          contract: contract(),
          report: report(tasksCreated: [
            {'id': 'task_1', 'title': 'Buy milk'}
          ]),
          toolCallCount: 1,
          domainCount: 1,
        ),
        isTrue);
  });

  test('multiple tool calls -> true', () {
    expect(
        policy.requiresSynthesis(
          contract: contract(),
          report: report(),
          toolCallCount: 2,
          domainCount: 1,
        ),
        isTrue);
  });

  test('multiple domains -> true', () {
    expect(
        policy.requiresSynthesis(
          contract: contract(),
          report: report(),
          toolCallCount: 1,
          domainCount: 2,
        ),
        isTrue);
  });

  test('warnings -> true', () {
    expect(
        policy.requiresSynthesis(
          contract: contract(),
          report: report(warnings: ['One email had no date']),
          toolCallCount: 1,
          domainCount: 1,
        ),
        isTrue);
  });

  test('required summary -> true', () {
    expect(
        policy.requiresSynthesis(
          contract: contract(outputs: {ResponseOutputType.summary}),
          report: report(),
          toolCallCount: 0,
          domainCount: 0,
        ),
        isTrue);
  });

  test('failed action -> true', () {
    expect(
        policy.requiresSynthesis(
          contract: contract(),
          report: report(actionsFailed: ['create_task did not complete']),
          toolCallCount: 1,
          domainCount: 1,
        ),
        isTrue);
  });

  test('contract flag alone -> true', () {
    expect(
        policy.requiresSynthesis(
          contract: contract(requiresSynthesis: true),
          report: report(),
          toolCallCount: 0,
          domainCount: 0,
        ),
        isTrue);
  });
}
