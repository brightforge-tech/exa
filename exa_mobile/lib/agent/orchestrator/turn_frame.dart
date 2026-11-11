import 'dart:convert';

import '../entities/models/active_entity_context.dart';
import '../models/turn_contract.dart';
import '../tools/tool_domains.dart';
import 'domain_router.dart';

/// How consequential this turn is. Drives evidence and assumption policy,
/// how much the retriever is allowed to guess, and (later) whether the turn
/// escalates to a stronger model.
enum TurnRisk {
  low,
  moderate,
  high;

  String get wireName => name;

  static TurnRisk fromWireName(String? name) => switch (name?.trim()) {
        'high' => TurnRisk.high,
        'moderate' || 'medium' => TurnRisk.moderate,
        _ => TurnRisk.low,
      };

  bool operator >(TurnRisk other) => index > other.index;
}

/// What the turn must be able to point at before it states something.
enum EvidencePolicy {
  /// Conversational turns: nothing to cite.
  none,

  /// Cite where it is available, but a well-formed answer without evidence
  /// is acceptable.
  preferEvidence,

  /// Every factual claim must map to a retrieved record or a tool result.
  requireEvidence;

  String get wireName => name;
}

/// What Exa may do when the request leaves something open.
enum AssumptionPolicy {
  /// Pick the obvious reading and continue silently.
  assumeSilently,

  /// Pick a reading, act, and say which one was picked.
  assumeAndDisclose,

  /// Stop and ask; acting on the wrong reading would be expensive.
  askFirst;

  String get wireName => name;
}

/// A specific thing the turn needs and does not yet have.
class UnresolvedSlot {
  const UnresolvedSlot({
    required this.name,
    required this.question,
    this.blocking = false,
  });

  final String name;
  final String question;

  /// True when proceeding on a guess would be unsafe or wasteful.
  final bool blocking;

  Map<String, Object?> toJson() => {
        'name': name,
        'question': question,
        if (blocking) 'blocking': true,
      };
}

/// A window of time the request scopes itself to ("this week", "tomorrow").
/// Used to filter retrieval so a question about today does not drag in
/// last quarter's episodes.
class TimeRange {
  const TimeRange({required this.start, required this.end, required this.label});

  final DateTime start;
  final DateTime end;
  final String label;

  bool contains(DateTime moment) =>
      !moment.isBefore(start) && !moment.isAfter(end);

  Map<String, Object?> toJson() => {
        'label': label,
        'start': start.toIso8601String(),
        'end': end.toIso8601String(),
      };
}

/// A minimal reference to something the turn is about.
class EntityRef {
  const EntityRef({
    required this.id,
    required this.type,
    required this.name,
    this.externalId,
    this.position,
  });

  final String id;
  final String type;
  final String name;
  final String? externalId;
  final int? position;

  Map<String, Object?> toJson() => {
        'id': id,
        'type': type,
        'name': name,
        if (externalId != null) 'source_id': externalId,
        if (position != null) 'position': position,
      };
}

/// What this turn is about, decided before anything is retrieved.
///
/// The pipeline used to route, retrieve, and only then build the completion
/// contract — which meant retrieval ran before Exa had defined what counted
/// as relevant, and the memory block filled up with whatever scored highest
/// against the raw request string. The frame is built first, from the
/// router's reply plus deterministic analysis of the request, and every
/// later stage narrows against it. It costs no extra model call.
///
/// The completion contract still refines this afterwards; the frame is
/// provisional by design.
class TurnFrame {
  const TurnFrame({
    required this.primaryGoal,
    required this.requiredOutputs,
    required this.constraints,
    required this.entities,
    required this.activeTopicId,
    required this.topicTokens,
    required this.risk,
    required this.evidencePolicy,
    required this.assumptionPolicy,
    required this.unresolved,
    required this.likelyDomains,
    required this.responseTokenBudget,
    required this.retrievalTerms,
    this.timeScope,
    this.topicShifted = false,
    this.requiresToolAction = true,
  });

  /// One line: what the user actually asked for.
  final String primaryGoal;

  /// What the final response must contain.
  final Set<ResponseOutputType> requiredOutputs;

  /// Limits the request imposes.
  final List<String> constraints;

