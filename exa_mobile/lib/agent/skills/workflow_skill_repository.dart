import 'dart:convert';

import '../../data/database/app_database.dart';
import '../models/turn_contract.dart';
import 'models/workflow_skill.dart';

/// SQLite persistence for workflow skills, their steps, and execution logs.
/// Skill versions are immutable: changing a skill means inserting the next
/// version, never rewriting one referenced by historical traces.
class WorkflowSkillRepository {
  WorkflowSkillRepository(this._database);

  final AppDatabase _database;

  Future<List<WorkflowSkill>> listEnabled() async {
    // Latest enabled version per name.
    final rows = await _database.db.rawQuery(
      'SELECT s.* FROM workflow_skills s '
      'JOIN (SELECT name, MAX(version) AS max_version FROM workflow_skills '
      '      WHERE is_enabled = 1 GROUP BY name) latest '
      'ON s.name = latest.name AND s.version = latest.max_version '
      'WHERE s.is_enabled = 1',
    );
    final skills = <WorkflowSkill>[];
    for (final row in rows) {
      skills.add(await _withSteps(row));
    }
    return skills;
  }

  Future<List<WorkflowSkill>> listAllVersions() async {
    final rows = await _database.db
        .query('workflow_skills', orderBy: 'name ASC, version DESC');
    final skills = <WorkflowSkill>[];
    for (final row in rows) {
      skills.add(await _withSteps(row));
    }
    return skills;
  }

