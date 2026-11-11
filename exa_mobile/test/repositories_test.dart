import 'package:flutter_test/flutter_test.dart';
import 'package:exa_mobile/data/database/app_database.dart';
import 'package:exa_mobile/data/models/reminder.dart';
import 'package:exa_mobile/data/repositories/behavior_repository.dart';
import 'package:exa_mobile/data/repositories/reminder_repository.dart';
import 'package:exa_mobile/data/repositories/schedule_repository.dart';
import 'package:exa_mobile/data/repositories/task_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late AppDatabase database;

  setUp(() async {
    database = AppDatabase();
    await database.open(overridePath: inMemoryDatabasePath);
  });

  tearDown(() => database.close());

  group('TaskRepository', () {
    test('creates and lists a task', () async {
      final repo = TaskRepository(database);
      final task = await repo.create(title: 'Buy milk');
      expect(task.status, 'Pending');

      final all = await repo.list();
      expect(all, hasLength(1));
      expect(all.first.title, 'Buy milk');
    });

    test('completes a task and excludes it from open list', () async {
      final repo = TaskRepository(database);
      final task = await repo.create(title: 'Do thing');
      await repo.complete(task.id);

      final open = await repo.list(openOnly: true);
      expect(open, isEmpty);

      final completed = await repo.list(status: 'Completed');
      expect(completed, hasLength(1));
      expect(completed.first.completedAt, isNotNull);
    });

    test('completing twice does not move the completion time', () async {
      final repo = TaskRepository(database);
      final task = await repo.create(title: 'Do thing');
      await repo.complete(task.id);
      const earlier = '2026-09-01T09:30:00.000';
      await database.db.update('tasks', {'completed_at': earlier},
          where: 'id = ?', whereArgs: [task.id]);

      await repo.complete(task.id);
      await repo.update(task.id, title: 'Did thing');

      final after = (await repo.list(status: 'Completed')).single;
      expect(after.title, 'Did thing');
      expect(after.completedAt, DateTime.parse(earlier));
    });

    test('lists what was completed since a moment, newest first', () async {
      final repo = TaskRepository(database);
      final first = await repo.create(title: 'First');
      final second = await repo.create(title: 'Second');
      final older = await repo.create(title: 'Older');
      await repo.create(title: 'Open');
      for (final task in [first, second, older]) {
        await repo.complete(task.id);
      }
      Future<void> stamp(String id, DateTime at) => database.db.update(
          'tasks', {'completed_at': at.toIso8601String()},
          where: 'id = ?', whereArgs: [id]);
      await stamp(first.id, DateTime(2026, 9, 27, 9));
      await stamp(second.id, DateTime(2026, 9, 27, 15));
      await stamp(older.id, DateTime(2026, 9, 26, 23, 59));

      final done = await repo.list(completedSince: DateTime(2026, 9, 27));
      expect([for (final task in done) task.title], ['Second', 'First']);
    });

    test('lists overdue tasks only', () async {
      final repo = TaskRepository(database);
      await repo.create(
          title: 'Late',
          dueAt: DateTime.now().subtract(const Duration(days: 1)));
      await repo.create(
          title: 'Future',
          dueAt: DateTime.now().add(const Duration(days: 1)));

      final overdue = await repo.listOverdue();
      expect(overdue, hasLength(1));
      expect(overdue.first.title, 'Late');
    });

    test('deletes a task', () async {
      final repo = TaskRepository(database);
      final task = await repo.create(title: 'Temp');
      expect(await repo.delete(task.id), isTrue);
      expect(await repo.list(), isEmpty);
    });
  });

  group('ReminderRepository', () {
    test('creates a reminder with a stable notification id', () async {
      final repo = ReminderRepository(database);
      final remindAt = DateTime.now().add(const Duration(hours: 2));
      final reminder =
          await repo.create(title: 'Call John', remindAt: remindAt);

      expect(reminder.notificationId,
          ReminderRepository.stableNotificationId(reminder.id));
      expect(reminder.status, 'Active');

      // Persisted across restart: reload from DB.
      final fromDb = await repo.getById(reminder.id);
      expect(fromDb, isNotNull);
      expect(fromDb!.remindAt.toIso8601String(),
          remindAt.toIso8601String());
    });

    test('cancels a reminder', () async {
      final repo = ReminderRepository(database);
      final reminder = await repo.create(
          title: 'X', remindAt: DateTime.now().add(const Duration(days: 1)));
      await repo.cancel(reminder.id);
      expect(await repo.listByStatus('Active'), isEmpty);
      expect(await repo.listByStatus('Canceled'), hasLength(1));
    });

    test('editing a reminder can change then clear recurrence', () async {
      final repo = ReminderRepository(database);
      final r = await repo.create(
          title: 'Gym',
          remindAt: DateTime.now().add(const Duration(days: 1)),
          recurrenceRule: 'weekly');

      var updated = await repo.update(r.id, recurrenceRule: 'monthly');
      expect(updated!.recurrenceRule, 'monthly');

      updated = await repo.update(r.id, clearRecurrence: true);
      expect(updated!.recurrenceRule, isNull);
      expect((await repo.getById(r.id))!.recurrenceRule, isNull);
    });

    test('weekly reminder occurs only on its weekday', () async {
      final repo = ReminderRepository(database);
      // Anchor on a Monday at 08:00.
      final monday = _nextWeekday(DateTime.monday, hour: 8);
      final reminder = await repo.create(
          title: 'Standup', remindAt: monday, recurrenceRule: 'weekly');

      expect(reminder.occurrenceOn(monday), isNotNull);
      expect(reminder.occurrenceOn(monday)!.hour, 8);
      // The next day (Tuesday) is not a match.
      expect(reminder.occurrenceOn(monday.add(const Duration(days: 1))),
          isNull);
      // Next Monday is a match again.
      expect(reminder.occurrenceOn(monday.add(const Duration(days: 7))),
          isNotNull);
    });

    test('occurrencesBetween expands recurrence and sorts by time',
        () async {
      final repo = ReminderRepository(database);
      final monday = _nextWeekday(DateTime.monday, hour: 9);
      await repo.create(
          title: 'Weekly', remindAt: monday, recurrenceRule: 'weekly');
      // A one-time reminder two days after the Monday.
      final oneOff = monday.add(const Duration(days: 2, hours: -1));
      await repo.create(title: 'One off', remindAt: oneOff);

      // Window: the Monday through 8 days later -> two weekly hits + one-off.
      final hits = await repo.occurrencesBetween(
          monday.subtract(const Duration(minutes: 1)),
          monday.add(const Duration(days: 8)));
      expect(hits.map((h) => h.key.title),
          containsAll(['Weekly', 'One off']));
      // Two weekly occurrences land in the 8-day window.
      expect(hits.where((h) => h.key.title == 'Weekly').length, 2);
      // Sorted ascending by occurrence time.
      for (var i = 1; i < hits.length; i++) {
        expect(hits[i].value.isBefore(hits[i - 1].value), isFalse);
      }
    });
  });

  group('Reminder.occurrenceOn (monthly)', () {
    Reminder monthly(DateTime remindAt) => Reminder(
          id: 'x',
          title: 'Rent',
          remindAt: remindAt,
          recurrenceRule: 'monthly',
          createdAt: remindAt,
          updatedAt: remindAt,
        );

    test('fires on the same day-of-month at the same time', () {
      final r = monthly(DateTime(2026, 1, 15, 9));
      final hit = r.occurrenceOn(DateTime(2026, 3, 15));
      expect(hit, isNotNull);
      expect(hit!.hour, 9);
      expect(r.occurrenceOn(DateTime(2026, 3, 14)), isNull);
    });

    test('clamps the 31st to the last day of shorter months', () {
      final r = monthly(DateTime(2026, 1, 31, 8));
      // Feb 2026 has 28 days -> fires Feb 28 (clamped), not the 27th.
      expect(r.occurrenceOn(DateTime(2026, 2, 28)), isNotNull);
      expect(r.occurrenceOn(DateTime(2026, 2, 27)), isNull);
      // March has 31 days -> fires on the 31st.
      expect(r.occurrenceOn(DateTime(2026, 3, 31)), isNotNull);
    });

    test('does not fire before its start month', () {
      final r = monthly(DateTime(2026, 6, 10, 7));
      expect(r.occurrenceOn(DateTime(2026, 5, 10)), isNull);
      expect(r.occurrenceOn(DateTime(2026, 6, 10)), isNotNull);
    });
  });

  group('ScheduleRepository', () {
    test('lists items for a single day', () async {
      final repo = ScheduleRepository(database);
      final today = DateTime.now();
      await repo.create(
          title: 'Standup',
          startAt: DateTime(today.year, today.month, today.day, 9));
      await repo.create(
          title: 'Next week',
          startAt: today.add(const Duration(days: 7)));

      final todayItems = await repo.listForDay(today);
      expect(todayItems, hasLength(1));
      expect(todayItems.first.title, 'Standup');
    });

    test('lead time persists and round-trips', () async {
      final repo = ScheduleRepository(database);
      final item = await repo.create(
          title: 'Dentist',
          startAt: DateTime.now().add(const Duration(days: 1)),
          leadTimeMinutes: 15);
      expect(item.leadTimeMinutes, 15);
      expect((await repo.getById(item.id))!.leadTimeMinutes, 15);

      final moved = await repo.update(item.id, leadTimeMinutes: 30);
      expect(moved!.leadTimeMinutes, 30);
      // Updating another field leaves the lead time untouched.
      final renamed = await repo.update(item.id, title: 'Dentist (moved)');
      expect(renamed!.leadTimeMinutes, 30);
    });

    test('event notification ids are negative and stable', () async {
      // Negative range keeps event ids from colliding with reminder ids
      // (which are positive) in the OS notification table.
      final id = ScheduleRepository.stableNotificationId('event-abc');
      expect(id, isNegative);
      expect(id, ScheduleRepository.stableNotificationId('event-abc'));
      expect(
          id, isNot(ScheduleRepository.stableNotificationId('event-xyz')));
    });
  });

  group('BehaviorRepository', () {
    test('low-risk behavior activates immediately with version 1', () async {
      final repo = BehaviorRepository(database);
      final behavior = await repo.createActive(
        title: 'Meetings first',
        behaviorType: 'summary_rule',
        ruleText: 'Show meetings before tasks in summaries.',
      );
      expect(behavior.status, 'Active');

      final versions = await repo.listVersions(behavior.id);
      expect(versions, hasLength(1));
      expect(versions.first['version_number'], 1);

      final active = await repo.listActive();
      expect(active, hasLength(1));
    });

    test('rule update creates a new version and rollback restores it',
        () async {
      final repo = BehaviorRepository(database);
      final behavior = await repo.createActive(
        title: 'Rule',
        behaviorType: 'preference_rule',
        ruleText: 'v1 text',
      );
      await repo.updateRuleText(behavior.id, 'v2 text',
          changeReason: 'tweak');

      var current = await repo.getById(behavior.id);
      expect(current!.ruleText, 'v2 text');
      expect(await repo.listVersions(behavior.id), hasLength(2));

      await repo.rollbackToVersion(behavior.id, 1);
      current = await repo.getById(behavior.id);
      expect(current!.ruleText, 'v1 text');
      // Rollback is itself a new version - history is append-only.
      expect(await repo.listVersions(behavior.id), hasLength(3));
    });

    test('medium-risk proposal stays pending until approved', () async {
      final repo = BehaviorRepository(database);
      final request = await repo.createChangeRequest(
        proposedTitle: 'Auto reminders from email',
        proposedRuleText: 'Create reminders from flagged emails.',
        behaviorType: 'workflow_rule',
        riskLevel: 'Medium Risk',
      );
      expect((await repo.listActive()), isEmpty);
      expect((await repo.listPendingRequests()), hasLength(1));

      final behavior = await repo.approveChangeRequest(request.id);
      expect(behavior, isNotNull);
      expect(behavior!.status, 'Active');
      expect(behavior.approvedByUser, isTrue);
      expect(await repo.listPendingRequests(), isEmpty);
    });
  });
}

/// The next date on or after now whose weekday is [weekday], at [hour]:00.
DateTime _nextWeekday(int weekday, {int hour = 9}) {
  final now = DateTime.now();
  var day = DateTime(now.year, now.month, now.day, hour);
  while (day.weekday != weekday || day.isBefore(now)) {
    day = day.add(const Duration(days: 1));
  }
  return day;
}
