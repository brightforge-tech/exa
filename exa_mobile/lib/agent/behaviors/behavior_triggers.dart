import '../../data/models/agent_behavior.dart';

/// A behavior rule that fires work when something happens, rather than only
/// shaping a turn that is already running.
///
/// Behaviors were previously advisory text: they could influence how the
/// agent acted during a turn, but nothing consulted them to decide whether a
/// turn should happen at all. That made a rule like "digest my email when it
/// arrives" impossible to honour - the sync job is deterministic code with
/// no model call, so the rule had nothing to attach to and only ever
/// affected the wording of the report.
///
/// A trigger is declared in the rule's params:
///
/// ```json
/// {"trigger": {"on": "new_mail", "action": "digest",
///              "min_interval_minutes": 30, "max_items": 15}}
/// ```
class BehaviorTrigger {
  const BehaviorTrigger({
    required this.behaviorId,
    required this.behaviorTitle,
    required this.event,
    required this.action,
    this.minIntervalMinutes = 30,
    this.maxItems = 15,
    this.maxFiringsPerDay = 8,
    this.maxRecordsPerFiring = 15,
    this.allowRecurringTasks = false,
    this.scope = const TriggerScope(),
  });

  /// Events a deterministic job can raise.
  static const eventNewMail = 'new_mail';

  /// New chat messages captured from WhatsApp and friends. A separate event
  /// from [eventNewMail] rather than a shared "new_item": a user who wants
  /// their mail digested hourly and their group chats left alone has to be
  /// able to say so, and one event with a filter cannot express that.
  static const eventNewMessage = 'new_message';

  /// What to do when the event fires.
  static const actionDigest = 'digest';

  static const events = {eventNewMail, eventNewMessage};
  static const actions = {actionDigest};

  final String behaviorId;
  final String behaviorTitle;
  final String event;
  final String action;

  /// Floor between firings. A 2-minute sync job must not start a model turn
  /// every 2 minutes, so the trigger paces itself independently of whatever
  /// raised the event.
  final int minIntervalMinutes;

  /// Ceiling on how much one firing takes on, so a backlog of 200 emails
  /// becomes several sane runs instead of one that blows the context window.
  final int maxItems;

  /// Firings allowed in a day. The interval paces *frequency*; this bounds
  /// *total* work, which is the number a user actually feels — a rule that
  /// fires every 30 minutes all day is 48 model turns they never asked for.
  final int maxFiringsPerDay;

  /// Records one firing may create. A rule that reads mail should produce a
  /// handful of tasks, not forty.
  final int maxRecordsPerFiring;

  /// Whether a firing may create something that repeats. Off by default:
  /// automation creating more automation is the loop with no natural end.
  final bool allowRecurringTasks;

  /// What this trigger is allowed to act on.
  final TriggerScope scope;

  /// Reads the trigger from a rule, or null when it declares none.
  ///
  /// Unknown events and actions are rejected rather than assumed: a typo
  /// must not silently arm something, and a rule from a newer version of the
  /// app must not fire an action this build does not implement.
  static BehaviorTrigger? fromBehavior(AgentBehavior behavior) {
    final raw = behavior.params['trigger'];
    if (raw is! Map) return null;
    final event = raw['on']?.toString();
    final action = raw['action']?.toString();
    if (event == null || !events.contains(event)) return null;
    if (action == null || !actions.contains(action)) return null;
    return BehaviorTrigger(
      behaviorId: behavior.id,
      behaviorTitle: behavior.title,
      event: event,
      action: action,
      minIntervalMinutes: _int(raw['min_interval_minutes'], 30, 1, 24 * 60),
      maxItems: _int(raw['max_items'], 15, 1, 50),
      maxFiringsPerDay: _int(raw['max_firings_per_day'], 8, 1, 48),
      maxRecordsPerFiring: _int(raw['max_records_created_per_firing'], 15, 1, 50),
      allowRecurringTasks: raw['allow_recurring_tasks'] == true,
      scope: TriggerScope.fromJson(behavior.params['scope']),
    );
  }

