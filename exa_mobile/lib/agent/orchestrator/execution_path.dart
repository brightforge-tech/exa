import '../models/turn_contract.dart';
import '../skills/models/workflow_skill.dart';
import '../skills/skill_matcher.dart';
import 'domain_router.dart';
import 'turn_frame.dart';

/// How much machinery a turn actually needs.
///
/// The full pipeline — route, retrieve, contract, tools, synthesis,
/// verification — is right for a request that changes several things across
/// domains. It is overkill for "thanks", and it is not enough for
/// "unsubscribe me from all of these". Running the same path for all three
/// spends latency where it buys nothing and skimps where it matters.
enum ExecutionPath {
  /// A confidently matched deterministic skill: ordered steps, no open
  /// loop, a rendered confirmation.
  deterministicCommand,

  /// Nothing to do but answer. One no-tool call.
  conversational,

  /// The full pipeline.
  standard,

  /// High-risk or ambiguous: more reasoning budget, verification forced on,
  /// no deterministic shortcuts, claim-level checking.
  escalated;

  String get wireName => switch (this) {
        deterministicCommand => 'deterministic_command',
        conversational => 'conversational',
        standard => 'standard',
        escalated => 'escalated',
      };
}

/// Why a turn took the path it took.
class PathDecision {
  const PathDecision({
    required this.path,
    this.signals = const [],
  });

  final ExecutionPath path;

  /// Named escalation signals, e.g. `financial_or_destructive`,
  /// `conflicting_memories`. Recorded so a surprising escalation is
  /// explainable after the fact.
  final List<String> signals;

  bool get isEscalated => path == ExecutionPath.escalated;

  Map<String, Object?> toJson() => {
        'path': path.wireName,
        if (signals.isNotEmpty) 'signals': signals,
      };
}

/// Picks the execution path deterministically.
///
/// Escalation is decided from evidence about the turn, never by asking the
/// model how hard it thinks the request is: a model that under-reports
/// difficulty would be choosing its own supervision.
class ExecutionPathPlanner {
  const ExecutionPathPlanner();

  /// Dependent tool steps beyond which a turn stops being routine.
  static const int stepEscalationThreshold = 3;

  /// Router confidence below which its skill nomination is not trusted
  /// enough to shortcut anything.
  static const double lowConfidence = 0.35;

  PathDecision decide({
    required TurnFrame frame,
    required CompletionContract contract,
    DomainRoutingResult? routing,
    SkillMatch? skillMatch,
    int retrievedMemoryCount = 0,
    int contradictedMemoryCount = 0,
    int unreliableMemoryCount = 0,
    bool previousRepairFailed = false,
    bool externalContentInScope = false,
  }) {
    final signals = <String>[];

    // Escalation signals, in the order they are worth reporting.
    if (frame.risk == TurnRisk.high) signals.add('financial_or_destructive');
    if (frame.hasBlockingAmbiguity) signals.add('ambiguous_referent');
    if (contradictedMemoryCount > 0) signals.add('conflicting_memories');
    if (contract.actions.length > stepEscalationThreshold) {
      signals.add('many_dependent_steps');
    }
    if (routing == null || !routing.structured) {
      signals.add('low_routing_confidence');
    }
    // Deliberately *not* "retrieval returned nothing": returning zero
    // memories is a valid, common and correct outcome — a fresh install has
    // none, and treating that as a risk signal would escalate every
    // consequential request forever. What matters is retrieval that found
    // things and none of them can be relied on.
    if (retrievedMemoryCount > 0 &&
        unreliableMemoryCount >= retrievedMemoryCount) {
      signals.add('low_retrieval_confidence');
    }
    if (previousRepairFailed) signals.add('previous_repair_failed');
    if (externalContentInScope) signals.add('external_content_instructions');

    // One signal is normal - most consequential requests trip
    // `financial_or_destructive` on their own and do not need a reviewer.
    // Two independent signals is where the extra latency starts paying for
    // itself; running a reviewer on every turn would cost more stability
    // than it buys.
    if (signals.length >= 2) {
      return PathDecision(path: ExecutionPath.escalated, signals: signals);
    }

    final skill = skillMatch?.skill;
    if (skill != null &&
        skillMatch != null &&
        skillMatch.confidence >= SkillMatcher.autoThreshold &&
        skill.mode == SkillExecutionMode.deterministic &&
        skill.steps.isNotEmpty) {
      return const PathDecision(path: ExecutionPath.deterministicCommand);
    }

    // The router explicitly said no tools are needed, planned nothing, and
    // the request is low risk. An empty domain set is a decision; a null
    // one ("all tools") is the absence of one, and must not shortcut.
    final saidNoTools = routing != null &&
        routing.structured &&
        routing.domains != null &&
        routing.domains!.isEmpty &&
        routing.actions.isEmpty;
    if (saidNoTools &&
        frame.risk == TurnRisk.low &&
        contract.actions.isEmpty &&
        !contract.requiresConfirmation) {
      return const PathDecision(path: ExecutionPath.conversational);
    }

    return PathDecision(path: ExecutionPath.standard, signals: signals);
  }
}
