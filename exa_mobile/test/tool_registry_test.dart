import 'package:exa_mobile/agent/security/capability_policy.dart';
import 'package:exa_mobile/agent/tools/tool_registry.dart';
import 'package:exa_mobile/features/dynamic_ui/screen_schema.dart';
import 'package:exa_mobile/data/database/app_database.dart';
import 'package:exa_mobile/data/repositories/behavior_repository.dart';
import 'package:exa_mobile/data/repositories/diagnostics_repository.dart';
import 'package:exa_mobile/data/repositories/browser_context_repository.dart';
import 'package:exa_mobile/data/repositories/chat_repository.dart';
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
  late ToolCallRepository toolCalls;

  /// Permissions disabled in a test via this set.
  final disabledPermissions = <String>{};
  late BrowserBridge browserBridge;

  setUp(() async {
    disabledPermissions.clear();
    browserBridge = BrowserBridge();
    database = AppDatabase();
    await database.open(overridePath: inMemoryDatabasePath);
    toolCalls = ToolCallRepository(database);
    // Not initialized: notification scheduling becomes a safe no-op,
    // which is exactly what unit tests need.
    final notifications = NotificationService();
    final mailAccounts = MailAccountRepository(database);
    final emails = EmailRepository(database);
    final schedule = ScheduleRepository(database);
    registry = ToolRegistry(
      tasks: TaskRepository(database),
      reminders: ReminderRepository(database),
      schedule: schedule,
      behaviors: BehaviorRepository(database),
      screens: DynamicScreenRepository(database),
      toolCalls: toolCalls,
      notifications: notifications,
      database: database,
      jobs: JobRepository(database),
      jobRunner:
          JobRunner(database: database, notifications: notifications),
      browserContext: BrowserContextRepository(database),
      emails: emails,
      browserBridge: browserBridge,
      mailAccounts: mailAccounts,
      mail: MailService(accounts: mailAccounts, emails: emails),
      deviceCalendar: DeviceCalendarService(schedule: schedule),
      pendingCalendar: PendingCalendarRepository(database),
      isPermissionEnabled: (permission) async =>
          !disabledPermissions.contains(permission),
    );
  });

  tearDown(() => database.close());

  test('every registered tool is classified for the capability gate',
      () async {
    // An unclassified tool is treated as outbound and becomes unusable in
    // background runs, so a new tool must be classified deliberately here
    // rather than discovered missing in production.
    final unclassified = registry.all
        .map((tool) => tool.name)
        .where((name) => !CapabilityGate.capabilities.containsKey(name))
        .toList()
      ..sort();
    expect(unclassified, isEmpty,
        reason: 'add these to CapabilityGate.capabilities');
  });

  test('every row-action tool is safe to put one tap away in a screen',
      () async {
    // A generated screen can put buttons on its rows, and those run without
    // the agent loop around them - no confirmation prompt, no capability
    // context beyond interactive. So the allowlist itself has to be the
    // guarantee: everything on it exists, is a local write or a read, and
    // never asks a question it has nowhere to ask.
    for (final name in ScreenSchema.allowedRowTools.keys) {
      final tool = registry[name];
      expect(tool, isNotNull, reason: '$name is not a registered tool');
      expect(tool!.requiresConfirmation, isFalse,
          reason: '$name asks for confirmation, which a row button cannot '
              'give - drop it from allowedRowTools');
      expect(
        CapabilityGate.capabilityOf(name),
        anyOf(ToolCapability.localWrite, ToolCapability.read),
        reason: '$name is destructive or outbound; a tap in a screen the '
            'model wrote must never do that',
      );
    }
  });

  test('a generated screen can be deleted, but not by a background run',
      () async {
    final screens = DynamicScreenRepository(database);
    await registry.execute('create_dynamic_screen', {
      'screen_key': 'scratch',
      'title': 'Scratch',
      'schema': {
        'data_source': {'table': 'tasks'},
        'components': [
          {
            'type': 'list',
            'item_template': {'title': '{{title}}'},
          },
        ],
      },
    });
    expect(await screens.getByKey('scratch'), isNotNull);

    // Deleting is destructive, so an unattended run is refused even though
    // it could create the same screen a moment earlier.
    final denied = await registry.execute(
      'delete_dynamic_screen',
      {'screen_key': 'scratch'},
      capabilities: const CapabilityContext(runMode: AgentRunMode.unattended),
    );
    expect(denied.wasDenied, isTrue);
    expect(await screens.getByKey('scratch'), isNotNull);

    final deleted = await registry
        .execute('delete_dynamic_screen', {'screen_key': 'scratch'});
    expect(deleted.success, isTrue);
    expect(await screens.getByKey('scratch'), isNull);
  });

  test('a built-in screen cannot be deleted out from under the app',
      () async {
    final result = await registry
        .execute('delete_dynamic_screen', {'screen_key': 'tasks'});
    expect(result.success, isFalse);
    expect(result.error, contains('built-in'));
  });

  test('deleting a screen that is not there fails rather than pretending',
      () async {
    final result = await registry
        .execute('delete_dynamic_screen', {'screen_key': 'never_existed'});
    expect(result.success, isFalse);
  });

  test('an unattended run cannot send email even when the model asks',
      () async {
    final result = await registry.execute(
      'send_email',
      {'to': 'someone@example.com', 'subject': 'Hi', 'body': 'Hello'},
      capabilities:
          const CapabilityContext(runMode: AgentRunMode.unattended),
    );
    expect(result.success, isFalse);
    expect(result.wasDenied, isTrue);
    // And the block is visible rather than silent.
    final events = await DiagnosticsRepository(database).recent();
    expect(events.map((e) => e.code), contains('TOOL_CAPABILITY_DENIED'));
  });

  test('an unattended run cannot delete a task it can still read',
      () async {
    final created = await registry.execute('create_task', {
      'title': 'Keep me',
    });
    final id = (created.data as Map)['id'] as String;

    const unattended =
        CapabilityContext(runMode: AgentRunMode.unattended);
    final listed =
        await registry.execute('list_tasks', {}, capabilities: unattended);
    expect(listed.success, isTrue);

    final deleted = await registry.execute('delete_task', {'id': id},
        capabilities: unattended);
    expect(deleted.wasDenied, isTrue);
    expect(await TaskRepository(database).getById(id), isNotNull);
  });

  test('a job allow-list narrows what its run may touch', () async {
    const permissions = CapabilityContext(
      runMode: AgentRunMode.unattended,
      jobPermissions: JobPermissions(allowedTools: {'list_tasks'}),
      jobId: 'job-1',
    );
    expect(
        (await registry.execute('list_tasks', {}, capabilities: permissions))
            .success,
        isTrue);
    final denied = await registry.execute(
        'create_task', {'title': 'Nope'}, capabilities: permissions);
    expect(denied.wasDenied, isTrue);
    expect(denied.error, contains('may only use'));
    // A read the list does not name still runs: the list narrows what the
    // job may change, not what it may look at.
    final read = await registry.execute('list_reminders', {},
        capabilities: permissions);
    expect(read.success, isTrue, reason: read.error);
  });

  test('a large undigested backlog comes back in batches, not all at once',
      () async {
    final emailRepo = EmailRepository(database);
    for (var i = 0; i < 57; i++) {
      await emailRepo.add(subject: 'Message $i', body: 'Body $i');
    }

    // Asking for "the undigested ones" used to return all 57 in a single
    // tool result, which alone exceeded the model context and killed the
    // turn instead of digesting the first batch.
    final first = await registry.execute(
        'read_email_context', {'undigested_only': true});
    expect(first.success, isTrue);
    final data = first.data as Map;
    expect((data['emails'] as List), hasLength(10),
        reason: 'default batch size');
    expect(data['total_undigested'], 57);
    expect(data['remaining'], 47);
    expect(data['next_step'], contains('again'));

    // Oldest first, so a backlog drains in arrival order.
    expect(((data['emails'] as List).first as Map)['subject'], 'Message 0');

    // An outsized request is clamped rather than honoured.
    final greedy = await registry.execute(
        'read_email_context', {'undigested_only': true, 'limit': 500});
    expect(((greedy.data as Map)['emails'] as List), hasLength(25));
  });

  test('marking a batch digested moves the backlog forward', () async {
    final emailRepo = EmailRepository(database);
    final ids = <String>[];
    for (var i = 0; i < 12; i++) {
      ids.add((await emailRepo.add(subject: 'M$i', body: 'B$i')).id);
    }

    await registry.execute('mark_email_digested', {'ids': ids.take(10)
        .toList()});
    final next = await registry.execute(
        'read_email_context', {'undigested_only': true});
    final data = next.data as Map;
    expect(data['total_undigested'], 2);
    expect(data['remaining'], 0);
    expect((data['emails'] as List), hasLength(2));
  });

  test('agent can create a task through the tool layer', () async {
    final result = await registry.execute('create_task', {
      'title': 'From the agent',
      'priority': 'High',
    });
    expect(result.success, isTrue);

    final tasks = await TaskRepository(database).list();
    expect(tasks, hasLength(1));
    expect(tasks.first.createdBy, 'agent');
  });

  test('every tool call is logged, including rejections', () async {
    await registry.execute('create_task', {'title': 'ok'});
    await registry.execute('create_task', {'wrong_field': true});
    await registry.execute('no_such_tool', {});

    final logs = await toolCalls.recent();
    expect(logs, hasLength(3));
    expect(logs.map((l) => l.status).toSet(),
        containsAll(['success', 'rejected']));
  });

  test('missing required parameters are rejected before execution',
      () async {
    final result = await registry.execute('create_reminder', {
      'title': 'no time given',
    });
    expect(result.success, isFalse);
    expect(result.error, contains('remind_at'));

    expect(await ReminderRepository(database).listAll(), isEmpty);
  });

  test('reminder in the past is rejected', () async {
    final result = await registry.execute('create_reminder', {
      'title': 'too late',
      'remind_at':
          DateTime.now().subtract(const Duration(days: 1)).toIso8601String(),
    });
    expect(result.success, isFalse);
    expect(result.error, contains('past'));
  });

  test('agent can create a reminder through the tool layer', () async {
    final remindAt = DateTime.now().add(const Duration(hours: 3));
    final result = await registry.execute('create_reminder', {
      'title': 'Call John',
      'remind_at': remindAt.toIso8601String(),
    });
    expect(result.success, isTrue);

    final reminders = await ReminderRepository(database).listAll();
    expect(reminders, hasLength(1));
    expect(reminders.first.title, 'Call John');
  });

  test('invalid dynamic screen schemas are rejected safely', () async {
    final result = await registry.execute('create_dynamic_screen', {
      'screen_key': 'evil',
      'title': 'Evil',
      'schema': {
        'data_source': {'table': 'settings'},
        'components': [
          {'type': 'header', 'text': 'x'},
        ],
      },
    });
    expect(result.success, isFalse);
    expect(await DynamicScreenRepository(database).listAll(), isEmpty);
  });

  test('valid dynamic screen is stored and openable', () async {
    final created = await registry.execute('create_dynamic_screen', {
      'screen_key': 'overdue_tasks',
      'title': 'Overdue tasks',
      'schema': {
        'layout': 'list',
        'data_source': {
          'table': 'tasks',
          'filters': [
            {'field': 'due_at', 'operator': 'lt', 'value': 'now'},
          ],
        },
        'components': [
          {'type': 'header', 'text': 'Overdue'},
          {
            'type': 'list',
            'item_template': {'title': '{{title}}'},
          },
        ],
      },
    });
    expect(created.success, isTrue);

    final opened =
        await registry.execute('open_screen', {'screen_key': 'overdue_tasks'});
    expect(opened.success, isTrue);
    expect(opened.navigateTo, '/screen/overdue_tasks');
  });

  test('open_screen resolves built-in screens', () async {
    final result =
        await registry.execute('open_screen', {'screen_key': 'tasks'});
    expect(result.success, isTrue);
    expect(result.navigateTo, '/tasks');
  });

  test('disabled permission group blocks the tool and logs the rejection',
      () async {
    disabledPermissions.add('tasks.write');

    final result =
        await registry.execute('create_task', {'title': 'blocked'});
    expect(result.success, isFalse);
    expect(result.error, contains('tasks.write'));
    expect(await TaskRepository(database).list(), isEmpty);

    final logs = await toolCalls.recent();
    expect(logs.single.status, 'rejected');

    // Reads are a different group and still work.
    final list = await registry.execute('list_tasks', {});
    expect(list.success, isTrue);
  });

  test('agent can create and run a daily summary job', () async {
    final created = await registry.execute('create_scheduled_job', {
      'name': 'Morning summary',
      'job_type': 'daily_summary',
      'time': '07:30',
    });
    expect(created.success, isTrue);
    final jobId = (created.data as Map)['id'] as String;

    final ran =
        await registry.execute('run_scheduled_job_now', {'id': jobId});
    expect(ran.success, isTrue);

    final jobs = JobRepository(database);
    final runs = await jobs.listRuns(jobId);
    expect(runs, hasLength(1));
    expect(runs.single.status, 'Success');

    // Job persists with a recomputed next run.
    final job = await jobs.getById(jobId);
    expect(job!.nextRunAt, isNotNull);
    expect(job.nextRunAt!.isAfter(DateTime.now()), isTrue);
  });

  test('daily summary job posts its brief into the chat', () async {
    final jobs = JobRepository(database);
    final job = await jobs.create(
      name: 'Morning brief',
      jobType: 'daily_summary',
      scheduleRule: {'type': 'daily', 'time': '07:30'},
    );
    final runner =
        JobRunner(database: database, notifications: NotificationService());

    final outcome = await runner.runJob(job);
    expect(outcome.success, isTrue);

    final messages = await ChatRepository(database).recent();
    expect(messages, isNotEmpty);
    final last = messages.last;
    expect(last.role, 'assistant');
    expect(last.meta?['source'], 'scheduled_job');
    expect(last.content, equals(outcome.summary));
  });

  test('pause/resume scheduled job', () async {
    final created = await registry.execute('create_scheduled_job', {
      'name': 'X',
      'job_type': 'task_cleanup',
      'time': '03:00',
    });
    final jobId = (created.data as Map)['id'] as String;

    await registry.execute('pause_scheduled_job', {'id': jobId});
    var job = await JobRepository(database).getById(jobId);
    expect(job!.status, 'Paused');
    expect(await JobRepository(database).listDue(), isEmpty);

    await registry.execute('resume_scheduled_job', {'id': jobId});
    job = await JobRepository(database).getById(jobId);
    expect(job!.status, 'Active');
  });

  test('muting a job silences it without stopping it', () async {
    final created = await registry.execute('create_scheduled_job', {
      'name': 'Noisy sync',
      'job_type': 'email_sync',
      'frequency': 'interval',
      'interval_minutes': 2,
    });
    final jobId = (created.data as Map)['id'] as String;
    expect((await JobRepository(database).getById(jobId))!.muteNotifications,
        isFalse);

    await registry.execute('mute_scheduled_job', {'id': jobId});
    var job = await JobRepository(database).getById(jobId);
    expect(job!.muteNotifications, isTrue);
    // "Too noisy" is not "stop doing it": the job keeps its schedule.
    expect(job.status, 'Active');
    expect(job.scheduleRule['minutes'], 2);

    await registry.execute('mute_scheduled_job', {'id': jobId, 'muted': false});
    job = await JobRepository(database).getById(jobId);
    expect(job!.muteNotifications, isFalse);

    final missing = await registry.execute('mute_scheduled_job', {'id': 'no'});
    expect(missing.success, isFalse);
  });

  test('a job created muted is created muted', () async {
    final created = await registry.execute('create_scheduled_job', {
      'name': 'Quiet sweep',
      'job_type': 'task_cleanup',
      'time': '03:00',
      'mute_notifications': true,
    });
    expect((created.data as Map)['mute_notifications'], isTrue);
    final jobId = (created.data as Map)['id'] as String;
    expect((await JobRepository(database).getById(jobId))!.muteNotifications,
        isTrue);
  });

  test('read_browser_context lists and reads shared pages', () async {
    final browserContext = BrowserContextRepository(database);
    final item = await browserContext.add(
      pageTitle: 'Quarterly report',
      pageUrl: 'https://example.com/report',
      extractedText: 'Revenue grew 12% quarter over quarter. ' * 20,
    );

    final list = await registry.execute('read_browser_context', {});
    expect(list.success, isTrue);
    expect((list.data as Map)['count'], 1);
    // Listing returns summaries, not the full text.
    final pages = (list.data as Map)['pages'] as List;
    expect((pages.single as Map).containsKey('extracted_text'), isFalse);

    final read =
        await registry.execute('read_browser_context', {'id': item.id});
    expect(read.success, isTrue);
    expect((read.data as Map)['extracted_text'], contains('Revenue'));
  });

  /// Fake two-tab browser registered on the bridge.
  void registerFakeTabs() {
    const pages = [
      BrowserPageSnapshot(
        title: 'Flight confirmation',
        url: 'https://airline.example.com/booking',
        text: 'Your flight AB123 departs June 20 at 14:05 from SEA.',
      ),
      BrowserPageSnapshot(
        title: 'Hotel booking',
        url: 'https://hotel.example.com/reservation',
        text: 'Reservation #991 - check-in June 20, two nights.',
      ),
    ];
    browserBridge.register(
      listTabs: () async => [
        for (var i = 0; i < pages.length; i++)
          BrowserTabInfo(
            index: i,
            title: pages[i].title,
            url: pages[i].url,
            isActive: i == 0,
          ),
      ],
      snapshotTab: (tabIndex) async {
        final index = tabIndex ?? 0; // null = active tab
        if (index < 0 || index >= pages.length) return null;
        return pages[index];
      },
    );
  }

  test('read_current_browser_page reads the active tab and stores it',
      () async {
    registerFakeTabs();

    final result =
        await registry.execute('read_current_browser_page', {});
    expect(result.success, isTrue);
    expect((result.data as Map)['page_text'], contains('AB123'));

    // The page also lands in shared-pages history for later re-reads.
    final stored = await BrowserContextRepository(database).recent();
    expect(stored, hasLength(1));
    expect(stored.single.pageTitle, 'Flight confirmation');
  });

  test('list_browser_tabs + tab_index read a background tab', () async {
    registerFakeTabs();

    final tabs = await registry.execute('list_browser_tabs', {});
    expect(tabs.success, isTrue);
    expect((tabs.data as Map)['count'], 2);
    final listed = ((tabs.data as Map)['tabs'] as List).cast<Map>();
    expect(listed[0]['active'], isTrue);
    expect(listed[1]['title'], 'Hotel booking');

    final background = await registry
        .execute('read_current_browser_page', {'tab_index': 1});
    expect(background.success, isTrue);
    expect((background.data as Map)['page_text'], contains('#991'));

    // Both reads accumulate in shared-pages history.
    await registry.execute('read_current_browser_page', {'tab_index': 0});
    final stored = await BrowserContextRepository(database).recent();
    expect(stored, hasLength(2));
  });

  test('read_current_browser_page rejects an invalid tab index',
      () async {
    registerFakeTabs();
    final result = await registry
        .execute('read_current_browser_page', {'tab_index': 9});
    expect(result.success, isFalse);
    expect(result.error, contains('list_browser_tabs'));
  });

  test('browser tools fail helpfully when browser is closed', () async {
    final read =
        await registry.execute('read_current_browser_page', {});
    expect(read.success, isFalse);
    expect(read.error, contains('Browser tab'));

    final tabs = await registry.execute('list_browser_tabs', {});
    expect(tabs.success, isTrue);
    expect((tabs.data as Map)['count'], 0);
  });

  test('email digest flow: read, full body, mark digested', () async {
    final emailRepo = EmailRepository(database);
    final email = await emailRepo.add(
      subject: 'Project kickoff Friday',
      sender: 'boss@example.com',
      body: 'Kickoff meeting Friday at 10:00 in Room 4. '
          'Please prepare the budget summary beforehand.',
    );

    // List undigested emails.
    final list = await registry
        .execute('read_email_context', {'undigested_only': true});
    expect(list.success, isTrue);
    expect((list.data as Map)['count'], 1);
    final listed = ((list.data as Map)['emails'] as List).single as Map;
    expect(listed['subject'], 'Project kickoff Friday');
    expect(listed.containsKey('body'), isFalse); // summaries only

    // Read the full body by id.
    final full =
        await registry.execute('read_email_context', {'id': email.id});
    expect((full.data as Map)['body'], contains('Room 4'));

    // Mark digested; it disappears from the undigested list.
    final marked = await registry
        .execute('mark_email_digested', {'id': email.id});
    expect(marked.success, isTrue);
    final after = await registry
        .execute('read_email_context', {'undigested_only': true});
    expect((after.data as Map)['count'], 0);
  });

  test('mark_email_digested marks several emails in one call', () async {
    final emailRepo = EmailRepository(database);
    final a = await emailRepo.add(subject: 'A', body: 'body a');
    final b = await emailRepo.add(subject: 'B', body: 'body b');

    final marked = await registry.execute('mark_email_digested', {
      'ids': [a.id, b.id, 'no_such_email'],
    });
    expect(marked.success, isTrue);
    final data = marked.data as Map;
    expect(data['count'], 2);
    expect(data['not_found'], ['no_such_email']);

    final after = await registry
        .execute('read_email_context', {'undigested_only': true});
    expect((after.data as Map)['count'], 0);
  });

  test('mark_email_digested without any id fails helpfully', () async {
    final result = await registry.execute('mark_email_digested', {});
    expect(result.success, isFalse);
    expect(result.error, contains('id'));
  });

  test('email body is capped at the storage limit', () async {
    final emailRepo = EmailRepository(database);
    final email = await emailRepo.add(
      subject: 'Huge',
      body: 'x' * (EmailRepository.maxBodyChars + 5000),
    );
    final stored = await emailRepo.getById(email.id);
    expect(stored!.body.length, EmailRepository.maxBodyChars);
  });

  test('recurring task spawns its next occurrence on completion',
      () async {
    final due = DateTime.now().add(const Duration(hours: 2));
    final created = await registry.execute('create_task', {
      'title': 'Water plants',
      'due_at': due.toIso8601String(),
      'recurrence_rule': 'daily',
    });
    expect(created.success, isTrue);
    final taskId = (created.data as Map)['id'] as String;

    await registry.execute('complete_task', {'id': taskId});

    final repo = TaskRepository(database);
    final open = await repo.list(openOnly: true);
    expect(open, hasLength(1));
    expect(open.single.title, 'Water plants');
    expect(open.single.recurrenceRule, 'daily');
    expect(open.single.dueAt!.isAfter(due), isTrue);
  });

  test('list_tasks can answer what was finished today', () async {
    final repo = TaskRepository(database);
    final old = await repo.create(title: 'Filed last month');
    final today = await repo.create(title: 'Sent the invoice');
    final reopened = await repo.create(title: 'Reopened after review');
    await repo.create(title: 'Still to do');
    await repo.complete(old.id);
    await repo.complete(today.id);
    await repo.complete(reopened.id);
    await repo.update(reopened.id, status: 'Pending');
    await database.db.update(
        'tasks',
        {
          'completed_at':
              DateTime.now().subtract(const Duration(days: 30)).toIso8601String(),
        },
        where: 'id = ?',
        whereArgs: [old.id]);

    final now = DateTime.now();
    final day = DateTime(now.year, now.month, now.day);
    final result = await registry.execute('list_tasks', {
      // A bare date, as the prompt list gives it, and a contradictory
      // open_only - the question is still "what was completed".
      'completed_since': day.toIso8601String().substring(0, 10),
      'open_only': true,
    });
    expect(result.success, isTrue);
    final tasks = (result.data as Map)['tasks'] as List;
    expect([for (final task in tasks) (task as Map)['title']],
        ['Sent the invoice']);
    final done = tasks.single as Map;
    expect(done['completed_at'], isNotNull);
    expect(done['completed_at_label'], contains(' at '));

    // An open task never claims a completion time, even a reopened one.
    final open = await registry.execute('list_tasks', {'open_only': true});
    for (final task in (open.data as Map)['tasks'] as List) {
      expect((task as Map).containsKey('completed_at'), isFalse);
    }

    final bad = await registry
        .execute('list_tasks', {'completed_since': 'this morning'});
    expect(bad.success, isFalse);
  });

  test('list_schedule labels the time each reminder fires', () async {
    final at = DateTime.now().add(const Duration(hours: 2));
    await registry.execute('create_reminder', {
      'title': 'Car service',
      'remind_at': at.toIso8601String(),
    });
    final result = await registry.execute('list_schedule', {
      'from': DateTime.now().toIso8601String(),
      'to': DateTime.now().add(const Duration(days: 1)).toIso8601String(),
    });
    final reminder =
        ((result.data as Map)['reminders'] as List).single as Map;
    expect(reminder['title'], 'Car service');
    expect(reminder['remind_at_label'], contains(' at '));
  });

  test('recurring task without due date is rejected', () async {
    final result = await registry.execute('create_task', {
      'title': 'No due date',
      'recurrence_rule': 'weekly',
    });
    expect(result.success, isFalse);
  });

  test('weekly scheduled job computes the right next run', () async {
    final created = await registry.execute('create_scheduled_job', {
      'name': 'Weekly review',
      'job_type': 'daily_review',
      'time': '09:00',
      'frequency': 'weekly',
      'weekday': 7, // Sunday
    });
    expect(created.success, isTrue);
    final jobId = (created.data as Map)['id'] as String;
    final job = await JobRepository(database).getById(jobId);
    expect(job!.nextRunAt!.weekday, DateTime.sunday);
    expect(job.nextRunAt!.hour, 9);
    expect(job.nextRunAt!.isAfter(DateTime.now()), isTrue);
  });

  test('interval job runs every N minutes and advances after a run',
      () async {
    final created = await registry.execute('create_scheduled_job', {
      'name': 'Mail sync',
      'job_type': 'email_sync',
      'frequency': 'interval',
      'interval_minutes': 30,
    });
    expect(created.success, isTrue);
    final jobId = (created.data as Map)['id'] as String;
    final repo = JobRepository(database);
    final job = await repo.getById(jobId);
    final untilNext = job!.nextRunAt!.difference(DateTime.now()).inMinutes;
    expect(untilNext, inInclusiveRange(28, 30));

    // After a run, the next occurrence is another interval out.
    final ranAt = DateTime.now();
    await repo.markRan(job, ranAt: ranAt);
    final after = await repo.getById(jobId);
    expect(after!.nextRunAt, ranAt.add(const Duration(minutes: 30)));
  });

  test('a 2-minute email sync interval is accepted', () async {
    final created = await registry.execute('create_scheduled_job', {
      'name': 'Fast mail sync',
      'job_type': 'email_sync',
      'frequency': 'interval',
      'interval_minutes': 2,
    });
    expect(created.success, isTrue);
    final jobId = (created.data as Map)['id'] as String;
    final job = await JobRepository(database).getById(jobId);
    final untilNext = job!.nextRunAt!.difference(DateTime.now()).inSeconds;
    expect(untilNext, inInclusiveRange(60, 120));
  });

  test('interval job without a valid interval_minutes is rejected',
      () async {
    final tooShort = await registry.execute('create_scheduled_job', {
      'name': 'Too eager',
      'job_type': 'email_sync',
      'frequency': 'interval',
      'interval_minutes': 1,
    });
    expect(tooShort.success, isFalse);
    expect(tooShort.error, contains('2'));

    final missing = await registry.execute('create_scheduled_job', {
      'name': 'No interval',
      'job_type': 'email_sync',
      'frequency': 'interval',
    });
    expect(missing.success, isFalse);
    expect(await JobRepository(database).listAll(), isEmpty);
  });

  test('agent can update, evaluate, and roll back its behaviors',
      () async {
    final created = await registry.execute('propose_behavior_change', {
      'title': 'Summary order',
      'behavior_type': 'summary_rule',
      'rule_text': 'v1: meetings first',
      'risk_level': 'Low Risk',
    });
    final behaviorId = (created.data as Map)['behavior_id'] as String;

    final updated = await registry.execute('update_behavior', {
      'behavior_id': behaviorId,
      'rule_text': 'v2: meetings, then overdue tasks',
      'reason': 'user feedback',
    });
    expect(updated.success, isTrue);
    expect((updated.data as Map)['version'], 2);

    final evaluated = await registry.execute('evaluate_behavior', {
      'behavior_id': behaviorId,
      'evaluation_note': 'Worked well this morning',
      'success_score': 5,
    });
    expect(evaluated.success, isTrue);

    final rolledBack =
        await registry.execute('rollback_behavior_version', {
      'behavior_id': behaviorId,
      'version_number': 1,
    });
    expect(rolledBack.success, isTrue);
    expect((rolledBack.data as Map)['rule_text'], 'v1: meetings first');
  });

  test('add_to_phone_calendar queues for approval, never writes directly',
      () async {
    final result = await registry.execute('add_to_phone_calendar', {
      'title': 'Dentist',
      'start_at':
          DateTime.now().add(const Duration(days: 2)).toIso8601String(),
      'location': 'Main St',
    });
    expect(result.success, isTrue);
    expect((result.data as Map)['queued'], isTrue);

    // It is durably logged as Pending - not silently done, not lost.
    final pending = PendingCalendarRepository(database);
    final items = await pending.listPending();
    expect(items, hasLength(1));
    expect(items.single.title, 'Dentist');
    expect(items.single.status, 'Pending');
    expect(items.single.externalEventId, isNull); // nothing written yet
    expect(await pending.pendingCount(), 1);
  });

  test('list_schedule surfaces reminders alongside events', () async {
    final today = DateTime.now();
    // A daily reminder anchored at 09:00 today: occurs today regardless of
    // the current clock time (recurrence is allowed to start in the past).
    final at = DateTime(today.year, today.month, today.day, 9);
    final created = await registry.execute('create_reminder', {
      'title': 'Take meds',
      'remind_at': at.toIso8601String(),
      'recurrence_rule': 'daily',
    });
    expect(created.success, isTrue);

    final listed = await registry.execute('list_schedule', {});
    expect(listed.success, isTrue);
    final reminders = (listed.data as Map)['reminders'] as List;
    expect(reminders, isNotEmpty);
    expect((reminders.first as Map)['title'], 'Take meds');
    expect((reminders.first as Map)['recurrence_rule'], 'daily');
  });

  test('daily review marks the emails it processed as digested', () async {
    final emailRepo = EmailRepository(database);
    final email = await emailRepo.add(
      subject: 'Invoice due',
      sender: 'billing@example.com',
      body: 'Your invoice of \$200 is due next Friday.',
    );
    expect(await emailRepo.undigested(), hasLength(1));

    final created = await registry.execute('create_scheduled_job', {
      'name': 'Morning review',
      'job_type': 'daily_review',
      'time': '07:30',
    });
    final jobId = (created.data as Map)['id'] as String;
    final ran =
        await registry.execute('run_scheduled_job_now', {'id': jobId});
    expect(ran.success, isTrue);

    // The review read the email into the briefing, so it's now digested.
    expect(await emailRepo.undigested(), isEmpty);
    expect((await emailRepo.getById(email.id))!.digested, isTrue);
  });

  test('plain daily summary leaves emails undigested', () async {
    final emailRepo = EmailRepository(database);
    await emailRepo.add(subject: 'FYI', body: 'Just so you know.');

    final created = await registry.execute('create_scheduled_job', {
      'name': 'Morning summary',
      'job_type': 'daily_summary',
      'time': '07:30',
    });
    final jobId = (created.data as Map)['id'] as String;
    await registry.execute('run_scheduled_job_now', {'id': jobId});

    // The plain summary only lists subjects; it doesn't digest them.
    expect(await emailRepo.undigested(), hasLength(1));
  });

  test('search finds matches across types and respects the type filter',
      () async {
    await registry.execute('create_task', {'title': 'Quarterly budget review'});
    await registry.execute('create_reminder', {
      'title': 'Send budget to Sam',
      'remind_at':
          DateTime.now().add(const Duration(hours: 5)).toIso8601String(),
    });
    await EmailRepository(database)
        .add(subject: 'Budget approved', body: 'The budget is approved.');

    final result = await registry.execute('search', {'query': 'budget'});
    expect(result.success, isTrue);
    final types = ((result.data as Map)['results'] as List)
        .map((r) => (r as Map)['type'])
        .toSet();
    expect(types, containsAll(['task', 'reminder', 'email']));

    final tasksOnly = await registry.execute(
        'search', {'query': 'budget', 'types': ['tasks']});
    final onlyTypes = ((tasksOnly.data as Map)['results'] as List)
        .map((r) => (r as Map)['type'])
        .toSet();
    expect(onlyTypes, {'task'});

    final empty = await registry.execute('search', {'query': 'zxqwv'});
    expect((empty.data as Map)['count'], 0);
  });

  test('update_schedule_event moves an event', () async {
    final start = DateTime.now().add(const Duration(days: 1));
    final created = await registry.execute('create_schedule_event', {
      'title': 'Dentist',
      'start_at': start.toIso8601String(),
    });
    final eventId = (created.data as Map)['id'] as String;

    final newStart = start.add(const Duration(hours: 3));
    final moved = await registry.execute('update_schedule_event', {
      'id': eventId,
      'start_at': newStart.toIso8601String(),
      'location': 'Main St clinic',
    });
    expect(moved.success, isTrue);
    expect((moved.data as Map)['location'], 'Main St clinic');
  });

  test('send_email fails helpfully without a configured account',
      () async {
    final result = await registry.execute('send_email', {
      'to': 'someone@example.com',
      'subject': 'Hi',
      'body': 'Test',
    });
    expect(result.success, isFalse);
    expect(result.error, contains('Mail accounts'));
  });

  test('low-risk behavior activates; medium-risk stays pending', () async {
    final low = await registry.execute('propose_behavior_change', {
      'title': 'Meetings first',
      'behavior_type': 'summary_rule',
      'rule_text': 'Show meetings before tasks.',
      'risk_level': 'Low Risk',
    });
    expect(low.success, isTrue);
    expect((low.data as Map)['status'], 'Active');

    final medium = await registry.execute('propose_behavior_change', {
      'title': 'Auto-create reminders',
      'behavior_type': 'workflow_rule',
      'rule_text': 'Create reminders automatically from emails.',
      'risk_level': 'Medium Risk',
    });
    expect(medium.success, isTrue);
    expect((medium.data as Map)['status'], 'Pending');

    final behaviors = BehaviorRepository(database);
    expect(await behaviors.listActive(), hasLength(1));
    expect(await behaviors.listPendingRequests(), hasLength(1));
  });
}
