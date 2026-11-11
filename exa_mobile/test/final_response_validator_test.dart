import 'package:exa_mobile/agent/models/agent_execution_report.dart';
import 'package:exa_mobile/agent/models/synthesized_response.dart';
import 'package:exa_mobile/agent/models/turn_contract.dart';
import 'package:exa_mobile/agent/services/final_response_validator.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/test_contracts.dart';

CompletionContract contract(Set<ResponseOutputType> outputs) => testContract(
      domains: const {'email'},
      requiredOutputs: outputs,
      requiresSynthesis: true,
    );

AgentExecutionReport report({List<String> actionsFailed = const []}) =>
    AgentExecutionReport(
      originalRequest: 'request',
      toolsCalled: const [],
      actionsCompleted: const [],
      actionsFailed: actionsFailed,
      tasksCreated: const [],
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
  const validator = FinalResponseValidator();

  test('complete response passes', () {
    final result = validator.validate(
      contract: contract(
          {ResponseOutputType.rundown, ResponseOutputType.taskList}),
      report: report(),
      response: const SynthesizedResponse(
        message: 'I reviewed 12 emails and created two tasks.',
        includedOutputs: {
          ResponseOutputType.rundown,
          ResponseOutputType.taskList,
        },
      ),
    );
    expect(result.isValid, isTrue);
    expect(result.missingOutputs, isEmpty);
  });

  test('missing rundown fails', () {
    final result = validator.validate(
      contract: contract(
          {ResponseOutputType.rundown, ResponseOutputType.taskList}),
      report: report(),
      response: const SynthesizedResponse(
        message: 'I created two tasks.',
        includedOutputs: {ResponseOutputType.taskList},
      ),
    );
    expect(result.isValid, isFalse);
    expect(result.missingOutputs, {ResponseOutputType.rundown});
  });

  test('missing task list fails', () {
    final result = validator.validate(
      contract: contract(
          {ResponseOutputType.rundown, ResponseOutputType.taskList}),
      report: report(),
      response: const SynthesizedResponse(
        message: 'Here is the rundown.',
        includedOutputs: {ResponseOutputType.rundown},
      ),
    );
    expect(result.isValid, isFalse);
    expect(result.missingOutputs, {ResponseOutputType.taskList});
  });

  test('empty response fails with every output missing', () {
    final result = validator.validate(
      contract: contract({ResponseOutputType.rundown}),
      report: report(),
      response: const SynthesizedResponse(
        message: '   ',
        includedOutputs: {ResponseOutputType.rundown},
      ),
    );
    expect(result.isValid, isFalse);
    expect(result.missingOutputs, {ResponseOutputType.rundown});
  });

  test('extra outputs are allowed', () {
    final result = validator.validate(
      contract: contract({ResponseOutputType.confirmation}),
      report: report(),
      response: const SynthesizedResponse(
        message: 'Done, and here is a bonus rundown too.',
        includedOutputs: {
          ResponseOutputType.confirmation,
          ResponseOutputType.rundown,
          ResponseOutputType.attentionItems,
        },
      ),
    );
    expect(result.isValid, isTrue);
  });

  test('failed actions do not require false success claims', () {
    // A turn with failures still validates as long as the required outputs
    // are covered - the failure report IS the honest content.
    final result = validator.validate(
      contract: contract({ResponseOutputType.failureReport}),
      report: report(actionsFailed: ['create_task did not complete']),
      response: const SynthesizedResponse(
        message: 'I could not create the task: the title was missing.',
        includedOutputs: {ResponseOutputType.failureReport},
      ),
    );
    expect(result.isValid, isTrue);
  });
}