  Future<WorkflowSkill?> getById(String id) async {
    final rows = await _database.db
        .query('workflow_skills', where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : _withSteps(rows.first);
  }

  Future<WorkflowSkill?> getByNameVersion(String name, int version) async {
    final rows = await _database.db.query(
      'workflow_skills',
      where: 'name = ? AND version = ?',
      whereArgs: [name, version],
      limit: 1,
    );
    return rows.isEmpty ? null : _withSteps(rows.first);
  }

  Future<WorkflowSkill?> getLatestByName(String name) async {
    final rows = await _database.db.query(
      'workflow_skills',
      where: 'name = ? AND is_enabled = 1',
      whereArgs: [name],
      orderBy: 'version DESC',
      limit: 1,
    );
    return rows.isEmpty ? null : _withSteps(rows.first);
  }

  Future<void> insert(WorkflowSkill skill) async {
    final batch = _database.db.batch();
    batch.insert('workflow_skills', {
      'id': skill.id,
      'name': skill.name,
      'description': skill.description,
      'version': skill.version,
      'required_domains_json': jsonEncode(skill.requiredDomains.toList()),
      'required_outputs_json':
          jsonEncode(skill.requiredOutputs.map((o) => o.wireName).toList()),
      'trigger_examples_json': jsonEncode(skill.triggerExamples),
      'input_schema_json': jsonEncode(skill.inputSchema),
      'execution_mode': skill.mode.wireName,
      'is_enabled': skill.isEnabled ? 1 : 0,
      'is_system_skill': skill.isSystemSkill ? 1 : 0,
      'requires_confirmation': skill.requiresConfirmation ? 1 : 0,
      'created_at': skill.createdAt.toIso8601String(),
      'updated_at': skill.updatedAt.toIso8601String(),
    });
    for (var order = 0; order < skill.steps.length; order++) {
      final step = skill.steps[order];
      batch.insert('workflow_skill_steps', {
        'id': '${skill.id}_${step.id}',
        'skill_id': skill.id,
        'step_key': step.id,
        'step_order': order,
        'name': step.name,
        'tool_name': step.toolName,
        'argument_template_json': jsonEncode(step.argumentTemplate),
        'depends_on_json': jsonEncode(step.dependsOn),
        'condition_expression': step.condition,
        'failure_policy': step.failurePolicy.wireName,
        'max_retries': step.maxRetries,
        'requires_confirmation': step.requiresConfirmation ? 1 : 0,
        'is_optional': step.isOptional ? 1 : 0,
        'for_each_path': step.forEachPath,
      });
    }
    await batch.commit(noResult: true);
  }

  Future<void> setEnabled(String id, bool enabled) async {
    await _database.db.update(
      'workflow_skills',
      {
        'is_enabled': enabled ? 1 : 0,
        'updated_at': DateTime.now().toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  // ---------------------------------------------------- execution logging --

  Future<void> recordExecutionStart({
    required String executionId,
    required WorkflowSkill skill,
    required String agentTurnId,
    required Map<String, dynamic> inputs,
  }) async {
    await _database.db.insert('skill_executions', {
      'id': executionId,
      'skill_id': skill.id,
      'skill_version': skill.version,
      'agent_turn_id': agentTurnId,
      'input_json': jsonEncode(inputs),
      'status': 'running',
      'started_at': DateTime.now().toIso8601String(),
    });
  }

  Future<void> recordExecutionEnd({
    required String executionId,
    required String status,
    String? failureReason,
  }) async {
    await _database.db.update(
      'skill_executions',
      {
        'status': status,
        'completed_at': DateTime.now().toIso8601String(),
        'failure_reason': failureReason,
      },
      where: 'id = ?',
      whereArgs: [executionId],
    );
  }

  Future<void> recordStep({
    required String executionId,
    required String stepId,
    required String status,
    String? argumentsJson,
    String? resultJson,
    String? errorMessage,
    int retryCount = 0,
    DateTime? startedAt,
    DateTime? completedAt,
  }) async {
    await _database.db.insert('skill_execution_steps', {
      'id': '${executionId}_${stepId}_${DateTime.now().microsecondsSinceEpoch}',
      'skill_execution_id': executionId,
      'skill_step_id': stepId,
      'status': status,
      'arguments_json': argumentsJson,
      'result_json': resultJson,
      'error_message': errorMessage,
      'retry_count': retryCount,
      'started_at': startedAt?.toIso8601String(),
      'completed_at': completedAt?.toIso8601String(),
    });
  }

  // ---------------------------------------------------------------- rows --

  Future<WorkflowSkill> _withSteps(Map<String, Object?> row) async {
    final stepRows = await _database.db.query(
      'workflow_skill_steps',
      where: 'skill_id = ?',
      whereArgs: [row['id']],
      orderBy: 'step_order ASC',
    );
    List<String> decodeList(Object? json) => json is String
        ? (jsonDecode(json) as List).whereType<String>().toList()
        : const [];
    return WorkflowSkill(
      id: row['id'] as String,
      name: row['name'] as String,
      description: row['description'] as String? ?? '',
      version: row['version'] as int,
      requiredDomains: decodeList(row['required_domains_json']).toSet(),
      requiredOutputs: {
        for (final name in decodeList(row['required_outputs_json']))
          if (ResponseOutputType.fromWireName(name) != null)
            ResponseOutputType.fromWireName(name)!,
      },
      triggerExamples: decodeList(row['trigger_examples_json']),
      inputSchema: row['input_schema_json'] is String
          ? (jsonDecode(row['input_schema_json'] as String) as Map)
              .cast<String, dynamic>()
          : const {},
      mode: SkillExecutionMode.fromWireName(
          row['execution_mode'] as String? ?? 'guided'),
      isEnabled: row['is_enabled'] == 1,
      isSystemSkill: row['is_system_skill'] == 1,
      requiresConfirmation: row['requires_confirmation'] == 1,
      steps: [
        for (final stepRow in stepRows)
          SkillStep(
            id: stepRow['step_key'] as String? ?? stepRow['id'] as String,
            name: stepRow['name'] as String,
            toolName: stepRow['tool_name'] as String,
            argumentTemplate: stepRow['argument_template_json'] is String
                ? (jsonDecode(stepRow['argument_template_json'] as String)
                        as Map)
                    .cast<String, dynamic>()
                : const {},
            dependsOn: decodeList(stepRow['depends_on_json']),
            condition: stepRow['condition_expression'] as String?,
            failurePolicy: SkillStepFailurePolicy.fromWireName(
                stepRow['failure_policy'] as String? ?? 'stop'),
            maxRetries: (stepRow['max_retries'] as int?) ?? 0,
            requiresConfirmation: stepRow['requires_confirmation'] == 1,
            isOptional: stepRow['is_optional'] == 1,
            forEachPath: stepRow['for_each_path'] as String?,
          ),
      ],
      createdAt: DateTime.tryParse(row['created_at'] as String? ?? '') ??
          DateTime.now(),
      updatedAt: DateTime.tryParse(row['updated_at'] as String? ?? '') ??
          DateTime.now(),
    );
  }
}