  /// The triggers armed for [event] across every active rule.
  static List<BehaviorTrigger> forEvent(
      List<AgentBehavior> active, String event) {
    final triggers = <BehaviorTrigger>[];
    for (final behavior in active) {
      final trigger = fromBehavior(behavior);
      if (trigger != null && trigger.event == event) triggers.add(trigger);
    }
    return triggers;
  }

  /// Settings key holding when this trigger last fired, so the interval
  /// survives app restarts and background isolates.
  String get lastFiredKey => 'behavior_trigger_last_fired_$behaviorId';

  /// How much of the interval to forgive when a firing left work behind.
  ///
  /// Draining a backlog is one job continued, not a new one started, so it
  /// should not be paced as though it were: with a 30-minute interval, 57
  /// emails at 15 a batch would otherwise take an hour and a half. Credit
  /// is capped so a continuation still leaves a gap of at least a few
  /// minutes between model turns.
  int get continuationCreditMinutes {
    final credit = minIntervalMinutes - 5;
    return credit < 0 ? 0 : credit;
  }

  bool isDue(DateTime? lastFired, {DateTime? now}) {
    if (lastFired == null) return true;
    final at = now ?? DateTime.now();
    return at.difference(lastFired).inMinutes >= minIntervalMinutes;
  }

  /// The write scope a firing runs under: whatever the rule declared,
  /// narrowed to what a trigger may ever do. A rule cannot widen itself.
  Map<String, Object?> get writeScopeJson => {
        'allowed_effects': [
          'task.create',
          'task.update_status',
          'reminder.create_one_time',
          'email.mark_digested',
          // Closing out the queue it was given. `message.send` is not here
          // and must not be: a rule that fires on incoming messages and can
          // also answer them is an assistant holding conversations nobody
          // asked it to have.
          'message.mark_digested',
          if (allowRecurringTasks) 'task.create_recurring',
        ],
        'write_scope': {
          'task.create': {
            'max_per_run': maxRecordsPerFiring,
            'requires_source_item': true,
            'allow_recurring': allowRecurringTasks,
          },
        },
        'max_records_per_run': maxRecordsPerFiring,
      };

  static int _int(Object? value, int fallback, int min, int max) {
    final parsed = value is int ? value : int.tryParse('${value ?? ''}');
    if (parsed == null) return fallback;
    return parsed.clamp(min, max);
  }
}

/// What a trigger may act on: which domains, which senders, which topics to
/// leave alone.
///
/// Without this, "extract tasks from my mail" means *all* mail, including
/// every newsletter — and the user gets a task list they did not ask for
/// and cannot explain.
class TriggerScope {
  const TriggerScope({
    this.domains = const {},
    this.senders = const {},
    this.excludeTopics = const {},
  });

  final Set<String> domains;
  final Set<String> senders;
  final Set<String> excludeTopics;

  bool get isEmpty =>
      domains.isEmpty && senders.isEmpty && excludeTopics.isEmpty;

  /// Whether an item described by [text] (subject, sender, body preview) is
  /// in scope.
  bool admits({String? sender, String text = ''}) {
    final lower = text.toLowerCase();
    for (final excluded in excludeTopics) {
      if (lower.contains(excluded.toLowerCase())) return false;
    }
    if (senders.isEmpty) return true;
    if (sender == null) return false;
    final from = sender.toLowerCase();
    return senders.any((allowed) => from.contains(allowed.toLowerCase()));
  }

  static TriggerScope fromJson(Object? json) {
    if (json is! Map) return const TriggerScope();
    Set<String> list(String key) {
      final value = json[key];
      if (value is! List) return const {};
      return value.whereType<String>().map((s) => s.trim()).toSet();
    }

    return TriggerScope(
      domains: list('domains'),
      senders: list('senders'),
      excludeTopics: list('exclude_topics'),
    );
  }

  Map<String, Object?> toJson() => {
        if (domains.isNotEmpty) 'domains': domains.toList(),
        if (senders.isNotEmpty) 'senders': senders.toList(),
        if (excludeTopics.isNotEmpty) 'exclude_topics': excludeTopics.toList(),
      };
}
