import '../models/tool_execution_record.dart';
import '../models/turn_contract.dart';
import '../tools/tool_domains.dart';
import 'contract_action_resolver.dart';

/// Whether a scheduled run has anything to create records *from*.
///
/// "Check my chats and file any tasks" is a request to turn what was read
/// into records. A run that read nothing new has nothing to turn into
/// anything - and yet a small model will still call `create_task`, from
/// whatever is lying around in its context, or from thin air ("call John",
/// "follow up on the invoice"). On the device this produced three bank
/// tasks created by a run whose only tool calls were the three creates.
///
/// The prompt asks the model not to. This is what stops it: in an isolated
/// run that was routed to messages or email, creating a task, reminder or
/// event is refused until some read in the *same run* has returned content.
/// Decided from the execution records, never from the model's account of
/// what it read.
///
/// Deliberately narrow. It does not apply to chat turns (the person in the
/// chat is the source), to runs the router did not send to messages or
/// email ("every Monday, add a task to submit my timesheet" reads nothing
/// and never should), or to anything other than the three record-creating
/// tools a digest uses.
class SourceGrounding {
  const SourceGrounding._();

  /// The tools a digest turns a message into.
  static const creatingTools = {
    'create_task',
    'create_reminder',
    'create_schedule_event',
    'add_to_phone_calendar',
  };

  /// Domains whose whole point is content that arrived from outside.
  static const _sourceDomains = {ToolDomains.messages, ToolDomains.email};

  /// Tools that return content a record could legitimately come from.
  /// `list_chats` and the sync tools are absent on purpose: a directory of
  /// chats and a count of new mail are not something to file a task from.
  static const _contentReaders = {
    'read_message_context',
    'read_chat',
    'read_email_context',
    'read_browser_context',
    'read_current_browser_page',
    'summarize_browser_page',
    'read_file',
    'search',
  };

  /// The source domains a request names in its own words, for the run whose
  /// routing call failed and so has no routed domains at all. A small model
  /// is exactly the one whose router reply fails to parse, and it must not
  /// be the case that the guard switches off when the model is at its worst.
  /// Unambiguous nouns only: "text" and "call" mean too many other things.
  static Set<String> impliedDomains(String request) {
    final words = request
        .toLowerCase()
        .split(RegExp(r'[^a-z0-9]+'))
        .where((word) => word.isNotEmpty)
        .toSet();
    return {
      if (words.intersection(_messageWords).isNotEmpty) ToolDomains.messages,
      if (words.intersection(_emailWords).isNotEmpty) ToolDomains.email,
    };
  }

  static const _messageWords = {
    'chat', 'chats', 'message', 'messages', 'whatsapp', 'telegram', 'signal',
  };
  static const _emailWords = {
    'email', 'emails', 'mail', 'mails', 'inbox', 'gmail', 'outlook',
  };

  /// Whether an isolated run was asked for something only tools can do: the
  /// router sent it to a tool domain, the request names one, or a planned
  /// action names the tool it needs. "Write me a quote every morning" is
  /// none of those - its text *is* the work, and it must never be nudged,
  /// discarded or failed for calling nothing.
  static bool owesToolWork({
    required Set<String> domains,
    required Iterable<List<String>> plannedTools,
  }) =>
      domains.any((domain) => domain != ToolDomains.core) ||
      plannedTools.any((tools) => tools.isNotEmpty);

  /// Null when [tool] may run, otherwise the reason to hand to the model.
  static String? refusalFor({
    required String tool,
    required bool isolated,
    required Set<String>? routedDomains,
    required List<ToolExecutionRecord> records,
  }) {
    if (!isolated || !creatingTools.contains(tool)) return null;
    // Routing failed or did not pick a source domain: not a digest, so
    // nothing here has an opinion about it.
    if (routedDomains == null ||
        routedDomains.intersection(_sourceDomains).isEmpty) {
      return null;
    }
    if (hasReadContent(records)) return null;
    return 'Nothing has been read in this run yet, so there is nothing to '
        'create this from. Read the new messages or emails first '
        '(undigested_only true) and create records only from what that '
        'returns. If it returns nothing new, do not create anything - say '
        'there was nothing new and stop.';
  }

  /// Why a planned create was settled without running.
  static const nothingCalledForIt = 'Nothing in what was read called for it.';

  /// Settles the creates a digest planned and turned out to have no use for.
  ///
  /// "Go through my new messages and add any tasks, reminders or events" is
  /// routed as three creates, all required, because the instructions name
  /// all three. Most batches need one or two of them. The one left over
  /// used to stand as work that was asked for and not done: the turn failed
  /// its check, a repair call was sent to correct a message that had
  /// nothing wrong with it (95 seconds on the local model, half the run),
  /// and the job's route was forgotten so the next run paid for routing
  /// again. Nothing in the messages calling for a reminder is not a
  /// reminder left unset.
  ///
  /// Held to the case it was written for. Only an isolated run routed to
  /// messages or email, and only once a read in it has returned something -
  /// the run that read nothing is [QuietTurn.settleUnneededActions]. Only
  /// an action whose every expected tool is one of [creatingTools]. And
  /// never when a create was tried and failed or was refused: that is a
  /// failure, and the reader is owed it.
  static CompletionContract settleUnneededCreates({
    required CompletionContract contract,
    required bool isolated,
    required Set<String>? routedDomains,
    required List<ToolExecutionRecord> records,
    required Set<String> knownToolNames,
  }) {
    if (!isolated) return contract;
    if (contract.actions.every((action) => action.isResolved)) {
      return contract;
    }
    if (routedDomains == null ||
        routedDomains.intersection(_sourceDomains).isEmpty) {
      return contract;
    }
    if (!hasReadContent(records)) return contract;
    final troubled = {
      for (final record in records)
        if (!record.isControlPlane &&
            creatingTools.contains(record.toolName) &&
            record.status != ToolExecutionStatus.success)
          record.toolName,
    };
    bool unneeded(ContractAction action) {
      final expected =
          ContractActionResolver.expectedToolsFor(action, knownToolNames);
      return expected.isNotEmpty &&
          creatingTools.containsAll(expected) &&
          expected.intersection(troubled).isEmpty;
    }

    return contract.copyWith(actions: [
      for (final action in contract.actions)
        action.isResolved || !unneeded(action)
            ? action
            : action.copyWith(
                status: ContractItemStatus.skipped,
                failureReason: nothingCalledForIt,
              ),
    ]);
  }

  /// True once a read in this run has returned at least one item.
  static bool hasReadContent(List<ToolExecutionRecord> records) {
    for (final record in records) {
      if (record.isControlPlane) continue;
      if (record.status != ToolExecutionStatus.success) continue;
      if (!_contentReaders.contains(record.toolName)) continue;
      if (_hasItems(record.rawResult)) return true;
    }
    return false;
  }

  static bool _hasItems(Object? raw) {
    if (raw is! Map) return false;
    final data = raw.cast<String, Object?>();
    // A single item read in full ("id" given) carries its body, not a count.
    for (final key in const ['body', 'text', 'content', 'summary']) {
      final value = data[key];
      if (value is String && value.trim().isNotEmpty) return true;
    }
    for (final key in const ['count', 'showing', 'total']) {
      final value = data[key];
      if (value is num) return value > 0;
    }
    return data.values.any((value) => value is List && value.isNotEmpty);
  }
}
