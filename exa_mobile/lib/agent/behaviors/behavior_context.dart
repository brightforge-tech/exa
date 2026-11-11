import '../../data/models/agent_behavior.dart';
import '../../data/repositories/behavior_repository.dart';
import '../tools/tool_domains.dart';

/// Where a set of behavior rules is being applied. A rule only reaches a
/// surface its type is relevant to, so the calendar rules don't ride along
/// on an email turn and the notification rules don't bloat the chat prompt.
class BehaviorSurface {
  BehaviorSurface._();

  /// The agent's action-phase system prompt (chat, overlay).
  static const String chat = 'chat';

  /// The no-tool finalization calls that write the user-facing message
  /// ([ResponseSynthesizer], [ResponseRepairer]).
  static const String finalResponse = 'final_response';

  /// A background job turn - no user is present.
  static const String scheduledJob = 'scheduled_job';

  /// Deterministic notification decisions (quiet hours, muting).
  static const String notification = 'notification';
}

/// The rules that apply to one piece of work, resolved once and shared by
/// everything that runs it.
///
/// Behaviors used to be read in exactly one place (the agent's system
/// prompt), which left the final-response calls, background jobs, and the
/// notification layer blind to them. This is the single resolver they all
/// go through: [load] decides which of the user's active rules are relevant
/// here, [render] turns them into the prompt block, and [ofType] hands the
/// raw rules to code that enforces them directly.
class BehaviorContext {
  const BehaviorContext({
    required this.behaviors,
    this.surface = BehaviorSurface.chat,
    this.unattended = false,
    this.droppedCount = 0,
  });

  /// No rules - for callers without a database (tests, isolates) and as the
  /// fallback when loading fails.
  const BehaviorContext.empty()
      : behaviors = const [],
        surface = BehaviorSurface.chat,
        unattended = false,
        droppedCount = 0;

  /// The relevant rules, in the repository's priority order.
  final List<AgentBehavior> behaviors;
  final String surface;

  /// True when nobody is watching (a background job): the agent must not ask
  /// questions or wait for approval.
  final bool unattended;

  /// How many relevant rules were cut by [maxRules]/[maxChars].
  final int droppedCount;

  /// Rules that always apply, whatever the turn is about: the user's
  /// preferences, their routines, and the safety rules.
  static const globalTypes = {
    'preference_rule',
    'workflow_rule',
    'safety_rule',
  };

  /// Rule type -> the tool domains it is about. A typed rule reaches a turn
  /// only when the turn touches one of its domains (or routing was skipped).
  static const typeDomains = <String, Set<String>>{
    'schedule_rule': {ToolDomains.calendar},
    'calendar_review_rule': {ToolDomains.calendar},
    'notification_rule': {ToolDomains.reminders, ToolDomains.calendar},
    'email_review_rule': {ToolDomains.email},
    'task_prioritization_rule': {ToolDomains.tasks},
    'screen_generation_rule': {ToolDomains.dynamicUi},
    'integration_rule': {
      ToolDomains.email,
      ToolDomains.browser,
      ToolDomains.backgroundJobs,
    },
  };

  /// Rule type -> surfaces it applies to regardless of domain. Summary rules
  /// are about how Exa writes, so they follow the text rather than a domain.
  static const typeSurfaces = <String, Set<String>>{
    'summary_rule': {
      BehaviorSurface.finalResponse,
      BehaviorSurface.scheduledJob,
    },
    'notification_rule': {
      BehaviorSurface.notification,
      BehaviorSurface.scheduledJob,
    },
  };

  /// Types that shape how a response reads rather than what it does - the
  /// set worth spending tokens on in the finalization calls.
  static const styleTypes = {
    'preference_rule',
    'summary_rule',
    'safety_rule',
    'notification_rule',
  };

  /// A long rule list must never crowd out the operating rules, especially
  /// on the small local models this app runs against.
  static const maxRules = 12;
  static const maxChars = 1500;

  /// Loads the active rules relevant to [surface] and [domains].
  ///
  /// [domains] is the turn's routed tool domains; null (routing skipped or
  /// unavailable) means "no domain filter", so every active rule is
  /// considered. Never throws - a behavior lookup failing must not take down
  /// the turn that wanted it.
  static Future<BehaviorContext> load({
    required BehaviorRepository behaviors,
    String surface = BehaviorSurface.chat,
    Set<String>? domains,
    bool unattended = false,
    Set<String>? onlyTypes,
  }) async {
    try {
      final active = await behaviors.listActive();
      return fromBehaviors(
        active,
        surface: surface,
        domains: domains,
        unattended: unattended,
        onlyTypes: onlyTypes,
      );
    } catch (_) {
      return BehaviorContext(surface: surface, unattended: unattended,
          behaviors: const []);
    }
  }