  /// What the turn is about, resolved before retrieval.
  final List<EntityRef> entities;

  /// Time window the request scopes itself to, when it states one.
  final TimeRange? timeScope;

  /// Stable id for the current subject. Retrieval prefers memories from the
  /// same topic; a shift stops the previous topic's capsule being replayed.
  final String activeTopicId;

  /// The content tokens the topic id was derived from, carried forward so
  /// the next turn can measure drift.
  final Set<String> topicTokens;

  /// True when this request is about something other than the last one.
  final bool topicShifted;

  final TurnRisk risk;
  final EvidencePolicy evidencePolicy;
  final AssumptionPolicy assumptionPolicy;

  /// Things the request left open. Blocking entries should stop execution.
  final List<UnresolvedSlot> unresolved;

  /// Domains the request probably needs (the router's answer, or the
  /// deterministic guess when routing failed).
  final Set<String> likelyDomains;

  /// Roughly how long the answer should be.
  final int responseTokenBudget;

  /// Expanded query terms for retrieval: request words, entity names and
  /// aliases, domain vocabulary. Retrieval scores against these rather than
  /// the raw request string.
  final Set<String> retrievalTerms;

  /// False for turns that only owe an answer (no tools needed).
  final bool requiresToolAction;

  bool get hasBlockingAmbiguity =>
      unresolved.any((slot) => slot.blocking);

  /// Compact form for diagnostics and replay traces.
  Map<String, Object?> toJson() => {
        'primary_goal': primaryGoal,
        'required_outputs': [
          for (final output in requiredOutputs) output.wireName,
        ],
        if (constraints.isNotEmpty) 'constraints': constraints,
        if (entities.isNotEmpty)
          'entities': [for (final entity in entities) entity.toJson()],
        if (timeScope != null) 'time_scope': timeScope!.toJson(),
        'topic_id': activeTopicId,
        if (topicShifted) 'topic_shifted': true,
        'risk': risk.wireName,
        'evidence_policy': evidencePolicy.wireName,
        'assumption_policy': assumptionPolicy.wireName,
        if (unresolved.isNotEmpty)
          'unresolved': [for (final slot in unresolved) slot.toJson()],
        if (likelyDomains.isNotEmpty) 'likely_domains': likelyDomains.toList(),
        'response_token_budget': responseTokenBudget,
        'requires_tool_action': requiresToolAction,
      };
}

/// Builds the [TurnFrame] from what is already available at the top of a
/// turn: the router's structured reply, the active entity context, and
/// deterministic analysis of the request text. No extra model call.
class TurnFrameBuilder {
  const TurnFrameBuilder({this.now});

  /// Injectable clock so time-scope parsing is testable.
  final DateTime Function()? now;

  DateTime get _now => now?.call() ?? DateTime.now();

  TurnFrame build({
    required String userText,
    DomainRoutingResult? routing,
    ActiveEntityContext activeEntities = ActiveEntityContext.empty,
    Set<String> previousTopicTokens = const {},
    String? previousTopicId,
    Set<String> priorTurnEntityIds = const {},
    bool unattended = false,
  }) {
    final requestTokens = contentTokens(userText);
    final entities = [
      for (final entity in activeEntities.entities.take(8))
        EntityRef(
          id: entity.entityId,
          type: entity.entityType.wireName,
          name: entity.displayName,
          externalId: entity.externalId,
          position: entity.position,
        ),
    ];

    final domains = routing?.domains ?? _guessDomains(requestTokens);
    final outputs = routing?.responseOutputs ?? const <ResponseOutputType>{};
    final timeScope = parseTimeScope(userText, _now);

    // Topic identity comes from the request's content words plus the
    // domains it touches, so "my emails" and "my inbox" land together while
    // "my emails" and "reschedule the dentist" do not.
    final topicTokens = {...requestTokens.take(8), ...domains};
    final topicId = _topicIdFor(topicTokens);
    final shifted = previousTopicTokens.isNotEmpty &&
        _overlap(topicTokens, previousTopicTokens) < 0.2 &&
        previousTopicId != topicId;

    final risk = _assessRisk(
      userText: userText,
      requestTokens: requestTokens,
      routing: routing,
      domains: domains,
    );
    final unresolved = _detectUnresolved(
      userText: userText,
      requestTokens: requestTokens,
      entities: entities,
      risk: risk,
      domains: domains,
      priorTurnEntityIds: priorTurnEntityIds,
    );

    return TurnFrame(
      primaryGoal: _primaryGoal(userText, routing),
      requiredOutputs: outputs,
      constraints: routing?.constraints ?? const [],
      entities: entities,
      timeScope: timeScope,
      activeTopicId: topicId,
      topicTokens: topicTokens,
      topicShifted: shifted,
      risk: risk,
      evidencePolicy: _evidencePolicyFor(risk, outputs),
      assumptionPolicy:
          _assumptionPolicyFor(risk, unresolved, unattended: unattended),
      unresolved: unresolved,
      likelyDomains: domains,
      responseTokenBudget: _responseBudgetFor(outputs, risk),
      retrievalTerms: {
        ...requestTokens,
        for (final entity in entities) ...contentTokens(entity.name),
        ...domains,
      },
      requiresToolAction:
          routing == null || routing.actions.isNotEmpty || domains.isNotEmpty,
    );
  }

