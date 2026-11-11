import '../../data/models/agent_behavior.dart';
import 'behavior_context.dart';
import 'notification_policy.dart';
import 'output_validator.dart';
import 'schedule_defaults.dart';
import 'token_estimator.dart';

/// Why a rule was included in - or kept out of - a phase.
class BehaviorDecision {
  const BehaviorDecision({
    required this.behaviorId,
    required this.title,
    required this.included,
    required this.reason,
    this.conflictGroup,
    this.phase,
  });

  final String behaviorId;
  final String title;
  final bool included;
  final String reason;
  final String? conflictGroup;
  final AgentPhase? phase;

  Map<String, Object?> toJson() => {
        'behavior_id': behaviorId,
        'title': title,
        'included': included,
        'reason': reason,
        if (conflictGroup != null) 'conflict_group': conflictGroup,
        if (phase != null) 'phase': phase!.name,
      };
}

/// The audit trail for one resolution: what applied, what lost a conflict,
/// what was dropped for budget, and what the app refused to load.
///
/// This is what makes "why did Exa do that?" answerable after the fact.
class BehaviorTrace {
  BehaviorTrace();

  final List<BehaviorDecision> decisions = [];
  final List<String> warnings = [];

  void include(AgentBehavior rule, String reason, {AgentPhase? phase}) =>
      decisions.add(BehaviorDecision(
        behaviorId: rule.id,
        title: rule.title,
        included: true,
        reason: reason,
        conflictGroup: rule.conflictGroup,
        phase: phase,
      ));

  void exclude(AgentBehavior rule, String reason, {AgentPhase? phase}) =>
      decisions.add(BehaviorDecision(
        behaviorId: rule.id,
        title: rule.title,
        included: false,
        reason: reason,
        conflictGroup: rule.conflictGroup,
        phase: phase,
      ));

  void warn(String message) => warnings.add(message);

  List<BehaviorDecision> get included =>
      decisions.where((d) => d.included).toList();
  List<BehaviorDecision> get excluded =>
      decisions.where((d) => !d.included).toList();

  Map<String, Object?> toJson() => {
        'included': [
          for (final d in included) d.behaviorId,
        ],
        'excluded': [
          for (final d in excluded) d.toJson(),
        ],
        if (warnings.isNotEmpty) 'warnings': warnings,
      };
}

/// The resolved behaviour for one turn: a different block per model call,
/// the constraints to check in code, the policies the app enforces itself,
/// and the trace explaining all of it.
///
/// Replacing one shared block with this does two things: it stops the
/// planner paying for writing-tone rules (and the writer paying for tool
/// policy), and it stops code-enforced rules being restated to the model at
/// all - the app already guarantees them.
class BehaviorPlan {
  const BehaviorPlan({
    required this.mandatoryRules,
    required this.plannerBlock,
    required this.actionBlock,
    required this.synthesisBlock,
    required this.repairBlock,
    required this.validators,
    required this.notificationPolicy,
    required this.scheduleDefaults,
    required this.trace,
    required this.version,
  });

  static final empty = BehaviorPlan(
    mandatoryRules: const [],
    plannerBlock: '',
    actionBlock: '',
    synthesisBlock: '',
    repairBlock: '',
    validators: const [],
    notificationPolicy: NotificationPolicy.none,
    scheduleDefaults: ScheduleDefaults.none,
    trace: BehaviorTrace(),
    version: 0,
  );

  /// Safety and other always-on rules, which appear in every phase block.
  final List<AgentBehavior> mandatoryRules;

  final String plannerBlock;
  final String actionBlock;
  final String synthesisBlock;
  final String repairBlock;

  /// Measurable output requirements, checked in code before any repair
  /// call is considered.
  final List<OutputConstraint> validators;

  final NotificationPolicy notificationPolicy;
  final ScheduleDefaults scheduleDefaults;
  final BehaviorTrace trace;

  /// Behavior-table version this plan was compiled from; recorded on job
  /// runs so a past result can be explained by the rules of its time.
  final int version;

