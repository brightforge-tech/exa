import '../../data/models/agent_behavior.dart';
import '../../data/repositories/behavior_repository.dart';
import 'behavior_context.dart';

/// The user's `notification_rule` behaviors, enforced in code rather than
/// read as prompt text.
///
/// A rule carries its machine-readable settings in [AgentBehavior.params]:
///
/// ```json
/// {"quiet_hours": {"from": "22:00", "to": "07:00"}}
/// ```
///
/// Quiet hours are the only rule the app can honour without asking a model,
/// so they are the only thing parsed here - anything else in the rule text
/// still reaches the agent through [BehaviorContext].
///
/// By default quiet hours only hold back *informational* notifications: job
/// briefings and status reports, which already land in chat and lose nothing
/// by waiting. Reminders and event alerts are times the user asked for
/// explicitly, and a specific instruction outranks a general preference -
/// deferring "your meeting starts now" to 07:00 would make it useless. A
/// rule can opt those in with `"include_timed_alerts": true`, which defers
/// one-off alerts; recurring reminders are still never moved, since shifting
/// them would silently rewrite the recurrence the user set.
class NotificationPolicy {
  const NotificationPolicy({
    this.quietFrom,
    this.quietTo,
    this.includeTimedAlerts = false,
  });

  /// No rules: every notification goes out as scheduled.
  static const NotificationPolicy none = NotificationPolicy();

  /// Minutes from midnight, or null when no quiet window is configured.
  final int? quietFrom;
  final int? quietTo;

  /// Whether quiet hours also defer one-off reminders and event alerts.
  final bool includeTimedAlerts;

  bool get hasQuietHours => quietFrom != null && quietTo != null;

  static Future<NotificationPolicy> load(BehaviorRepository behaviors) async {
    try {
      final context = await BehaviorContext.load(
        behaviors: behaviors,
        surface: BehaviorSurface.notification,
        onlyTypes: const {'notification_rule'},
      );
      return fromBehaviors(context.ofType('notification_rule'));
    } catch (_) {
      return none;
    }
  }

  /// Notification classes, which quiet hours treat differently.
  ///
  /// `content` is the user's own material (briefings, job results) and is
  /// what quiet hours are for. `timedAlert` is a reminder or event alert
  /// they explicitly scheduled. `systemHealth` is the app reporting that it
  /// could not do its job - suppressing that would turn a quiet night into
  /// an invisible outage, so it always goes out.
  static const channelContent = 'content';
  static const channelTimedAlert = 'timed_alert';
  static const channelSystemHealth = 'system_health';

  /// Whether a notification of [channel] must be held back at [when].
  bool shouldSuppress(String channel, DateTime when) {
    if (channel == channelSystemHealth) return false;
    if (!isQuiet(when)) return false;
    if (channel == channelTimedAlert) {
      // Timed alerts are deferred (see nextAudibleTime), never dropped.
      return false;
    }
    return true;
  }

  /// The narrowest window wins when several rules configure quiet hours -
  /// combining them arbitrarily could silence more than any single rule
  /// asked for, so the first one that parses is used.
  static NotificationPolicy fromBehaviors(List<AgentBehavior> rules) {
    for (final rule in rules) {
      final quiet = rule.params['quiet_hours'];
      if (quiet is! Map) continue;
      final from = _minutes(quiet['from']);
      final to = _minutes(quiet['to']);
      if (from != null && to != null && from != to) {
        return NotificationPolicy(
          quietFrom: from,
          quietTo: to,
          includeTimedAlerts: quiet['include_timed_alerts'] == true,
        );
      }
    }
    return none;
  }

  /// Whether [when] falls inside the quiet window. Windows that wrap past
  /// midnight (22:00 -> 07:00) are the normal case, so both orderings are
  /// handled.
  bool isQuiet(DateTime when) {
    if (!hasQuietHours) return false;
    final minute = when.hour * 60 + when.minute;
    final from = quietFrom!;
    final to = quietTo!;
    return from < to
        ? minute >= from && minute < to
        : minute >= from || minute < to;
  }

  /// The first moment at or after [when] that is outside the quiet window.
  /// Used for alerts that must still arrive (reminders, event starts) but
  /// can wait until morning.
  DateTime nextAudibleTime(DateTime when) {
    if (!isQuiet(when)) return when;
    final to = quietTo!;
    final sameDay =
        DateTime(when.year, when.month, when.day, to ~/ 60, to % 60);
    return sameDay.isAfter(when)
        ? sameDay
        : sameDay.add(const Duration(days: 1));
  }

  /// "HH:mm" -> minutes from midnight; null when unparseable.
  static int? _minutes(Object? value) {
    if (value is int) return value >= 0 && value < 1440 ? value : null;
    if (value is! String) return null;
    final parts = value.split(':');
    if (parts.isEmpty) return null;
    final hour = int.tryParse(parts.first);
    final minute = parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0;
    if (hour == null || hour < 0 || hour > 23) return null;
    if (minute < 0 || minute > 59) return null;
    return hour * 60 + minute;
  }
}
