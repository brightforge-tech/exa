import 'package:exa_mobile/data/database/app_database.dart';
import 'package:exa_mobile/data/models/day_plan_entry.dart';
import 'package:exa_mobile/data/repositories/day_plan_repository.dart';
import 'package:exa_mobile/data/repositories/reminder_repository.dart';
import 'package:exa_mobile/data/repositories/task_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late AppDatabase database;
  late DayPlanRepository plans;
  late TaskRepository tasks;
  late ReminderRepository reminders;

  final monday = DateTime(2026, 8, 10);
  final tuesday = DateTime(2026, 8, 11);

  setUp(() async {
    database = AppDatabase();
    await database.open(overridePath: inMemoryDatabasePath);
    plans = DayPlanRepository(database);
    tasks = TaskRepository(database);
    reminders = ReminderRepository(database);
  });

  tearDown(() => database.close());

  group('planning a day', () {
    test('a planned task keeps its own due date', () async {
      // The whole point of the board: when you mean to do it is not when it
      // is due, and planning must never quietly move a deadline.
      final task = await tasks.create(
          title: 'File the tax return', dueAt: DateTime(2026, 8, 28, 17));
      await plans.plan(
        day: monday,
        title: task.title,
        startMinute: 9 * 60,
        sourceType: DayPlanEntry.sourceTask,
        sourceId: task.id,
        durationMinutes: 60,
      );

      final entries = await plans.listForDay(monday);
      expect(entries.single.startLabel, '09:00');
      expect(entries.single.endLabel, '10:00');
      expect((await tasks.getById(task.id))!.dueAt, DateTime(2026, 8, 28, 17));
    });

    test('planning the same task twice on a day moves it', () async {
      final task = await tasks.create(title: 'Write the brief');
      final first = await plans.plan(
        day: monday,
        title: task.title,
        startMinute: 9 * 60,
        sourceType: DayPlanEntry.sourceTask,
        sourceId: task.id,
      );
      final second = await plans.plan(
        day: monday,
        title: task.title,
        startMinute: 14 * 60,
        sourceType: DayPlanEntry.sourceTask,
        sourceId: task.id,
      );

      // Same card, new time - not a second copy of the same work.
      expect(second.id, first.id);
      final entries = await plans.listForDay(monday);
      expect(entries, hasLength(1));
      expect(entries.single.startLabel, '14:00');
    });

    test('the same task can be planned on two different days', () async {
      final task = await tasks.create(title: 'Revise chapter 2');
      await plans.plan(
        day: monday,
        title: task.title,
        startMinute: 9 * 60,
        sourceType: DayPlanEntry.sourceTask,
        sourceId: task.id,
      );
      await plans.plan(
        day: tuesday,
        title: task.title,
        startMinute: 9 * 60,
        sourceType: DayPlanEntry.sourceTask,
        sourceId: task.id,
      );
      expect(await plans.listForDay(monday), hasLength(1));
      expect(await plans.listForDay(tuesday), hasLength(1));
    });

    test('ad-hoc blocks repeat freely - two coffee breaks are fine', () async {
      await plans.plan(day: monday, title: 'Break', startMinute: 11 * 60);
      await plans.plan(day: monday, title: 'Break', startMinute: 15 * 60);
      expect(await plans.listForDay(monday), hasLength(2));
    });

    test('listForDay reads only that day, in time order', () async {
      await plans.plan(day: monday, title: 'Late', startMinute: 16 * 60);
      await plans.plan(day: monday, title: 'Early', startMinute: 8 * 60);
      await plans.plan(day: tuesday, title: 'Tomorrow', startMinute: 8 * 60);

      final entries = await plans.listForDay(monday);
      expect(entries.map((e) => e.title), ['Early', 'Late']);
    });
  });

  group('board views', () {
    test('a card takes its done state from the task, not a stored copy',
        () async {
      final task = await tasks.create(title: 'Book the flights');
      await plans.plan(
        day: monday,
        title: task.title,
        startMinute: 10 * 60,
        sourceType: DayPlanEntry.sourceTask,
        sourceId: task.id,
      );
      expect((await plans.viewsForDay(monday)).single.done, isFalse);

      // Completed on the Tasks screen, by a tool, by a job - the board has to
      // agree without anything syncing it.
      await tasks.update(task.id, status: 'Completed');
      expect((await plans.viewsForDay(monday)).single.done, isTrue);
    });

    test('a card follows the task title after a rename', () async {
      final task = await tasks.create(title: 'Old name');
      await plans.plan(
        day: monday,
        title: task.title,
        startMinute: 10 * 60,
        sourceType: DayPlanEntry.sourceTask,
        sourceId: task.id,
      );
      await tasks.update(task.id, title: 'New name');
      expect((await plans.viewsForDay(monday)).single.title, 'New name');
    });

    test('a card whose task was deleted disappears and is cleaned up',
        () async {
      final task = await tasks.create(title: 'Cancelled work');
      await plans.plan(
        day: monday,
        title: task.title,
        startMinute: 10 * 60,
        sourceType: DayPlanEntry.sourceTask,
        sourceId: task.id,
      );
      await tasks.delete(task.id);

      expect(await plans.viewsForDay(monday), isEmpty);
      // ...and the orphan row is gone, not just hidden.
      expect(await plans.listForDay(monday), isEmpty);
    });

    test('a reminder card is done once the reminder is', () async {
      final reminder = await reminders.create(
          title: 'Call the vet', remindAt: DateTime(2026, 8, 10, 9));
      await plans.plan(
        day: monday,
        title: reminder.title,
        startMinute: 9 * 60,
        sourceType: DayPlanEntry.sourceReminder,
        sourceId: reminder.id,
      );
      expect((await plans.viewsForDay(monday)).single.done, isFalse);
      await reminders.complete(reminder.id);
      expect((await plans.viewsForDay(monday)).single.done, isTrue);
    });

    test('an ad-hoc block keeps its own done state', () async {
      final entry =
          await plans.plan(day: monday, title: 'Deep work', startMinute: 600);
      await plans.setStatus(entry.id, DayPlanEntry.statusDone);
      expect((await plans.viewsForDay(monday)).single.done, isTrue);
    });
  });

  group('moving and clearing', () {
    test('move changes the time without touching the duration', () async {
      final entry = await plans.plan(
          day: monday,
          title: 'Review',
          startMinute: 9 * 60,
          durationMinutes: 45);
      final moved = await plans.move(entry.id, startMinute: 13 * 60);
      expect(moved!.startLabel, '13:00');
      expect(moved.durationMinutes, 45);
    });

    test('clearDay empties one day and leaves the next alone', () async {
      await plans.plan(day: monday, title: 'A', startMinute: 9 * 60);
      await plans.plan(day: tuesday, title: 'B', startMinute: 9 * 60);
      expect(await plans.clearDay(monday), 1);
      expect(await plans.listForDay(monday), isEmpty);
      expect(await plans.listForDay(tuesday), hasLength(1));
    });

    test('plannedSourceIds is what keeps the backlog from repeating itself',
        () async {
      final task = await tasks.create(title: 'Already planned');
      await plans.plan(
        day: monday,
        title: task.title,
        startMinute: 9 * 60,
        sourceType: DayPlanEntry.sourceTask,
        sourceId: task.id,
      );
      await plans.plan(day: monday, title: 'A block', startMinute: 11 * 60);

      // Blocks have no source, so they never filter anything out.
      expect(await plans.plannedSourceIds(monday), {task.id});
    });
  });

  group('firstFreeMinute', () {
    DayPlanEntry at(int startMinute, int duration) => DayPlanEntry(
          id: 's$startMinute',
          planDate: '2026-08-10',
          sourceType: DayPlanEntry.sourceNote,
          title: 'busy',
          startMinute: startMinute,
          durationMinutes: duration,
          createdAt: DateTime(2026, 8, 10),
          updatedAt: DateTime(2026, 8, 10),
        );

    test('an empty day starts at the top of the board', () {
      expect(DayPlanRepository.firstFreeMinute(const []),
          DayPlanRepository.boardStartMinute);
    });

    test('skips past what is already there, landing on the grid', () {
      // 06:00-07:10 taken -> the next usable slot is 07:30, not 07:10:
      // off-grid cards cannot be dragged anywhere afterwards.
      final free = DayPlanRepository.firstFreeMinute([at(6 * 60, 70)]);
      expect(free, 7 * 60 + 30);
    });

    test('finds a gap between two blocks when the work fits', () {
      final free = DayPlanRepository.firstFreeMinute(
        [at(6 * 60, 60), at(8 * 60, 60)],
        durationMinutes: 60,
      );
      expect(free, 7 * 60);
    });

    test('skips a gap that is too short for the duration asked for', () {
      // 07:00-08:00 is free but 90 minutes does not fit, so the answer is
      // after the second block rather than a card that overlaps it.
      final free = DayPlanRepository.firstFreeMinute(
        [at(6 * 60, 60), at(8 * 60, 60)],
        durationMinutes: 90,
      );
      expect(free, 9 * 60);
    });

    test('a full day returns null rather than stacking work', () {
      final full = [
        for (var m = DayPlanRepository.boardStartMinute;
            m < DayPlanRepository.boardEndMinute;
            m += 60)
          at(m, 60),
      ];
      expect(DayPlanRepository.firstFreeMinute(full), isNull);
    });

    test('searching from a later time never goes backwards', () {
      final free =
          DayPlanRepository.firstFreeMinute(const [], after: 14 * 60 + 5);
      expect(free, 14 * 60 + 30);
    });
  });

  group('time parsing', () {
    test('reads HH:mm, and the clock time out of an ISO datetime', () {
      expect(DayPlanEntry.parseTimeOfDay('09:30'), 9 * 60 + 30);
      expect(DayPlanEntry.parseTimeOfDay('9:05'), 9 * 60 + 5);
      // A model asked for a time often sends a whole datetime.
      expect(DayPlanEntry.parseTimeOfDay('2026-08-10T14:15:00'),
          14 * 60 + 15);
    });

    test('refuses nonsense instead of guessing', () {
      expect(DayPlanEntry.parseTimeOfDay('tomorrow'), isNull);
      expect(DayPlanEntry.parseTimeOfDay('25:00'), isNull);
      expect(DayPlanEntry.parseTimeOfDay(''), isNull);
      expect(DayPlanEntry.parseTimeOfDay(null), isNull);
    });
  });
}
