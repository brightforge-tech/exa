import '../../data/repositories/chat_repository.dart';

/// Aggregated quality signals across recent turns, in the four groups that
/// answer four different questions:
///
///   * **Relevance** — did Exa answer what was asked?
///   * **Accuracy** — was what it said true?
///   * **Safety** — did it do only what it was allowed to?
///   * **Efficiency** — what did that cost?
///
/// Every input is already recorded on the assistant message's `turn`
/// metadata by the orchestrator, so this is aggregation rather than new
/// instrumentation. The point of naming them is the regression gate: a
/// change that makes prompts bigger or answers less relevant should fail a
/// test, not be noticed months later.
class TurnMetrics {
  const TurnMetrics({
    required this.turns,
    required this.contractCoverage,
    required this.relevanceCoverage,
    required this.memoriesRetrieved,
    required this.memoriesCited,
    required this.memoriesSuppressed,
    required this.unsupportedClaims,
    required this.verificationFailures,
    required this.repairs,
    required this.scopedWritesBlocked,
    required this.injectionsNeutralized,
    required this.untrustedBlocks,
    required this.modelCalls,
    required this.toolSchemaTokens,
    required this.deterministicRenders,
    required this.escalations,
    this.requiredActions = 0,
    this.unresolvedRequiredActions = 0,
    this.cappedTurns = 0,
    this.cacheReadTokens = 0,
    this.cacheWriteTokens = 0,
    this.exactToolTurns = 0,
    this.exactToolScopeAbandoned = 0,
    this.clarificationTurns = 0,
    this.underDecomposedTurns = 0,
  });

  static const empty = TurnMetrics(
    turns: 0,
    contractCoverage: 1,
    relevanceCoverage: 1,
    memoriesRetrieved: 0,
    memoriesCited: 0,
    memoriesSuppressed: 0,
    unsupportedClaims: 0,
    verificationFailures: 0,
    repairs: 0,
    scopedWritesBlocked: 0,
    injectionsNeutralized: 0,
    untrustedBlocks: 0,
    modelCalls: 0,
    toolSchemaTokens: 0,
    deterministicRenders: 0,
    escalations: 0,
  );

  final int turns;

  // Relevance.
  /// Fraction of turns that finished with every required output present.
  final double contractCoverage;

  /// Mean fraction of response sections that mapped to something the turn
  /// actually did or owed.
  final double relevanceCoverage;

  final int memoriesRetrieved;

  /// Retrieved-versus-cited is the honest measure of whether the memory
  /// block earned its tokens. A large gap means retrieval is padding.
  final int memoriesCited;
  final int memoriesSuppressed;

  // Accuracy.
  final int unsupportedClaims;
  final int verificationFailures;
  final int repairs;

  // Safety.
  final int scopedWritesBlocked;
  final int injectionsNeutralized;
  final int untrustedBlocks;

  // Efficiency.
  final int modelCalls;
  final int toolSchemaTokens;

  /// Turns answered in code rather than by a model call.
  final int deterministicRenders;
  final int escalations;

  // Completion. `contractCoverage` above measures whether the *message* was
  // complete; these measure whether the *work* was. They diverge exactly when
  // a turn does some of what it was asked and describes it as all of it.
  final int requiredActions;
  final int unresolvedRequiredActions;

  /// Turns cut off by the action cap or the iteration backstop while the model
  /// was still working. Not failures - unfinished requests, which is why they
  /// need counting separately from `verificationFailures`.
  final int cappedTurns;

  /// Turns that could not establish what the user meant, so they read, changed
  /// nothing, and asked.
  ///
  /// This is the one metric here whose *rise* is the problem. Asking is the
  /// correct outcome for a genuinely ambiguous request; a climbing rate means
  /// detection has become too eager and is turning answerable requests into
  /// questions, which is a worse assistant than one that occasionally guesses.
  final int clarificationTurns;

  /// Turns where a clause of the request matched no planned action.
  ///
  /// Has no regression limit on purpose: it measures a detector that has not
  /// been calibrated yet, so a ceiling would be a guess enforcing a guess.
  /// Read it, then decide whether it is worth acting on.
  final int underDecomposedTurns;

  /// Prompt-cache accounting across the counted turns' tool loops. A high
  /// write total against a near-zero read total is a prefix being rewritten
  /// every turn rather than reused.
  final int cacheReadTokens;
  final int cacheWriteTokens;

  /// How often progressive tool disclosure held: turns where the router named
  /// exact tools, and turns that then had to abandon that list mid-flight.
  final int exactToolTurns;
  final int exactToolScopeAbandoned;

  double get modelCallsPerTurn => turns == 0 ? 0 : modelCalls / turns;

  double get repairRate => turns == 0 ? 0 : repairs / turns;

