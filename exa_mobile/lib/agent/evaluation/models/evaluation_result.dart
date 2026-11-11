/// The scored outcome of evaluating one turn (live or replayed) against a
/// scenario's expectations.
class EvaluationResult {
  const EvaluationResult({
    required this.scenarioId,
    required this.runId,
    required this.passed,
    required this.overallScore,
    required this.metrics,
    required this.failures,
    required this.createdAt,
  });

  final String scenarioId;
  final String runId;
  final bool passed;
  final double overallScore;
  final Map<String, double> metrics;
  final List<String> failures;
  final DateTime createdAt;

  Map<String, Object?> toJson() => {
        'scenario_id': scenarioId,
        'run_id': runId,
        'passed': passed,
        'overall_score': overallScore,
        'metrics': metrics,
        'failures': failures,
        'created_at': createdAt.toIso8601String(),
      };
}

/// Spec §13.10 pass criteria: zero forbidden-tool violations, zero
/// duplicates, full contract and output completion, and a strong overall
/// score.
bool evaluationPassed(EvaluationResult result) {
  return (result.metrics['forbidden_tool_violations'] ?? 1) == 0 &&
      (result.metrics['duplicate_action_rate'] ?? 1) == 0 &&
      (result.metrics['contract_completion'] ?? 0) == 1.0 &&
      (result.metrics['required_output_completion'] ?? 0) == 1.0 &&
      result.overallScore >= 0.85;
}
