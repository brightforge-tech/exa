import '../models/agent_execution_report.dart';
import '../models/turn_contract.dart';

/// Decides whether a turn needs a final no-tool response-generation call.
///
/// Simple one-shot requests ("open my task screen") return a deterministic
/// confirmation and skip the extra call; anything that changed data, spanned
/// domains, hit problems, or owes the user an output gets synthesized.
class SynthesisPolicy {
  const SynthesisPolicy();

  bool requiresSynthesis({
    required CompletionContract contract,
    required AgentExecutionReport report,
    required int toolCallCount,
    required int domainCount,
  }) {
    if (contract.requiresSynthesis) {
      return true;
    }
    if (contract.requiredOutputs.isNotEmpty) {
      return true;
    }
    // A required action that never reached a terminal state means the turn
    // did not do what it was asked. The loop's own text about it is then the
    // least trustworthy thing in the turn - this is the model writing "the
    // Settings screen is now open" having never called open_screen - so it
    // gets rebuilt from the execution report and checked, rather than
    // forwarded verbatim.
    if (contract.actions
        .any((action) => action.required && !action.isResolved)) {
      return true;
    }
    if (toolCallCount > 1) {
      return true;
    }
    if (domainCount > 1) {
      return true;
    }
    if (report.hasFailures || report.hasWarnings) {
      return true;
    }
    if (report.tasksCreated.isNotEmpty ||
        report.eventsCreated.isNotEmpty ||
        report.eventsModified.isNotEmpty ||
        report.emailDigestItems.isNotEmpty ||
        report.filesAffected.isNotEmpty ||
        report.screensCreated.isNotEmpty ||
        report.rulesChanged.isNotEmpty) {
      return true;
    }
    return false;
  }
}
