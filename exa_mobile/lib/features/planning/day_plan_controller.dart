import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/day_plan_entry.dart';
import '../../data/models/reminder.dart';
import '../../data/repositories/day_plan_repository.dart';
import '../../services/planning/day_plan_sync.dart';
import '../../data/models/schedule_item.dart';
import '../../data/models/task_item.dart';
import '../../shared/providers.dart';

/// Which day the board is showing. Defaults to today; the arrows move it.
final planDayProvider = StateProvider<DateTime>((ref) {
  final now = DateTime.now();
  return DateTime(now.year, now.month, now.day);
});

/// Something that could be planned but is not yet: an open task, or any
/// active reminder.
///
/// Reminders are offered whatever day they are currently set for, not only
/// ones already landing on the day being planned - pulling next Tuesday's
/// reminder into this afternoon is the normal reason to open the board, and
/// doing that moves when it fires (see [DayPlanSync]).
class BacklogItem {
  const BacklogItem.task(TaskItem this.task)
      : reminder = null,
        firesAt = null;
  const BacklogItem.reminder(Reminder this.reminder, this.firesAt)
      : task = null;

  final TaskItem? task;
  final Reminder? reminder;

  /// When this reminder goes off on the day being planned, or null when it
  /// is set for some other day. Non-null is what makes it the natural slot
  /// to drop the card into.
  final DateTime? firesAt;

  bool get isReminder => reminder != null;

  /// Whether it already belongs to the day on screen.
  bool get isToday => firesAt != null;

  String get id => task?.id ?? reminder!.id;
  String get title => task?.title ?? reminder!.title;

  String get sourceType =>
      isReminder ? DayPlanEntry.sourceReminder : DayPlanEntry.sourceTask;

  DateTime? get dueAt => task?.dueAt;
  String? get priority => task?.priority;

  /// The time this item is anchored to, for ordering the strip: when a
  /// reminder fires, or when a task is due.
  DateTime? get anchorAt => firesAt ?? dueAt ?? reminder?.remindAt;
}

/// Everything one screenful of the board needs, loaded together so the
/// timeline and the backlog can never disagree about what is planned.
class DayPlanBoard {
  const DayPlanBoard({
    required this.day,
    required this.planned,
    required this.backlog,
    required this.events,
  });

  final DateTime day;
  final List<DayPlanItem> planned;
  final List<BacklogItem> backlog;

  /// The day's real calendar events, drawn but not draggable: they are
  /// commitments, and their job here is to stop the user planning over one.
  final List<ScheduleItem> events;

  int get plannedMinutes =>
      planned.fold(0, (sum, item) => sum + item.entry.durationMinutes);

  int get doneCount => planned.where((item) => item.done).length;
}

final dayPlanBoardProvider =
    FutureProvider.autoDispose<DayPlanBoard>((ref) async {
  final day = ref.watch(planDayProvider);
  final dayStart = DateTime(day.year, day.month, day.day);
  final dayEnd = dayStart.add(const Duration(days: 1));

  final planRepository = ref.watch(dayPlanRepositoryProvider);
  final planned = await planRepository.viewsForDay(day);
  final plannedIds = await planRepository.plannedSourceIds(day);

  final tasks = await ref.watch(taskRepositoryProvider).list(openOnly: true);
  // Every active reminder, not just the ones already on this day:
  // rescheduling one onto today is the point of dragging it here.
  // [Reminder.occurrenceOn] says whether it happens to land here already,
  // which is what makes it a "today" card rather than a "moving it" card.
  final activeReminders =
      await ref.watch(reminderRepositoryProvider).listByStatus('Active');
  final events =
      await ref.watch(scheduleRepositoryProvider).listBetween(dayStart, dayEnd);

  final backlog = <BacklogItem>[
    for (final task in tasks)
      if (!plannedIds.contains(task.id)) BacklogItem.task(task),
    for (final reminder in activeReminders)
      if (!plannedIds.contains(reminder.id))
        BacklogItem.reminder(reminder, reminder.occurrenceOn(dayStart)),
  ];
  // What is anchored soonest first, undated last: the top of the strip
  // should be what the user has least freedom about.
  backlog.sort((a, b) {
    final aAt = a.anchorAt;
    final bAt = b.anchorAt;
    if (aAt != null && bAt != null) return aAt.compareTo(bAt);
    if (aAt != null) return -1;
    if (bAt != null) return 1;
    return a.title.toLowerCase().compareTo(b.title.toLowerCase());
  });

  return DayPlanBoard(
    day: dayStart,
    planned: planned,
    backlog: backlog,
    events: events,
  );
});

/// Actions the board performs. Thin on purpose: each one writes through a
/// repository and invalidates the board, so what is on screen is always what
/// is in the database rather than an optimistic guess.
class DayPlanController {
  DayPlanController(this._ref);

  final Ref _ref;

