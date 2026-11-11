import 'package:exa_mobile/agent/services/contract_action_resolver.dart';
import 'package:exa_mobile/agent/services/idempotency_service.dart';
import 'package:exa_mobile/agent/models/tool_execution_record.dart';
import 'package:exa_mobile/agent/models/turn_contract.dart';
import 'package:exa_mobile/data/database/app_database.dart';
import 'package:exa_mobile/data/repositories/idempotency_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('IdempotencyService', () {
    const service = IdempotencyService();

    test('identical calls produce identical keys regardless of argument '
        'order', () {
      final a = service.buildKey(
        agentTurnId: 'turn_1',
        toolName: 'create_task',
        arguments: {'title': 'Send invoice', 'priority': 'High'},
      );
      final b = service.buildKey(
        agentTurnId: 'turn_1',
        toolName: 'create_task',
        arguments: {'priority': 'High', 'title': 'Send invoice'},
      );
      expect(a, b);
    });

    test('different turns, tools, arguments, or targets change the key', () {
      final base = service.buildKey(
        agentTurnId: 'turn_1',
        toolName: 'create_task',
        arguments: {'title': 'x'},
      );
      expect(
          service.buildKey(
              agentTurnId: 'turn_2',
              toolName: 'create_task',
              arguments: {'title': 'x'}),
          isNot(base));
      expect(
          service.buildKey(
              agentTurnId: 'turn_1',
              toolName: 'update_task',
              arguments: {'title': 'x'}),
          isNot(base));
      expect(
          service.buildKey(
              agentTurnId: 'turn_1',
              toolName: 'create_task',
              arguments: {'title': 'y'}),
          isNot(base));
      expect(
          service.buildKey(
              agentTurnId: 'turn_1',
              toolName: 'create_task',
              arguments: {'title': 'x'},
              targetEntityId: 'task_9'),
          isNot(base));
    });

    test('side-effecting verbs are keyed; reads and syncs are not', () {
      expect(service.isSideEffecting('create_task'), isTrue);
      expect(service.isSideEffecting('delete_email'), isTrue);
      expect(service.isSideEffecting('send_email'), isTrue);
      expect(service.isSideEffecting('mark_email_digested'), isTrue);
      expect(service.isSideEffecting('list_tasks'), isFalse);
      expect(service.isSideEffecting('read_email_context'), isFalse);
      expect(service.isSideEffecting('search'), isFalse);
      expect(service.isSideEffecting('sync_emails'), isFalse,
          reason: 'syncs are safe to repeat');
    });
  });

  group('IdempotencyRepository', () {
    late AppDatabase database;
    late IdempotencyRepository repository;

    setUp(() async {
      database = AppDatabase();
      await database.open(overridePath: inMemoryDatabasePath);
      repository = IdempotencyRepository(database);
    });

    tearDown(() => database.close());

    test('records a success once and finds it', () async {
      await repository.recordSuccess(
        key: 'k1',
        agentTurnId: 'turn_1',
        toolName: 'create_task',
        resultJson: '{"id": "t1"}',
      );
      // A second record with the same key is ignored, not an error.
      await repository.recordSuccess(
        key: 'k1',
        agentTurnId: 'turn_1',
        toolName: 'create_task',
        resultJson: '{"id": "t2"}',
      );
      final found = await repository.findSuccessful('k1');
      expect(found, isNotNull);
      expect(found!.resultJson, '{"id": "t1"}');
      expect(await repository.findSuccessful('other'), isNull);
    });
  });

  group('ContractActionResolver', () {
    // A realistic slice of the registry: enough for "send an email" to map
    // onto send_email, and enough near-misses sharing the token `email` that
    // the verb gate has to do real work.
    const knownTools = {
      'create_task', 'update_task', 'complete_task', 'delete_task',
      'create_reminder', 'cancel_reminder', 'send_email', 'sync_emails',
      'read_email_context', 'mark_email_digested', 'create_schedule_event',
      'open_screen', 'search',
    };

    List<ContractAction> resolve({
      required List<ContractAction> actions,
      required List<ToolExecutionRecord> records,
      Set<String> tools = knownTools,
    }) =>
        const ContractActionResolver().resolve(
          actions: actions,
          records: records,
          knownToolNames: tools,
        );

    ToolExecutionRecord record(String toolName,
            {ToolExecutionStatus status = ToolExecutionStatus.success,
            String? error,
            String? summary}) =>
        ToolExecutionRecord(
          toolCallId: 'c_$toolName',
          toolName: toolName,
          domain: 'tasks',
          arguments: const {},
          status: status,
          errorMessage: error,
          summary: summary,
          startedAt: DateTime(2026),
          completedAt: DateTime(2026),
        );

    test('expected tool names resolve directly', () {
      final resolved = resolve(
        actions: const [
          ContractAction(
              id: 'a',
              description: 'whatever label',
              expectedToolNames: ['create_task']),
        ],
        records: [record('create_task')],
      );
      expect(resolved.single.status, ContractItemStatus.completed);
    });

    test('token overlap matches create_tasks to create_task', () {
      final resolved = resolve(
        actions: const [
          ContractAction(id: 'a', description: 'create_tasks'),
        ],
        records: [record('create_task')],
      );
      expect(resolved.single.status, ContractItemStatus.completed);
    });

    test('a matching failed record marks the action failed with a reason',
        () {
      final resolved = resolve(
        actions: const [
          ContractAction(id: 'a', description: 'send_email'),
        ],
        records: [
          record('send_email',
              status: ToolExecutionStatus.failure, error: 'SMTP down'),
        ],
      );
      expect(resolved.single.status, ContractItemStatus.failed);
      expect(resolved.single.failureReason, 'SMTP down');
    });

    test('a denied matching record marks the action cancelled', () {
      final resolved = resolve(
        actions: const [
          ContractAction(id: 'a', description: 'delete_task'),
        ],
        records: [record('delete_task', status: ToolExecutionStatus.denied)],
      );
      expect(resolved.single.status, ContractItemStatus.cancelled);
    });

    test('no-tool turns resolve conversational actions as completed', () {
      final resolved = resolve(
        actions: const [
          ContractAction(id: 'a', description: 'answer_question'),
        ],
        records: const [],
      );
      expect(resolved.single.status, ContractItemStatus.completed);
    });

    test('an unmatched action on a mixed turn stays pending for the '
        'verifier to flag', () {
      final resolved = resolve(
        actions: const [
          ContractAction(id: 'a', description: 'reticulate splines'),
        ],
        records: [
          record('create_task'),
          record('send_email', status: ToolExecutionStatus.failure),
        ],
      );
      expect(resolved.single.status, ContractItemStatus.pending);
    });

    test('a second required action with no evidence stays pending even when '
        'the turn was otherwise clean', () {
      // The failure this rule exists for: only the task was created, and the
      // turn used to report itself as having done both.
      final resolved = resolve(
        actions: const [
          ContractAction(id: 'a', description: 'create a task'),
          ContractAction(id: 'b', description: 'draft a reply to John'),
        ],
        records: [record('create_task')],
      );
      expect(resolved.first.status, ContractItemStatus.completed);
      expect(resolved.last.status, ContractItemStatus.pending,
          reason: 'create_task is already evidence for the first action, so '
              'there is nothing left to absorb the second');
    });

    test('a differently-phrased label is absorbed by spare successful work',
        () {
      // The leniency the capacity rule preserves: "review_emails" names no
      // tool, but the turn really did read mail, and read_email_context is
      // not accounted for by anything else.
      final resolved = resolve(
        actions: const [
          ContractAction(id: 'a', description: 'create_tasks'),
          ContractAction(id: 'b', description: 'review_emails'),
        ],
        records: [
          record('create_task'),
          record('read_email_context'),
          record('sync_emails'),
        ],
      );
      expect(resolved.map((a) => a.status),
          everyElement(ContractItemStatus.completed));
    });

    test('reading mail is not evidence for sending it', () {
      // Bare token overlap matched these on `email` alone, so a request to
      // send resolved as completed off a sync/read call.
      for (final tool in ['sync_emails', 'read_email_context']) {
        final resolved = resolve(
          actions: const [
            ContractAction(id: 'a', description: 'send an email to John'),
            ContractAction(id: 'b', description: 'create a task'),
          ],
          records: [record(tool), record('create_task')],
        );
        expect(resolved.first.status, ContractItemStatus.pending,
            reason: '$tool must not satisfy "send an email"');
      }
    });

    test('optional actions do not consume the absorption credit a required '
        'action needs', () {
      final resolved = resolve(
        actions: const [
          ContractAction(id: 'a', description: 'tidy up afterwards',
              required: false),
          ContractAction(id: 'b', description: 'reticulate splines'),
        ],
        records: [record('create_task')],
      );
      expect(resolved.first.status, ContractItemStatus.completed);
      expect(resolved.last.status, ContractItemStatus.completed,
          reason: 'the one spare success must still be available to the '
              'required action');
    });

    test('two identical successful calls are two pieces of evidence', () {
      final resolved = resolve(
        actions: const [
          ContractAction(id: 'a', description: 'create_task'),
          ContractAction(id: 'b', description: 'something else entirely'),
        ],
        records: [
          record('create_task'),
          ToolExecutionRecord(
            toolCallId: 'c_create_task_2',
            toolName: 'create_task',
            domain: 'tasks',
            arguments: const {},
            status: ToolExecutionStatus.success,
            startedAt: DateTime(2026),
            completedAt: DateTime(2026),
          ),
        ],
      );
      // Both records match action "create_task" by name, so neither is spare
      // and the unrelated action has nothing behind it.
      expect(resolved.first.status, ContractItemStatus.completed);
      expect(resolved.last.status, ContractItemStatus.pending);
    });
  });
}
