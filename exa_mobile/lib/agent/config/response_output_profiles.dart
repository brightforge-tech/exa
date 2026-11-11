import '../models/turn_contract.dart';

/// Deterministic fallback output requirements by request type.
///
/// When the router misses an output but the turn's tool usage makes the
/// request type obvious (emails were digested, files were changed, a rule
/// was edited), the orchestrator supplements the contract with the matching
/// profile so the final response still covers what users expect.
class ResponseOutputProfiles {
  ResponseOutputProfiles._();

  static const emailDigest = {
    ResponseOutputType.rundown,
    ResponseOutputType.taskList,
    ResponseOutputType.meetingList,
    ResponseOutputType.deadlineList,
    ResponseOutputType.attentionItems,
  };

  static const calendarChange = {
    ResponseOutputType.confirmation,
    ResponseOutputType.resultList,
    ResponseOutputType.warningList,
  };

  static const fileOperation = {
    ResponseOutputType.confirmation,
    ResponseOutputType.resultList,
    ResponseOutputType.failureReport,
  };

  static const behaviorRuleChange = {
    ResponseOutputType.changeDescription,
    ResponseOutputType.warningList,
    ResponseOutputType.confirmation,
  };

  /// Tools whose use marks a calendar change.
  static const calendarWriteTools = {
    'create_schedule_event',
    'update_schedule_event',
    'delete_schedule_event',
    'add_to_phone_calendar',
    'sync_device_calendar',
  };

  /// Tools whose use marks a file operation.
  static const fileWriteTools = {'store_file', 'write_file', 'delete_file'};

  /// Tools whose use marks a behavior-rule change.
  static const behaviorChangeTools = {
    'propose_behavior_change',
    'update_behavior',
    'rollback_behavior_version',
  };

  /// Extra outputs implied by [usedTools] and the contract's intent.
  /// Purely deterministic - this is the safety net under the router.
  static Set<ResponseOutputType> supplement({
    required CompletionContract contract,
    required Set<String> usedTools,
  }) {
    final extra = <ResponseOutputType>{};

    if (usedTools.contains('read_email_context') &&
        _hasDigestIntent(contract)) {
      extra.addAll(emailDigest);
    }
    if (usedTools.any(calendarWriteTools.contains)) {
      extra.addAll(calendarChange);
    }
    if (usedTools.any(fileWriteTools.contains)) {
      extra.addAll(fileOperation);
    }
    if (usedTools.any(behaviorChangeTools.contains)) {
      extra.addAll(behaviorRuleChange);
    }
    return extra;
  }

  static bool _hasDigestIntent(CompletionContract contract) {
    const markers = ['digest', 'rundown', 'review', 'summar'];
    bool mentions(String text) {
      final lower = text.toLowerCase();
      return markers.any(lower.contains);
    }

    return contract.actionDescriptions.any(mentions) ||
        mentions(contract.originalRequest) ||
        contract.requiredOutputs.contains(ResponseOutputType.rundown) ||
        contract.requiredOutputs.contains(ResponseOutputType.summary);
  }
}
