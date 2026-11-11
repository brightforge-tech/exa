import '../../data/models/day_plan_entry.dart';
import '../../data/models/reminder.dart';
import '../../data/repositories/reminder_repository.dart';
import '../notifications/notification_service.dart';

/// Keeps a reminder's alarm on the slot its card occupies.
///
/// Tasks and reminders behave differently on the planning board, and the
/// difference is the point:
///
///  * A task has a *deadline*. Planning it decides when you mean to do it,
///    which is a different fact, so the due date is never touched.
///  * A reminder has no deadline - the time it fires IS the whole reminder.
///    Dragging it to 14:00 and having it still go off at 08:00 would leave
///    the board saying one thing and the phone doing another.
///
/// So planning or moving a reminder reschedules it, notification included.
/// Lives here rather than in the board controller because the agent's
/// `plan_day_item` has to do exactly the same thing - two copies of this rule
/// would drift, and the drift would be silent.
class DayPlanSync {
  const DayPlanSync({required this.reminders, required this.notifications});

  final ReminderRepository reminders;
  final NotificationService notifications;

  /// Moves the reminder behind [entry] to the day and time of its card.
  /// Returns the updated reminder, or null when the entry is not a reminder
  /// (a task or an ad-hoc block, where there is nothing to reschedule).
  ///
  /// A repeating reminder keeps repeating - the rule is untouched and only
  /// the time it fires moves, which is what dragging a weekly reminder to
  /// Thursday morning is asking for.
  Future<Reminder?> alignReminder(DayPlanEntry entry) async {
    if (entry.sourceType != DayPlanEntry.sourceReminder) return null;
    final id = entry.sourceId;
    if (id == null) return null;

    final existing = await reminders.getById(id);
    if (existing == null) return null;

    final target = entry.startAt;
    if (_sameMinute(existing.remindAt, target)) return existing;

    final updated = await reminders.update(id, remindAt: target);
    if (updated == null) return null;
    // Cancel before scheduling: the pending alarm is keyed on the old time
    // and would otherwise still fire there.
    await notifications.cancelReminder(updated);
    if (updated.status == 'Active') {
      await notifications.scheduleReminder(updated);
    }
    return updated;
  }

  static bool _sameMinute(DateTime a, DateTime b) =>
      a.year == b.year &&
      a.month == b.month &&
      a.day == b.day &&
      a.hour == b.hour &&
      a.minute == b.minute;
}
