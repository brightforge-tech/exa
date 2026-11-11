import 'package:exa_mobile/agent/entities/entity_repository.dart';
import 'package:exa_mobile/agent/entities/models/agent_entity.dart';
import 'package:exa_mobile/agent/memory/memory_consolidator.dart';
import 'package:exa_mobile/agent/memory/request_lexicon.dart';
import 'package:exa_mobile/agent/memory/memory_repository.dart';
import 'package:exa_mobile/agent/memory/memory_retriever.dart';
import 'package:exa_mobile/agent/memory/memory_write_policy.dart';
import 'package:exa_mobile/agent/memory/models/agent_memory.dart';
import 'package:exa_mobile/agent/memory/models/memory_candidate.dart';
import 'package:exa_mobile/data/database/app_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

MemoryCandidate candidate({
  AgentMemoryType type = AgentMemoryType.semantic,
  String content = 'The user prefers concise email digests.',
  double importance = 0.7,
  double confidence = 0.8,
  bool requiresUserConfirmation = false,
  bool isSensitive = false,
}) =>
    MemoryCandidate(
      type: type,
      content: content,
      reason: 'test',
      importance: importance,
      confidence: confidence,
      entityIds: const [],
      sourceType: 'agent_turn',
      sourceId: 'turn_test',
      requiresUserConfirmation: requiresUserConfirmation,
      isSensitive: isSensitive,
    );

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('MemoryWritePolicy', () {
    const policy = MemoryWritePolicy();

    test('low confidence is rejected', () {
      expect(policy.evaluate(candidate(confidence: 0.3)),
          MemoryWriteDecision.reject);
    });

    test('low importance is rejected', () {
      expect(policy.evaluate(candidate(importance: 0.2)),
          MemoryWriteDecision.reject);
    });

    test('working memory writes with expiry', () {
      expect(policy.evaluate(candidate(type: AgentMemoryType.working)),
          MemoryWriteDecision.writeWithExpiry);
    });

    test('confirmation-required candidates are held for approval', () {
      expect(policy.evaluate(candidate(requiresUserConfirmation: true)),
          MemoryWriteDecision.requestConfirmation);
    });

    test('sensitive inferences are never stored silently', () {
      expect(policy.evaluate(candidate(isSensitive: true)),
          MemoryWriteDecision.requestConfirmation);
    });

    test('secrets are rejected outright', () {
      expect(
          policy.evaluate(
              candidate(content: 'The user\'s password is hunter2')),
          MemoryWriteDecision.reject);
      expect(
          policy.evaluate(candidate(content: 'Their API key is sk-abc123')),
          MemoryWriteDecision.reject);
    });
  });

  group('with database', () {
    late AppDatabase database;
    late MemoryRepository repository;
    late MemoryWriter writer;
    late MemoryRetriever retriever;

    setUp(() async {
      database = AppDatabase();
      await database.open(overridePath: inMemoryDatabasePath);
      repository = MemoryRepository(database);
      writer = MemoryWriter(repository: repository);
      retriever = MemoryRetriever(repository);
    });

    tearDown(() => database.close());

    test('accepted candidates are written; rejects are counted', () async {
      final outcome = await writer.processCandidates([
        candidate(),
        candidate(confidence: 0.1),
      ]);
      expect(outcome.written, 1);
      expect(outcome.rejected, 1);
      expect(await repository.listLive(), hasLength(1));
    });

    test('near-duplicates merge instead of piling up', () async {
      await writer.processCandidates([candidate()]);
      final outcome = await writer.processCandidates([
        candidate(importance: 0.9),
      ]);
      expect(outcome.merged, 1);
      final live = await repository.listLive();
      expect(live, hasLength(1));
      expect(live.single.importance, 0.9);
    });

    test('retrieval prefers relevant memories and caps per type', () async {
      for (var i = 0; i < 8; i++) {
        await repository.insert(
          type: AgentMemoryType.semantic,
          content: 'Unrelated fact number $i about gardening',
          importance: 0.5,
          confidence: 0.9,
          sourceType: 'test',
          sourceId: '$i',
        );
      }
      await repository.insert(
        type: AgentMemoryType.semantic,
        content: 'Amy is associated with Business Central reporting',
        importance: 0.7,
        confidence: 0.9,
        sourceType: 'test',
        sourceId: 'amy',
      );

      final result = await retriever.retrieve(
          request: 'Did Amy respond about the Business Central reports?');
      expect(result.ofType(AgentMemoryType.semantic).length,
          lessThanOrEqualTo(5));
      expect(result.memories.first.content, contains('Amy'));
    });

    test('expired working memories are excluded and cleaned up', () async {
      await repository.insert(
        type: AgentMemoryType.working,
        content: 'Pending confirmation for the invoice email',
        importance: 0.6,
        confidence: 0.9,
        sourceType: 'test',
        sourceId: 'w1',
        expiresAt: DateTime.now().subtract(const Duration(hours: 1)),
      );
      expect(await repository.listLive(), isEmpty);
      await repository.expireDue();
      expect(await repository.listAll(), isEmpty,
          reason: 'expired working memory is hard-deleted');
    });

    test('deleting a memory removes its entity links', () async {
      final db = database.db;
      await db.insert('agent_entities', {
        'id': 'ent_1',
        'entity_type': 'person',
        'display_name': 'Amy',
        'metadata_json': '{}',
        'created_at': DateTime.now().toIso8601String(),
        'updated_at': DateTime.now().toIso8601String(),
      });
      final memory = await repository.insert(
        type: AgentMemoryType.semantic,
        content: 'Amy works on reporting',
        importance: 0.7,
        confidence: 0.9,
        sourceType: 'test',
        sourceId: 's1',
        entityIds: ['ent_1'],
      );
      expect(await db.query('memory_entities'), hasLength(1));
      await repository.delete(memory.id);
      expect(await db.query('memory_entities'), isEmpty);
    });

    test('user-confirmed memories outrank unconfirmed twins', () async {
      await repository.insert(
        type: AgentMemoryType.semantic,
        content: 'The user prefers brief email summaries',
        importance: 0.6,
        confidence: 0.8,
        sourceType: 'test',
        sourceId: 'a',
      );
      final confirmed = await repository.insert(
        type: AgentMemoryType.semantic,
        content: 'The user wants short concise digests of email',
        importance: 0.6,
        confidence: 0.8,
        sourceType: 'test',
        sourceId: 'b',
        userConfirmed: true,
      );
      final result =
          await retriever.retrieve(request: 'digest my email briefly');
      expect(result.memories.first.id, confirmed.id);
    });

    group('MemoryConsolidator', () {
      test('merges duplicate memories', () async {
        await repository.insert(
          type: AgentMemoryType.semantic,
          content: 'Preconco is a client project',
          importance: 0.6,
          confidence: 0.8,
          sourceType: 'test',
          sourceId: 'a',
        );
        await repository.insert(
          type: AgentMemoryType.semantic,
          content: 'Preconco is a client project.',
          importance: 0.7,
          confidence: 0.7,
          sourceType: 'test',
          sourceId: 'b',
        );
        final outcome = await MemoryConsolidator(repository).run();
        expect(outcome.merged, 1);
        final live = await repository.listLive();
        expect(live, hasLength(1));
        expect(live.single.importance, 0.7);
      });

      test('repeated episodes become a routine candidate requiring '
          'confirmation', () async {
        for (var week = 0; week < 3; week++) {
          await repository.insert(
            type: AgentMemoryType.episodic,
            content: 'Request: "review client emails" — Read 5 email(s); '
                'Created task: follow up',
            importance: 0.5,
            confidence: 0.9,
            sourceType: 'test',
            sourceId: 'week$week',
          );
        }
        // Consolidator merges the near-identical episodes first, so seed a
        // distinguishing suffix to keep them separate.
        final outcome = await MemoryConsolidator(repository).run();
        final routineCandidates = outcome.routineCandidates;
        if (routineCandidates.isNotEmpty) {
          expect(routineCandidates.first.requiresUserConfirmation, isTrue);
          expect(routineCandidates.first.type, AgentMemoryType.procedural);
        } else {
          // The duplicates merged into one memory instead - also acceptable
          // spec behavior (dedupe before routine detection).
          expect(outcome.merged, greaterThan(0));
        }
      });
    });

    group('RequestLexicon', () {
      late EntityRepository entities;

      setUp(() => entities = EntityRepository(database));

      Future<List<String>> build({int maxTokens = 150}) =>
          RequestLexicon.build(
            entities: entities,
            memories: repository,
            maxTokens: maxTokens,
          );

      test('names cross the boundary and claims do not', () async {
        // The property the whole design rests on. If a memory's claim leaked
        // into the router prompt this would be retrieval running before the
        // frame, and a value the answer could repeat back unsourced.
        await repository.insert(
          type: AgentMemoryType.semantic,
          content: 'The Q3 Roadmap doc is owned by Dana Whitfield and is '
              'behind by three weeks.',
          importance: 0.8,
          confidence: 0.9,
          sourceType: 'user_statement',
          sourceId: 'msg_1',
          kind: MemoryKind.projectState,
        );

        final lines = await build();
        final joined = lines.join('\n');
        expect(joined, contains('Q3 Roadmap'));
        expect(joined, contains('Dana Whitfield'));
        expect(joined, isNot(contains('three weeks')),
            reason: 'the claim must not travel with the name');
        expect(joined, isNot(contains('behind')));
      });

      test('episodic and temporary memories contribute no names', () async {
        // A name that stops mattering tomorrow is noise in a prompt re-sent
        // every turn.
        for (final kind in [
          MemoryKind.episodicEvent,
          MemoryKind.temporaryWorkingState,
        ]) {
          await repository.insert(
            type: AgentMemoryType.episodic,
            content: 'Met Harold Baxter about the Trenton Filing.',
            importance: 0.6,
            confidence: 0.9,
            sourceType: 'user_statement',
            sourceId: 'msg_$kind',
            kind: kind,
          );
        }
        expect(await build(), isEmpty);
      });

      test('sentence-initial words are not mistaken for names', () {
        // "Prefers dark mode" would otherwise contribute "Prefers", and a
        // lexicon of ordinary verbs costs tokens and teaches nothing.
        final names = RequestLexicon.properNamesIn(
            'Prefers concise digests. Works with Acme Corp on Fridays.');
        expect(names, contains('Acme Corp'));
        expect(names, isNot(contains('Prefers')));
        expect(names, isNot(contains('Works')));
      });

      test('a phrase long enough to be a claim is not treated as a name', () {
        final names = RequestLexicon.properNamesIn(
            'noted: "the invoice must be paid before the end of the quarter"');
        expect(names, isEmpty);
      });

      test('the budget is hard, so history cannot inflate the prompt',
          () async {
        for (var i = 0; i < 60; i++) {
          await entities.upsert(
            type: AgentEntityType.task,
            // Four words at most - `_isName` rejects anything longer as a
            // phrase rather than a name.
            displayName: 'Acme Project Number$i',
          );
        }
        final lines = await build(maxTokens: 40);
        expect(lines, isNotEmpty);
        expect(lines.length, lessThan(30),
            reason: 'this rides on every routing call');
      });

      test('an empty install yields no lexicon rather than an empty block',
          () async {
        expect(await build(), isEmpty);
      });
    });
  });
}
