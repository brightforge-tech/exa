import 'package:exa_mobile/data/database/app_database.dart';
import 'package:exa_mobile/data/repositories/email_repository.dart';
import 'package:exa_mobile/data/repositories/reminder_repository.dart';
import 'package:exa_mobile/data/repositories/schedule_repository.dart';
import 'package:exa_mobile/data/repositories/task_repository.dart';
import 'package:exa_mobile/features/assistant/today_panel.dart';
import 'package:exa_mobile/shared/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late AppDatabase database;
  late ProviderContainer container;

  setUp(() async {
    database = AppDatabase();
    await database.open(overridePath: inMemoryDatabasePath);
    container = ProviderContainer(
      overrides: [appDatabaseProvider.overrideWithValue(database)],
    );
  });

  tearDown(() {
    container.dispose();
    return database.close();
  });

  test('todayDashboardProvider buckets the day correctly', () async {
    final now = DateTime.now();
    final startOfDay = DateTime(now.year, now.month, now.day);

    // Overdue task (due yesterday), due-today task (due late today).
    await TaskRepository(database).create(
        title: 'Pay rent',
        dueAt: startOfDay.subtract(const Duration(hours: 6)));
    await TaskRepository(database).create(
        title: 'Submit report',
        dueAt: startOfDay.add(const Duration(hours: 23, minutes: 59)));
    // An event today.
    await ScheduleRepository(database)
        .create(title: 'Standup', startAt: startOfDay.add(const Duration(hours: 9)));
    // A daily reminder anchored today -> occurs today.
    await ReminderRepository(database).create(
        title: 'Take meds',
        remindAt: startOfDay.add(const Duration(hours: 8)),
        recurrenceRule: 'daily');
    // An undigested email.
    await EmailRepository(database).add(subject: 'Invoice', body: 'Due soon.');

    final dashboard = await container.read(todayDashboardProvider.future);

    expect(dashboard.isEmpty, isFalse);
    expect(dashboard.overdue, hasLength(1));
    expect(dashboard.overdue.first.title, 'Pay rent');
    expect(dashboard.dueToday.map((t) => t.title), contains('Submit report'));
    // The overdue task must not be double-counted in due-today.
    expect(dashboard.dueToday.any((t) => t.title == 'Pay rent'), isFalse);
    expect(dashboard.events, hasLength(1));
    expect(dashboard.reminders, hasLength(1));
    expect(dashboard.reminders.first.key.title, 'Take meds');
    expect(dashboard.undigestedEmails, hasLength(1));
    expect(dashboard.scheduleCount, 2); // 1 event + 1 reminder
  });

  test('todayDashboardProvider is empty on a clear day', () async {
    final dashboard = await container.read(todayDashboardProvider.future);
    expect(dashboard.isEmpty, isTrue);
  });
}
