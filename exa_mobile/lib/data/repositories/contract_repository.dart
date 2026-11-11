import 'dart:convert';

import '../../agent/models/turn_contract.dart';
import '../database/app_database.dart';

/// Persists completion contracts and their per-action statuses, so every
/// multi-step request leaves a durable record of what was demanded and what
/// actually resolved.
class ContractRepository {
  ContractRepository(this._database);

  final AppDatabase _database;

  Future<void> save(CompletionContract contract) async {
    final batch = _database.db.batch();
    batch.insert(
      'completion_contracts',
      {
        'id': contract.id,
        'agent_turn_id': contract.agentTurnId,
        'original_request': contract.originalRequest,
        'domains_json':
            contract.domains == null ? null : jsonEncode(contract.domains!.toList()),
        'required_outputs_json': jsonEncode(
            contract.requiredOutputs.map((o) => o.wireName).toList()),
        'constraints_json': jsonEncode(contract.constraints),
        'assumptions_json': jsonEncode(contract.assumptions),
        'skill_id': contract.skillId,
        'skill_version': contract.skillVersion,
        'requires_confirmation': contract.requiresConfirmation ? 1 : 0,
        'requires_synthesis': contract.requiresSynthesis ? 1 : 0,
        'requires_verification': contract.requiresVerification ? 1 : 0,
        'created_at': contract.createdAt.toIso8601String(),
      },
    );
    for (final action in contract.actions) {
      batch.insert('completion_contract_actions', _actionRow(contract.id, action));
    }
    await batch.commit(noResult: true);
  }

  /// Rewrites the action rows after resolution/verification so the stored
  /// contract reflects final statuses.
  Future<void> updateActions(
      String contractId, List<ContractAction> actions) async {
    final batch = _database.db.batch();
    batch.delete('completion_contract_actions',
        where: 'contract_id = ?', whereArgs: [contractId]);
    for (final action in actions) {
      batch.insert('completion_contract_actions', _actionRow(contractId, action));
    }
    await batch.commit(noResult: true);
  }

  Future<CompletionContract?> getByTurnId(String agentTurnId) async {
    final rows = await _database.db.query(
      'completion_contracts',
      where: 'agent_turn_id = ?',
      whereArgs: [agentTurnId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final row = rows.first;
    final actionRows = await _database.db.query(
      'completion_contract_actions',
      where: 'contract_id = ?',
      whereArgs: [row['id']],
    );
    return _fromRows(row, actionRows);
  }

  Map<String, Object?> _actionRow(String contractId, ContractAction action) => {
        'id': action.id,
        'contract_id': contractId,
        'description': action.description,
        'status': action.status.wireName,
        'required': action.required ? 1 : 0,
        'expected_tool_names_json': jsonEncode(action.expectedToolNames),
        'entity_ids_json': jsonEncode(action.entityIds),
        'failure_reason': action.failureReason,
      };

  static CompletionContract _fromRows(
    Map<String, Object?> row,
    List<Map<String, Object?>> actionRows,
  ) {
    List<String> decodeList(Object? json) => json is String
        ? (jsonDecode(json) as List).whereType<String>().toList()
        : const [];
    return CompletionContract(
      id: row['id'] as String,
      agentTurnId: row['agent_turn_id'] as String,
      originalRequest: row['original_request'] as String,
      domains: row['domains_json'] == null
          ? null
          : decodeList(row['domains_json']).toSet(),
      actions: [
        for (final actionRow in actionRows)
          ContractAction(
            id: actionRow['id'] as String,
            description: actionRow['description'] as String,
            status: ContractItemStatus.fromWireName(
                actionRow['status'] as String? ?? 'pending'),
            required: actionRow['required'] == 1,
            expectedToolNames:
                decodeList(actionRow['expected_tool_names_json']),
            entityIds: decodeList(actionRow['entity_ids_json']),
            failureReason: actionRow['failure_reason'] as String?,
          ),
      ],
      requiredOutputs: {
        for (final name in decodeList(row['required_outputs_json']))
          if (ResponseOutputType.fromWireName(name) != null)
            ResponseOutputType.fromWireName(name)!,
      },
      skillId: row['skill_id'] as String?,
      skillVersion: row['skill_version'] as int?,
      constraints: decodeList(row['constraints_json']),
      assumptions: decodeList(row['assumptions_json']),
      requiresConfirmation: row['requires_confirmation'] == 1,
      requiresSynthesis: row['requires_synthesis'] == 1,
      requiresVerification: row['requires_verification'] == 1,
      createdAt: DateTime.tryParse(row['created_at'] as String? ?? '') ??
          DateTime.now(),
    );
  }
}
