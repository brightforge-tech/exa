import 'package:sqflite/sqflite.dart';

import '../database/app_database.dart';

/// One successfully executed side-effecting tool call, keyed by its
/// idempotency key. Consulted before execution so retries, repairs, skill
/// re-runs, and loop repetition can never duplicate a side effect.
class IdempotencyRecord {
  const IdempotencyRecord({
    required this.key,
    required this.agentTurnId,
    required this.toolName,
    required this.resultJson,
    required this.createdAt,
  });

  final String key;
  final String agentTurnId;
  final String toolName;
  final String resultJson;
  final DateTime createdAt;
}

class IdempotencyRepository {
  IdempotencyRepository(this._database);

  final AppDatabase _database;

  Future<IdempotencyRecord?> findSuccessful(String key) async {
    final rows = await _database.db.query(
      'idempotency_records',
      where: 'key = ?',
      whereArgs: [key],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final row = rows.first;
    return IdempotencyRecord(
      key: row['key'] as String,
      agentTurnId: row['agent_turn_id'] as String? ?? '',
      toolName: row['tool_name'] as String,
      resultJson: row['result_json'] as String? ?? 'null',
      createdAt: DateTime.tryParse(row['created_at'] as String? ?? '') ??
          DateTime.now(),
    );
  }

  Future<void> recordSuccess({
    required String key,
    required String agentTurnId,
    required String toolName,
    required String resultJson,
  }) async {
    await _database.db.insert(
      'idempotency_records',
      _row(
        key: key,
        agentTurnId: agentTurnId,
        toolName: toolName,
        resultJson: resultJson,
      ),
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  /// The same insert inside a caller's transaction, so the guard against
  /// repeating a side effect commits together with the log entry that says
  /// the side effect happened. Split across two commits, a process death
  /// between them leaves an action that ran with nothing recording that it
  /// did — and the retry does it again.
  Future<void> recordSuccessIn(
    DatabaseExecutor txn, {
    required String key,
    required String agentTurnId,
    required String toolName,
    required String resultJson,
  }) async {
    await txn.insert(
      'idempotency_records',
      _row(
        key: key,
        agentTurnId: agentTurnId,
        toolName: toolName,
        resultJson: resultJson,
      ),
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  static Map<String, Object?> _row({
    required String key,
    required String agentTurnId,
    required String toolName,
    required String resultJson,
  }) =>
      {
        'key': key,
        'agent_turn_id': agentTurnId,
        'tool_name': toolName,
        'result_json': resultJson,
        'created_at': DateTime.now().toIso8601String(),
      };

  /// Keys older than [retention] no longer guard anything useful.
  Future<int> pruneOlderThan(Duration retention) =>
      _database.db.delete(
        'idempotency_records',
        where: 'created_at < ?',
        whereArgs: [
          DateTime.now().subtract(retention).toIso8601String(),
        ],
      );
}
