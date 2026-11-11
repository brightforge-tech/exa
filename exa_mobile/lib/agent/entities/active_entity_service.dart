import 'package:sqflite/sqflite.dart';

import '../../data/database/app_database.dart';
import 'entity_extractor.dart';
import 'models/active_entity_context.dart';
import 'models/agent_entity.dart';

/// Maintains the per-conversation active entity context: what the recent
/// turns touched, with decaying salience and list positions, so pronouns
/// and follow-ups ("delete the second one") resolve against application
/// state instead of the model's recall.
class ActiveEntityService {
  ActiveEntityService(this._database);

  final AppDatabase _database;

  /// How much salience an entity keeps per turn it goes untouched. Two
  /// quiet turns take 1.0 -> 0.36 (still resolvable); five drop below the
  /// retention floor.
  static const double decayPerTurn = 0.6;
  static const double retentionFloor = 0.05;
  static const int maxEntities = 24;

  Future<ActiveEntityContext> resolveForTurn(String conversationId) async {
    final rows = await _database.db.query(
      'active_entity_context',
      where: 'conversation_id = ?',
      whereArgs: [conversationId],
      orderBy: 'salience DESC',
      limit: maxEntities,
    );
    return ActiveEntityContext(
      conversationId: conversationId,
      entities: [
        for (final row in rows)
          ActiveEntityReference(
            entityId: row['entity_id'] as String,
            entityType:
                AgentEntityType.fromWireName(row['entity_type'] as String),
            displayName: row['display_name'] as String,
            salience: (row['salience'] as num).toDouble(),
            lastMentionedAt:
                DateTime.tryParse(row['last_mentioned_at'] as String? ?? '') ??
                    DateTime.now(),
            externalId: row['external_id'] as String?,
            position: row['position_index'] as int?,
          ),
      ],
      updatedAt: DateTime.now(),
    );
  }

  /// Applies this turn's extraction result: existing entries decay, touched
  /// entities reset to full salience (with fresh positions), and entries
  /// below the retention floor are dropped.
  Future<void> updateAfterTurn({
    required String conversationId,
    required EntityExtractionResult extraction,
  }) async {
    final now = DateTime.now().toIso8601String();
    final db = _database.db;

    await db.rawUpdate(
      'UPDATE active_entity_context SET salience = salience * ?, '
      'position_index = NULL WHERE conversation_id = ?',
      [decayPerTurn, conversationId],
    );

    final batch = db.batch();
    for (final entity in extraction.touched) {
      batch.insert(
        'active_entity_context',
        {
          'conversation_id': conversationId,
          'entity_id': entity.id,
          'entity_type': entity.type.wireName,
          'display_name': entity.displayName,
          'external_id': entity.externalId,
          'salience': 1.0,
          'position_index': extraction.positions[entity.id],
          'last_mentioned_at': now,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    batch.delete(
      'active_entity_context',
      where: 'conversation_id = ? AND salience < ?',
      whereArgs: [conversationId, retentionFloor],
    );
    await batch.commit(noResult: true);

    // Keep the context bounded: drop the least salient beyond the cap.
    await db.rawDelete(
      'DELETE FROM active_entity_context WHERE conversation_id = ? AND '
      'entity_id NOT IN (SELECT entity_id FROM active_entity_context '
      'WHERE conversation_id = ? ORDER BY salience DESC LIMIT ?)',
      [conversationId, conversationId, maxEntities],
    );
  }

  Future<void> clear(String conversationId) async {
    await _database.db.delete(
      'active_entity_context',
      where: 'conversation_id = ?',
      whereArgs: [conversationId],
    );
  }
}