  /// Of the actions the user actually asked for, the fraction the turn has
  /// evidence for. This is the number silent partial completion used to hide
  /// in: it can fall while `contractCoverage` stays at 1.0.
  double get actionCompletionRate => requiredActions == 0
      ? 1
      : (requiredActions - unresolvedRequiredActions) / requiredActions;

  double get cappedTurnRate => turns == 0 ? 0 : cappedTurns / turns;

  double get clarificationRate => turns == 0 ? 0 : clarificationTurns / turns;

  /// Share of cached prefix tokens that were read rather than written. Near
  /// zero means the cache is costing 1.25x and returning nothing.
  double get cacheHitRate {
    final total = cacheReadTokens + cacheWriteTokens;
    return total == 0 ? 0 : cacheReadTokens / total;
  }

  /// Share of exact-tool turns that had to widen back to domain scoping - the
  /// router naming a list the turn could not work with.
  double get exactToolAbandonRate =>
      exactToolTurns == 0 ? 0 : exactToolScopeAbandoned / exactToolTurns;

  /// Of the memories put in front of the model, how many the answer used.
  double get memoryCitationRate =>
      memoriesRetrieved == 0 ? 1 : memoriesCited / memoriesRetrieved;

  double get averageToolSchemaTokens =>
      turns == 0 ? 0 : toolSchemaTokens / turns;

  Map<String, Object?> toJson() => {
        'turns': turns,
        'completion': {
          'required_actions': requiredActions,
          'unresolved_required_actions': unresolvedRequiredActions,
          'action_completion_rate': _round(actionCompletionRate),
          'capped_turns': cappedTurns,
          'capped_turn_rate': _round(cappedTurnRate),
          'clarification_turns': clarificationTurns,
          'clarification_rate': _round(clarificationRate),
          'under_decomposed_turns': underDecomposedTurns,
        },
        'relevance': {
          'contract_coverage': _round(contractCoverage),
          'response_relevance': _round(relevanceCoverage),
          'memories_retrieved': memoriesRetrieved,
          'memories_cited': memoriesCited,
          'memory_citation_rate': _round(memoryCitationRate),
          'memories_suppressed': memoriesSuppressed,
        },
        'accuracy': {
          'unsupported_claims': unsupportedClaims,
          'verification_failures': verificationFailures,
          'repair_rate': _round(repairRate),
        },
        'safety': {
          'scoped_writes_blocked': scopedWritesBlocked,
          'injections_neutralized': injectionsNeutralized,
          'untrusted_content_blocks': untrustedBlocks,
        },
        'efficiency': {
          'model_calls_per_turn': _round(modelCallsPerTurn),
          'avg_tool_schema_tokens': averageToolSchemaTokens.round(),
          'deterministic_renders': deterministicRenders,
          'escalations': escalations,
          'cache_read_tokens': cacheReadTokens,
          'cache_write_tokens': cacheWriteTokens,
          'cache_hit_rate': _round(cacheHitRate),
          'exact_tool_turns': exactToolTurns,
          'exact_tool_abandon_rate': _round(exactToolAbandonRate),
        },
      };

  static double _round(double value) =>
      double.parse(value.toStringAsFixed(3));

