import 'turn_contract.dart';

/// Operational metadata for one agent turn: routing, required outputs,
/// tool counters, skill/memory/entity usage, synthesis, verification, and
/// stage timings.
///
/// Exposes only operational facts and completed actions - never hidden
/// reasoning or chain-of-thought.
class AgentTurnDiagnostics {
  const AgentTurnDiagnostics({
    required this.routedDomains,
    required this.plannedActions,
    required this.requiredOutputs,
    required this.routerSucceeded,
    required this.usedAllToolsFallback,
    required this.synthesisRequired,
    required this.synthesisPerformed,
    required this.repairPerformed,
    required this.userActionToolCalls,
    required this.scopeExpansionCalls,
    required this.missingOutputsBeforeRepair,
    required this.missingOutputsAfterRepair,
    required this.routingDuration,
    required this.toolLoopDuration,
    required this.synthesisDuration,
    this.agentTurnId = '',
    this.contractId = '',
    this.verificationPerformed = false,
    this.verificationPassed = true,
    this.verificationScore = 1.0,
    this.verificationIssueCodes = const [],
    this.unsupportedClaimCount = 0,
    this.skillName,
    this.skillVersion,
    this.skillMode,
    this.skillConfidence = 0,
    this.entitiesResolved = 0,
    this.memoriesRetrieved = 0,
    this.memoriesWritten = 0,
    this.duplicateActionsBlocked = 0,
    this.replayTraceRecorded = false,
    this.turnFrame,
    this.relevance,
    this.executionPath,
    this.escalated = false,
    this.escalationSignals = const [],
    this.deterministicRender,
    this.routeSource = 'router',
    this.repairDiscarded = false,
    this.repairReasons = const [],
    this.rejectedClaims = const [],
    this.draftDelivered = false,
    this.draftRewrittenBecause,
    this.memoriesCited = 0,
    this.memoriesSuppressed = 0,
    this.untrustedContentBlocks = 0,
    this.injectionAttemptsNeutralized = 0,
    this.scopedWritesBlocked = 0,
    this.toolSchemaTokens = 0,
    this.modelCalls = 0,
    this.requiredActions = 0,
    this.unresolvedRequiredActions = 0,
    this.turnCapped = false,
    this.cacheReadTokens = 0,
    this.cacheWriteTokens = 0,
    this.exactToolsNamed = 0,
    this.exactToolScopeAbandoned = false,
    this.blockedOnAmbiguity = false,
    this.ambiguitySlots = const [],
    this.requestClauses = 0,
    this.unaccountedClauses = 0,
  });

  final Set<String> routedDomains;
  final List<String> plannedActions;
  final Set<ResponseOutputType> requiredOutputs;
  final bool routerSucceeded;
  final bool usedAllToolsFallback;
  final bool synthesisRequired;
  final bool synthesisPerformed;
  final bool repairPerformed;
  final int userActionToolCalls;
  final int scopeExpansionCalls;
  final Set<ResponseOutputType> missingOutputsBeforeRepair;
  final Set<ResponseOutputType> missingOutputsAfterRepair;
  final Duration routingDuration;
  final Duration toolLoopDuration;
  final Duration synthesisDuration;

  final String agentTurnId;
  final String contractId;
  final bool verificationPerformed;
  final bool verificationPassed;
  final double verificationScore;
  final List<String> verificationIssueCodes;
  final int unsupportedClaimCount;
  final String? skillName;
  final int? skillVersion;
  final String? skillMode;
  final double skillConfidence;
  final int entitiesResolved;
  final int memoriesRetrieved;
  final int memoriesWritten;
  final int duplicateActionsBlocked;
  final bool replayTraceRecorded;

  /// The provisional frame this turn ran under (goal, topic, risk, policy).
  final Map<String, Object?>? turnFrame;

  /// Deterministic relevance scoring of the final message.
  final Map<String, Object?>? relevance;

  /// Which adaptive path the turn took (`deterministic_command`,
  /// `conversational`, `standard`, `escalated`).
  final String? executionPath;
  final bool escalated;
  final List<String> escalationSignals;

  /// Set when the user-facing text was rendered in code rather than
  /// written by the model.
  final String? deterministicRender;

  /// Retrieval quality: how many retrieved memories the response actually
  /// used, and how many were dropped below the relevance threshold.
  final int memoriesCited;
  final int memoriesSuppressed;