  String blockFor(AgentPhase phase) => switch (phase) {
        AgentPhase.planner => plannerBlock,
        AgentPhase.action => actionBlock,
        AgentPhase.synthesis => synthesisBlock,
        AgentPhase.repair => repairBlock,
      };

  /// Rule types each phase can actually use.
  ///
  /// The planner decides what to do; the writer decides how it reads. A
  /// rule about bullet counts does not change which tools to call, and a
  /// rule about email review does not change how a sentence is phrased.
  static const phaseTypes = <AgentPhase, Set<String>>{
    AgentPhase.planner: {
      'safety_rule',
      'workflow_rule',
      'preference_rule',
      'task_prioritization_rule',
      'email_review_rule',
      'calendar_review_rule',
      'schedule_rule',
      'integration_rule',
    },
    AgentPhase.action: {
      'safety_rule',
      'workflow_rule',
      'preference_rule',
      'task_prioritization_rule',
      'email_review_rule',
      'calendar_review_rule',
      'schedule_rule',
      'integration_rule',
      'screen_generation_rule',
    },
    AgentPhase.synthesis: {
      'safety_rule',
      'preference_rule',
      'summary_rule',
    },
    // Repair gets only what it must satisfy; the failed constraints are
    // passed separately by the caller.
    AgentPhase.repair: {'safety_rule'},
  };

  static const _headings = <AgentPhase, String>{
    AgentPhase.planner: 'Rules that shape what you do (follow these):',
    AgentPhase.action: 'Your saved behavior rules (follow these):',
    AgentPhase.synthesis:
        "The user's saved rules for how you write (follow these):",
    AgentPhase.repair: 'Rules you must not break while correcting this:',
  };

  /// Compiles a plan from the active rules.
  ///
  /// [domains] is the turn's routed tool domains (null = unrouted).
  /// [contextWindow] sizes the per-phase token budgets for small models.
  static BehaviorPlan compile(
    List<AgentBehavior> active, {
    Set<String>? domains,
    String surface = BehaviorSurface.chat,
    bool unattended = false,
    int? contextWindow,
    int version = 0,
    DateTime? now,
  }) {
    final trace = BehaviorTrace();
    final at = now ?? DateTime.now();

    // 1. Drop rules that must not apply at all, loudly.
    final usable = <AgentBehavior>[];
    for (final rule in active) {
      if (rule.expiresAt != null && !rule.expiresAt!.isAfter(at)) {
        trace.exclude(rule, 'expired');
        continue;
      }
      if (!AgentBehavior.types.contains(rule.behaviorType)) {
        // Fail closed: an unrecognised type (typo, half-deployed feature,
        // future migration) must never leak instructions into a prompt.
        trace.exclude(rule, 'unknown behavior type "${rule.behaviorType}"');
        trace.warn('Rule "${rule.title}" has unsupported type '
            '"${rule.behaviorType}" and was not applied.');
        continue;
      }
      usable.add(rule);
    }

    // 2. Collapse duplicates. Safety rules are never dropped for budget, so
    // without this an accumulation of near-identical ones (re-approved,
    // re-imported, restated) would grow every prompt without bound.
    final deduped = <AgentBehavior>[];
    final seenText = <String>{};
    for (final rule in usable) {
      final fingerprint =
          '${rule.behaviorType}|${_normalize(rule.ruleText)}';
      if (!seenText.add(fingerprint)) {
        trace.exclude(rule, 'duplicate of an already-applied rule');
        continue;
      }
      deduped.add(rule);
    }

    // 3. Resolve contradictions before anything reaches a prompt.
    final resolved = _resolveConflicts(deduped, trace);

    // 4. Split off what the app enforces itself - those cost no tokens.
    final codeEnforced = <AgentBehavior>[];
    final promptable = <AgentBehavior>[];
    for (final rule in resolved) {
      if (rule.isCodeEnforced && !rule.isMandatory) {
        codeEnforced.add(rule);
        trace.exclude(rule, 'enforced in code, not sent to the model');
      } else {
        promptable.add(rule);
      }
    }

    final mandatory = promptable.where((r) => r.isMandatory).toList();

    // 5. Build one block per phase, each within its own token budget.
    final blocks = <AgentPhase, String>{};
    for (final phase in AgentPhase.values) {
      blocks[phase] = _renderPhase(
        phase: phase,
        rules: promptable,
        domains: domains,
        surface: surface,
        unattended: unattended,
        contextWindow: contextWindow,
        trace: trace,
      );
    }

    // 6. Deterministic consumers read the whole resolved set, including the
    // code-enforced rules that were kept out of the prompts.
    final all = [...resolved];
    return BehaviorPlan(
      mandatoryRules: mandatory,
      plannerBlock: blocks[AgentPhase.planner]!,
      actionBlock: blocks[AgentPhase.action]!,
      synthesisBlock: blocks[AgentPhase.synthesis]!,
      repairBlock: blocks[AgentPhase.repair]!,
      validators: [
        for (final rule in all) ...OutputConstraint.fromBehavior(rule),
      ],
      notificationPolicy: NotificationPolicy.fromBehaviors(
          all.where((r) => r.behaviorType == 'notification_rule').toList()),
      scheduleDefaults: ScheduleDefaults.fromBehaviors(
          all.where((r) => r.behaviorType == 'schedule_rule').toList()),
      trace: trace,
      version: version,
    );
  }

