import 'dart:convert';

import '../../data/database/app_database.dart';
import '../models/turn_contract.dart';
import 'models/evaluation_result.dart';
import 'models/evaluation_scenario.dart';

/// SQLite persistence for evaluation scenarios and their run results.
class EvaluationRepository {
  EvaluationRepository(this._database);

  final AppDatabase _database;

  Future<void> insertScenario(EvaluationScenario scenario) async {
    await _database.db.insert('evaluation_scenarios', {
      'id': scenario.id,
      'name': scenario.name,
      'user_request': scenario.userRequest,
      'mock_state_json': jsonEncode(scenario.mockState),
      'expected_domains_json': jsonEncode(scenario.expectedDomains.toList()),
      'required_tools_json': jsonEncode(scenario.requiredTools.toList()),
      'forbidden_tools_json': jsonEncode(scenario.forbiddenTools.toList()),
      'required_outputs_json':
          jsonEncode(scenario.requiredOutputs.map((o) => o.wireName).toList()),
      'expected_skill': scenario.expectedSkill,
      'expected_entities_json': jsonEncode(scenario.expectedEntities),
      'expected_memory_ids_json': jsonEncode(scenario.expectedMemoryIds),
      'maximum_tool_calls': scenario.maximumToolCalls,
      'tags_json': jsonEncode(scenario.tags),
      'source_trace_id': scenario.sourceTraceId,
      'created_at': scenario.createdAt.toIso8601String(),
    });
  }

  Future<List<EvaluationScenario>> listScenarios() async {
    final rows = await _database.db
        .query('evaluation_scenarios', orderBy: 'created_at DESC');
    return rows.map(_scenarioFromRow).toList();
  }

  Future<void> insertResult(EvaluationResult result) async {
    await _database.db.insert('evaluation_results', {
      'id': result.runId,
      'scenario_id': result.scenarioId,
      'passed': result.passed ? 1 : 0,
      'overall_score': result.overallScore,
      'metrics_json': jsonEncode(result.metrics),
      'failures_json': jsonEncode(result.failures),
      'created_at': result.createdAt.toIso8601String(),
    });
  }

  Future<List<EvaluationResult>> resultsForScenario(String scenarioId) async {
    final rows = await _database.db.query(
      'evaluation_results',
      where: 'scenario_id = ?',
      whereArgs: [scenarioId],
      orderBy: 'created_at DESC',
    );
    return [
      for (final row in rows)
        EvaluationResult(
          scenarioId: row['scenario_id'] as String,
          runId: row['id'] as String,
          passed: row['passed'] == 1,
          overallScore: (row['overall_score'] as num).toDouble(),
          metrics: row['metrics_json'] is String
              ? ((jsonDecode(row['metrics_json'] as String) as Map)
                  .map((key, value) =>
                      MapEntry(key.toString(), (value as num).toDouble())))
              : const {},
          failures: row['failures_json'] is String
              ? (jsonDecode(row['failures_json'] as String) as List)
                  .whereType<String>()
                  .toList()
              : const [],
          createdAt: DateTime.tryParse(row['created_at'] as String? ?? '') ??
              DateTime.now(),
        ),
    ];
  }

  static EvaluationScenario _scenarioFromRow(Map<String, Object?> row) {
    List<String> decodeList(Object? json) => json is String
        ? (jsonDecode(json) as List).whereType<String>().toList()
        : const [];
    return EvaluationScenario(
      id: row['id'] as String,
      name: row['name'] as String,
      userRequest: row['user_request'] as String,
      mockState: row['mock_state_json'] is String
          ? (jsonDecode(row['mock_state_json'] as String) as Map)
              .cast<String, dynamic>()
          : const {},
      expectedDomains: decodeList(row['expected_domains_json']).toSet(),
      requiredTools: decodeList(row['required_tools_json']).toSet(),
      forbiddenTools: decodeList(row['forbidden_tools_json']).toSet(),
      requiredOutputs: {
        for (final name in decodeList(row['required_outputs_json']))
          if (ResponseOutputType.fromWireName(name) != null)
            ResponseOutputType.fromWireName(name)!,
      },
      expectedSkill: row['expected_skill'] as String?,
      expectedEntities: decodeList(row['expected_entities_json']),
      expectedMemoryIds: decodeList(row['expected_memory_ids_json']),
      maximumToolCalls: (row['maximum_tool_calls'] as int?) ?? 24,
      tags: decodeList(row['tags_json']),
      sourceTraceId: row['source_trace_id'] as String?,
      createdAt: DateTime.tryParse(row['created_at'] as String? ?? '') ??
          DateTime.now(),
    );
  }
}