  /// The filtering itself, over an already-loaded list. [active] is expected
  /// in the repository's order (priority ASC, created_at ASC), which is also
  /// the order rules are dropped from the end in.
  static BehaviorContext fromBehaviors(
    List<AgentBehavior> active, {
    String surface = BehaviorSurface.chat,
    Set<String>? domains,
    bool unattended = false,
    Set<String>? onlyTypes,
  }) {
    final relevant = <AgentBehavior>[];
    for (final behavior in active) {
      // Safety rules are never filtered out, by surface, domain or type.
      final isSafety = behavior.behaviorType == 'safety_rule';
      if (!isSafety &&
          onlyTypes != null &&
          !onlyTypes.contains(behavior.behaviorType)) {
        continue;
      }
      if (isSafety || _appliesTo(behavior, surface, domains)) {
        relevant.add(behavior);
      }
    }

    // Trim from the end: the repository orders by priority, so what goes
    // first is what the user (or the agent) ranked least important.
    final kept = <AgentBehavior>[];
    var chars = 0;
    var dropped = 0;
    for (final behavior in relevant) {
      final cost = behavior.ruleText.length + behavior.behaviorType.length + 6;
      if (kept.length >= maxRules || (chars + cost > maxChars &&
          kept.isNotEmpty)) {
        dropped++;
        continue;
      }
      kept.add(behavior);
      chars += cost;
    }

    return BehaviorContext(
      behaviors: kept,
      surface: surface,
      unattended: unattended,
      droppedCount: dropped,
    );
  }

  static bool _appliesTo(
          AgentBehavior behavior, String surface, Set<String>? domains) =>
      appliesTo(behavior, surface, domains);

  /// Whether [behavior] is relevant to this surface/domain combination.
  /// Shared with [BehaviorPlan], which applies the same relevance test per
  /// model phase.
  static bool appliesTo(
      AgentBehavior behavior, String surface, Set<String>? domains) {
    final type = behavior.behaviorType;
    if (globalTypes.contains(type)) return true;

    final ruleSurfaces = typeSurfaces[type];
    if (ruleSurfaces != null && ruleSurfaces.contains(surface)) return true;

    final ruleDomains = typeDomains[type];
    if (ruleDomains != null) {
      // No routing information: every domain-scoped rule is a candidate.
      return domains == null || ruleDomains.any(domains.contains);
    }
    // Surface-scoped only (summary rules): the surface above didn't match,
    // and there is no domain to fall back on.
    if (ruleSurfaces != null) return false;
    // An unknown/unmapped type has nothing to filter on - keep it rather
    // than silently dropping a rule the user saved.
    return true;
  }

  bool get isEmpty => behaviors.isEmpty;
  bool get isNotEmpty => behaviors.isNotEmpty;

  /// The rules of one type, for code that enforces them directly instead of
  /// putting them in a prompt.
  List<AgentBehavior> ofType(String behaviorType) =>
      behaviors.where((b) => b.behaviorType == behaviorType).toList();

  /// A narrower view of the same rules for another surface, without a second
  /// database round trip (the finalization calls reuse the turn's context).
  BehaviorContext forSurface(String newSurface, {Set<String>? onlyTypes}) =>
      fromBehaviors(
        behaviors,
        surface: newSurface,
        unattended: unattended,
        onlyTypes: onlyTypes,
      );

  /// The prompt block: the rules, plus the unattended banner when no user is
  /// there to answer. Empty string when there is nothing to say.
  String render({String heading = 'Your saved behavior rules (follow these):'}) {
    if (behaviors.isEmpty && !unattended) return '';
    final buffer = StringBuffer();
    if (behaviors.isNotEmpty) {
      buffer.writeln(heading);
      for (final behavior in behaviors) {
        buffer.writeln('- [${behavior.behaviorType}] ${behavior.ruleText}');
      }
    }
    if (unattended) {
      if (behaviors.isNotEmpty) buffer.writeln();
      buffer.writeln(unattendedBanner);
    }
    return buffer.toString().trimRight();
  }

  static const unattendedBanner =
      'You are running unattended: this is a scheduled background run and '
      'the user is not present. Do not ask questions and do not wait for '
      'approval - anything that needs their confirmation must be skipped '
      'and reported as skipped in your summary. Write the result as a '
      'standalone briefing they will read later.\n'
      // Short imperative sentences, one rule each: this block is read by
      // 2-bit local models as often as by frontier ones, and the failure it
      // addresses - writing up a digest that was never run - is theirs.
      'Nothing is carried over from earlier runs. Work only from what your '
      'tools return in THIS run:\n'
      '- Call the tools first. Do not write the result until they have '
      'returned.\n'
      '- When the job is to go through messages or email, create a task, '
      'reminder or event only from an item a read tool returned in this '
      'run.\n'
      '- If those reads return nothing new, create nothing from them: say '
      'there was nothing new and stop.\n'
      '- Report only what the tool results show. Never describe a step you '
      'did not run.';
}