  /// Case- and punctuation-insensitive form used to spot rules that say the
  /// same thing in slightly different words.
  static String _normalize(String text) => text
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9 ]'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  /// One winner per conflict group.
  ///
  /// Precedence, in order: a system safety rule can never lose; then
  /// code-enforced over advisory (the app already guarantees it), then
  /// narrower scope, then explicit-over-inferred, then higher priority
  /// (lower number), then more recently confirmed, then higher confidence.
  /// The comparison is total and stable, so the same rules always resolve
  /// the same way.
  static List<AgentBehavior> _resolveConflicts(
      List<AgentBehavior> rules, BehaviorTrace trace) {
    final grouped = <String, List<AgentBehavior>>{};
    final ungrouped = <AgentBehavior>[];
    for (final rule in rules) {
      final group = rule.conflictGroup?.trim();
      if (group == null || group.isEmpty) {
        ungrouped.add(rule);
      } else {
        grouped.putIfAbsent(group, () => []).add(rule);
      }
    }

    final winners = <AgentBehavior>[];
    for (final entry in grouped.entries) {
      final candidates = [...entry.value]..sort(compareForConflict);
      final winner = candidates.first;
      winners.add(winner);
      for (final loser in candidates.skip(1)) {
        // A system safety rule never loses; if one is here, both apply and
        // the conflict is surfaced instead of silently resolved.
        if (loser.isSystemSafety) {
          winners.add(loser);
          trace.include(loser, 'system safety rule, never overridden');
          trace.warn('Rules "${winner.title}" and "${loser.title}" both '
              'claim conflict group "${entry.key}"; the safety rule was '
              'kept alongside the winner.');
          continue;
        }
        trace.exclude(
            loser, 'lost conflict "${entry.key}" to "${winner.title}"');
        // A user-created rule that would have weakened a built-in safety
        // rule is not just dropped quietly - that is exactly the case
        // someone will need explained later.
        if (winner.isSystemSafety) {
          trace.warn('Rule "${loser.title}" was not applied: it conflicts '
              'with the built-in safety rule "${winner.title}", which '
              'cannot be overridden.');
        }
      }
    }

    final resolved = [...ungrouped, ...winners]
      ..sort((a, b) => a.priority.compareTo(b.priority));
    return resolved;
  }

  /// Total order for conflict resolution; lower sorts first (wins).
  static int compareForConflict(AgentBehavior a, AgentBehavior b) {
    int flag(bool value) => value ? 0 : 1;
    var result = flag(a.isSystemSafety).compareTo(flag(b.isSystemSafety));
    if (result != 0) return result;
    result = flag(a.isCodeEnforced).compareTo(flag(b.isCodeEnforced));
    if (result != 0) return result;
    result = b.scopeSpecificity.compareTo(a.scopeSpecificity);
    if (result != 0) return result;
    result =
        flag(a.source == 'explicit').compareTo(flag(b.source == 'explicit'));
    if (result != 0) return result;
    result = a.priority.compareTo(b.priority);
    if (result != 0) return result;
    result = b.effectiveConfirmedAt.compareTo(a.effectiveConfirmedAt);
    if (result != 0) return result;
    result = b.confidence.compareTo(a.confidence);
    if (result != 0) return result;
    // Last resort so the order never depends on input order.
    return a.id.compareTo(b.id);
  }

  /// The behavior surface a phase represents. The planner and action phases
  /// belong to the turn's own surface (a chat turn or a scheduled job); the
  /// two finalization calls are always the final-response surface.
  static String surfaceForPhase(AgentPhase phase, String turnSurface) =>
      switch (phase) {
        AgentPhase.synthesis || AgentPhase.repair =>
          BehaviorSurface.finalResponse,
        _ => turnSurface,
      };

  static String _renderPhase({
    required AgentPhase phase,
    required List<AgentBehavior> rules,
    required Set<String>? domains,
    required String surface,
    required bool unattended,
    required int? contextWindow,
    required BehaviorTrace trace,
  }) {
    final allowedTypes = phaseTypes[phase]!;
    final relevant = <AgentBehavior>[];
    for (final rule in rules) {
      if (rule.isMandatory) {
        relevant.add(rule);
        continue;
      }
      if (!allowedTypes.contains(rule.behaviorType)) continue;
      // Relevance is judged against the surface this phase actually is: the
      // finalization calls ARE the final-response surface, whatever kind of
      // turn they belong to.
      if (!BehaviorContext.appliesTo(
          rule, surfaceForPhase(phase, surface), domains)) {
        continue;
      }
      relevant.add(rule);
    }

    // Rank by usefulness, not just numeric priority: a narrowly scoped rule
    // about this very request beats a high-priority global preference.
    relevant.sort((a, b) {
      int flag(bool value) => value ? 0 : 1;
      var result = flag(a.isMandatory).compareTo(flag(b.isMandatory));
      if (result != 0) return result;
      result = b.scopeSpecificity.compareTo(a.scopeSpecificity);
      if (result != 0) return result;
      result = a.priority.compareTo(b.priority);
      if (result != 0) return result;
      result = b.confidence.compareTo(a.confidence);
      if (result != 0) return result;
      return b.effectiveConfirmedAt.compareTo(a.effectiveConfirmedAt);
    });

    final budget = BehaviorTokenBudget.forPhase(phase,
        contextWindow: contextWindow);
    final kept = <AgentBehavior>[];
    var spent = 0;
    for (final rule in relevant) {
      final cost =
          TokenEstimator.estimateRuleLine(rule.behaviorType, rule.ruleText);
      // Mandatory rules are never dropped for budget - they are the ones
      // that must survive a full table.
      if (!rule.isMandatory && spent + cost > budget.maxTokens) {
        trace.exclude(rule, 'over the ${phase.name} token budget', phase: phase);
        continue;
      }
      kept.add(rule);
      spent += cost;
      trace.include(rule, 'applies to ${phase.name}', phase: phase);
    }

    if (kept.isEmpty && !unattended) return '';

    final buffer = StringBuffer();
    if (kept.isNotEmpty) {
      buffer.writeln(_headings[phase]!);
      for (final rule in kept) {
        buffer.writeln('- [${rule.behaviorType}] ${rule.ruleText}');
      }
    }
    // The unattended banner is an operating condition, not a preference, so
    // it goes to the phases that can act on it.
    if (unattended &&
        (phase == AgentPhase.planner || phase == AgentPhase.action)) {
      if (kept.isNotEmpty) buffer.writeln();
      buffer.writeln(BehaviorContext.unattendedBanner);
    }
    return buffer.toString().trimRight();
  }
}
