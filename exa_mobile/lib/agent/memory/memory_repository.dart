import 'package:sqflite/sqflite.dart';

import '../../data/database/app_database.dart';
import '../models/agent_ids.dart' show AgentId;
import 'models/agent_memory.dart';

/// SQLite persistence for agent memories and their entity links.
class MemoryRepository {
  MemoryRepository(this._database);

  final AppDatabase _database;

  Future<AgentMemory> insert({
    required AgentMemoryType type,
    required String content,
    required double importance,
    required double confidence,
    required String sourceType,
    required String sourceId,
    String? summary,
    List<String> entityIds = const [],
    DateTime? expiresAt,
    bool userConfirmed = false,
    bool isSensitive = false,
    MemoryKind? kind,
    MemoryProvenance provenance = MemoryProvenance.deterministicInference,
    DateTime? observedAt,
    DateTime? validFrom,
    DateTime? validUntil,
    DateTime? lastConfirmedAt,
    String? topicScope,
    String? supersedesMemoryId,
    int reinforcementCount = 1,
  }) async {
    final now = DateTime.now();
    final memory = AgentMemory(
      id: AgentId.memory(),
      type: type,
      content: content,
      summary: summary,
      entityIds: entityIds,
      importance: importance,
      confidence: confidence,
      sourceType: sourceType,
      sourceId: sourceId,
      createdAt: now,
      updatedAt: now,
      expiresAt: expiresAt,
      userConfirmed: userConfirmed,
      isSensitive: isSensitive,
      kind: kind,
      provenance: provenance,
      observedAt: observedAt,
      validFrom: validFrom,
      validUntil: validUntil,
      lastConfirmedAt: lastConfirmedAt,
      topicScope: topicScope,
      supersedesMemoryId: supersedesMemoryId,
      reinforcementCount: reinforcementCount,
    );
    final batch = _database.db.batch();
    batch.insert('agent_memories', _toRow(memory));
    for (final entityId in entityIds.toSet()) {
      batch.insert(
        'memory_entities',
        {'memory_id': memory.id, 'entity_id': entityId},
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    }
    await batch.commit(noResult: true);
    return memory;
  }

  Future<void> update(AgentMemory memory) async {
    await _database.db.update(
      'agent_memories',
      _toRow(memory),
      where: 'id = ?',
      whereArgs: [memory.id],
    );
  }

  Future<AgentMemory?> getById(String id) async {
    final rows = await _database.db
        .query('agent_memories', where: 'id = ?', whereArgs: [id], limit: 1);
    if (rows.isEmpty) return null;
    return _withEntities(_fromRow(rows.first));
  }

  /// Live (non-archived, non-expired) memories, optionally by type.
  Future<List<AgentMemory>> listLive({AgentMemoryType? type}) async {
    final now = DateTime.now().toIso8601String();
    final rows = await _database.db.query(
      'agent_memories',
      where: 'is_archived = 0 AND (expires_at IS NULL OR expires_at > ?)'
          '${type != null ? ' AND memory_type = ?' : ''}',
      whereArgs: [now, if (type != null) type.wireName],
      orderBy: 'updated_at DESC',
    );
    final memories = <AgentMemory>[];
    for (final row in rows) {
      memories.add(await _withEntities(_fromRow(row)));
    }
    return memories;
  }

  /// Everything, for the memory review screen (archived included).
  Future<List<AgentMemory>> listAll({int limit = 500}) async {
    final rows = await _database.db.query(
      'agent_memories',
      orderBy: 'updated_at DESC',
      limit: limit,
    );
    final memories = <AgentMemory>[];
    for (final row in rows) {
      memories.add(await _withEntities(_fromRow(row)));
    }
    return memories;
  }

  /// Memories linked to any of [entityIds].
  Future<List<AgentMemory>> forEntities(List<String> entityIds) async {
    if (entityIds.isEmpty) return const [];
    final placeholders = List.filled(entityIds.length, '?').join(',');
    final rows = await _database.db.rawQuery(
      'SELECT DISTINCT m.* FROM agent_memories m '
      'JOIN memory_entities me ON me.memory_id = m.id '
      'WHERE me.entity_id IN ($placeholders) AND m.is_archived = 0',
      entityIds,
    );
    final memories = <AgentMemory>[];
    for (final row in rows) {
      memories.add(await _withEntities(_fromRow(row)));
    }
    return memories;
  }

  Future<void> touchAccess(List<String> memoryIds) async {
    if (memoryIds.isEmpty) return;
    final placeholders = List.filled(memoryIds.length, '?').join(',');
    await _database.db.rawUpdate(
      'UPDATE agent_memories SET access_count = access_count + 1, '
      'last_accessed_at = ? WHERE id IN ($placeholders)',
      [DateTime.now().toIso8601String(), ...memoryIds],
    );
  }

  /// Marks [memoryId] as contradicted by [byMemoryId] and drops its
  /// confidence. Contradicted memories are kept, not deleted: retrieval
  /// penalizes them heavily, and keeping them means "why did Exa think
  /// that?" stays answerable.
  Future<void> markContradicted(String memoryId, String byMemoryId) async {
    await _database.db.rawUpdate(
      'UPDATE agent_memories SET contradicted_by_memory_id = ?, '
      'confidence = MIN(confidence, 0.15), updated_at = ? WHERE id = ?',
      [byMemoryId, DateTime.now().toIso8601String(), memoryId],
    );
  }

  /// Records another independent observation of the same thing. This is
  /// what lets an inferred preference become durable — and what stops one
  /// unusual request from doing so.
  Future<void> reinforce(String memoryId, {bool confirmed = false}) async {
    final now = DateTime.now().toIso8601String();
    await _database.db.rawUpdate(
      'UPDATE agent_memories SET reinforcement_count = reinforcement_count + 1, '
      'last_confirmed_at = ?, updated_at = ?, '
      'confidence = MIN(1.0, confidence + 0.1)'
      '${confirmed ? ', user_confirmed = 1' : ''} WHERE id = ?',
      [now, now, memoryId],
    );
  }

  /// Live memories that still apply right now: not archived, not expired,
  /// and inside their validity window.
  Future<List<AgentMemory>> listApplicable({DateTime? asOf}) async {
    final moment = asOf ?? DateTime.now();
    final live = await listLive();
    return [
      for (final memory in live)
        if (!memory.isOutOfValidityAt(moment)) memory,
    ];
  }

  Future<void> delete(String id) async {
    await _database.db
        .delete('memory_entities', where: 'memory_id = ?', whereArgs: [id]);
    await _database.db
        .delete('agent_memories', where: 'id = ?', whereArgs: [id]);
  }

  Future<void> deleteByType(AgentMemoryType type) async {
    await _database.db.rawDelete(
      'DELETE FROM memory_entities WHERE memory_id IN '
      '(SELECT id FROM agent_memories WHERE memory_type = ?)',
      [type.wireName],
    );
    await _database.db.delete('agent_memories',
        where: 'memory_type = ?', whereArgs: [type.wireName]);
  }

  Future<void> archive(String id) async {
    await _database.db.update(
      'agent_memories',
      {'is_archived': 1, 'updated_at': DateTime.now().toIso8601String()},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Hard-deletes expired working memories; archives other expired types.
  Future<void> expireDue() async {
    final now = DateTime.now().toIso8601String();
    await _database.db.rawDelete(
      'DELETE FROM memory_entities WHERE memory_id IN '
      '(SELECT id FROM agent_memories WHERE memory_type = ? '
      'AND expires_at IS NOT NULL AND expires_at < ?)',
      [AgentMemoryType.working.wireName, now],
    );
    await _database.db.delete(
      'agent_memories',
      where: 'memory_type = ? AND expires_at IS NOT NULL AND expires_at < ?',
      whereArgs: [AgentMemoryType.working.wireName, now],
    );
    await _database.db.rawUpdate(
      'UPDATE agent_memories SET is_archived = 1 '
      'WHERE expires_at IS NOT NULL AND expires_at < ? AND is_archived = 0',
      [now],
    );
  }

  Future<AgentMemory> _withEntities(AgentMemory memory) async {
    final rows = await _database.db.query(
      'memory_entities',
      where: 'memory_id = ?',
      whereArgs: [memory.id],
    );
    if (rows.isEmpty) return memory;
    return memory.copyWith(
      entityIds: [for (final row in rows) row['entity_id'] as String],
    );
  }

  Map<String, Object?> _toRow(AgentMemory memory) => {
        'id': memory.id,
        'memory_type': memory.type.wireName,
        'content': memory.content,
        'summary': memory.summary,
        'importance': memory.importance,
        'confidence': memory.confidence,
        'source_type': memory.sourceType,
        'source_id': memory.sourceId,
        'expires_at': memory.expiresAt?.toIso8601String(),
        'last_accessed_at': memory.lastAccessedAt?.toIso8601String(),
        'access_count': memory.accessCount,
        'user_confirmed': memory.userConfirmed ? 1 : 0,
        'is_sensitive': memory.isSensitive ? 1 : 0,
        'is_archived': memory.isArchived ? 1 : 0,
        'created_at': memory.createdAt.toIso8601String(),
        'updated_at': memory.updatedAt.toIso8601String(),
        // Lifecycle and provenance (schema v19).
        'memory_kind': memory.kind.wireName,
        'provenance': memory.provenance.wireName,
        'observed_at': memory.observedAt.toIso8601String(),
        'valid_from': memory.validFrom.toIso8601String(),
        'valid_until': memory.validUntil?.toIso8601String(),
        'last_confirmed_at': memory.lastConfirmedAt?.toIso8601String(),
        'topic_scope': memory.topicScope,
        'supersedes_memory_id': memory.supersedesMemoryId,
        'contradicted_by_memory_id': memory.contradictedByMemoryId,
        'reinforcement_count': memory.reinforcementCount,
      };

  static AgentMemory _fromRow(Map<String, Object?> row) => AgentMemory(
        id: row['id'] as String,
        type: AgentMemoryType.fromWireName(row['memory_type'] as String),
        content: row['content'] as String,
        summary: row['summary'] as String?,
        importance: (row['importance'] as num?)?.toDouble() ?? 0.5,
        confidence: (row['confidence'] as num?)?.toDouble() ?? 0.5,
        sourceType: row['source_type'] as String? ?? 'unknown',
        sourceId: row['source_id'] as String? ?? '',
        expiresAt: DateTime.tryParse(row['expires_at'] as String? ?? ''),
        lastAccessedAt:
            DateTime.tryParse(row['last_accessed_at'] as String? ?? ''),
        accessCount: (row['access_count'] as int?) ?? 0,
        userConfirmed: row['user_confirmed'] == 1,
        isSensitive: row['is_sensitive'] == 1,
        isArchived: row['is_archived'] == 1,
        createdAt: DateTime.tryParse(row['created_at'] as String? ?? '') ??
            DateTime.now(),
        updatedAt: DateTime.tryParse(row['updated_at'] as String? ?? '') ??
            DateTime.now(),
        // Null for rows written before schema v19; the getters fall back to
        // the tier default and to created_at.
        kind: row['memory_kind'] == null
            ? null
            : MemoryKind.fromWireName(row['memory_kind'] as String?),
        provenance: MemoryProvenance.fromWireName(row['provenance'] as String?),
        observedAt: DateTime.tryParse(row['observed_at'] as String? ?? ''),
        validFrom: DateTime.tryParse(row['valid_from'] as String? ?? ''),
        validUntil: DateTime.tryParse(row['valid_until'] as String? ?? ''),
        lastConfirmedAt:
            DateTime.tryParse(row['last_confirmed_at'] as String? ?? ''),
        topicScope: row['topic_scope'] as String?,
        supersedesMemoryId: row['supersedes_memory_id'] as String?,
        contradictedByMemoryId: row['contradicted_by_memory_id'] as String?,
        reinforcementCount: (row['reinforcement_count'] as int?) ?? 1,
      );
}