  /// Safety counters.
  final int untrustedContentBlocks;
  final int injectionAttemptsNeutralized;
  final int scopedWritesBlocked;

  /// Efficiency counters.
  final int toolSchemaTokens;
  final int modelCalls;

  /// Completion counters, recorded after the resolver has run against the
  /// turn's evidence.
  ///
  /// [unresolvedRequiredActions] is the number the turn was asked to do and
  /// has no evidence for. It is the counterpart to
  /// `missing_outputs_after_repair`: that one says the *message* was
  /// incomplete, this one says the *work* was. Nothing recorded it before,
  /// which is why silent partial completion was invisible.
  final int requiredActions;
  final int unresolvedRequiredActions;

  /// True when the tool loop stopped while the model was still asking for
  /// tools - the per-turn action cap or the iteration backstop cut the
  /// request off partway. Distinct from a failure: everything that ran,
  /// ran fine, and the request is simply unfinished.
  final bool turnCapped;

  /// What the prompt cache did this turn, summed across the turn's model
  /// calls. Reads near zero against non-zero writes means the cached prefix
  /// is being rewritten rather than reused.
  final int cacheReadTokens;
  final int cacheWriteTokens;

  /// How well progressive tool disclosure held up: how many exact tools the
  /// router named, and whether the turn had to abandon that list mid-flight
  /// (an `expand_tools` call, which costs the saving *and* a round trip).
  final int exactToolsNamed;
  final bool exactToolScopeAbandoned;

  /// Where the turn's route came from: `router` (the model was asked),
  /// `cache` (a scheduled job's stored route) or `given_up` (asking has
  /// failed too often lately, so the turn ran unrouted without asking).
  final String routeSource;

  /// True when a repair ran and its result was set aside because it
  /// checked out worse than the message it was correcting.
  final bool repairDiscarded;

  /// What was wrong with the message a repair was asked to correct: the
  /// verifier's issue codes, plus `breaks_a_rule` and `off_topic`. Until
  /// this was recorded a repair could be seen to have run and not why.
  final List<String> repairReasons;

  /// The claims the first message declared that nothing in the turn backed,
  /// as `type: description`. `unsupported_claims` is counted after a repair,
  /// when it is nearly always zero; seven repairs in one morning gave the
  /// same reason and left nothing to say which claim had caused them, or
  /// whether the fault was the message's or the check's.
  final List<String> rejectedClaims;

  /// [claims] cut to what a run record has room for.
  static List<String> claimsToKeep(List<String> claims) => [
        for (final claim in claims.take(maxRejectedClaims))
          claim.length <= maxRejectedClaimChars
              ? claim
              : '${claim.substring(0, maxRejectedClaimChars)}...',
      ];

  static const maxRejectedClaims = 5;
  static const maxRejectedClaimChars = 200;

  /// True when the action phase's own answer was checked in code and sent,
  /// with no second call to write it again.
  final bool draftDelivered;

  /// Why a draft that was considered for that was rewritten after all.
  final String? draftRewrittenBecause;

  /// True when the turn could not establish what the user meant, so it was
  /// restricted to reads and owed them a question instead of an action.
  ///
  /// Counted separately from both failures and unresolved actions: asking is
  /// the correct outcome here, not a shortfall. What it does need watching for
  /// is the opposite - a rate that climbs means detection has become too
  /// eager and is turning answerable requests into questions.
  final bool blockedOnAmbiguity;
  final List<String> ambiguitySlots;

  /// How many clauses of the request asked for something, and how many of
  /// those no planned action covers.
  ///
  /// The mirror image of [unresolvedRequiredActions]: that one counts work
  /// planned and not done, this one counts work never planned. Diagnostic
  /// only - the clause splitter needs measuring against real traffic (and
  /// dictated input carries no punctuation to split on) before anything is
  /// allowed to depend on it.
  final int requestClauses;
  final int unaccountedClauses;

