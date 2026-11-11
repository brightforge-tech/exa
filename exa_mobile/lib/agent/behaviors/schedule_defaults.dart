import '../../data/models/agent_behavior.dart';
import '../../data/repositories/behavior_repository.dart';
import 'behavior_context.dart';

/// The user's `schedule_rule` behaviors, applied when an event is created
/// without an explicit duration or reminder lead time.
///
/// Parameters live in [AgentBehavior.params]:
///
/// ```json
/// {"default_lead_minutes": 15, "default_duration_minutes": 30}
/// ```
///
/// Only fills gaps: an explicit value from the caller (the agent, or the
/// Schedule screen's sheet) always wins over the rule.
class ScheduleDefaults {
  const ScheduleDefaults({this.leadMinutes, this.durationMinutes});

  static const ScheduleDefaults none = ScheduleDefaults();

  final int? leadMinutes;
  final int? durationMinutes;

  bool get isEmpty => leadMinutes == null && durationMinutes == null;

  static Future<ScheduleDefaults> load(BehaviorRepository behaviors) async {
    try {
      final context = await BehaviorContext.load(
        behaviors: behaviors,
        onlyTypes: const {'schedule_rule'},
      );
      return fromBehaviors(context.ofType('schedule_rule'));
    } catch (_) {
      return none;
    }
  }

  /// First rule that sets a value wins - the repository orders by priority,
  /// so that is the rule the user (or the agent) ranked highest.
  static ScheduleDefaults fromBehaviors(List<AgentBehavior> rules) {
    int? lead;
    int? duration;
    for (final rule in rules) {
      lead ??= _minutes(rule.params['default_lead_minutes']);
      duration ??= _minutes(rule.params['default_duration_minutes']);
    }
    return ScheduleDefaults(leadMinutes: lead, durationMinutes: duration);
  }

  static int? _minutes(Object? value) {
    final minutes = value is int ? value : int.tryParse('${value ?? ''}');
    if (minutes == null || minutes < 0 || minutes > 24 * 60) return null;
    return minutes;
  }
}
