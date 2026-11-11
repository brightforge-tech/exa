import 'package:exa_mobile/agent/security/capability_policy.dart';
import 'package:exa_mobile/agent/security/write_scope.dart';
import 'package:exa_mobile/agent/tools/tool_domains.dart';
import 'package:exa_mobile/agent/tools/tool_registry.dart';
import 'package:exa_mobile/data/database/app_database.dart';
import 'package:exa_mobile/data/models/day_plan_entry.dart';
import 'package:exa_mobile/data/repositories/behavior_repository.dart';
import 'package:exa_mobile/data/repositories/browser_context_repository.dart';
import 'package:exa_mobile/data/repositories/day_plan_repository.dart';
import 'package:exa_mobile/data/repositories/dynamic_screen_repository.dart';
import 'package:exa_mobile/data/repositories/email_repository.dart';
import 'package:exa_mobile/data/repositories/job_repository.dart';
import 'package:exa_mobile/data/repositories/mail_account_repository.dart';
import 'package:exa_mobile/data/repositories/pending_calendar_repository.dart';
import 'package:exa_mobile/data/repositories/reminder_repository.dart';
import 'package:exa_mobile/data/repositories/schedule_repository.dart';
import 'package:exa_mobile/data/repositories/task_repository.dart';
import 'package:exa_mobile/data/repositories/tool_call_repository.dart';
import 'package:exa_mobile/services/background_jobs/job_runner.dart';
import 'package:exa_mobile/services/browser/browser_bridge.dart';
import 'package:exa_mobile/services/calendar/device_calendar_service.dart';
import 'package:exa_mobile/services/mail/mail_service.dart';
import 'package:exa_mobile/services/notifications/notification_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late AppDatabase database;
  late ToolRegistry registry;
  late TaskRepository tasks;
  late ReminderRepository reminders;
  late DayPlanRepository plans;

  /// Today, because the tools default to it and that is the path the user
  /// actually takes ("plan this for me").
  final today = DateTime.now();

  setUp(() async {
    database = AppDatabase();
    await database.open(overridePath: inMemoryDatabasePath);
    tasks = TaskRepository(database);
    reminders = ReminderRepository(database);
    plans = DayPlanRepository(database);
    final notifications = NotificationService();
    final mailAccounts = MailAccountRepository(database);
    final emails = EmailRepository(database);
    final schedule = ScheduleRepository(database);
    registry = ToolRegistry(
      tasks: tasks,
      reminders: reminders,
      schedule: schedule,
      behaviors: BehaviorRepository(database),
      screens: DynamicScreenRepository(database),
      toolCalls: ToolCallRepository(database),
      notifications: notifications,
      database: database,
      jobs: JobRepository(database),
      jobRunner: JobRunner(database: database, notifications: notifications),
      browserContext: BrowserContextRepository(database),
      emails: emails,
      browserBridge: BrowserBridge(),
      mailAccounts: mailAccounts,
      mail: MailService(accounts: mailAccounts, emails: emails),
      deviceCalendar: DeviceCalendarService(schedule: schedule),
      pendingCalendar: PendingCalendarRepository(database),
    );
  });

  tearDown(() => database.close());

  test('planning a task sets aside time without moving its deadline',
      () async {
    final due = DateTime(2026, 12, 1, 17);
    final task = await tasks.create(title: 'Renew the passport', dueAt: due);

    final result = await registry.execute('plan_day_item', {
      'task_id': task.id,
      'start_time': '09:30',
      'duration_minutes': 45,
    });

    expect(result.success, isTrue);
    final data = result.data as Map;
    expect(data['start_time'], '09:30');
    expect(data['end_time'], '10:15');
    expect(data['source'], DayPlanEntry.sourceTask);
    // The board is intent; the deadline is a fact about the task and is not
    // the agent's to move here.
    expect((await tasks.getById(task.id))!.dueAt, due);
  });

  test('with no start_time the item lands in the first free slot', () async {
    await plans.plan(
        day: today,
        title: 'Standup',
        startMinute: DayPlanRepository.boardStartMinute,
        durationMinutes: 60);
    final task = await tasks.create(title: 'Write the report');

    final result =
        await registry.execute('plan_day_item', {'task_id': task.id});

    expect(result.success, isTrue);
    expect((result.data as Map)['start_time'],
        DayPlanEntry.formatMinuteOfDay(DayPlanRepository.boardStartMinute + 60));
  });

  test('a title with no id plans an ad-hoc block', () async {
    final result = await registry.execute('plan_day_item', {
      'title': 'Deep work',
      'start_time': '13:00',
    });
    expect(result.success, isTrue);
    expect((result.data as Map)['source'], DayPlanEntry.sourceNote);
    expect((await plans.listForDay(today)).single.title, 'Deep work');
  });

  test('planning nothing in particular fails with what to give instead',
      () async {
    final result = await registry.execute('plan_day_item', {});
    expect(result.success, isFalse);
    expect(result.error, contains('task_id'));
  });

  test('an unknown task id fails rather than inventing a block', () async {
    final result =
        await registry.execute('plan_day_item', {'task_id': 'does-not-exist'});
    expect(result.success, isFalse);
    expect(result.error, contains('does-not-exist'));
    expect(await plans.listForDay(today), isEmpty);
  });

  test('list_day_plan reports the day, its cards and the next free slot',
      () async {
    final task = await tasks.create(title: 'Prep slides');
    await registry.execute('plan_day_item', {
      'task_id': task.id,
      'start_time': '09:00',
      'duration_minutes': 60,
    });

    final result = await registry.execute('list_day_plan', {});
    expect(result.success, isTrue);
    final data = result.data as Map;
    expect(data['date'], DayPlanEntry.dateKey(today));
    expect(data['planned_minutes'], 60);
    final planned = (data['planned'] as List).cast<Map>();
    expect(planned.single['title'], 'Prep slides');
    expect(planned.single['start_time'], '09:00');
    expect(planned.single['done'], isFalse);
    // The board opens at 06:00 and the card is at 09:00, so the first free
    // slot is still the top of the day.
    expect(data['next_free_slot'], '06:00');
  });

  test('list_day_plan shows a card as done once the task is', () async {
    final task = await tasks.create(title: 'Pay the invoice');
    await registry
        .execute('plan_day_item', {'task_id': task.id, 'start_time': '10:00'});
    await registry.execute('complete_task', {'id': task.id});

    final result = await registry.execute('list_day_plan', {});
    final planned = ((result.data as Map)['planned'] as List).cast<Map>();
    expect(planned.single['done'], isTrue);
  });

  test('move changes the time; unplan leaves the task alone', () async {
    final task = await tasks.create(title: 'Grocery run');
    final planned = await registry
        .execute('plan_day_item', {'task_id': task.id, 'start_time': '09:00'});
    final entryId = (planned.data as Map)['id'] as String;

    final moved = await registry.execute('move_day_plan_item', {
      'entry_id': entryId,
      'start_time': '17:30',
    });
    expect((moved.data as Map)['start_time'], '17:30');

    final removed =
        await registry.execute('unplan_day_item', {'entry_id': entryId});
    expect(removed.success, isTrue);
    expect(await plans.listForDay(today), isEmpty);
    // Taking it off the board is not the same as finishing or deleting it.
    expect((await tasks.getById(task.id))!.isOpen, isTrue);
  });

  test('move with neither a time nor a duration says so', () async {
    final entry = await plans.plan(
        day: today, title: 'Block', startMinute: 9 * 60);
    final result =
        await registry.execute('move_day_plan_item', {'entry_id': entry.id});
    expect(result.success, isFalse);
    expect(result.error, contains('duration_minutes'));
  });

  test('moving an entry that is not there fails cleanly', () async {
    final result = await registry.execute(
        'move_day_plan_item', {'entry_id': 'nope', 'start_time': '10:00'});
    expect(result.success, isFalse);
  });

  test('planning a reminder reschedules it to the slot', () async {
    // A reminder has no deadline - the time it fires IS the reminder. So
    // unlike a task's due date, planning one moves it, or the board would
    // say one thing while the phone did another.
    final reminder = await reminders.create(
        title: 'Take the medication',
        remindAt: DateTime(today.year, today.month, today.day, 8));

    final result = await registry.execute('plan_day_item', {
      'reminder_id': reminder.id,
      'start_time': '20:00',
    });

    expect(result.success, isTrue);
    final updated = (await reminders.getById(reminder.id))!;
    expect(updated.remindAt.hour, 20);
    expect(updated.remindAt.day, today.day);
    // ...and the result says so, so the answer can tell the user.
    expect((result.data as Map)['reminder_now_fires_at'], isNotNull);
  });

  test('a reminder set for another day moves onto the day it is planned',
      () async {
    final reminder = await reminders.create(
        title: 'Renew the parking permit',
        remindAt: DateTime(today.year, today.month, today.day, 9)
            .add(const Duration(days: 6)));

    await registry.execute('plan_day_item', {
      'reminder_id': reminder.id,
      'start_time': '11:00',
    });

    final updated = (await reminders.getById(reminder.id))!;
    expect(updated.remindAt.year, today.year);
    expect(updated.remindAt.month, today.month);
    expect(updated.remindAt.day, today.day);
    expect(updated.remindAt.hour, 11);
  });

  test('a repeating reminder keeps repeating when it is planned', () async {
    final reminder = await reminders.create(
        title: 'Stand up and stretch',
        remindAt: DateTime(today.year, today.month, today.day, 9),
        recurrenceRule: 'daily');

    await registry.execute('plan_day_item', {
      'reminder_id': reminder.id,
      'start_time': '15:30',
    });

    final updated = (await reminders.getById(reminder.id))!;
    // Only the hour moves; dragging a daily reminder is retiming it, not
    // cancelling the repeat.
    expect(updated.recurrenceRule, 'daily');
    expect(updated.remindAt.hour, 15);
    expect(updated.remindAt.minute, 30);
  });

  test('moving a reminder card moves the alarm with it', () async {
    final reminder = await reminders.create(
        title: 'Call the bank',
        remindAt: DateTime(today.year, today.month, today.day, 9));
    final planned = await registry.execute(
        'plan_day_item', {'reminder_id': reminder.id, 'start_time': '10:00'});
    final entryId = (planned.data as Map)['id'] as String;

    await registry.execute('move_day_plan_item', {
      'entry_id': entryId,
      'start_time': '16:00',
    });

    expect((await reminders.getById(reminder.id))!.remindAt.hour, 16);
  });

  test('planning a task still leaves its due date alone', () async {
    // The other half of the rule: a deadline is not the agent's to move
    // just because the user decided when to do the work.
    final due = DateTime(2026, 12, 1, 17);
    final task = await tasks.create(title: 'File the return', dueAt: due);
    await registry
        .execute('plan_day_item', {'task_id': task.id, 'start_time': '09:00'});
    expect((await tasks.getById(task.id))!.dueAt, due);
  });

  test('the tools are registered, routable and classified', () {
    const names = [
      'list_day_plan',
      'plan_day_item',
      'move_day_plan_item',
      'unplan_day_item',
    ];
    for (final name in names) {
      expect(registry[name], isNotNull, reason: '$name not registered');
      expect(registry.domainOf(name), ToolDomains.calendar,
          reason: '$name must be reachable when the router picks calendar');
      expect(CapabilityGate.capabilities.containsKey(name), isTrue,
          reason: '$name unclassified is $name unusable in background runs');
    }
    // Writes are one effect, so a job can be scoped to "may plan my day" and
    // nothing else.
    for (final name in names.skip(1)) {
      expect(WriteScope.effectOf(name, const {}), WriteEffect.dayPlanUpdate);
    }
    expect(WriteScope.unattendedDefault.allows(WriteEffect.dayPlanUpdate),
        isTrue);
  });
}
