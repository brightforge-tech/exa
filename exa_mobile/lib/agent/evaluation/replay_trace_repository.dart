import 'dart:convert';

import '../../data/database/app_database.dart';
import 'models/replay_trace.dart';

/// SQLite persistence for replay traces.
class ReplayTraceRepository {
  ReplayTraceRepository(this._database);

  final AppDatabase _database;

  Future<void> insert(ReplayTrace trace) async {
    await _database.db.insert('replay_traces', {
      'id': trace.id,
      'agent_turn_id': trace.agentTurnId,
      'user_request': trace.userRequest,
      'routing_result_json': jsonEncode(trace.routingResult),
      'contract_json': jsonEncode(trace.contract),
      'memories_json': jsonEncode(trace.memoriesProvided),
      'active_entities_json': jsonEncode(trace.activeEntities),
      'tool_executions_json': jsonEncode(trace.toolExecutions),
      'execution_report_json': jsonEncode(trace.executionReport),
      'final_response_json': jsonEncode(trace.finalResponse),
      'verification_result_json': jsonEncode(trace.verificationResult),
      'model_configuration_json': jsonEncode(trace.modelConfiguration),
      'skill_execution_json': trace.skillExecution == null
          ? null
          : jsonEncode(trace.skillExecution),
      'user_feedback_json':
          trace.userFeedback == null ? null : jsonEncode(trace.userFeedback),
      'contains_sensitive_data': trace.containsSensitiveData ? 1 : 0,
      'created_at': trace.createdAt.toIso8601String(),
    });
  }

  Future<ReplayTrace?> getById(String id) async {
    final rows = await _database.db
        .query('replay_traces', where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  Future<ReplayTrace?> getByTurnId(String agentTurnId) async {
    final rows = await _database.db.query(
      'replay_traces',
      where: 'agent_turn_id = ?',
      whereArgs: [agentTurnId],
      orderBy: 'created_at DESC',
      limit: 1,
    );
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  /// Most recent trace overall - what "the last turn" refers to when the
  /// user corrects Exa.
  Future<ReplayTrace?> latest() async {
    final rows = await _database.db
        .query('replay_traces', orderBy: 'created_at DESC', limit: 1);
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  Future<List<ReplayTrace>> recent({int limit = 50}) async {
    final rows = await _database.db
        .query('replay_traces', orderBy: 'created_at DESC', limit: limit);
    return rows.map(_fromRow).toList();
  }

  /// Attaches user feedback (a correction) to an existing trace.
  Future<void> attachFeedback(String traceId, Map<String, dynamic> feedback) async {
    await _database.db.update(
      'replay_traces',
      {'user_feedback_json': jsonEncode(feedback)},
      where: 'id = ?',
      whereArgs: [traceId],
    );
  }

  Future<void> clearAll() async {
    await _database.db.delete('replay_traces');
  }

  static ReplayTrace _fromRow(Map<String, Object?> row) {
    Map<String, dynamic> decodeMap(Object? json) => json is String
        ? (jsonDecode(json) as Map).cast<String, dynamic>()
        : <String, dynamic>{};
    List<Map<String, dynamic>> decodeMapList(Object? json) => json is String
        ? (jsonDecode(json) as List)
            .whereType<Map>()
            .map((item) => item.cast<String, dynamic>())
            .toList()
        : <Map<String, dynamic>>[];
    return ReplayTrace(
      id: row['id'] as String,
      agentTurnId: row['agent_turn_id'] as String,
      userRequest: row['user_request'] as String,
      routingResult: decodeMap(row['routing_result_json']),
      contract: decodeMap(row['contract_json']),
      memoriesProvided: decodeMapList(row['memories_json']),
      activeEntities: decodeMapList(row['active_entities_json']),
      toolExecutions: decodeMapList(row['tool_executions_json']),
      executionReport: decodeMap(row['execution_report_json']),
      finalResponse: decodeMap(row['final_response_json']),
      verificationResult: decodeMap(row['verification_result_json']),
      modelConfiguration: decodeMap(row['model_configuration_json']),
      skillExecution: row['skill_execution_json'] is String
          ? decodeMap(row['skill_execution_json'])
          : null,
      userFeedback: row['user_feedback_json'] is String
          ? decodeMap(row['user_feedback_json'])
          : null,
      containsSensitiveData: row['contains_sensitive_data'] == 1,
      createdAt: DateTime.tryParse(row['created_at'] as String? ?? '') ??
          DateTime.now(),
    );
  }
}
