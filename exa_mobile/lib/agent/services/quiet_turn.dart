import '../models/agent_execution_report.dart';
import '../models/tool_execution_record.dart';
import '../models/turn_contract.dart';
import 'response_synthesizer.dart';

/// Whether a turn found nothing to tell the user about.
///
/// A scheduled "digest my chats every 5 minutes" used to post a chat card
/// and a notification on every run; when nothing has arrived since the last
/// run, that is noise. Quiet means: the turn only checked things (no tool
/// outside the housekeeping set), every sync/read reported zero new items,
/// nothing was created or changed, nothing failed, and no required action
/// was left undone. Any doubt - a sync result without a count, a tool
/// outside the set - is *not* quiet, because a wrongly hidden card costs
/// more than one more card.
///
/// Decided in code from the records, never from the model's opinion of its
/// own run.
class QuietTurn {
  const QuietTurn._();

  static bool isQuiet({
    required CompletionContract contract,
    required AgentExecutionReport report,
    required List<ToolExecutionRecord> records,
  }) =>
      ResponseSynthesizer.nothingNeededDoing(
          contract: contract, report: report) &&
      nothingNewRead(records);

  /// Settles the actions a turn was given but had no input for.
  ///
  /// "Read my new messages and pull out any tasks" on a run that read zero
  /// new messages has no tasks to pull out. Those actions are complete for
  /// want of anything to do, not left undone: there is nothing to disclose,
  /// and the turn can be quiet. Applies only when [nothingNewRead] holds -
  /// a turn that read something, changed something, or failed keeps its
  /// unresolved actions and answers for them.
  static CompletionContract settleUnneededActions({
    required CompletionContract contract,
    required List<ToolExecutionRecord> records,
  }) {
    if (contract.actions.every((action) => action.isResolved)) {
      return contract;
    }
    if (!nothingNewRead(records)) return contract;
    return contract.copyWith(actions: [
      for (final action in contract.actions)
        action.isResolved
            ? action
            : action.copyWith(status: ContractItemStatus.completed),
    ]);
  }

  /// True when every sync/read tool this turn ran reported zero new items.
  ///
  /// A housekeeping tool whose result carries no count is "we do not know",
  /// which is not "nothing new". Marking items handled adds nothing new by
  /// definition.
  static bool nothingNewRead(List<ToolExecutionRecord> records) {
    var sawCount = false;
    for (final record in records) {
      if (record.isControlPlane) continue;
      if (record.status != ToolExecutionStatus.success) return false;
      final data = record.rawResult is Map
          ? (record.rawResult as Map).cast<String, Object?>()
          : const <String, Object?>{};
      final count = switch (record.toolName) {
        'sync_messages' => _count(data['new_messages']),
        'sync_emails' => _count(data['new_emails']),
        'sync_device_calendar' => _count(data['imported']),
        'read_message_context' || 'read_email_context' =>
          _count(data['count']),
        'mark_message_digested' || 'mark_email_digested' => 0,
        _ => null,
      };
      if (count == null || count > 0) return false;
      sawCount = true;
    }
    return sawCount;
  }

  static int? _count(Object? value) => value is num ? value.toInt() : null;
}
