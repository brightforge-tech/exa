import 'package:exa_mobile/agent/memory/conversation_capsule.dart';
import 'package:exa_mobile/agent/memory/memory_lifecycle.dart';
import 'package:exa_mobile/agent/memory/memory_repository.dart';
import 'package:exa_mobile/agent/memory/memory_retriever.dart';
import 'package:exa_mobile/agent/memory/memory_write_policy.dart';
import 'package:exa_mobile/agent/memory/models/agent_memory.dart';
import 'package:exa_mobile/agent/memory/models/memory_candidate.dart';
import 'package:exa_mobile/agent/models/agent_execution_report.dart';
import 'package:exa_mobile/agent/models/agent_ids.dart';
import 'package:exa_mobile/agent/models/turn_contract.dart';
import 'package:exa_mobile/agent/orchestrator/turn_frame.dart';
import 'package:exa_mobile/data/database/app_database.dart';
import 'package:exa_mobile/data/database/write_coordinator.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late AppDatabase database;

  setUp(() async {
    database = AppDatabase();
    await database.open(overridePath: inMemoryDatabasePath);
  });

  tearDown(() async => database.close());

  group('memory provenance', () {
    test('model speculation can never become memory', () {
      const policy = MemoryWritePolicy();
      final speculated = MemoryCandidate(
        type: AgentMemoryType.semantic,
        content: 'The user probably prefers morning meetings.',
        reason: 'the model said so',
        importance: 0.9,
        confidence: 0.95,
        entityIds: const [],
        sourceType: 'model',
        sourceId: 'turn_1',
        provenance: MemoryProvenance.modelSpeculation,
      );
      // High scores must not buy their way past provenance.
      expect(policy.evaluate(speculated), MemoryWriteDecision.reject);
    });

    test('a stated fact and a derived one are stored differently', () async {
      final memories = MemoryRepository(database);
      final stated = await memories.insert(
        type: AgentMemoryType.semantic,
        content: 'I always send invoices on Fridays',
        importance: 0.8,
        confidence: 1,
        sourceType: 'conversation',
        sourceId: 'turn_1',
        kind: MemoryKind.explicitPreference,
        provenance: MemoryProvenance.userStatement,
      );
      final derived = await memories.insert(
        type: AgentMemoryType.episodic,
        content: 'Created 3 tasks from email',
        importance: 0.5,
        confidence: 0.9,
        sourceType: 'agent_turn',
        sourceId: 'turn_1',
      );
      final reloadedStated = await memories.getById(stated.id);
      final reloadedDerived = await memories.getById(derived.id);
      expect(reloadedStated!.provenance, MemoryProvenance.userStatement);
      expect(reloadedStated.kind, MemoryKind.explicitPreference);
      expect(reloadedDerived!.provenance,
          MemoryProvenance.deterministicInference);
    });

    test('an inferred preference is not durable until reinforced', () async {
      final memories = MemoryRepository(database);
      final inferred = await memories.insert(
        type: AgentMemoryType.procedural,
        content: 'Prefers short summaries',
        importance: 0.6,
        confidence: 0.6,
        sourceType: 'agent_turn',
        sourceId: 'turn_1',
        kind: MemoryKind.inferredPreference,
      );
      expect(inferred.isDurable, isFalse);
      await memories.reinforce(inferred.id);
      await memories.reinforce(inferred.id);
      final reloaded = await memories.getById(inferred.id);
      expect(reloaded!.reinforcementCount, 3);
      expect(reloaded.isDurable, isTrue);
    });

    test('temporary state gets a validity window even without one', () {
      final candidate = MemoryLifecycle.withValidityWindow(MemoryCandidate(
        type: AgentMemoryType.working,
        content: 'Working from home today',
        reason: 'test',
        importance: 0.5,
        confidence: 0.9,
        entityIds: const [],
        sourceType: 'conversation',
        sourceId: 'turn_1',
        kind: MemoryKind.temporaryWorkingState,
        observedAt: DateTime(2026, 7, 27),
      ));
      expect(candidate.validUntil, DateTime(2026, 7, 28));
    });
  });

  group('corrections', () {
    test('a correction supersedes rather than accumulates', () async {
      final memories = MemoryRepository(database);
      final lifecycle = MemoryLifecycle(memories);
      final original = await memories.insert(
        type: AgentMemoryType.semantic,
        content: 'The planning meeting is on Thursday',
        importance: 0.7,
        confidence: 0.9,
        sourceType: 'conversation',
        sourceId: 'turn_1',
        topicScope: 'topic_meetings',
      );

      final outcome = await lifecycle.applyCorrection(
        userText: 'No, the planning meeting is on Friday',
        agentTurnId: 'turn_2',
        topicId: 'topic_meetings',
      );

      expect(outcome.detected, isTrue);
      expect(outcome.supersededMemoryId, original.id);

      final reloaded = await memories.getById(original.id);
      expect(reloaded!.isContradicted, isTrue);
      expect(reloaded.confidence, lessThanOrEqualTo(0.15));

      final correction = await memories.getById(outcome.correctionMemoryId!);
      expect(correction!.kind, MemoryKind.correction);
      expect(correction.supersedesMemoryId, original.id);
      expect(correction.provenance, MemoryProvenance.userStatement);
    });

    test('an ordinary message is not treated as a correction', () async {
      final lifecycle = MemoryLifecycle(MemoryRepository(database));
      final outcome = await lifecycle.applyCorrection(
        userText: 'What is on my schedule tomorrow?',
        agentTurnId: 'turn_2',
      );
      expect(outcome.detected, isFalse);
    });

    test('a correction with nothing close enough supersedes nothing',
        () async {
      final memories = MemoryRepository(database);
      await memories.insert(
        type: AgentMemoryType.semantic,
        content: 'The user drives a blue estate car',
        importance: 0.5,
        confidence: 0.8,
        sourceType: 'conversation',
        sourceId: 'turn_1',
      );
      final outcome = await MemoryLifecycle(memories).applyCorrection(
        userText: 'No, the quarterly budget spreadsheet lives in Drive',
        agentTurnId: 'turn_2',
      );
      expect(outcome.detected, isTrue);
      expect(outcome.supersededMemoryId, isNull);
    });
  });

  group('retrieval pipeline', () {
    test('a contradicted memory is buried, not surfaced', () async {
      final memories = MemoryRepository(database);
      final stale = await memories.insert(
        type: AgentMemoryType.semantic,
        content: 'The planning meeting is on Thursday',
        importance: 0.8,
        confidence: 0.9,
        sourceType: 'conversation',
        sourceId: 'turn_1',
      );
      final fresh = await memories.insert(
        type: AgentMemoryType.semantic,
        content: 'The planning meeting is on Friday',
        importance: 0.8,
        confidence: 1,
        sourceType: 'user_correction',
        sourceId: 'turn_2',
        kind: MemoryKind.correction,
        provenance: MemoryProvenance.userStatement,
      );
      await memories.markContradicted(stale.id, fresh.id);

      final result = await MemoryRetriever(memories).retrieve(
        request: 'when is the planning meeting',
      );
      final ids = result.memories.map((m) => m.id).toList();
      expect(ids, contains(fresh.id));
      if (ids.contains(stale.id)) {
        expect(ids.indexOf(fresh.id), lessThan(ids.indexOf(stale.id)));
      }
    });

    test('returning nothing is a valid outcome', () async {
      final memories = MemoryRepository(database);
      await memories.insert(
        type: AgentMemoryType.semantic,
        content: 'Prefers oat milk in coffee',
        importance: 0.4,
        confidence: 0.5,
        sourceType: 'conversation',
        sourceId: 'turn_1',
      );
      final result = await MemoryRetriever(memories).retrieve(
        request: 'compile the quarterly revenue projection spreadsheet',
      );
      expect(result.isEmpty, isTrue);
      expect(result.suppressedCount, greaterThan(0));
    });

    test('a memory outside the request time scope is filtered out', () async {
      final memories = MemoryRepository(database);
      await memories.insert(
        type: AgentMemoryType.episodic,
        content: 'Reviewed the invoice backlog thoroughly',
        importance: 0.7,
        confidence: 0.9,
        sourceType: 'agent_turn',
        sourceId: 'turn_old',
        observedAt: DateTime.now().subtract(const Duration(days: 40)),
      );

      const builder = TurnFrameBuilder();
      final frame = builder.build(
        userText: 'what did I do with the invoice backlog today',
      );
      expect(frame.timeScope, isNotNull);

      final result = await MemoryRetriever(memories)
          .retrieve(request: frame.primaryGoal, frame: frame);
      expect(result.isEmpty, isTrue);
    });

    test('a standing preference is never filtered by a time scope', () async {
      final memories = MemoryRepository(database);
      await memories.insert(
        type: AgentMemoryType.semantic,
        content: 'Invoice reviews should always list overdue items first',
        importance: 0.8,
        confidence: 1,
        sourceType: 'conversation',
        sourceId: 'turn_1',
        kind: MemoryKind.explicitPreference,
        provenance: MemoryProvenance.userStatement,
        observedAt: DateTime.now().subtract(const Duration(days: 200)),
      );
      const builder = TurnFrameBuilder();
      final frame =
          builder.build(userText: 'run the invoice review for today');
      final result = await MemoryRetriever(memories)
          .retrieve(request: 'invoice review', frame: frame);
      expect(result.memories, hasLength(1));
    });

    test('scoring records why each memory was chosen', () async {
      final memories = MemoryRepository(database);
      await memories.insert(
        type: AgentMemoryType.semantic,
        content: 'The invoice application replaces the Power App',
        importance: 0.8,
        confidence: 0.9,
        sourceType: 'conversation',
        sourceId: 'turn_1',
        provenance: MemoryProvenance.userStatement,
      );
      final result = await MemoryRetriever(memories)
          .retrieve(request: 'invoice application status');
      expect(result.scored, isNotEmpty);
      expect(result.scored.first.components.keys, contains('lexical'));
    });
  });

  group('conversation capsules', () {
    test('a capsule accumulates decisions and is invalidated by a '
        'correction', () async {
      final capsules = ConversationCapsuleRepository(database);
      final report = AgentExecutionReport(
        originalRequest: 'build the invoice app',
        toolsCalled: const [],
        actionsCompleted: const ['Created task Draft schema'],
        actionsFailed: const [],
        tasksCreated: const [
          {'id': 'task_1', 'title': 'Draft schema'},
        ],
        eventsCreated: const [],
        eventsModified: const [],
        emailDigestItems: const [],
        filesAffected: const [],
        screensCreated: const [],
        rulesChanged: const [],
        warnings: const [],
        uncertainItems: const ['Which database?'],
        partialFailures: const [],
      );
      final contract = CompletionContract(
        id: AgentId.contract(),
        agentTurnId: 'turn_1',
        originalRequest: 'build the invoice app',
        domains: const {'tasks'},
        actions: const [],
        requiredOutputs: const {},
        constraints: const ['.NET only'],
        requiresConfirmation: false,
        requiresSynthesis: true,
        requiresVerification: false,
        createdAt: DateTime.now(),
      );

      for (var i = 0; i < 3; i++) {
        await capsules.recordTurn(
          conversationId: 'main',
          topicId: 'topic_invoice',
          contract: contract,
          report: report,
          entityIds: const ['task_1'],
        );
      }

      final capsule = await capsules.forTopic(
          conversationId: 'main', topicId: 'topic_invoice');
      expect(capsule, isNotNull);
      expect(capsule!.turnCount, 3);
      expect(capsule.currentConstraints, contains('.NET only'));
      expect(capsule.unresolvedQuestions, contains('Which database?'));
      // Deduplicated: the same action three times is one fact.
      expect(capsule.completedActions, hasLength(1));
      expect(capsule.evidenceRefs, contains('task_1'));
      expect(capsule.render(), contains('generated_summary'));

      await capsules.invalidate(
          conversationId: 'main', topicId: 'topic_invoice');
      expect(
        await capsules.forTopic(
            conversationId: 'main', topicId: 'topic_invoice'),
        isNull,
      );
    });
  });

  group('database hardening', () {
    test('the database reports healthy after opening', () async {
      expect(database.health?.isHealthy, isTrue);
    });

    test('a critical write commits both rows or neither', () async {
      await database.criticalWrite((txn) async {
        await txn.insert('tool_calls', {
          'id': 'tc_1',
          'tool_name': 'create_task',
          'status': 'success',
          'created_at': DateTime.now().toIso8601String(),
        });
        await txn.insert('idempotency_records', {
          'key': 'k1',
          'agent_turn_id': 'turn_1',
          'tool_name': 'create_task',
          'result_json': '{}',
          'created_at': DateTime.now().toIso8601String(),
        });
      });
      expect((await database.db.query('tool_calls')).length, 1);
      expect((await database.db.query('idempotency_records')).length, 1);

      await expectLater(
        database.criticalWrite((txn) async {
          await txn.insert('tool_calls', {
            'id': 'tc_2',
            'tool_name': 'create_task',
            'status': 'success',
            'created_at': DateTime.now().toIso8601String(),
          });
          // Duplicate primary key: the whole transaction must roll back.
          await txn.insert('idempotency_records', {
            'key': 'k1',
            'agent_turn_id': 'turn_2',
            'tool_name': 'create_task',
            'result_json': '{}',
            'created_at': DateTime.now().toIso8601String(),
          });
        }),
        throwsA(anything),
      );
      expect((await database.db.query('tool_calls')).length, 1);
    });

    test('only lock contention is treated as retryable', () {
      expect(WriteCoordinator.isTransient(StateError('nope')), isFalse);
    });

    test('writes are serialized within an isolate', () async {
      final coordinator = WriteCoordinator();
      final order = <int>[];
      final futures = [
        for (var i = 0; i < 5; i++)
          coordinator.write(() async {
            await Future<void>.delayed(Duration(milliseconds: 5 - i));
            order.add(i);
          }),
      ];
      await Future.wait(futures);
      expect(order, [0, 1, 2, 3, 4]);
      expect(coordinator.writeCount, 5);
    });
  });
}
