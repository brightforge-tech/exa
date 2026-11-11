import '../models/tool_execution_record.dart';
import '../models/turn_contract.dart';
import 'action_lexicon.dart';

/// Resolves contract action statuses from the turn's actual tool execution
/// records - evidence, never the model's own account of what it did.
///
/// Each action first gets an **expectation**: the tools whose success would
/// satisfy it. It comes from `expectedToolNames` when the router or a skill
/// predicted it, and is otherwise derived from the registry's tool names by
/// the verb-gated match in [toolSatisfies]. What happens next depends on
/// whether that expectation exists:
///
/// | Expectation | Nothing in it ran | Why |
/// |---|---|---|
/// | Known | `pending` | We know what the action needed and it did not happen |
/// | None | absorbed, up to spare successful work | We cannot tell what it needed, so the turn's unexplained successes stand in |
///
/// ### Why it works this way
///
/// Both halves exist because the same failure got through the old rules: a
/// turn that did *some* of what it was asked and recorded itself as having
/// done all of it.
///
/// Bare token overlap used to be enough to match, and every email tool shares
/// the token `email` - so "send an email to John" was satisfied by a
/// `sync_emails` or `read_email_context` call that merely *read* mail. The
/// verb carries the whole meaning of a tool name (`send` vs `sync` vs `read`),
/// so [toolSatisfies] requires it to be present with one further token
/// agreeing.
///
/// Unmatched actions then inherited the turn's mood: any success and no
/// failure marked them `completed`. So "create a task and draft a reply",
/// where only the task was created, resolved as fully complete - and neither
/// verifier check could see it, because `unresolved_action` needs an
/// unresolved action and `action_claimed_without_execution` needs a turn that
/// ran no tools at all. It reported full contract coverage while dropping half
/// the request.
///
/// The leniency was there for a real reason, and deleting it would trade
/// silent under-reporting for noisy over-reporting: a router label often names
/// no tool at all ("review_emails" when the tool is `read_email_context`), and
/// accusing that turn of failing is its own kind of wrong. So leniency is kept
/// exactly where the evidence runs out - an action we could not map - and
/// bounded there too: it may consume only a successful record no other action
/// accounts for, one apiece. When the spare work is gone, what is left stays
/// `pending`, which is what [TurnVerifier] reports as `unresolved_action` and
/// a repair then has to disclose.
///
/// Summaries are deliberately not a matching signal. A summary can read
/// "Created task: Email John about the invoice", and no amount of token
/// counting separates that from having emailed him.
class ContractActionResolver {
  const ContractActionResolver();

  /// [knownToolNames] is every tool the registry can run, used to tell "this
  /// action needed a tool that did not run" apart from "this action names
  /// nothing we recognize". Required rather than defaulted: an empty set
  /// silently disables the first case, and that is the case that catches
  /// dropped work.
  List<ContractAction> resolve({
    required List<ContractAction> actions,
    required List<ToolExecutionRecord> records,
    required Set<String> knownToolNames,
  }) {
    final workRecords =
        records.where((record) => !record.isControlPlane).toList();
    final anySuccess =
        workRecords.any((r) => r.status == ToolExecutionStatus.success);
    final anyFailure = workRecords.any((r) =>
        r.status == ToolExecutionStatus.failure ||
        r.status == ToolExecutionStatus.partial);

    // Pass 1: what each action expected, and which records met it. Done for
    // every action before anything is absorbed, so absorption can never be
    // handed a record that an action further down the list matches directly.
    final matches = <int, List<ToolExecutionRecord>>{};
    final expectations = <int, Set<String>>{};
    final accountedFor = <int>{};
    for (var i = 0; i < actions.length; i++) {
      if (actions[i].isResolved) continue;
      final expectation = expectedToolsFor(actions[i], knownToolNames);
      expectations[i] = expectation;
      // By position, not by value: two identical `create_task` calls are two
      // separate pieces of evidence, and `indexOf` would collapse them.
      final matched = <ToolExecutionRecord>[];
      for (var j = 0; j < workRecords.length; j++) {
        if (!expectation.contains(workRecords[j].toolName)) continue;
        matched.add(workRecords[j]);
        accountedFor.add(j);
      }
      matches[i] = matched;
    }

    // Which unmappable actions the turn's spare successful work can stand in
    // for. Allocated by affinity rather than by list order: on "review my
    // emails and add any meetings" that ran only a calendar tool, the one
    // spare success is evidence for the meeting, and handing it to whichever
    // action came first would name the wrong one as unresolved.
    final absorbing = _allocateAbsorption(
      actions: actions,
      records: workRecords,
      matches: matches,
      expectations: expectations,
      accountedFor: accountedFor,
      eligible: anySuccess && !anyFailure,
    );

    final resolved = <ContractAction>[];
    for (var i = 0; i < actions.length; i++) {
      final action = actions[i];
      // Terminal statuses set earlier (e.g. by a skill executor) stand.
      if (action.isResolved) {
        resolved.add(action);
        continue;
      }
      final matched = matches[i] ?? const <ToolExecutionRecord>[];
      if (matched.isNotEmpty) {
        resolved.add(_fromMatches(action, matched));
        continue;
      }
      if (workRecords.isEmpty) {
        // A no-tool turn: the action is answered in conversation (or was
        // never really a tool action). The verifier still checks outputs.
        resolved.add(action.copyWith(status: ContractItemStatus.completed));
        continue;
      }
      if (!anySuccess) {
        resolved.add(action.copyWith(
          status: ContractItemStatus.failed,
          failureReason: 'No tool completed successfully this turn.',
        ));
        continue;
      }
      // We know which tools this action needed, and none of them ran. No
      // amount of other successful work is evidence for it.
      if ((expectations[i] ?? const {}).isNotEmpty) {
        resolved.add(action);
        continue;
      }
      if (anyFailure) {
        // Mixed turn and nothing mappable: leave pending; the verifier
        // reports it as unresolved so it is disclosed, never assumed done.
        resolved.add(action);
        continue;
      }
      // An optional action is not verified, so it keeps the lenient reading
      // without spending credit a required action may need.
      if (!action.required) {
        resolved.add(action.copyWith(status: ContractItemStatus.completed));
        continue;
      }
      if (absorbing.contains(i)) {
        resolved.add(action.copyWith(status: ContractItemStatus.completed));
        continue;
      }
      // Every successful record is already accounted for by another action.
      // This one has nothing behind it.
      resolved.add(action);
    }
    return resolved;
  }