  /// The router states the goal when it can; otherwise the request's own
  /// first sentence is a better label than a guessed paraphrase.
  static String _primaryGoal(String userText, DomainRoutingResult? routing) {
    final goal = routing?.primaryGoal?.trim();
    if (goal != null && goal.isNotEmpty) return goal;
    final actions = routing?.actions ?? const [];
    if (actions.isNotEmpty) {
      return actions.map((action) => action.description).take(3).join('; ');
    }
    final trimmed = userText.trim();
    final stop = trimmed.indexOf(RegExp(r'[.!?\n]'));
    final first = stop > 12 ? trimmed.substring(0, stop) : trimmed;
    return first.length > 160 ? '${first.substring(0, 160)}...' : first;
  }

  /// Deterministic risk assessment. The router may raise it but never lower
  /// it: a model that under-reports risk must not be able to unlock a
  /// cheaper path.
  static TurnRisk _assessRisk({
    required String userText,
    required Set<String> requestTokens,
    required DomainRoutingResult? routing,
    required Set<String> domains,
  }) {
    const destructive = {
      'delete', 'remove', 'erase', 'wipe', 'cancel', 'clear', 'purge',
      'unsubscribe', 'send', 'email', 'reply', 'forward', 'pay', 'buy',
      'purchase', 'transfer', 'book', 'order',
    };
    final routerRisk = TurnRisk.fromWireName(routing?.risk);
    var risk = TurnRisk.low;

    if (requestTokens.any(destructive.contains) ||
        routing?.requiresConfirmation == true ||
        domains.contains(ToolDomains.email)) {
      risk = TurnRisk.high;
    } else if ((routing?.actions.length ?? 0) > 1 || domains.length > 1) {
      risk = TurnRisk.moderate;
    }
    return routerRisk.index > risk.index ? routerRisk : risk;
  }