  /// Aggregates the `turn` metadata the orchestrator stores on each
  /// assistant message.
  static Future<TurnMetrics> fromRecentTurns(
    ChatRepository chat, {
    int limit = 100,
  }) async {
    final messages = await chat.recent(limit: limit);
    var turns = 0;
    var contractSatisfied = 0;
    var relevanceSum = 0.0;
    var relevanceCount = 0;
    var retrieved = 0;
    var cited = 0;
    var suppressed = 0;
    var unsupported = 0;
    var verificationFailures = 0;
    var repairs = 0;
    var scopedBlocked = 0;
    var injections = 0;
    var untrusted = 0;
    var modelCalls = 0;
    var schemaTokens = 0;
    var renders = 0;
    var escalations = 0;
    var requiredActions = 0;
    var unresolvedActions = 0;
    var capped = 0;
    var cacheRead = 0;
    var cacheWrite = 0;
    var exactToolTurns = 0;
    var exactAbandoned = 0;
    var clarifications = 0;
    var underDecomposed = 0;

    for (final message in messages) {
      if (message.role != 'assistant') continue;
      final turn = message.meta?['turn'];
      if (turn is! Map) continue;
      turns++;

      int intOf(String key) {
        final value = turn[key];
        return value is num ? value.toInt() : 0;
      }

      final missing = turn['missing_outputs_after_repair'];
      if (missing is! List || missing.isEmpty) contractSatisfied++;

      final relevance = turn['relevance'];
      if (relevance is Map && relevance['coverage'] is num) {
        relevanceSum += (relevance['coverage'] as num).toDouble();
        relevanceCount++;
      }

      retrieved += intOf('memories_used');
      cited += intOf('memories_cited');
      suppressed += intOf('memories_suppressed');
      unsupported += intOf('unsupported_claims');
      if (turn['verification_performed'] == true &&
          turn['verification_passed'] == false) {
        verificationFailures++;
      }
      if (turn['repair_performed'] == true) repairs++;
      scopedBlocked += intOf('scoped_writes_blocked');
      injections += intOf('injection_attempts_neutralized');
      untrusted += intOf('untrusted_content_blocks');
      modelCalls += intOf('model_calls');
      schemaTokens += intOf('tool_schema_tokens');
      if (turn['deterministic_render'] != null) renders++;
      if (turn['escalated'] == true) escalations++;
      requiredActions += intOf('required_actions');
      unresolvedActions += intOf('unresolved_required_actions');
      if (turn['turn_capped'] == true) capped++;
      cacheRead += intOf('cache_read_tokens');
      cacheWrite += intOf('cache_write_tokens');
      if (intOf('exact_tools_named') > 0) {
        exactToolTurns++;
        if (turn['exact_tool_scope_abandoned'] == true) exactAbandoned++;
      }
      if (turn['blocked_on_ambiguity'] == true) clarifications++;
      if (intOf('unaccounted_clauses') > 0) underDecomposed++;
    }

    if (turns == 0) return empty;
    return TurnMetrics(
      turns: turns,
      contractCoverage: contractSatisfied / turns,
      relevanceCoverage:
          relevanceCount == 0 ? 1 : relevanceSum / relevanceCount,
      memoriesRetrieved: retrieved,
      memoriesCited: cited,
      memoriesSuppressed: suppressed,
      unsupportedClaims: unsupported,
      verificationFailures: verificationFailures,
      repairs: repairs,
      scopedWritesBlocked: scopedBlocked,
      injectionsNeutralized: injections,
      untrustedBlocks: untrusted,
      modelCalls: modelCalls,
      toolSchemaTokens: schemaTokens,
      deterministicRenders: renders,
      escalations: escalations,
      requiredActions: requiredActions,
      unresolvedRequiredActions: unresolvedActions,
      cappedTurns: capped,
      cacheReadTokens: cacheRead,
      cacheWriteTokens: cacheWrite,
      exactToolTurns: exactToolTurns,
      exactToolScopeAbandoned: exactAbandoned,
      clarificationTurns: clarifications,
      underDecomposedTurns: underDecomposed,
    );
  }
}

/// Limits a code change must not cross.
///
/// These exist so a refactor cannot silently make prompts bigger or answers
/// less relevant. They are deliberately loose: a gate that fails on normal
/// variation gets disabled, and a disabled gate protects nothing.
class RegressionLimits {
  const RegressionLimits._();

  /// Full tool definitions for the whole registry. Domain scoping cuts this
  /// to roughly 2,500 and exact-tool loading well below that; the ceiling
  /// catches a tool added with a page of prose in its description.
  static const int maxFullToolSchemaTokens = 8000;

  /// The compact capability catalogue the router sees. If this approaches
  /// the schemas it replaces, progressive disclosure has stopped paying.
  static const int maxCatalogTokens = 1200;

  /// Model calls for a turn that does one thing: route, act, synthesize.
  static const double maxModelCallsPerSimpleTurn = 4;

  /// Repairs are a correction mechanism, not a routine stage.
  static const double maxRepairRate = 0.25;

  /// Below this, the memory block is mostly padding the answer ignored.
  static const double minMemoryCitationRate = 0.2;

  /// Required actions that must end the turn with evidence behind them.
  ///
  /// Deliberately not 1.0: a turn can legitimately leave an action unresolved
  /// when a tool failed, the user declined, or the request was cut off - and
  /// those are *disclosed*, which is the correct outcome. What this catches is
  /// the rate climbing, which means either the resolver stopped recognizing
  /// work it should, or the agent genuinely started dropping requests.
  static const double minActionCompletionRate = 0.85;

  /// Turns cut off mid-request by the action cap. A few is normal on heavy
  /// batch work; a lot means the caps no longer fit the flows, and until
  /// continuation exists those requests simply end unfinished.
  static const double maxCappedTurnRate = 0.1;

  /// Exact-tool turns that had to widen back to domain scoping. Past this,
  /// the router is naming lists the turn cannot work with, and progressive
  /// disclosure is costing a round trip more often than it saves tokens.
  static const double maxExactToolAbandonRate = 0.25;

  /// Turns that stopped to ask what the user meant.
  ///
  /// The only ceiling here that guards against a *feature* rather than a bug.
  /// An assistant that asks about one request in twenty is careful; one that
  /// asks about one in five has made ambiguity detection too eager and is
  /// worse than one that occasionally guesses and says so.
  static const double maxClarificationRate = 0.15;
}
