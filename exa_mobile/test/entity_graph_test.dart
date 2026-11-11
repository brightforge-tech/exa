import 'package:exa_mobile/agent/entities/active_entity_service.dart';
import 'package:exa_mobile/agent/entities/entity_extractor.dart';
import 'package:exa_mobile/agent/entities/entity_graph_service.dart';
import 'package:exa_mobile/agent/entities/entity_relationship_repository.dart';
import 'package:exa_mobile/agent/entities/entity_repository.dart';
import 'package:exa_mobile/agent/entities/models/agent_entity.dart';
import 'package:exa_mobile/agent/entities/models/entity_relationship.dart';
import 'package:exa_mobile/agent/models/tool_execution_record.dart';
import 'package:exa_mobile/data/database/app_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

ToolExecutionRecord record(
  String toolName,
  Map<String, Object?> arguments,
  Object? rawResult, {
  ToolExecutionStatus status = ToolExecutionStatus.success,
}) =>
    ToolExecutionRecord(
      toolCallId: 'call_${toolName}_${arguments.hashCode}',
      toolName: toolName,
      domain: 'tasks',
      arguments: arguments,
      rawResult: rawResult,
      status: status,
      startedAt: DateTime(2026),
      completedAt: DateTime(2026),
    );

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late AppDatabase database;
  late EntityGraphService graph;
  late EntityExtractor extractor;
  late ActiveEntityService activeEntities;

  setUp(() async {
    database = AppDatabase();
    await database.open(overridePath: inMemoryDatabasePath);
    graph = EntityGraphService(
      entityRepository: EntityRepository(database),
      relationshipRepository: EntityRelationshipRepository(database),
    );
    extractor = EntityExtractor(graph);
    activeEntities = ActiveEntityService(database);
  });

  tearDown(() => database.close());

  test('external entity upsert does not create duplicates', () async {
    final first = await graph.upsertExternalEntity(
      type: AgentEntityType.task,
      displayName: 'Send invoice',
      externalSource: 'sqlite_task',
      externalId: 'task_1',
    );
    final second = await graph.upsertExternalEntity(
      type: AgentEntityType.task,
      displayName: 'Send revised invoice',
      externalSource: 'sqlite_task',
      externalId: 'task_1',
    );
    expect(second.id, first.id);
    expect(second.displayName, 'Send revised invoice');
  });

  test('named entities dedupe by canonical name', () async {
    final amy1 = await graph.upsertNamedEntity(
        type: AgentEntityType.person, displayName: 'Amy');
    final amy2 = await graph.upsertNamedEntity(
        type: AgentEntityType.person, displayName: 'amy ');
    expect(amy2.id, amy1.id);
  });

  test('relationships are single edges and traversable both ways', () async {
    final task = await graph.upsertExternalEntity(
      type: AgentEntityType.task,
      displayName: 'Send report',
      externalSource: 'sqlite_task',
      externalId: 'task_2',
    );
    final project = await graph.upsertNamedEntity(
        type: AgentEntityType.project, displayName: 'BC Reporting');
    await graph.link(
        sourceEntityId: task.id,
        targetEntityId: project.id,
        type: EntityRelationshipType.belongsTo);
    await graph.link(
        sourceEntityId: task.id,
        targetEntityId: project.id,
        type: EntityRelationshipType.belongsTo);

    final related = await graph.getRelatedEntities(entityId: project.id);
    expect(related.map((e) => e.id), [task.id]);
    final fromTask = await graph.getRelatedEntities(entityId: task.id);
    expect(fromTask.map((e) => e.id), [project.id]);
  });

  test('archived entities are excluded from traversal', () async {
    final task = await graph.upsertExternalEntity(
      type: AgentEntityType.task,
      displayName: 'Old task',
      externalSource: 'sqlite_task',
      externalId: 'task_3',
    );
    final project = await graph.upsertNamedEntity(
        type: AgentEntityType.project, displayName: 'Preconco');
    await graph.link(
        sourceEntityId: task.id,
        targetEntityId: project.id,
        type: EntityRelationshipType.belongsTo);
    await graph.archiveEntity(task.id);

    final related = await graph.getRelatedEntities(entityId: project.id);
    expect(related, isEmpty);
  });

  test('two-hop traversal reaches the project via the task', () async {
    final email = await graph.upsertExternalEntity(
      type: AgentEntityType.email,
      displayName: 'Reports update',
      externalSource: 'sqlite_email',
      externalId: 'email_1',
    );
    final task = await graph.upsertExternalEntity(
      type: AgentEntityType.task,
      displayName: 'Reply to Amy',
      externalSource: 'sqlite_task',
      externalId: 'task_4',
    );
    final project = await graph.upsertNamedEntity(
        type: AgentEntityType.project, displayName: 'BC Upgrade');
    await graph.link(
        sourceEntityId: task.id,
        targetEntityId: email.id,
        type: EntityRelationshipType.createdFrom);
    await graph.link(
        sourceEntityId: task.id,
        targetEntityId: project.id,
        type: EntityRelationshipType.belongsTo);

    final oneHop = await graph.getRelatedEntities(entityId: email.id);
    expect(oneHop.map((e) => e.id), [task.id]);
    final twoHop =
        await graph.getRelatedEntities(entityId: email.id, depth: 2);
    expect(twoHop.map((e) => e.id).toSet(), {task.id, project.id});
  });

  group('EntityExtractor', () {
    test('emails link to their senders', () async {
      final extraction = await extractor.applyRecords([
        record('read_email_context', {}, {
          'count': 1,
          'emails': [
            {
              'id': 'email_100',
              'subject': 'Business Central reports',
              'from': 'Amy <amy@example.com>',
              'digested': false,
            },
          ],
        }),
      ]);
      expect(extraction.touched, hasLength(1));
      final email = extraction.touched.single;
      expect(email.type, AgentEntityType.email);

      final related = await graph.getRelatedEntities(entityId: email.id);
      expect(related.single.type, AgentEntityType.person);
      expect(related.single.displayName, 'Amy');
    });

    test('a task created from a single fully-read email links createdFrom',
        () async {
      final extraction = await extractor.applyRecords([
        record('read_email_context', {'id': 'email_100'}, {
          'id': 'email_100',
          'subject': 'Reports',
          'from': 'amy@example.com',
          'body': 'please send the report',
        }),
        record('create_task', {'title': 'Send report update'},
            {'id': 'task_900', 'title': 'Send report update'}),
      ]);
      final task = extraction.touched
          .firstWhere((entity) => entity.type == AgentEntityType.task);
      final related = await graph.getRelatedEntities(
        entityId: task.id,
        relationships: {EntityRelationshipType.createdFrom},
      );
      expect(related.single.type, AgentEntityType.email);
    });

    test('listed reminders get 1-based positions', () async {
      final extraction = await extractor.applyRecords([
        record('list_reminders', {'status': 'Active'}, {
          'count': 2,
          'reminders': [
            {'id': 'rem_1', 'title': 'First', 'status': 'Active'},
            {'id': 'rem_2', 'title': 'Second', 'status': 'Active'},
          ],
        }),
      ]);
      expect(extraction.positions.values.toSet(), {1, 2});
      final second = extraction.touched
          .firstWhere((entity) => entity.displayName == 'Second');
      expect(extraction.positions[second.id], 2);
    });

    test('failed tool calls contribute nothing', () async {
      final extraction = await extractor.applyRecords([
        record('create_task', {'title': 'x'}, null,
            status: ToolExecutionStatus.failure),
      ]);
      expect(extraction.touched, isEmpty);
    });
  });

  group('ActiveEntityService', () {
    test('touched entities enter the context with full salience and decay '
        'across turns', () async {
      final extraction = await extractor.applyRecords([
        record('list_reminders', {}, {
          'count': 2,
          'reminders': [
            {'id': 'rem_1', 'title': 'First', 'status': 'Active'},
            {'id': 'rem_2', 'title': 'Second', 'status': 'Active'},
          ],
        }),
      ]);
      await activeEntities.updateAfterTurn(
          conversationId: 'main', extraction: extraction);

      var context = await activeEntities.resolveForTurn('main');
      expect(context.entities, hasLength(2));
      expect(context.entities.first.salience, 1.0);
      expect(context.entities.map((e) => e.position).toSet(), {1, 2});
      // source ids travel with the context for follow-up tool calls.
      expect(context.entities.map((e) => e.externalId).toSet(),
          {'rem_1', 'rem_2'});

      // A quiet turn decays salience and clears stale positions.
      await activeEntities.updateAfterTurn(
          conversationId: 'main',
          extraction: EntityExtractionResult.empty);
      context = await activeEntities.resolveForTurn('main');
      expect(context.entities.first.salience,
          closeTo(ActiveEntityService.decayPerTurn, 0.001));
      expect(context.entities.first.position, isNull);
    });

    test('entities below the retention floor are dropped', () async {
      final extraction = await extractor.applyRecords([
        record('create_task', {'title': 'Fleeting'},
            {'id': 'task_x', 'title': 'Fleeting'}),
      ]);
      await activeEntities.updateAfterTurn(
          conversationId: 'main', extraction: extraction);
      for (var turn = 0; turn < 8; turn++) {
        await activeEntities.updateAfterTurn(
            conversationId: 'main',
            extraction: EntityExtractionResult.empty);
      }
      final context = await activeEntities.resolveForTurn('main');
      expect(context.entities, isEmpty);
    });
  });
}