  /// Ambiguity worth stopping for, found without a model.
  ///
  /// Blocking stays gated on risk: an assistant that asks about everything is
  /// worse than one that occasionally guesses and says so. Everything here
  /// fails open - a pattern not recognized leaves the turn exactly as it was
  /// before this existed.
  static List<UnresolvedSlot> _detectUnresolved({
    required String userText,
    required Set<String> requestTokens,
    required List<EntityRef> entities,
    required TurnRisk risk,
    required Set<String> domains,
    required Set<String> priorTurnEntityIds,
  }) {
    final slots = <UnresolvedSlot>[];
    final lower = userText.toLowerCase();
    final reference = RegExp(
      r'\b(it|that one|this one|the other one|them|those|him|her|the same)\b',
    ).firstMatch(lower);
    // A pronoun with its own antecedent in the request is not a dangling
    // reference. "Sync new emails and digest them" says what "them" is; only
    // a request that opens on the pronoun ("delete it", "now cancel it") is
    // actually reaching back to a previous turn.
    final hasBareReference =
        reference != null && !_resolvesItself(lower, reference.start);
    final namesAReference = entities.any(
        (entity) => contentTokens(entity.name).any(requestTokens.contains));

    if (hasBareReference && !namesAReference) {
      if (entities.isEmpty && priorTurnEntityIds.isEmpty) {
        // "Delete it" with nothing at all in scope. This used to produce no
        // slot - the check required more than one candidate - so the least
        // resolvable case of all was the one that sailed through and let the
        // model pick something.
        //
        // `priorTurnEntityIds` is load-bearing, not belt-and-braces: the
        // entity graph is empty on a fresh install and whenever the
        // intelligence layer is absent, so testing `entities` alone turns
        // "remind me to stretch" / "now cancel it" - about as resolvable as a
        // follow-up gets - into a question. The previous turn's own record of
        // what it touched is the referent, and it survives an empty graph.
        slots.add(UnresolvedSlot(
          name: 'referent',
          question: 'What should this apply to? Nothing recent is in scope to '
              'resolve it against.',
          blocking: risk == TurnRisk.high,
        ));
      } else if (entities.length > 1) {
        // Several candidates and nothing in the request distinguishes them.
        final byType = <String, int>{};
        for (final entity in entities) {
          byType[entity.type] = (byType[entity.type] ?? 0) + 1;
        }
        final ambiguousType = byType.entries
            .where((entry) => entry.value > 1)
            .map((entry) => entry.key)
            .firstOrNull;
        if (ambiguousType != null) {
          slots.add(UnresolvedSlot(
            name: 'referent',
            question: 'Which $ambiguousType is meant? Several were mentioned '
                'recently.',
            blocking: risk == TurnRisk.high,
          ));
        }
      }
    }

    // A reminder or an event without a time is not a reminder. Scheduling it
    // on a guessed time is the case the whole `..._label` discipline exists to
    // keep honest, and a wrong one is worse than no reminder at all: the user
    // stops watching for the thing themselves.
    final scheduling = domains.contains(ToolDomains.reminders) ||
        domains.contains(ToolDomains.calendar);
    final createsSomething = requestTokens.any(const {
      'remind', 'reminder', 'schedule', 'meeting', 'event', 'appointment',
      'book', 'set',
    }.contains);
    if (scheduling && createsSomething && !hasExplicitTime(userText)) {
      slots.add(const UnresolvedSlot(
        name: 'time',
        question: 'What time should this be set for? The request does not say '
            'one.',
        // Always blocking: unlike a referent, there is no most-likely reading
        // to fall back on - every choice is invented.
        blocking: true,
      ));
    }

    // Two different time scopes in one request ("tomorrow" and "next week").
    // Not blocking: one of them is usually the subject and the other is
    // incidental, and saying which was used is enough.
    if (_timeScopePhrases(lower).length > 1) {
      slots.add(UnresolvedSlot(
        name: 'time_scope',
        question: 'Which period is meant - '
            '${_timeScopePhrases(lower).join(' or ')}?',
      ));
    }
    return slots;
  }

  /// Whether enough of a noun phrase precedes the pronoun at [pronounStart]
  /// for the request to be its own antecedent.
  ///
  /// Three content words is the line: "delete it" and "now cancel it" fall
  /// under it and are genuine backward references, while "sync new emails and
  /// digest them" clears it and needs no previous turn to make sense.
  static bool _resolvesItself(String lower, int pronounStart) =>
      contentTokens(lower.substring(0, pronounStart)).length >= 3;

  /// Whether the request states a time at all: a clock time, a weekday, a
  /// date, or one of the relative phrases [parseTimeScope] knows.
  ///
  /// Deliberately a different question from [parseTimeScope], which answers
  /// "what window should retrieval filter to" and returns nothing for "at
  /// 3pm". Both live here so the two sets of patterns cannot drift apart.
  static bool hasExplicitTime(String text) {
    final lower = text.toLowerCase();
    return _explicitTimePatterns.any((pattern) => pattern.hasMatch(lower)) ||
        _timeScopePhrases(lower).isNotEmpty;
  }

