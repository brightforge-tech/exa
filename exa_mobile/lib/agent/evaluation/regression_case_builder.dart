import '../models/agent_ids.dart';
import '../models/turn_contract.dart';
import 'models/evaluation_scenario.dart';
import 'models/replay_trace.dart';

/// Converts a (redacted) replay trace plus a user correction into a
/// regression scenario, so a production failure becomes a permanent test:
/// same request, same mocked tool results, and expectations that would have
/// caught the failure.
class RegressionCaseBuilder {
  const RegressionCaseBuilder();

  /// [failureType]: missing_required_output | duplicate_action |
  /// unsupported_claim | wrong_tool | other.
  EvaluationScenario build({
    required ReplayTrace trace,
    required String userCorrection,
    required String failureType,
    String? missingOutputWireName,
  }) {
    // Mock every tool result the original turn saw, in call order.
    final mockState = <String, List<Map<String, dynamic>>>{};
    final calledTools = <String>[];
    for (final execution in trace.toolExecutions) {
      if (execution['is_control_plane'] == true) continue;
      final toolName = execution['tool_name'] as String?;
      if (toolName == null) continue;
      calledTools.add(toolName);
      final raw = execution['raw_result'];
      mockState.putIfAbsent(toolName, () => []).add(
            raw is Map
                ? raw.cast<String, dynamic>()
                : {'value': raw?.toString()},
          );
    }

    final requiredOutputs = <ResponseOutputType>{
      for (final name in ((trace.contract['required_outputs'] as List?) ??
              const [])
          .whereType<String>())
        if (ResponseOutputType.fromWireName(name) != null)
          ResponseOutputType.fromWireName(name)!,
    };
    if (missingOutputWireName != null) {
      final missing = ResponseOutputType.fromWireName(missingOutputWireName);
      if (missing != null) requiredOutputs.add(missing);
    }

    // Side-effecting tools that ran once must not run more often in a
    // correct replay; duplicate-action failures pin the exact budget.
    final maximumToolCalls = failureType == 'duplicate_action'
        ? calledTools.length - 1
        : calledTools.length + 4;

    return EvaluationScenario(
      id: AgentId.evaluation(),
      name: 'regression: $failureType (${trace.agentTurnId})',
      userRequest: trace.userRequest,
      mockState: mockState,
      expectedDomains: ((trace.contract['domains'] as List?) ?? const [])
          .whereType<String>()
          .toSet(),
      requiredTools: calledTools.toSet(),
      forbiddenTools: const {},
      requiredOutputs: requiredOutputs,
      expectedSkill: trace.skillExecution?['skill_name'] as String?,
      maximumToolCalls: maximumToolCalls < 1 ? 1 : maximumToolCalls,
      tags: ['regression', failureType],
      sourceTraceId: trace.id,
      createdAt: DateTime.now(),
    );
  }

  /// The stored feedback payload attached to the original trace.
  Map<String, dynamic> feedbackPayload({
    required String failureType,
    required String userCorrection,
    required String originalTurnId,
    String? missingOutputWireName,
  }) =>
      {
        'failure_type': failureType,
        'missing_output': ?missingOutputWireName,
        'original_turn_id': originalTurnId,
        'user_correction': userCorrection,
      };
}
