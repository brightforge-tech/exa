import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../database/app_database.dart';
import '../models/tool_call_log.dart';

class ToolCallRepository {
  ToolCallRepository(this._database);

  final AppDatabase _database;
  static const _uuid = Uuid();

  Future<ToolCallLog> log({
    required String toolName,
    String? inputJson,
    String? outputJson,
    required String status,
    String? errorMessage,
  }) async {
    final entry = _entry(
      toolName: toolName,
      inputJson: inputJson,
      outputJson: outputJson,
      status: status,
      errorMessage: errorMessage,
    );
    await _database.db.insert('tool_calls', entry.toRow());
    return entry;
  }

  /// The same insert inside a caller's transaction, so a successful call's
  /// log entry and its idempotency guard commit or fail together.
  Future<ToolCallLog> logIn(
    DatabaseExecutor txn, {
    required String toolName,
    String? inputJson,
    String? outputJson,
    required String status,
    String? errorMessage,
  }) async {
    final entry = _entry(
      toolName: toolName,
      inputJson: inputJson,
      outputJson: outputJson,
      status: status,
      errorMessage: errorMessage,
    );
    await txn.insert('tool_calls', entry.toRow());
    return entry;
  }

  ToolCallLog _entry({
    required String toolName,
    String? inputJson,
    String? outputJson,
    required String status,
    String? errorMessage,
  }) =>
      ToolCallLog(
        id: _uuid.v4(),
        toolName: toolName,
        inputJson: inputJson,
        outputJson: outputJson,
        status: status,
        errorMessage: errorMessage,
        createdAt: DateTime.now(),
      );

  Future<List<ToolCallLog>> recent({int limit = 200}) async {
    final rows = await _database.db.query(
      'tool_calls',
      orderBy: 'created_at DESC',
      limit: limit,
    );
    return rows.map(ToolCallLog.fromRow).toList();
  }
}