  /// The unmappable required actions that spare successful work may stand in
  /// for, at most one record apiece.
  ///
  /// When there is enough spare work to go round, every candidate gets it.
  /// When there is not, the ones the evidence most resembles win - so the
  /// action reported as unresolved is the one the turn least looks like it
  /// did. Summaries are used here, and only here: this allocates leniency
  /// among actions that could not be mapped to a tool at all, so it can never
  /// satisfy an action whose expectation is known and unmet.
  static Set<int> _allocateAbsorption({
    required List<ContractAction> actions,
    required List<ToolExecutionRecord> records,
    required Map<int, List<ToolExecutionRecord>> matches,
    required Map<int, Set<String>> expectations,
    required Set<int> accountedFor,
    required bool eligible,
  }) {
    if (!eligible) return const {};
    final spare = <ToolExecutionRecord>[
      for (var i = 0; i < records.length; i++)
        if (!accountedFor.contains(i) &&
            records[i].status == ToolExecutionStatus.success)
          records[i],
    ];
    if (spare.isEmpty) return const {};

    final candidates = <int>[];
    for (var i = 0; i < actions.length; i++) {
      final action = actions[i];
      if (action.isResolved || !action.required) continue;
      if ((matches[i] ?? const []).isNotEmpty) continue;
      if ((expectations[i] ?? const {}).isNotEmpty) continue;
      candidates.add(i);
    }
    if (candidates.length <= spare.length) return candidates.toSet();

    final scored = [
      for (final index in candidates)
        (index: index, score: _affinity(actions[index], spare)),
    ]..sort((a, b) =>
        a.score == b.score ? a.index.compareTo(b.index) : b.score - a.score);
    return {for (final entry in scored.take(spare.length)) entry.index};
  }

  /// How much any one spare record looks like the work [action] describes.
  static int _affinity(
      ContractAction action, List<ToolExecutionRecord> records) {
    final actionTokens = _tokens(action.description);
    if (actionTokens.isEmpty) return 0;
    var best = 0;
    for (final record in records) {
      final recordTokens = {
        ..._tokens(record.toolName),
        if (record.summary != null) ..._tokens(record.summary!),
      };
      final overlap = actionTokens.intersection(recordTokens).length;
      if (overlap > best) best = overlap;
    }
    return best;
  }

  /// The tools whose success would satisfy [action]: what the router or skill
  /// declared, or else every registered tool the description names.
  static Set<String> expectedToolsFor(
    ContractAction action,
    Set<String> knownToolNames,
  ) {
    if (action.expectedToolNames.isNotEmpty) {
      return action.expectedToolNames.toSet();
    }
    final actionTokens = _tokens(action.description);
    if (actionTokens.isEmpty) return const {};
    return {
      for (final name in knownToolNames)
        if (_nameMatches(actionTokens, name)) name,
    };
  }

  /// Whether a successful call to [toolName] is evidence for [description].
  /// Exposed for the tests that pin the `send` / `sync` / `read` distinction.
  static bool toolSatisfies(String description, String toolName) =>
      _nameMatches(_tokens(description), toolName);

  ContractAction _fromMatches(
    ContractAction action,
    List<ToolExecutionRecord> matches,
  ) {
    final succeeded =
        matches.where((r) => r.status == ToolExecutionStatus.success);
    if (succeeded.isNotEmpty) {
      return action.copyWith(
        status: ContractItemStatus.completed,
        entityIds: {
          ...action.entityIds,
          for (final record in succeeded) ...record.touchedEntityIds,
        }.toList(),
      );
    }
    if (matches.any((r) => r.status == ToolExecutionStatus.denied)) {
      return action.copyWith(
        status: ContractItemStatus.cancelled,
        failureReason: 'The user declined this action.',
      );
    }
    return action.copyWith(
      status: ContractItemStatus.failed,
      failureReason: matches
              .map((r) => r.errorMessage)
              .whereType<String>()
              .firstOrNull ??
          'The matching tool call failed.',
    );
  }

  /// Verb-gated name matching, shared with [RequestDecomposition] so the two
  /// cannot disagree about what a verb is.
  static bool _nameMatches(Set<String> actionTokens, String toolName) =>
      ActionLexicon.toolMatches(actionTokens, toolName);

  static Set<String> _tokens(String text) => ActionLexicon.tokens(text);
}