  static final _explicitTimePatterns = <RegExp>[
    // 3pm, 3:30, 15:00, 3 o'clock
    RegExp(r'\b\d{1,2}\s*(:\d{2})?\s*(am|pm)\b'),
    RegExp(r'\b\d{1,2}:\d{2}\b'),
    RegExp(r"\b\d{1,2}\s*o'?clock\b"),
    // Weekday names, which the action prompt already maps via
    // [upcomingWeekdayMap] - so the frame must recognize them too.
    RegExp(r'\b(monday|tuesday|wednesday|thursday|friday|saturday|sunday)\b'),
    // in 20 minutes / in 2 hours / in 3 days
    RegExp(r'\bin \d+\s*(min|mins|minute|minutes|hour|hours|day|days|week|weeks)\b'),
    // the 15th, June 3, 2026-06-03
    RegExp(r'\b\d{1,2}(st|nd|rd|th)\b'),
    RegExp(r'\b(january|february|march|april|may|june|july|august|september|'
        r'october|november|december)\s+\d{1,2}\b'),
    RegExp(r'\b\d{4}-\d{2}-\d{2}\b'),
    // noon / midnight / this morning / tonight
    RegExp(r'\b(noon|midday|midnight)\b'),
    RegExp(r'\b(this|tomorrow|tonight)\s*(morning|afternoon|evening)?\b'),
    RegExp(r'\b(morning|afternoon|evening)\b'),
  ];

  /// The relative scope phrases present in [lower], in the order they are
  /// tested by [parseTimeScope]. Shared so "two scopes were named" and "this
  /// is the scope" cannot disagree.
  static List<String> _timeScopePhrases(String lower) {
    const phrases = {
      'today': r'\btoday\b',
      'tonight': r'\btonight\b',
      'tomorrow': r'\btomorrow\b',
      'yesterday': r'\byesterday\b',
      'this week': r'\bthis week\b',
      'next week': r'\bnext week\b',
      'last week': r'\blast week\b',
      'this weekend': r'\bthis weekend\b',
      'this month': r'\bthis month\b',
      'next month': r'\bnext month\b',
    };
    return [
      for (final entry in phrases.entries)
        if (RegExp(entry.value).hasMatch(lower)) entry.key,
    ];
  }

  static EvidencePolicy _evidencePolicyFor(
      TurnRisk risk, Set<ResponseOutputType> outputs) {
    const evidenceHungry = {
      ResponseOutputType.rundown,
      ResponseOutputType.summary,
      ResponseOutputType.taskList,
      ResponseOutputType.meetingList,
      ResponseOutputType.deadlineList,
      ResponseOutputType.resultList,
      ResponseOutputType.attentionItems,
      ResponseOutputType.priorityPlan,
    };
    if (risk == TurnRisk.high || outputs.any(evidenceHungry.contains)) {
      return EvidencePolicy.requireEvidence;
    }
    if (outputs.isEmpty) return EvidencePolicy.none;
    return EvidencePolicy.preferEvidence;
  }

  /// [unattended] never yields [AssumptionPolicy.askFirst].
  ///
  /// Asking is not an available action in a scheduled run - there is nobody to
  /// answer, so a turn that stops to ask simply does nothing and reports
  /// nothing done. This cost a real outage: the user's every-30-minutes email
  /// digest says "Sync new emails and Digest **them**", the pronoun tripped the
  /// bare-reference rule, "email" made the turn high risk, and the job went
  /// read-only and asked a question into the void - `sync_emails` refused with
  /// `awaiting_clarification`, run after run, reporting "No emails were
  /// digested this time".
  ///
  /// The slot stays `blocking`, so the turn still escalates and still gets
  /// verified; what changes is that it proceeds on the likeliest reading and
  /// says which one it chose - exactly what the unattended banner already
  /// asks of it.
  static AssumptionPolicy _assumptionPolicyFor(
      TurnRisk risk, List<UnresolvedSlot> unresolved,
      {bool unattended = false}) {
    if (!unattended && unresolved.any((slot) => slot.blocking)) {
      return AssumptionPolicy.askFirst;
    }
    if (risk == TurnRisk.high) return AssumptionPolicy.assumeAndDisclose;
    if (unresolved.isNotEmpty) return AssumptionPolicy.assumeAndDisclose;
    return AssumptionPolicy.assumeSilently;
  }

