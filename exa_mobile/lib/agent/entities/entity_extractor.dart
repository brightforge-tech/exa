import '../models/tool_execution_record.dart';
import 'entity_graph_service.dart';
import 'models/agent_entity.dart';
import 'models/entity_relationship.dart';

/// What one turn's tool records contributed to the entity graph.
class EntityExtractionResult {
  const EntityExtractionResult({
    required this.touched,
    required this.positions,
  });

  /// Graph entities this turn created, modified, read, or listed.
  final List<AgentEntity> touched;

  /// 1-based list positions for entities that appeared in a listed result
  /// (so "the second reminder" resolves deterministically next turn).
  final Map<String, int> positions;

  static const empty = EntityExtractionResult(touched: [], positions: {});
}

/// Deterministically mirrors tool results into the entity graph after the
/// tool loop finishes. No model involvement: every entity and relationship
/// written here is read straight out of a validated tool record.
class EntityExtractor {
  EntityExtractor(this._graph);

  final EntityGraphService _graph;

  Future<EntityExtractionResult> applyRecords(
      List<ToolExecutionRecord> records) async {
    final touched = <String, AgentEntity>{};
    final positions = <String, int>{};

    // Emails read this turn, for createdFrom links on tasks/events the same
    // turn produced. Only an unambiguous single full read is linkable.
    AgentEntity? focusEmail;
    var readEmailList = false;
    final createdThisTurn = <AgentEntity>[];

    void touch(AgentEntity entity) => touched[entity.id] = entity;

    for (final record in records) {
      if (record.isControlPlane ||
          record.status != ToolExecutionStatus.success) {
        continue;
      }
      final result = record.rawResult is Map
          ? (record.rawResult as Map).cast<String, Object?>()
          : const <String, Object?>{};

      switch (record.toolName) {
        case 'create_task':
        case 'update_task':
        case 'complete_task':
          final entity = await _upsertFromResult(
            result,
            type: AgentEntityType.task,
            source: 'sqlite_task',
            statusKey: 'status',
          );
          if (entity != null) {
            touch(entity);
            if (record.toolName == 'create_task') createdThisTurn.add(entity);
          }
        case 'delete_task':
          await _archiveExternal('sqlite_task', record.arguments['id']);
        case 'create_reminder':
        case 'update_reminder':
          final entity = await _upsertFromResult(
            result,
            type: AgentEntityType.reminder,
            source: 'sqlite_reminder',
            statusKey: 'status',
          );
          if (entity != null) touch(entity);
        case 'cancel_reminder':
          await _archiveExternal('sqlite_reminder', record.arguments['id']);
        case 'create_schedule_event':
        case 'update_schedule_event':
          final entity = await _upsertFromResult(
            result,
            type: AgentEntityType.calendarEvent,
            source: 'sqlite_schedule',
            statusKey: 'status',
          );
          if (entity != null) {
            touch(entity);
            if (record.toolName == 'create_schedule_event') {
              createdThisTurn.add(entity);
            }
          }
        case 'delete_schedule_event':
          await _archiveExternal('sqlite_schedule', record.arguments['id']);
        case 'add_to_phone_calendar':
          final title = record.arguments['title'];
          if (title is String && title.isNotEmpty) {
            final entity = await _graph.upsertNamedEntity(
              type: AgentEntityType.calendarEvent,
              displayName: title,
              metadata: {'queued_for_approval': true},
            );
            touch(entity);
          }
        case 'read_email_context':
          if (result['emails'] is List) {
            readEmailList = true;
            var position = 0;
            for (final raw
                in (result['emails'] as List).whereType<Map>()) {
              position++;
              final entity = await _upsertEmail(raw.cast<String, Object?>());
              if (entity != null) {
                touch(entity);
                positions[entity.id] = position;
              }
            }
          } else if (result['id'] != null) {
            final entity = await _upsertEmail(result);
            if (entity != null) {
              touch(entity);
              focusEmail = entity;
            }
          }
        case 'store_file':
          final name = result['name'] ?? record.arguments['name'];
          if (name is String && name.isNotEmpty) {
            final entity = await _graph.upsertExternalEntity(
              type: AgentEntityType.file,
              displayName: name,
              externalSource: 'sqlite_attachment',
              externalId: (result['id'] ?? name).toString(),
            );
            touch(entity);
          }
        case 'create_dynamic_screen':
          final key = result['screen_key'] ?? record.arguments['screen_key'];
          if (key is String && key.isNotEmpty) {
            final entity = await _graph.upsertExternalEntity(
              type: AgentEntityType.screen,
              displayName: (record.arguments['title'] as String?) ?? key,
              externalSource: 'sqlite_dynamic_screen',
              externalId: key,
            );
            touch(entity);
          }
        case 'create_scheduled_job':
          final entity = await _upsertFromResult(
            result,
            type: AgentEntityType.backgroundJob,
            source: 'sqlite_scheduled_job',
            nameKey: 'name',
          );
          if (entity != null) touch(entity);
        case 'propose_behavior_change':
        case 'update_behavior':
        case 'activate_behavior':
          final id = result['behavior_id'] ?? result['id'];
          final title =
              record.arguments['title'] ?? record.arguments['proposed_title'];
          if (id != null) {
            final entity = await _graph.upsertExternalEntity(
              type: AgentEntityType.behaviorRule,
              displayName:
                  title is String && title.isNotEmpty ? title : 'Rule $id',
              externalSource: 'sqlite_behavior',
              externalId: id.toString(),
            );
            touch(entity);
          }
        case 'list_tasks':
          await _positionList(result['tasks'], AgentEntityType.task,
              'sqlite_task', touch, positions);
        case 'list_reminders':
          await _positionList(result['reminders'], AgentEntityType.reminder,
              'sqlite_reminder', touch, positions);
        case 'list_schedule':
          await _positionList(result['events'] ?? result['items'],
              AgentEntityType.calendarEvent, 'sqlite_schedule', touch,
              positions);
      }
    }

    // Tasks/events extracted from one specific email are createdFrom it.
    if (focusEmail != null && !readEmailList) {
      for (final created in createdThisTurn) {
        await _graph.link(
          sourceEntityId: created.id,
          targetEntityId: focusEmail.id,
          type: EntityRelationshipType.createdFrom,
          source: 'entity_extractor',
        );
      }
    }

    return EntityExtractionResult(
      touched: touched.values.toList(),
      positions: positions,
    );
  }

