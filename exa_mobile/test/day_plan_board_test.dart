import 'package:exa_mobile/data/database/app_database.dart';
import 'package:exa_mobile/data/repositories/reminder_repository.dart';
import 'package:exa_mobile/data/repositories/task_repository.dart';
import 'package:exa_mobile/features/planning/day_plan_controller.dart';
import 'package:exa_mobile/services/notifications/notification_service.dart';
import 'package:exa_mobile/shared/providers.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// What the board offers to plan, and what happens to a reminder when it is
/// planned. The tool tests cover the agent's route to the same rules; these
/// cover the screen's.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    // Notification scheduling goes through a platform channel that does not
    // exist in tests; answering it keeps rescheduling a no-op instead of a
    // crash.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel(
          'dexterous.com/flutter/local_notifications'),
      (call) async => null,
    );
  });

  late AppDatabase database;
  late ProviderContainer container;
  late TaskRepository tasks;
  late ReminderRepository reminders;

  final today = DateTime.now();
  DateTime at(int day, int hour, [int minute = 0]) => DateTime(
      today.year, today.month, today.day, hour, minute).add(Duration(days: day));

  setUp(() async {
    database = AppDatabase();
    await database.open(overridePath: inMemoryDatabasePath);
    tasks = TaskRepository(database);
    reminders = ReminderRepository(database);
    container = ProviderContainer(overrides: [
      appDatabaseProvider.overrideWithValue(database),
      notificationServiceProvider.overrideWithValue(NotificationService()),
    ]);
  });

  tearDown(() {
    container.dispose();
    return database.close();
  });

  /// Reads the board, holding a subscription first: it is an autoDispose
  /// provider, so without a listener it is torn down between reads and the
  /// refresh after a mutation lands on a disposed element.
  Future<DayPlanBoard> board() {
    container.listen(dayPlanBoardProvider, (_, _) {});
    return container.read(dayPlanBoardProvider.future);
  }

  test('every active reminder is offered, whatever day it is set for',
      () async {
    await reminders.create(title: 'Today thing', remindAt: at(0, 9));
    await reminders.create(title: 'Next week thing', remindAt: at(6, 9));
    await reminders.create(title: 'Yesterday thing', remindAt: at(-1, 9));

    final titles = (await board()).backlog.map((item) => item.title);
    // Pulling next week's reminder into today is the reason to open this
    // board, so it cannot be hidden until the day it already falls on.
    expect(titles, containsAll(
        ['Today thing', 'Next week thing', 'Yesterday thing']));
  });

  test('a cancelled reminder is not offered', () async {
    final reminder =
        await reminders.create(title: 'Called off', remindAt: at(0, 9));
    await reminders.cancel(reminder.id);
    expect((await board()).backlog, isEmpty);
  });

  test('only reminders landing on this day are marked as todays', () async {
    await reminders.create(title: 'Today thing', remindAt: at(0, 9));
    await reminders.create(title: 'Next week thing', remindAt: at(6, 9));

    final backlog = (await board()).backlog;
    final todays =
        backlog.firstWhere((item) => item.title == 'Today thing');
    final later =
        backlog.firstWhere((item) => item.title == 'Next week thing');

    // The card renders differently for the two: one shows a time, the other
    // shows the date it would be moved from.
    expect(todays.isToday, isTrue);
    expect(todays.firesAt, isNotNull);
    expect(later.isToday, isFalse);
    expect(later.firesAt, isNull);
  });

  test('a daily reminder counts as todays whatever day it started', () async {
    await reminders.create(
        title: 'Stretch', remindAt: at(-10, 9), recurrenceRule: 'daily');
    expect((await board()).backlog.single.isToday, isTrue);
  });

  test('planning a reminder from another day moves it here', () async {
    await reminders.create(title: 'Renew permit', remindAt: at(6, 9));
    final item = (await board()).backlog.single;

    await container
        .read(dayPlanControllerProvider)
        .planBacklogItem(item, startMinute: 11 * 60);

    final updated = (await reminders.listAll()).single;
    expect(updated.remindAt.day, today.day);
    expect(updated.remindAt.hour, 11);
    // ...and it is now a card on the board rather than a backlog chip.
    final after = await board();
    expect(after.backlog, isEmpty);
    expect(after.planned.single.entry.startLabel, '11:00');
  });

  test('tapping a reminder tries its own hour first', () async {
    // An 08:00 reminder pulled onto today most likely still wants 08:00.
    await reminders.create(title: 'Morning pills', remindAt: at(3, 8));
    final item = (await board()).backlog.single;

    final entry = await container
        .read(dayPlanControllerProvider)
        .planAtNextFreeSlot(item);

    expect(entry!.startLabel, '08:00');
  });

  test('planning a task leaves its due date where it was', () async {
    final due = DateTime(2026, 12, 1, 17);
    await tasks.create(title: 'File the return', dueAt: due);
    final item = (await board()).backlog.single;

    await container
        .read(dayPlanControllerProvider)
        .planBacklogItem(item, startMinute: 9 * 60);

    expect((await tasks.list()).single.dueAt, due);
  });

  test('taking a reminder off the board leaves it where it was moved to',
      () async {
    await reminders.create(title: 'Call the bank', remindAt: at(0, 9));
    final item = (await board()).backlog.single;
    final entry = await container
        .read(dayPlanControllerProvider)
        .planBacklogItem(item, startMinute: 16 * 60);

    await container.read(dayPlanControllerProvider).unplan(entry.id);

    // Unplanning is "I am not doing it at that time after all", not "undo
    // the reschedule" - silently springing back would be its own surprise.
    expect((await reminders.listAll()).single.remindAt.hour, 16);
  });
}