  DateTime get _day => _ref.read(planDayProvider);

  DayPlanSync get _sync => DayPlanSync(
        reminders: _ref.read(reminderRepositoryProvider),
        notifications: _ref.read(notificationServiceProvider),
      );

  Future<DayPlanEntry> planBacklogItem(
    BacklogItem item, {
    required int startMinute,
    int? durationMinutes,
  }) async {
    final entry = await _ref.read(dayPlanRepositoryProvider).plan(
          day: _day,
          title: item.title,
          startMinute: startMinute,
          sourceType: item.sourceType,
          sourceId: item.id,
          durationMinutes:
              durationMinutes ?? DayPlanEntry.defaultDurationMinutes,
        );
    // A reminder's alarm follows its card; a task's deadline never does.
    await _sync.alignReminder(entry);
    _reload();
    return entry;
  }

  /// Places [item] wherever it next fits, for the tap-instead-of-drag path.
  ///
  /// A reminder is tried at its own hour first, even when it is currently set
  /// for another day: an 08:00 reminder pulled onto today most likely still
  /// wants 08:00, and landing there means the alarm barely moves.
  Future<DayPlanEntry?> planAtNextFreeSlot(BacklogItem item) async {
    final repository = _ref.read(dayPlanRepositoryProvider);
    final existing = await repository.listForDay(_day);
    final anchor = item.firesAt ?? item.reminder?.remindAt;
    final preferred = anchor != null
        ? anchor.hour * 60 + anchor.minute
        : _defaultSearchStart();
    final minute = DayPlanRepository.firstFreeMinute(existing,
            after: preferred) ??
        DayPlanRepository.firstFreeMinute(existing,
            after: DayPlanRepository.boardStartMinute);
    if (minute == null) return null;
    return planBacklogItem(item, startMinute: minute);
  }

  Future<DayPlanEntry?> moveEntry(String id,
      {int? startMinute, int? durationMinutes}) async {
    final entry = await _ref.read(dayPlanRepositoryProvider).move(id,
        startMinute: startMinute, durationMinutes: durationMinutes);
    if (entry != null) await _sync.alignReminder(entry);
    _reload();
    return entry;
  }

  Future<DayPlanEntry> addBlock({
    required String title,
    required int startMinute,
    int durationMinutes = DayPlanEntry.defaultDurationMinutes,
  }) async {
    final entry = await _ref.read(dayPlanRepositoryProvider).plan(
          day: _day,
          title: title,
          startMinute: startMinute,
          durationMinutes: durationMinutes,
        );
    _reload();
    return entry;
  }

  Future<void> unplan(String id) async {
    await _ref.read(dayPlanRepositoryProvider).unplan(id);
    _reload();
  }

  Future<void> clearDay() async {
    await _ref.read(dayPlanRepositoryProvider).clearDay(_day);
    _reload();
  }

  /// Ticking a card off completes the thing itself, not just the card.
  ///
  /// The board shows a task's real status (see [DayPlanItem.done]), so
  /// marking only the entry would produce a card that claims to be done next
  /// to a task that is still open - two answers to one question.
  Future<void> setDone(DayPlanItem item, bool done) async {
    switch (item.entry.sourceType) {
      case DayPlanEntry.sourceTask:
        await _ref.read(taskRepositoryProvider).update(
              item.entry.sourceId!,
              status: done ? 'Completed' : 'Pending',
            );
      case DayPlanEntry.sourceReminder:
        final reminders = _ref.read(reminderRepositoryProvider);
        if (done) {
          await reminders.complete(item.entry.sourceId!);
        } else {
          await reminders.update(item.entry.sourceId!, status: 'Active');
        }
      default:
        await _ref.read(dayPlanRepositoryProvider).setStatus(
              item.entry.id,
              done ? DayPlanEntry.statusDone : DayPlanEntry.statusPlanned,
            );
    }
    _reload();
  }

  Future<void> setSkipped(DayPlanItem item, bool skipped) async {
    await _ref.read(dayPlanRepositoryProvider).setStatus(
          item.entry.id,
          skipped ? DayPlanEntry.statusSkipped : DayPlanEntry.statusPlanned,
        );
    _reload();
  }

  /// Where auto-placement starts looking: the next slot from now when
  /// planning today, the top of the board on any other day.
  int _defaultSearchStart() {
    final now = DateTime.now();
    final day = _day;
    final isToday =
        now.year == day.year && now.month == day.month && now.day == day.day;
    if (!isToday) return DayPlanRepository.boardStartMinute;
    final minute = now.hour * 60 + now.minute;
    return minute < DayPlanRepository.boardStartMinute
        ? DayPlanRepository.boardStartMinute
        : minute;
  }

  void _reload() => _ref.invalidate(dayPlanBoardProvider);
}

final dayPlanControllerProvider =
    Provider<DayPlanController>((ref) => DayPlanController(ref));
