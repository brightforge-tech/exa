import 'dart:convert';

enum ToolExecutionStatus {
  success,
  failure,
  partial,
  cancelled,
  denied,
}

/// One executed tool call, captured for the execution report, verification,
/// replay traces, and diagnostics.
///
/// Every tool call in a turn produces a record - including `expand_tools`,
/// which is flagged as control-plane activity (it changes the control
/// environment; it does not complete part of the user's request).
class ToolExecutionRecord {
  const ToolExecutionRecord({
    required this.toolCallId,
    required this.toolName,
    required this.domain,
    required this.arguments,
    required this.status,
    required this.startedAt,
    required this.completedAt,
    this.agentTurnId = '',
    this.isControlPlane = false,
    this.rawResult,
    this.summary,
    this.errorMessage,
    this.idempotencyKey,
    this.wasDeduplicated = false,
    this.createdEntityIds = const [],
    this.modifiedEntityIds = const [],
    this.deletedEntityIds = const [],
    this.warnings = const [],
  });

  final String toolCallId;
  final String toolName;

  /// The agent turn this call belongs to (`turn_<uuid>`).
  final String agentTurnId;

  /// Tool domain name (see [ToolDomains]); 'control' for meta-tools.
  final String domain;
  final Map<String, Object?> arguments;
  final ToolExecutionStatus status;
  final DateTime startedAt;
  final DateTime completedAt;

  /// Scope expansion and similar meta-calls that change the control
  /// environment rather than completing user work.
  final bool isControlPlane;

  final Object? rawResult;

  /// Short machine-generated or tool-provided description.
  final String? summary;
  final String? errorMessage;

  /// Set on side-effecting calls; used to block duplicate execution.
  final String? idempotencyKey;

  /// True when this call was answered from a previous successful execution
  /// with the same idempotency key instead of running again.
  final bool wasDeduplicated;

  final List<String> createdEntityIds;
  final List<String> modifiedEntityIds;
  final List<String> deletedEntityIds;
  final List<String> warnings;

  /// Every entity id this call touched, in one list.
  List<String> get touchedEntityIds => [
        ...createdEntityIds,
        ...modifiedEntityIds,
        ...deletedEntityIds,
      ];

  /// Serialized for replay traces. Raw results are stored as JSON when
  /// encodable, otherwise as their string form (never dropped silently).
  Map<String, Object?> toJson() => {
        'tool_call_id': toolCallId,
        'agent_turn_id': agentTurnId,
        'tool_name': toolName,
        'domain': domain,
        'arguments': arguments,
        'status': status.name,
        'started_at': startedAt.toIso8601String(),
        'completed_at': completedAt.toIso8601String(),
        'is_control_plane': isControlPlane,
        if (rawResult != null) 'raw_result': _encodable(rawResult),
        if (summary != null) 'summary': summary,
        if (errorMessage != null) 'error_message': errorMessage,
        if (idempotencyKey != null) 'idempotency_key': idempotencyKey,
        if (wasDeduplicated) 'was_deduplicated': true,
        if (createdEntityIds.isNotEmpty)
          'created_entity_ids': createdEntityIds,
        if (modifiedEntityIds.isNotEmpty)
          'modified_entity_ids': modifiedEntityIds,
        if (deletedEntityIds.isNotEmpty)
          'deleted_entity_ids': deletedEntityIds,
        if (warnings.isNotEmpty) 'warnings': warnings,
      };

  static Object? _encodable(Object? value) {
    try {
      jsonEncode(value);
      return value;
    } catch (_) {
      return value.toString();
    }
  }
}
