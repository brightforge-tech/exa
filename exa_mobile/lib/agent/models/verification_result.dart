import 'turn_contract.dart';

enum VerificationSeverity {
  info,
  warning,
  error,
  critical;

  String get wireName => name;
}

/// One problem the verifier found with the finished turn.
class VerificationIssue {
  const VerificationIssue({
    required this.code,
    required this.message,
    required this.severity,
    this.relatedContractActionId,
    this.relatedToolRecordId,
    this.relatedOutput,
  });

  final String code;
  final String message;
  final VerificationSeverity severity;
  final String? relatedContractActionId;
  final String? relatedToolRecordId;
  final ResponseOutputType? relatedOutput;

  Map<String, Object?> toJson() => {
        'code': code,
        'message': message,
        'severity': severity.wireName,
        if (relatedContractActionId != null)
          'related_contract_action_id': relatedContractActionId,
        if (relatedToolRecordId != null)
          'related_tool_record_id': relatedToolRecordId,
        if (relatedOutput != null) 'related_output': relatedOutput!.wireName,
      };
}

/// The verifier's judgment of a finished turn: evidence-based, never derived
/// from the final text alone.
class VerificationResult {
  const VerificationResult({
    required this.passed,
    required this.score,
    required this.issues,
    required this.missingOutputs,
    required this.unsupportedClaims,
    required this.requiresRepair,
    required this.requiresUserAttention,
    this.fabricatedDates = const [],
    this.authoritativeDates = const [],
    this.performed = true,
  });

  /// A verification that never ran (lightweight turns).
  const VerificationResult.skipped()
      : passed = true,
        score = 1.0,
        issues = const [],
        missingOutputs = const {},
        unsupportedClaims = const [],
        fabricatedDates = const [],
        authoritativeDates = const [],
        requiresRepair = false,
        requiresUserAttention = false,
        performed = false;

  final bool passed;
  final double score;
  final List<VerificationIssue> issues;
  final Set<ResponseOutputType> missingOutputs;

  /// Claim descriptions the execution report does not support.
  final List<String> unsupportedClaims;

  /// Dates (yyyy-mm-dd) the response states that nothing in the turn's
  /// evidence contains - almost always a model "correcting" a stored future
  /// date to match its own stale sense of today.
  final List<String> fabricatedDates;

  /// The `..._label` values the tools actually produced, for a repair to
  /// copy verbatim.
  final List<String> authoritativeDates;

  final bool requiresRepair;
  final bool requiresUserAttention;

  /// False when verification was skipped for a lightweight turn.
  final bool performed;

  Map<String, Object?> toJson() => {
        'performed': performed,
        'passed': passed,
        'score': score,
        'issues': [for (final issue in issues) issue.toJson()],
        'missing_outputs': missingOutputs.map((o) => o.wireName).toList(),
        'unsupported_claims': unsupportedClaims,
        if (fabricatedDates.isNotEmpty) 'fabricated_dates': fabricatedDates,
        'requires_repair': requiresRepair,
        'requires_user_attention': requiresUserAttention,
      };
}
