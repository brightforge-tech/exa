import '../entities/models/active_entity_context.dart';
import '../memory/memory_retriever.dart';
import '../memory/models/agent_memory.dart';
import '../models/agent_execution_report.dart';
import '../models/agent_ids.dart';
import '../models/synthesized_response.dart';
import '../models/tool_execution_record.dart';
import '../models/turn_contract.dart';
import '../models/verification_result.dart';
import '../skills/models/workflow_skill.dart';
import 'models/replay_trace.dart';
import 'replay_redaction_service.dart';
import 'replay_trace_repository.dart';

/// Records one replay trace per significant turn. Traces are redacted by
/// default; [storeFullTraces] (a user setting for local debugging) keeps the
/// raw values and marks the row sensitive.
class ReplayRecorder {
  ReplayRecorder({
    required ReplayTraceRepository repository,
    ReplayRedactionService redaction = const ReplayRedactionService(),
  })  : _traces = repository,
        _redactionService = redaction;

  final ReplayTraceRepository _traces;
  final ReplayRedactionService _redactionService;

  Future<ReplayTrace?> record({
    required String agentTurnId,
    required String userRequest,
    required Map<String, dynamic> routingResult,
    required CompletionContract contract,
    required MemoryRetrievalResult? memories,
    required ActiveEntityContext? activeEntities,
    required List<ToolExecutionRecord> records,
    required AgentExecutionReport report,
    required SynthesizedResponse response,
    required VerificationResult verification,
    required Map<String, dynamic> modelConfiguration,
    SkillExecutionResult? skillExecution,
    bool storeFullTraces = false,
  }) async {
    var trace = ReplayTrace(
      id: AgentId.trace(),
      agentTurnId: agentTurnId,
      createdAt: DateTime.now(),
      userRequest: userRequest,
      routingResult: routingResult,
      contract: contract.toJson().cast<String, dynamic>(),
      memoriesProvided: [
        for (final memory in memories?.memories ?? const <AgentMemory>[])
          memory.toContextJson().cast<String, dynamic>(),
      ],
      activeEntities: [
        for (final summary
            in activeEntities?.toSummaries() ?? const <Map<String, Object?>>[])
          summary.cast<String, dynamic>(),
      ],
      toolExecutions: [
        for (final record in records)
          record.toJson().cast<String, dynamic>(),
      ],
      executionReport: report.toJson().cast<String, dynamic>(),
      finalResponse: response.toJson().cast<String, dynamic>(),
      verificationResult: verification.toJson().cast<String, dynamic>(),
      modelConfiguration: modelConfiguration,
      skillExecution: skillExecution?.toJson().cast<String, dynamic>(),
      containsSensitiveData: storeFullTraces,
    );
    if (!storeFullTraces) {
      trace = _redactionService.redact(trace);
    }
    await _traces.insert(trace);
    return trace;
  }
}
