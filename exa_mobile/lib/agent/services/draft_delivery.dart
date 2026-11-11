import 'dart:convert';

import '../models/agent_execution_report.dart';
import '../models/tool_execution_record.dart';
import '../models/turn_contract.dart';
import '../security/capability_policy.dart';
import 'action_lexicon.dart';
import 'contract_action_resolver.dart';
import 'date_consistency.dart';

/// Decides whether the answer the action phase wrote can go to the user as
/// it is.
///
/// A turn that reads and reports - "what is on today", a morning summary -
/// ends its tool loop with the model writing the answer, the tool results in
/// front of it in full. That answer used to be set aside and written again
/// by a second call working from a trimmed copy of the same results, and
/// often a third to repair the second. On the device's local model the
/// first draft of a morning summary took 123 seconds and the rewrite 153,
/// to say the same thing from less.
///
/// The rewrite exists for turns whose own account cannot be taken on trust:
/// something was created or changed, something failed, or work was planned
/// and not done. None of that is true of a turn that only looked things up
/// and did everything it set out to. For those the draft is checked here,
/// in code, and delivered; anything this cannot vouch for is rewritten as
/// before.
class DraftDelivery {
  const DraftDelivery();

  /// Shorter than this is a remark, not an answer to a request that needed
  /// several reads.
  static const minimumLength = 40;

  /// Tools that take in what has arrived. They write, but nothing the
  /// reader asked to have changed, and nothing the answer has to account
  /// for.
  static const intakeTools = {
    'sync_messages',
    'sync_emails',
    'sync_device_calendar',
  };

  /// What a planned action is called when the answer itself carries it out.
  ///
  /// A router asked to plan "list my open tasks, then write them up" plans
  /// two actions, and only the first is a tool call. The second can never
  /// be matched to a tool record, so it stays unresolved - and the turn is
  /// then reported as having left required work undone when the work is
  /// sitting in its draft. Only consulted for an action that names no tool
  /// at all; one that needed a tool which did not run is never excused.
  static const writingVerbs = {
    'write', 'summarize', 'summarise', 'summary', 'report', 'tell', 'give',
    'explain', 'present', 'provide', 'describe', 'compile', 'compose',
    'format', 'produce', 'output', 'draft', 'list', 'rank', 'prioritize',
    'prioritise', 'order', 'sort', 'group', 'highlight', 'identify',
    'suggest', 'recommend', 'select', 'choose', 'pick', 'compare', 'answer',
    'respond', 'return', 'state', 'note', 'mention', 'outline', 'render',
    'generate', 'create',
  };

  static final _markup = RegExp(
      r'<\|?/?(tool_call|tool_response|think|im_start|im_end)\b|</think>');

  /// Whether [action] is something the answer does rather than a tool. It
  /// has to lead with a writing verb and name nothing that is only ever
  /// done through a tool to someone or something else.
  static bool _isCarriedOutByWriting(ContractAction action) {
    final words = action.description
        .toLowerCase()
        .split(RegExp(r'[^a-z0-9]+'))
        .where((word) => word.length > 2)
        .map(ActionLexicon.singular)
        .toList();
    if (words.isEmpty) return false;
    if (!writingVerbs.contains(words.first)) return false;
    const reachesOut = {
      'email', 'mail', 'message', 'sms', 'text', 'call', 'send', 'reply',
      'remind', 'reminder', 'schedule', 'event', 'meeting', 'file',
      'screen', 'job', 'rule',
    };
    // "create_task" and "generate_reminder" are tool work whatever they
    // lead with; "create_summary" is not.
    final leadsWithMaking =
        words.first == 'create' || words.first == 'generate';
    if (leadsWithMaking && !words.skip(1).any(_reportNouns.contains)) {
      return false;
    }
    return !words.skip(1).any(reachesOut.contains) ||
        words.skip(1).any(_reportNouns.contains);
  }

  static const _reportNouns = {
    'summary', 'report', 'list', 'rundown', 'overview', 'answer', 'reply',
    'response', 'breakdown', 'plan', 'brief', 'briefing', 'digest',
    'outline', 'recap',
  };

  /// Null when [draft] may be delivered as written; otherwise the reason it
  /// is rewritten, as a short code for the turn's diagnostics.
  String? reasonToRewrite({
    required String draft,
    required String request,
    required CompletionContract contract,
    required AgentExecutionReport report,
    required List<ToolExecutionRecord> records,
    required Iterable<String> toolNames,
    String turnContext = '',
    bool escalated = false,
  }) {
    final text = draft.trim();
    if (text.length < minimumLength) return 'too_short';
    // A reply envelope or template markup that leaked into the text.
    if (text.startsWith('{') || text.startsWith('[{')) return 'not_prose';
    if (_markup.hasMatch(text)) return 'not_prose';
    if (escalated) return 'escalated';

    var looked = false;
    for (final record in records) {
      if (record.isControlPlane) continue;
      if (record.status != ToolExecutionStatus.success) return 'tool_failed';
      if (record.wasDeduplicated) return 'changed_something';
      final capability = CapabilityGate.capabilityOf(record.toolName);
      if (capability == ToolCapability.read) {
        looked = true;
      } else if (!intakeTools.contains(record.toolName)) {
        return 'changed_something';
      }
    }
    // Nothing was read, so there is nothing for the draft to be a report of.
    if (!looked) return 'read_nothing';

    if (report.hasFailures || report.hasWarnings) return 'has_failures';
    if (report.tasksCreated.isNotEmpty ||
        report.eventsCreated.isNotEmpty ||
        report.eventsModified.isNotEmpty ||
        report.emailDigestItems.isNotEmpty ||
        report.filesAffected.isNotEmpty ||
        report.screensCreated.isNotEmpty ||
        report.rulesChanged.isNotEmpty) {
      return 'changed_something';
    }
    final known = toolNames.toSet();
    for (final action in contract.actions) {
      if (!action.required || action.isResolved) continue;
      // It needed a tool, and the tool did not run.
      if (ContractActionResolver.expectedToolsFor(action, known).isNotEmpty) {
        return 'unresolved_action';
      }
      if (!_isCarriedOutByWriting(action)) return 'unresolved_action';
    }

    // The reader is never shown the machinery's own names for things.
    final lower = text.toLowerCase();
    for (final name in toolNames) {
      if (name.contains('_') && lower.contains(name.toLowerCase())) {
        return 'names_a_tool';
      }
    }

    // Every date it states has to be one the turn actually saw - which
    // includes today and the days ahead: the model was told those with the
    // request, and "today, Sunday September 27" is not an invention.
    final seen = StringBuffer()
      ..writeln(request)
      ..writeln(turnContext)
      ..writeln(jsonEncode(report.toJson()));
    for (final record in records) {
      if (record.rawResult == null) continue;
      try {
        seen.writeln(jsonEncode(record.rawResult));
      } catch (_) {
        seen.writeln('${record.rawResult}');
      }
    }
    if (DateConsistency.unsupportedDates(
      message: text,
      evidence: seen.toString(),
    ).isNotEmpty) {
      return 'unsupported_date';
    }
    return null;
  }
}
