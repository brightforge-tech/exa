import 'dart:convert';

import '../../data/database/app_database.dart';
import '../models/agent_ids.dart' show AgentId;
import 'models/entity_relationship.dart';

/// SQLite persistence for graph edges.
class EntityRelationshipRepository {
  EntityRelationshipRepository(this._database);

  final AppDatabase _database;

  Future<EntityRelationship?> find({
    required String sourceEntityId,
    required String targetEntityId,
    required EntityRelationshipType type,
  }) async {
    final rows = await _database.db.query(
      'entity_relationships',
      where:
          'source_entity_id = ? AND target_entity_id = ? AND relationship_type = ?',
      whereArgs: [sourceEntityId, targetEntityId, type.wireName],
      limit: 1,
    );
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  /// Creates the edge if absent; duplicate links are one edge, not many.
  Future<EntityRelationship> upsert({
    required String sourceEntityId,
    required String targetEntityId,
    required EntityRelationshipType type,
    String? customType,
    double confidence = 1.0,
    String? source,
    Map<String, dynamic> metadata = const {},
    DateTime? validFrom,
    DateTime? validUntil,
  }) async {
    final existing = await find(
      sourceEntityId: sourceEntityId,
      targetEntityId: targetEntityId,
      type: type,
    );
    if (existing != null) return existing;

    final relationship = EntityRelationship(
      id: AgentId.relationship(),
      sourceEntityId: sourceEntityId,
      targetEntityId: targetEntityId,
      type: type,
      customType: customType,
      metadata: metadata,
      confidence: confidence,
      source: source,
      validFrom: validFrom,
      validUntil: validUntil,
      createdAt: DateTime.now(),
    );
    await _database.db.insert('entity_relationships', {
      'id': relationship.id,
      'source_entity_id': relationship.sourceEntityId,
      'target_entity_id': relationship.targetEntityId,
      'relationship_type': relationship.type.wireName,
      'custom_type': relationship.customType,
      'metadata_json': jsonEncode(relationship.metadata),
      'confidence': relationship.confidence,
      'source': relationship.source,
      'valid_from': relationship.validFrom?.toIso8601String(),
      'valid_until': relationship.validUntil?.toIso8601String(),
      'created_at': relationship.createdAt.toIso8601String(),
    });
    return relationship;
  }

  /// Edges touching [entityId] in either direction, valid now, optionally
  /// filtered by type.
  Future<List<EntityRelationship>> forEntity(
    String entityId, {
    Set<EntityRelationshipType>? types,
  }) async {
    final rows = await _database.db.query(
      'entity_relationships',
      where: '(source_entity_id = ? OR target_entity_id = ?)',
      whereArgs: [entityId, entityId],
    );
    final now = DateTime.now();
    return rows
        .map(_fromRow)
        .where((rel) => rel.isValidAt(now))
        .where((rel) => types == null || types.contains(rel.type))
        .toList();
  }

  Future<void> delete(String id) async {
    await _database.db
        .delete('entity_relationships', where: 'id = ?', whereArgs: [id]);
  }

  /// Hard-deletes edges whose validity window has closed.
  Future<int> removeExpired() => _database.db.delete(
        'entity_relationships',
        where: 'valid_until IS NOT NULL AND valid_until < ?',
        whereArgs: [DateTime.now().toIso8601String()],
      );

  static EntityRelationship _fromRow(Map<String, Object?> row) =>
      EntityRelationship(
        id: row['id'] as String,
        sourceEntityId: row['source_entity_id'] as String,
        targetEntityId: row['target_entity_id'] as String,
        type: EntityRelationshipType.fromWireName(
            row['relationship_type'] as String),
        customType: row['custom_type'] as String?,
        metadata: row['metadata_json'] is String
            ? (jsonDecode(row['metadata_json'] as String) as Map)
                .cast<String, dynamic>()
            : const {},
        confidence: (row['confidence'] as num?)?.toDouble() ?? 1.0,
        source: row['source'] as String?,
        validFrom: DateTime.tryParse(row['valid_from'] as String? ?? ''),
        validUntil: DateTime.tryParse(row['valid_until'] as String? ?? ''),
        createdAt: DateTime.tryParse(row['created_at'] as String? ?? '') ??
            DateTime.now(),
      );
}
