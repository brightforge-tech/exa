import '../models/agent_ids.dart';
import 'models/evaluation_result.dart';
import 'models/evaluation_scenario.dart';
import 'models/replay_trace.dart';

/// Scores a turn (as a replay trace) against a scenario's expectations.
/// All metrics are 0-1 unless they are counts/rates.
class EvaluationScorer {
  const EvaluationScorer();

  EvaluationResult score({
    required EvaluationScenario scenario,
    required ReplayTrace trace,
    String? runId,
  }) {
    final failures = <String>[];
    final metrics = <String, double>{};

    // --- Domains ----------------------------------------------------------
    final routedDomains = ((trace.routingResult['domains'] as List?) ??
            (trace.contract['domains'] as List?) ??
            const [])
        .whereType<String>()
        .toSet();
    final expected = scenario.expectedDomains;
    if (expected.isNotEmpty) {
      final correct = routedDomains.intersection(expected).length;
      metrics['domain_precision'] =
          routedDomains.isEmpty ? 0 : correct / routedDomains.length;
      metrics['domain_recall'] = correct / expected.length;
      if (metrics['domain_recall']! < 1.0) {
        failures.add('Missing expected domains: '
            '${expected.difference(routedDomains).join(', ')}');
      }
    }

    // --- Tools ------------------------------------------------------------
    final calledTools = [
      for (final execution in trace.toolExecutions)
        if (execution['is_control_plane'] != true)
          execution['tool_name'] as String? ?? '',
    ].where((name) => name.isNotEmpty).toList();
    final calledSet = calledTools.toSet();

    if (scenario.requiredTools.isNotEmpty) {
      final covered =
          scenario.requiredTools.intersection(calledSet).length;
      metrics['required_tool_coverage'] =
          covered / scenario.requiredTools.length;
      if (covered < scenario.requiredTools.length) {
        failures.add('Required tools not called: '
            '${scenario.requiredTools.difference(calledSet).join(', ')}');
      }
    }

    final violations =
        scenario.forbiddenTools.intersection(calledSet).length.toDouble();
    metrics['forbidden_tool_violations'] = violations;
    if (violations > 0) {
      failures.add('Forbidden tools called: '
          '${scenario.forbiddenTools.intersection(calledSet).join(', ')}');
    }

    metrics['tool_call_count'] = calledTools.length.toDouble();
    if (calledTools.length > scenario.maximumToolCalls) {
      failures.add('Used ${calledTools.length} tool calls '
          '(limit ${scenario.maximumToolCalls}).');
    }

    // Duplicate actions: identical successful side-effecting calls.
    var duplicates = 0;
    final seen = <String>{};
    for (final execution in trace.toolExecutions) {
      if (execution['status'] != 'success') continue;
      final key = execution['idempotency_key'] as String? ??
          '${execution['tool_name']}|${execution['arguments']}';
      final isSideEffect = execution['idempotency_key'] != null;
      if (isSideEffect && !seen.add(key) &&
          execution['was_deduplicated'] != true) {
        duplicates++;
      }
    }
    metrics['duplicate_action_rate'] =
        calledTools.isEmpty ? 0 : duplicates / calledTools.length;
    if (duplicates > 0) {
      failures.add('$duplicates duplicate side-effecting call(s).');
    }

    // --- Contract & outputs -----------------------------------------------
    final actions = ((trace.contract['actions'] as List?) ?? const [])
        .whereType<Map>()
        .toList();
    final requiredActions =
        actions.where((action) => action['required'] != false).toList();
    final resolved = requiredActions.where((action) {
      final status = action['status'];
      return status == 'completed' ||
          status == 'failed' ||
          status == 'skipped' ||
          status == 'cancelled';
    }).length;
    metrics['contract_completion'] = requiredActions.isEmpty
        ? 1.0
        : resolved / requiredActions.length;
    if (metrics['contract_completion']! < 1.0) {
      failures.add('Unresolved required contract actions.');
    }

    final includedOutputs =
        ((trace.finalResponse['included_outputs'] as List?) ?? const [])
            .whereType<String>()
            .toSet();
    final requiredOutputs =
        scenario.requiredOutputs.map((o) => o.wireName).toSet();
    metrics['required_output_completion'] = requiredOutputs.isEmpty
        ? 1.0
        : requiredOutputs.intersection(includedOutputs).length /
            requiredOutputs.length;
    if (metrics['required_output_completion']! < 1.0) {
      failures.add('Missing required outputs: '
          '${requiredOutputs.difference(includedOutputs).join(', ')}');
    }

    // --- Skill selection ----------------------------------------------------
    if (scenario.expectedSkill != null) {
      final usedSkill = trace.skillExecution?['skill_name'] ??
          trace.contract['skill_name'] ??
          trace.routingResult['skill'];
      metrics['skill_selection'] =
          usedSkill == scenario.expectedSkill ? 1.0 : 0.0;
      if (metrics['skill_selection'] != 1.0) {
        failures.add('Expected skill ${scenario.expectedSkill}, '
            'got ${usedSkill ?? 'none'}.');
      }
    }

    // --- Verification -------------------------------------------------------
    metrics['verification_passed'] =
        trace.verificationResult['passed'] == true ? 1.0 : 0.0;
    metrics['unsupported_claims'] =
        ((trace.verificationResult['unsupported_claims'] as List?) ?? const [])
            .length
            .toDouble();
    if (metrics['unsupported_claims']! > 0) {
      failures.add('Response contains unsupported claims.');
    }

    // --- Overall ------------------------------------------------------------
    final scoreParts = <double>[
      metrics['domain_recall'] ?? 1.0,
      metrics['required_tool_coverage'] ?? 1.0,
      metrics['contract_completion'] ?? 1.0,
      metrics['required_output_completion'] ?? 1.0,
      metrics['verification_passed'] ?? 1.0,
      if (scenario.expectedSkill != null) metrics['skill_selection'] ?? 0.0,
      violations > 0 ? 0.0 : 1.0,
      duplicates > 0 ? 0.0 : 1.0,
    ];
    final overall =
        scoreParts.reduce((a, b) => a + b) / scoreParts.length;

    final result = EvaluationResult(
      scenarioId: scenario.id,
      runId: runId ?? AgentId.evaluation(),
      passed: false, // finalized below via evaluationPassed
      overallScore: overall,
      metrics: metrics,
      failures: failures,
      createdAt: DateTime.now(),
    );
    return EvaluationResult(
      scenarioId: result.scenarioId,
      runId: result.runId,
      passed: evaluationPassed(result),
      overallScore: result.overallScore,
      metrics: result.metrics,
      failures: result.failures,
      createdAt: result.createdAt,
    );
  }
}
