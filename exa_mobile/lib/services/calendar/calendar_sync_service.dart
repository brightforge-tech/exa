import '../../data/models/schedule_item.dart';
import '../../data/models/task_item.dart';
import '../../data/repositories/schedule_repository.dart';
import '../../data/repositories/settings_repository.dart';
import '../../data/repositories/task_repository.dart';
import 'device_calendar_service.dart';

/// Mirrors app-created events and tasks onto the phone calendar.
///
/// The in-app item is always saved first and remains the source of truth;
/// the phone-calendar copy is a best-effort mirror addressed by the item's
/// `deviceEventId` ("calendarId:eventId"), so later edits and deletes reach
/// the same platform event and imports can skip our own mirrors.
///
/// The `syncXIfEnabled` methods are gated on the Settings toggles and never
/// throw - creating a task must not fail because the calendar is
/// unavailable. [pushEvent]/[pushTask] write unconditionally (explicit user
/// intent, e.g. the per-event checkbox) and do throw, so the UI can report
/// the failure.
class CalendarSyncService {
  CalendarSyncService({
    required this.deviceCalendar,
    required this.schedule,
    required this.tasks,
    required this.settings,
  });

  final DeviceCalendarService deviceCalendar;
  final ScheduleRepository schedule;
  final TaskRepository tasks;
  final SettingsRepository settings;

  /// Mirrored tasks appear as a short block at their due time.
  static const taskEventDuration = Duration(minutes: 30);

  Future<bool> eventSyncEnabled() => settings.isCalendarSyncEventsEnabled();

  Future<bool> taskSyncEnabled() => settings.isCalendarSyncTasksEnabled();

  /// Creates or updates [item]'s phone-calendar mirror and records its ref.
  Future<void> pushEvent(ScheduleItem item) async {
    final ref = await deviceCalendar.upsertEvent(
      eventRef: item.deviceEventId,
      title: item.title,
      startAt: item.startAt,
      endAt: item.endAt,
      location: item.location,
      description: item.description,
      reminderMinutes: item.leadTimeMinutes,
    );
    if (ref != item.deviceEventId) {
      await schedule.setDeviceEventId(item.id, ref);
    }
  }

  /// Creates or updates [task]'s phone-calendar mirror (a block at its due
  /// time) and records its ref. No-op for tasks without a due date.
  Future<void> pushTask(TaskItem task) async {
    final dueAt = task.dueAt;
    if (dueAt == null) return;
    final ref = await deviceCalendar.upsertEvent(
      eventRef: task.deviceEventId,
      title: task.title,
      startAt: dueAt,
      endAt: dueAt.add(taskEventDuration),
      description: task.description,
      reminderMinutes: 0,
    );
    if (ref != task.deviceEventId) {
      await tasks.setDeviceEventId(task.id, ref);
    }
  }

  /// Best-effort mirror of a created/updated event. Creates the mirror only
  /// when the Settings toggle is on, but always keeps an existing mirror in
  /// step (and removes it when the event is canceled). Device-imported
  /// events are already on the phone calendar and are never mirrored back.
  Future<void> syncEventIfEnabled(ScheduleItem item) async {
    if (item.source == 'device') return;
    if (item.status == 'Canceled') {
      await removeEventMirror(item);
      return;
    }
    if (item.deviceEventId == null && !await eventSyncEnabled()) return;
    try {
      await pushEvent(item);
    } catch (_) {
      // Mirror is best-effort; the in-app event is already saved.
    }
  }

  /// Best-effort mirror of a created/updated task. The mirror exists only
  /// while the task is open and has a due date; completing, canceling, or
  /// un-dating the task removes it from the phone calendar.
  Future<void> syncTaskIfEnabled(TaskItem task) async {
    final wanted = task.isOpen && task.dueAt != null;
    if (task.deviceEventId != null) {
      if (!wanted) {
        await removeTaskMirror(task);
        return;
      }
    } else {
      if (!wanted || !await taskSyncEnabled()) return;
    }
    try {
      await pushTask(task);
    } catch (_) {
      // Mirror is best-effort; the in-app task is already saved.
    }
  }

  /// Removes a deleted event's phone-calendar mirror, if it has one.
  Future<void> removeEventMirror(ScheduleItem item) async {
    final ref = item.deviceEventId;
    if (ref == null) return;
    try {
      await deviceCalendar.deleteEventByRef(ref);
      await schedule.setDeviceEventId(item.id, null);
    } catch (_) {
      // Best-effort: the mirror may already be gone.
    }
  }

  /// Removes a task's phone-calendar mirror, if it has one.
  Future<void> removeTaskMirror(TaskItem task) async {
    final ref = task.deviceEventId;
    if (ref == null) return;
    try {
      await deviceCalendar.deleteEventByRef(ref);
      await tasks.setDeviceEventId(task.id, null);
    } catch (_) {
      // Best-effort: the mirror may already be gone.
    }
  }

  /// Mirrors any open, upcoming items that should be on the phone calendar
  /// but aren't yet: the backfill when a sync toggle is switched on, and the
  /// self-heal for items that appeared without going through a synced path
  /// (e.g. the next occurrence a recurring task spawns on completion).
  ///
  /// Silently does nothing when calendar permission has not been granted, so
  /// it is safe to run at app startup without prompting. Set [interactive]
  /// to prompt for permission (the toggle-enable path).
  Future<void> syncPending({bool interactive = false}) async {
    if (!interactive && !await deviceCalendar.hasPermission()) return;
    final now = DateTime.now();
    if (await eventSyncEnabled()) {
      final upcoming =
          await schedule.listBetween(now, now.add(const Duration(days: 365)));
      for (final item in upcoming) {
        if (item.source == 'device' || item.deviceEventId != null) continue;
        if (item.status == 'Canceled') continue;
        try {
          await pushEvent(item);
        } catch (_) {
          return; // Permission denied or calendar unavailable: stop quietly.
        }
      }
    }
    if (await taskSyncEnabled()) {
      final open = await tasks.list(openOnly: true);
      for (final task in open) {
        if (task.deviceEventId != null) continue;
        if (task.dueAt == null || task.dueAt!.isBefore(now)) continue;
        try {
          await pushTask(task);
        } catch (_) {
          return;
        }
      }
    }
  }
}
