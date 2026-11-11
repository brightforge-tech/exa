import 'dart:convert';

import '../../data/database/app_database.dart';
import '../models/agent_ids.dart' show AgentId;
import 'models/agent_entity.dart';

/// SQLite persistence for graph entities.
class EntityRepository {
  EntityRepository(this._database);

  final AppDatabase _database;

  Future<AgentEntity?> getById(String id) async {
    final rows = await _database.db.query(
      'agent_entities',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  Future<AgentEntity?> findByExternal(
      String externalSource, String externalId) async {
    final rows = await _database.db.query(
      'agent_entities',
      where: 'external_source = ? AND external_id = ?',
      whereArgs: [externalSource, externalId],
      limit: 1,
    );
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  /// Case-insensitive name lookup, excluding archived entities.
  Future<List<AgentEntity>> findByName(String name,
      {AgentEntityType? type}) async {
    final canonical = name.trim().toLowerCase();
    final rows = await _database.db.query(
      'agent_entities',
      where: 'canonical_name = ? AND is_archived = 0'
          '${type != null ? ' AND entity_type = ?' : ''}',
      whereArgs: [canonical, if (type != null) type.wireName],
    );
    return rows.map(_fromRow).toList();
  }

  /// The most recently touched entities, for the router's request lexicon.
  ///
  /// Names only ever leave here as names - the router is being told what words
  /// refer to things, not what is true about them. See [RequestLexicon].
  Future<List<AgentEntity>> listRecent({int limit = 40}) async {
    final rows = await _database.db.query(
      'agent_entities',
      where: 'is_archived = 0',
      orderBy: 'updated_at DESC',
      limit: limit,
    );
    return rows.map(_fromRow).toList();
  }

  Future<List<AgentEntity>> getByIds(List<String> ids) async {
    if (ids.isEmpty) return const [];
    final placeholders = List.filled(ids.length, '?').join(',');
    final rows = await _database.db.query(
      'agent_entities',
      where: 'id IN ($placeholders)',
      whereArgs: ids,
    );
    return rows.map(_fromRow).toList();
  }

  Future<void> insert(AgentEntity entity) async {
    await _database.db.insert('agent_entities', _toRow(entity));
  }

  Future<void> update(AgentEntity entity) async {
    await _database.db.update(
      'agent_entities',
      _toRow(entity),
      where: 'id = ?',
      whereArgs: [entity.id],
    );
  }

  Future<void> archive(String id) async {
    await _database.db.update(
      'agent_entities',
      {'is_archived': 1, 'updated_at': DateTime.now().toIso8601String()},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> delete(String id) async {
    await _database.db.delete('entity_relationships',
        where: 'source_entity_id = ? OR target_entity_id = ?',
        whereArgs: [id, id]);
    await _database.db
        .delete('agent_entities', where: 'id = ?', whereArgs: [id]);
  }

  /// Creates the entity if it does not exist yet (matched on external
  /// source+id, falling back to canonical name for source-less entities
  /// like people), otherwise refreshes its name/metadata.
  Future<AgentEntity> upsert({
    required AgentEntityType type,
    required String displayName,
    String? externalSource,
    String? externalId,
    Map<String, dynamic> metadata = const {},
    double confidence = 1.0,
  }) async {
    AgentEntity? existing;
    if (externalSource != null && externalId != null) {
      existing = await findByExternal(externalSource, externalId);
    }
    existing ??= (await findByName(displayName, type: type)).firstOrNull;

    final now = DateTime.now();
    if (existing != null) {
      final updated = existing.copyWith(
        displayName: displayName,
        metadata: {...existing.metadata, ...metadata},
        confidence:
            confidence > existing.confidence ? confidence : existing.confidence,
        isArchived: false,
        updatedAt: now,
      );
      await update(updated);
      return updated;
    }

    final entity = AgentEntity(
      id: AgentId.entity(),
      type: type,
      displayName: displayName,
      canonicalName: displayName.trim().toLowerCase(),
      externalSource: externalSource,
      externalId: externalId,
      metadata: metadata,
      confidence: confidence,
      createdAt: now,
      updatedAt: now,
    );
    await insert(entity);
    return entity;
  }

  Map<String, Object?> _toRow(AgentEntity entity) => {
        'id': entity.id,
        'entity_type': entity.type.wireName,
        'display_name': entity.displayName,
        'canonical_name':
            entity.canonicalName ?? entity.displayName.trim().toLowerCase(),
        'external_source': entity.externalSource,
        'external_id': entity.externalId,
        'metadata_json': jsonEncode(entity.metadata),
        'confidence': entity.confidence,
        'is_archived': entity.isArchived ? 1 : 0,
        'created_at': entity.createdAt.toIso8601String(),
        'updated_at': entity.updatedAt.toIso8601String(),
      };

  static AgentEntity _fromRow(Map<String, Object?> row) => AgentEntity(
        id: row['id'] as String,
        type: AgentEntityType.fromWireName(row['entity_type'] as String),
        displayName: row['display_name'] as String,
        canonicalName: row['canonical_name'] as String?,
        externalSource: row['external_source'] as String?,
        externalId: row['external_id'] as String?,
        metadata: row['metadata_json'] is String
            ? (jsonDecode(row['metadata_json'] as String) as Map)
                .cast<String, dynamic>()
            : const {},
        confidence: (row['confidence'] as num?)?.toDouble() ?? 1.0,
        isArchived: row['is_archived'] == 1,
        createdAt: DateTime.tryParse(row['created_at'] as String? ?? '') ??
            DateTime.now(),
        updatedAt: DateTime.tryParse(row['updated_at'] as String? ?? '') ??
            DateTime.now(),
      );
}
