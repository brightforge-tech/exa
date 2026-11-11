import '../models/tool_execution_record.dart';
import '../services/execution_report_builder.dart';
import '../tools/agent_tool.dart';
import '../tools/tool_domains.dart';
import '../tools/tool_registry.dart';

/// Builds one [ToolExecutionRecord] from a completed tool call - shared by
/// the open agent loop and the skill executor so both produce identical
/// evidence for the report builder, verifier, and replay traces.
ToolExecutionRecord buildExecutionRecord({
  required ToolRegistry registry,
  required String toolUseId,
  required String toolName,
  required Map<String, Object?> input,
  required ToolResult result,
  required bool denied,
  required bool isControlPlane,
  required DateTime startedAt,
  String agentTurnId = '',
  String? idempotencyKey,
}) {
  final data =
      result.data is Map ? (result.data as Map).cast<String, Object?>() : null;
  // Either the identical call already ran this turn (idempotency), or an
  // unattended create found the record already on the user's list, or was
  // held because it may be (`DuplicateGuard`). All succeeded without making
  // anything.
  final wasDeduplicated = data?['already_completed'] == true ||
      data?['already_exists'] == true ||
      data?['possible_duplicate'] == true;
  final entityId = [
    data?['id'],
    data?['behavior_id'],
    data?['screen_key'],
    data?['pending_id'],
    data?['request_id'],
  ].whereType<String>().firstOrNull;
  final verb = toolName.split('_').first;
  const creates = {'create', 'store', 'add', 'propose'};
  const modifies = {
    'update', 'complete', 'mark', 'pause', 'resume', 'activate',
    'rollback', 'save',
  };
  const deletes = {'delete', 'cancel'};
  final deletedId = input['id'] is String ? input['id'] as String : null;
  return ToolExecutionRecord(
    toolCallId: toolUseId,
    toolName: toolName,
    agentTurnId: agentTurnId,
    domain: isControlPlane
        ? 'control'
        : registry.domainOf(toolName) ?? ToolDomains.core,
    arguments: input,
    status: denied
        ? ToolExecutionStatus.denied
        : result.success
            ? ToolExecutionStatus.success
            : ToolExecutionStatus.failure,
    startedAt: startedAt,
    completedAt: DateTime.now(),
    isControlPlane: isControlPlane,
    rawResult: result.data,
    idempotencyKey: idempotencyKey,
    wasDeduplicated: wasDeduplicated,
    summary: result.success
        ? ExecutionReportBuilder.summarize(
            toolName: toolName, arguments: input, rawResult: result.data)
        : null,
    errorMessage: result.error,
    createdEntityIds: [
      if (result.success &&
          !wasDeduplicated &&
          creates.contains(verb) &&
          entityId != null)
        entityId,
    ],
    modifiedEntityIds: [
      if (result.success &&
          !wasDeduplicated &&
          modifies.contains(verb) &&
          entityId != null)
        entityId,
    ],
    deletedEntityIds: [
      if (result.success &&
          !wasDeduplicated &&
          deletes.contains(verb) &&
          deletedId != null)
        deletedId,
    ],
  );
}