  Map<String, Object?> toJson() => {
        if (routeSource != 'router') 'route_source': routeSource,
        if (draftDelivered) 'draft_delivered': true,
        if (repairDiscarded) 'repair_discarded': true,
        if (repairReasons.isNotEmpty) 'repair_reasons': repairReasons,
        if (rejectedClaims.isNotEmpty) 'rejected_claims': rejectedClaims,
        if (draftRewrittenBecause != null)
          'draft_rewritten_because': draftRewrittenBecause,
        'routed_domains': routedDomains.toList(),
        'planned_actions': plannedActions,
        'required_outputs':
            requiredOutputs.map((o) => o.wireName).toList(),
        'router_succeeded': routerSucceeded,
        'used_all_tools_fallback': usedAllToolsFallback,
        'synthesis_required': synthesisRequired,
        'synthesis_performed': synthesisPerformed,
        'repair_performed': repairPerformed,
        'user_action_tool_calls': userActionToolCalls,
        'scope_expansion_calls': scopeExpansionCalls,
        'missing_outputs_before_repair':
            missingOutputsBeforeRepair.map((o) => o.wireName).toList(),
        'missing_outputs_after_repair':
            missingOutputsAfterRepair.map((o) => o.wireName).toList(),
        'routing_ms': routingDuration.inMilliseconds,
        'tool_loop_ms': toolLoopDuration.inMilliseconds,
        'synthesis_ms': synthesisDuration.inMilliseconds,
        if (agentTurnId.isNotEmpty) 'agent_turn_id': agentTurnId,
        if (contractId.isNotEmpty) 'contract_id': contractId,
        'verification_performed': verificationPerformed,
        if (verificationPerformed) ...{
          'verification_passed': verificationPassed,
          'verification_score': verificationScore,
          if (verificationIssueCodes.isNotEmpty)
            'verification_issues': verificationIssueCodes,
          if (unsupportedClaimCount > 0)
            'unsupported_claims': unsupportedClaimCount,
        },
        if (skillName != null) ...{
          'skill': skillName,
          'skill_version': skillVersion,
          'skill_mode': skillMode,
          'skill_confidence': skillConfidence,
        },
        if (entitiesResolved > 0) 'entities_resolved': entitiesResolved,
        if (memoriesRetrieved > 0) 'memories_used': memoriesRetrieved,
        if (memoriesWritten > 0) 'memories_written': memoriesWritten,
        if (duplicateActionsBlocked > 0)
          'duplicate_actions_blocked': duplicateActionsBlocked,
        'replay_trace_recorded': replayTraceRecorded,
        if (turnFrame != null) 'turn_frame': turnFrame,
        if (relevance != null) 'relevance': relevance,
        if (executionPath != null) 'execution_path': executionPath,
        if (escalated) ...{
          'escalated': true,
          if (escalationSignals.isNotEmpty)
            'escalation_signals': escalationSignals,
        },
        if (deterministicRender != null)
          'deterministic_render': deterministicRender,
        if (memoriesCited > 0) 'memories_cited': memoriesCited,
        if (memoriesSuppressed > 0) 'memories_suppressed': memoriesSuppressed,
        if (untrustedContentBlocks > 0)
          'untrusted_content_blocks': untrustedContentBlocks,
        if (injectionAttemptsNeutralized > 0)
          'injection_attempts_neutralized': injectionAttemptsNeutralized,
        if (scopedWritesBlocked > 0)
          'scoped_writes_blocked': scopedWritesBlocked,
        if (toolSchemaTokens > 0) 'tool_schema_tokens': toolSchemaTokens,
        if (modelCalls > 0) 'model_calls': modelCalls,
        if (requiredActions > 0) 'required_actions': requiredActions,
        // Always emitted once the turn planned any required action, including
        // the zero: "0 of 3 unresolved" is the measurement, and omitting it
        // would make a healthy turn indistinguishable from an unrecorded one.
        if (requiredActions > 0)
          'unresolved_required_actions': unresolvedRequiredActions,
        if (turnCapped) 'turn_capped': true,
        if (cacheReadTokens > 0) 'cache_read_tokens': cacheReadTokens,
        if (cacheWriteTokens > 0) 'cache_write_tokens': cacheWriteTokens,
        if (exactToolsNamed > 0) 'exact_tools_named': exactToolsNamed,
        if (exactToolScopeAbandoned) 'exact_tool_scope_abandoned': true,
        if (blockedOnAmbiguity) ...{
          'blocked_on_ambiguity': true,
          if (ambiguitySlots.isNotEmpty) 'ambiguity_slots': ambiguitySlots,
        },
        if (requestClauses > 0) 'request_clauses': requestClauses,
        if (unaccountedClauses > 0)
          'unaccounted_clauses': unaccountedClauses,
      };
}