  /// A phone screen. A confirmation is two lines; a weekly rundown is not.
  static int _responseBudgetFor(
      Set<ResponseOutputType> outputs, TurnRisk risk) {
    const listy = {
      ResponseOutputType.rundown,
      ResponseOutputType.taskList,
      ResponseOutputType.meetingList,
      ResponseOutputType.deadlineList,
      ResponseOutputType.resultList,
      ResponseOutputType.attentionItems,
      ResponseOutputType.priorityPlan,
      ResponseOutputType.generatedContent,
    };
    var budget = 180;
    for (final output in outputs) {
      budget += listy.contains(output) ? 160 : 60;
    }
    if (risk == TurnRisk.high) budget += 80;
    return budget.clamp(180, 1200);
  }

  /// Domains guessed from request vocabulary when routing produced nothing.
  /// Deliberately narrow: a wrong guess only affects retrieval weighting,
  /// never which tools are exposed.
  static Set<String> _guessDomains(Set<String> tokens) {
    const vocabulary = <String, String>{
      'task': ToolDomains.tasks,
      'tasks': ToolDomains.tasks,
      'todo': ToolDomains.tasks,
      'remind': ToolDomains.reminders,
      'reminder': ToolDomains.reminders,
      'reminders': ToolDomains.reminders,
      'alarm': ToolDomains.reminders,
      'meeting': ToolDomains.calendar,
      'calendar': ToolDomains.calendar,
      'schedule': ToolDomains.calendar,
      'event': ToolDomains.calendar,
      'appointment': ToolDomains.calendar,
      'email': ToolDomains.email,
      'emails': ToolDomains.email,
      'inbox': ToolDomains.email,
      'mail': ToolDomains.email,
      'file': ToolDomains.files,
      'files': ToolDomains.files,
      'document': ToolDomains.files,
      'attachment': ToolDomains.files,
      'browser': ToolDomains.browser,
      'page': ToolDomains.browser,
      'tab': ToolDomains.browser,
      'job': ToolDomains.backgroundJobs,
      'jobs': ToolDomains.backgroundJobs,
      'rule': ToolDomains.behaviorRules,
      'rules': ToolDomains.behaviorRules,
      'behaviour': ToolDomains.behaviorRules,
      'behavior': ToolDomains.behaviorRules,
    };
    return {
      for (final token in tokens)
        if (vocabulary.containsKey(token)) vocabulary[token]!,
    };
  }

  static String _topicIdFor(Set<String> tokens) {
    if (tokens.isEmpty) return 'topic_general';
    final sorted = tokens.toList()..sort();
    // Stable, short, and readable in a trace.
    var hash = 0;
    for (final code in utf8.encode(sorted.join('|'))) {
      hash = (hash * 31 + code) & 0x7fffffff;
    }
    return 'topic_${hash.toRadixString(36)}';
  }

  static double _overlap(Set<String> a, Set<String> b) {
    if (a.isEmpty || b.isEmpty) return 0;
    return a.intersection(b).length / a.union(b).length;
  }

