import 'package:exa_mobile/agent/models/turn_contract.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/test_contracts.dart';

void main() {
  group('ResponseOutputType', () {
    test('wire names round-trip', () {
      for (final type in ResponseOutputType.values) {
        expect(ResponseOutputType.fromWireName(type.wireName), type,
            reason: type.wireName);
      }
    });

    test('unknown response-output values are rejected', () {
      expect(ResponseOutputType.fromWireName('interpretive_dance'), isNull);
      expect(ResponseOutputType.fromWireName(''), isNull);
    });

    test('tolerates case and whitespace', () {
      expect(ResponseOutputType.fromWireName(' Task_List '),
          ResponseOutputType.taskList);
    });
  });

  group('ContractAction', () {
    test('pending and awaiting-confirmation are unresolved', () {
      const pending = ContractAction(id: 'a', description: 'do it');
      expect(pending.isResolved, isFalse);
      expect(
          pending
              .copyWith(status: ContractItemStatus.awaitingConfirmation)
              .isResolved,
          isFalse);
    });

    test('completed, failed, skipped, cancelled are resolved', () {
      const action = ContractAction(id: 'a', description: 'do it');
      for (final status in [
        ContractItemStatus.completed,
        ContractItemStatus.failed,
        ContractItemStatus.skipped,
        ContractItemStatus.cancelled,
      ]) {
        expect(action.copyWith(status: status).isResolved, isTrue,
            reason: status.wireName);
      }
    });

    test('serializes and parses round-trip', () {
      const action = ContractAction(
        id: 'act_1',
        description: 'create_tasks',
        status: ContractItemStatus.failed,
        required: true,
        expectedToolNames: ['create_task'],
        failureReason: 'boom',
      );
      final parsed = ContractAction.fromJson(action.toJson());
      expect(parsed.id, 'act_1');
      expect(parsed.status, ContractItemStatus.failed);
      expect(parsed.expectedToolNames, ['create_task']);
      expect(parsed.failureReason, 'boom');
    });
  });

  group('CompletionContract', () {
    test('actions are distinct from required outputs', () {
      final contract = testContract(
        originalRequest: 'Digest my emails and give me a rundown',
        domains: {'email', 'tasks'},
        actionLabels: ['review_emails', 'create_tasks'],
        requiredOutputs: {
          ResponseOutputType.rundown,
          ResponseOutputType.taskList,
        },
        requiresSynthesis: true,
      );
      // Completing every action must not empty the required outputs -
      // they are tracked separately by design.
      expect(contract.actionDescriptions, isNot(contains('rundown')));
      expect(contract.hasRequiredOutputs, isTrue);
      expect(contract.requiredOutputs.length, 2);
    });

    test('summary requests require synthesis', () {
      final contract = testContract(
        originalRequest: 'Summarize my day',
        domains: {'calendar'},
        actionLabels: ['review_schedule'],
        requiredOutputs: {ResponseOutputType.summary},
        requiresSynthesis: true,
      );
      expect(contract.requiresSynthesis, isTrue);
      expect(contract.hasRequiredOutputs, isTrue);
    });

    test('one-step navigation does not require synthesis', () {
      final contract = testContract(
        originalRequest: 'Open my task screen',
        actionLabels: ['open_task_screen'],
      );
      expect(contract.requiresSynthesis, isFalse);
      expect(contract.hasRequiredOutputs, isFalse);
    });

    test('consequential actions carry the confirmation flag', () {
      final contract = testContract(
        originalRequest: 'Delete all completed tasks',
        domains: {'tasks'},
        actionLabels: ['delete_completed_tasks'],
        requiredOutputs: {ResponseOutputType.confirmation},
        requiresConfirmation: true,
        requiresSynthesis: true,
      );
      expect(contract.requiresConfirmation, isTrue);
    });

    test('copyWith replaces outputs without touching the rest', () {
      final contract = testContract(
        originalRequest: 'r',
        domains: {'email'},
        actionLabels: ['a'],
        requiredOutputs: {ResponseOutputType.confirmation},
        requiresSynthesis: true,
      );
      final merged = contract.copyWith(requiredOutputs: {
        ...contract.requiredOutputs,
        ResponseOutputType.rundown,
      });
      expect(merged.requiredOutputs,
          {ResponseOutputType.confirmation, ResponseOutputType.rundown});
      expect(merged.originalRequest, 'r');
      expect(merged.requiresSynthesis, isTrue);
    });

    test('fallback contract is conservative', () {
      final contract = fallbackContract(originalRequest: 'anything');
      expect(contract.domains, isNull, reason: 'all tools exposed');
      expect(contract.actions, isEmpty);
      expect(contract.requiredOutputs, {ResponseOutputType.confirmation});
      expect(contract.requiresSynthesis, isTrue,
          reason: 'routing failure must never skip final synthesis');
      expect(contract.requiresVerification, isTrue,
          reason: 'a blind turn is still checked against its own report');
    });

    test('serializes and parses round-trip', () {
      final contract = testContract(
        originalRequest: 'Digest my emails',
        domains: {'email'},
        actionLabels: ['review_emails'],
        requiredOutputs: {ResponseOutputType.rundown},
        constraints: ['Do not create duplicate tasks'],
        requiresSynthesis: true,
        requiresVerification: true,
      );
      final parsed = CompletionContract.fromJson(contract.toJson());
      expect(parsed.id, contract.id);
      expect(parsed.agentTurnId, contract.agentTurnId);
      expect(parsed.domains, {'email'});
      expect(parsed.actions.single.description, 'review_emails');
      expect(parsed.requiredOutputs, {ResponseOutputType.rundown});
      expect(parsed.constraints, ['Do not create duplicate tasks']);
      expect(parsed.requiresVerification, isTrue);
    });
  });
}
