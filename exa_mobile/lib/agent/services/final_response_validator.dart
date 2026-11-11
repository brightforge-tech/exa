import '../models/agent_execution_report.dart';
import '../models/synthesized_response.dart';
import '../models/turn_contract.dart';

class FinalResponseValidationResult {
  const FinalResponseValidationResult({
    required this.isValid,
    required this.missingOutputs,
  });

  final bool isValid;
  final Set<ResponseOutputType> missingOutputs;
}

/// Checks the synthesized response against the contract's required outputs,
/// using the structured `included_outputs` declaration rather than trying
/// to infer completeness from prose.
class FinalResponseValidator {
  const FinalResponseValidator();

  FinalResponseValidationResult validate({
    required CompletionContract contract,
    required AgentExecutionReport report,
    required SynthesizedResponse response,
  }) {
    if (response.message.trim().isEmpty) {
      return FinalResponseValidationResult(
        isValid: false,
        missingOutputs: contract.requiredOutputs,
      );
    }
    final missing =
        contract.requiredOutputs.difference(response.includedOutputs);
    // Extra declared outputs are allowed; only required-but-missing fail.
    return FinalResponseValidationResult(
      isValid: missing.isEmpty,
      missingOutputs: missing,
    );
  }
}