  /// Deterministic time-scope parsing for the phrases that actually appear
  /// in requests. Anything else leaves the scope null (= no time filter),
  /// which is the safe direction: an unfiltered retrieval is merely noisier,
  /// a wrongly filtered one silently drops the answer.
  static TimeRange? parseTimeScope(String text, DateTime now) {
    final lower = text.toLowerCase();
    final startOfDay = DateTime(now.year, now.month, now.day);

    TimeRange range(String label, DateTime start, DateTime end) =>
        TimeRange(start: start, end: end, label: label);

    if (RegExp(r'\btoday\b|\bthis morning\b|\bthis afternoon\b|\btonight\b')
        .hasMatch(lower)) {
      return range('today', startOfDay, startOfDay.add(const Duration(days: 1)));
    }
    if (lower.contains('tomorrow')) {
      final start = startOfDay.add(const Duration(days: 1));
      return range('tomorrow', start, start.add(const Duration(days: 1)));
    }
    if (lower.contains('yesterday')) {
      final start = startOfDay.subtract(const Duration(days: 1));
      return range('yesterday', start, startOfDay);
    }
    if (RegExp(r'\bthis week\b').hasMatch(lower)) {
      final start = startOfDay.subtract(Duration(days: now.weekday - 1));
      return range('this week', start, start.add(const Duration(days: 7)));
    }
    if (RegExp(r'\bnext week\b').hasMatch(lower)) {
      final start =
          startOfDay.add(Duration(days: 8 - now.weekday));
      return range('next week', start, start.add(const Duration(days: 7)));
    }
    if (RegExp(r'\blast week\b').hasMatch(lower)) {
      final thisWeek = startOfDay.subtract(Duration(days: now.weekday - 1));
      final start = thisWeek.subtract(const Duration(days: 7));
      return range('last week', start, thisWeek);
    }
    if (RegExp(r'\bthis weekend\b').hasMatch(lower)) {
      // Saturday of the current week, through the end of Sunday.
      final start = startOfDay.add(Duration(days: 6 - now.weekday));
      return range('this weekend', start, start.add(const Duration(days: 2)));
    }
    if (RegExp(r'\bthis month\b').hasMatch(lower)) {
      final start = DateTime(now.year, now.month);
      return range('this month', start, DateTime(now.year, now.month + 1));
    }
    if (RegExp(r'\bnext month\b').hasMatch(lower)) {
      final start = DateTime(now.year, now.month + 1);
      return range('next month', start, DateTime(now.year, now.month + 2));
    }
    if (RegExp(r'\b(end of (the )?month)\b').hasMatch(lower)) {
      // The last three days, which is what "before the end of the month"
      // means in practice for a deadline.
      final end = DateTime(now.year, now.month + 1);
      return range('end of the month',
          end.subtract(const Duration(days: 3)), end);
    }
    // "in 2 hours", "in 3 days" - a window from now to then, so a question
    // about it retrieves what falls inside rather than everything.
    final relative = RegExp(
            r'\bin (\d+)\s*(min|mins|minute|minutes|hour|hours|day|days|week|weeks)\b')
        .firstMatch(lower);
    if (relative != null) {
      final amount = int.tryParse(relative.group(1) ?? '');
      if (amount != null && amount > 0) {
        final unit = relative.group(2)!;
        final span = switch (unit) {
          'min' || 'mins' || 'minute' || 'minutes' => Duration(minutes: amount),
          'hour' || 'hours' => Duration(hours: amount),
          'week' || 'weeks' => Duration(days: 7 * amount),
          _ => Duration(days: amount),
        };
        return range('in $amount $unit', now, now.add(span));
      }
    }
    // A weekday name means the next occurrence of it, which is the same
    // mapping [upcomingWeekdayMap] hands the action model. The frame has to
    // agree with the prompt about what "Friday" is, or "what's on Friday?"
    // gets no time filter while the reminder it creates gets the right date.
    for (var weekday = 1; weekday <= 7; weekday++) {
      final name = _weekdayNames[weekday - 1];
      if (!RegExp('\\b$name\\b').hasMatch(lower)) continue;
      final ahead = (weekday - now.weekday + 7) % 7;
      final start = startOfDay.add(Duration(days: ahead));
      return range(name, start, start.add(const Duration(days: 1)));
    }
    return null;
  }

  static const _weekdayNames = [
    'monday', 'tuesday', 'wednesday', 'thursday', 'friday', 'saturday',
    'sunday',
  ];

  /// Content words: lowercase, de-punctuated, stopwords and very short
  /// tokens dropped. Shared with retrieval so both sides score the same
  /// vocabulary.
  static Set<String> contentTokens(String text) {
    const stopwords = {
      'the', 'a', 'an', 'and', 'or', 'of', 'to', 'for', 'from', 'with',
      'my', 'me', 'in', 'on', 'is', 'are', 'was', 'were', 'it', 'this',
      'that', 'you', 'your', 'user', 'please', 'can', 'could', 'would',
      'about', 'have', 'has', 'had', 'get', 'got', 'any', 'all', 'some',
      'what', 'when', 'where', 'which', 'who', 'how', 'why', 'let', 'lets',
    };
    return text
        .toLowerCase()
        .split(RegExp(r'[^a-z0-9]+'))
        .where((token) => token.length > 2 && !stopwords.contains(token))
        .toSet();
  }
}