  /// Archives the graph entity mirroring a deleted/cancelled source record.
  Future<void> _archiveExternal(String source, Object? externalId) async {
    if (externalId is! String || externalId.isEmpty) return;
    final entity =
        await _graph.entities.findByExternal(source, externalId);
    if (entity != null) {
      await _graph.archiveEntity(entity.id);
    }
  }

  Future<void> _positionList(
    Object? rawList,
    AgentEntityType type,
    String source,
    void Function(AgentEntity) touch,
    Map<String, int> positions,
  ) async {
    if (rawList is! List) return;
    var position = 0;
    for (final raw in rawList.whereType<Map>()) {
      position++;
      final map = raw.cast<String, Object?>();
      final entity = await _upsertFromResult(map,
          type: type, source: source, statusKey: 'status');
      if (entity != null) {
        touch(entity);
        positions[entity.id] = position;
      }
      if (position >= 20) break; // Follow-ups reference the visible few.
    }
  }

  Future<AgentEntity?> _upsertFromResult(
    Map<String, Object?> result, {
    required AgentEntityType type,
    required String source,
    String nameKey = 'title',
    String? statusKey,
  }) async {
    final id = result['id'];
    final name = result[nameKey];
    if (id == null || name is! String || name.isEmpty) return null;
    return _graph.upsertExternalEntity(
      type: type,
      displayName: name,
      externalSource: source,
      externalId: id.toString(),
      metadata: {
        if (statusKey != null && result[statusKey] != null)
          'status': result[statusKey],
        if (result['due_at'] != null) 'due_at': result['due_at'],
        if (result['start_at'] != null) 'start_at': result['start_at'],
      },
    );
  }

  /// Upserts an email entity plus its sender person and the sentBy edge.
  Future<AgentEntity?> _upsertEmail(Map<String, Object?> result) async {
    final id = result['id'];
    final subject = result['subject'];
    if (id == null || subject is! String) return null;
    final email = await _graph.upsertExternalEntity(
      type: AgentEntityType.email,
      displayName: subject,
      externalSource: 'sqlite_email',
      externalId: id.toString(),
      metadata: {
        if (result['digested'] != null) 'digested': result['digested'],
        if (result['received_at'] != null)
          'received_at': result['received_at'],
      },
    );
    final sender = result['from'] ?? result['sender'];
    if (sender is String && sender.trim().isNotEmpty) {
      final person = await _graph.upsertNamedEntity(
        type: AgentEntityType.person,
        displayName: senderDisplayName(sender),
        metadata: {
          if (senderAddress(sender) != null) 'email': senderAddress(sender),
        },
        confidence: 0.9,
      );
      await _graph.link(
        sourceEntityId: email.id,
        targetEntityId: person.id,
        type: EntityRelationshipType.sentBy,
        source: 'entity_extractor',
      );
    }
    return email;
  }

  /// `"Amy Chen <amy@example.com>"` -> "Amy Chen"; bare addresses use the
  /// local part (`"amy@example.com"` -> "amy").
  static String senderDisplayName(String sender) {
    final match = RegExp(r'^\s*"?([^"<]+?)"?\s*<').firstMatch(sender);
    if (match != null) return match.group(1)!.trim();
    final at = sender.indexOf('@');
    if (at > 0 && !sender.contains('<')) {
      return sender.substring(0, at).trim();
    }
    return sender.trim();
  }

  static String? senderAddress(String sender) {
    final match = RegExp(r'<([^>]+)>').firstMatch(sender);
    if (match != null) return match.group(1)!.trim();
    return sender.contains('@') ? sender.trim() : null;
  }
}
