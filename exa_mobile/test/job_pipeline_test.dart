import 'dart:async';
import 'dart:convert';

import 'package:exa_mobile/agent/behaviors/notification_policy.dart';
import 'package:exa_mobile/agent/memory/models/agent_memory.dart';
import 'package:exa_mobile/agent/orchestrator/agent_intelligence.dart';
import 'package:exa_mobile/agent/orchestrator/agent_orchestrator.dart';
import 'package:exa_mobile/agent/tools/tool_registry.dart';
import 'package:exa_mobile/data/database/app_database.dart';
import 'package:exa_mobile/data/models/scheduled_job.dart';
import 'package:exa_mobile/data/repositories/behavior_repository.dart';
import 'package:exa_mobile/data/repositories/diagnostics_repository.dart';
import 'package:exa_mobile/data/repositories/browser_context_repository.dart';
import 'package:exa_mobile/data/repositories/chat_repository.dart';
import 'package:exa_mobile/data/repositories/dynamic_screen_repository.dart';
import 'package:exa_mobile/data/repositories/email_repository.dart';
import 'package:exa_mobile/data/repositories/idempotency_repository.dart';
import 'package:exa_mobile/data/repositories/job_repository.dart';
import 'package:exa_mobile/data/repositories/mail_account_repository.dart';
import 'package:exa_mobile/data/repositories/pending_calendar_repository.dart';
import 'package:exa_mobile/data/repositories/reminder_repository.dart';
import 'package:exa_mobile/data/repositories/schedule_repository.dart';
import 'package:exa_mobile/data/repositories/settings_repository.dart';
import 'package:exa_mobile/data/repositories/task_repository.dart';
import 'package:exa_mobile/data/repositories/tool_call_repository.dart';
import 'package:exa_mobile/services/ai_client/claude_client.dart';
import 'package:exa_mobile/services/background_jobs/job_runner.dart';
import 'package:exa_mobile/services/browser/browser_bridge.dart';
import 'package:exa_mobile/services/calendar/device_calendar_service.dart';
import 'package:exa_mobile/services/mail/mail_service.dart';
import 'package:exa_mobile/services/notifications/notification_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Background jobs routed through the agent pipeline: a daily_review job
/// runs as a full orchestrator turn (contract, verification, entities,
/// memory, replay trace) and degrades to the legacy deterministic summary
/// when no capable provider is available.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  void mockApiKey(String? key) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (call) async => call.method == 'read' ? key : null,
    );
  }

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      null,
    );
  });

  http.Response json(Map<String, Object?> body) => http.Response(
      jsonEncode(body), 200,
      headers: {'content-type': 'application/json'});

  http.Response endTurn(String text) => json({
        'stop_reason': 'end_turn',
        'content': [
          {'type': 'text', 'text': text},
        ],
      });

  (JobRunner, AppDatabase, AgentIntelligence) buildStack(
      MockClient? mockHttp,
      {NotificationService? notifications}) {
    final database = AppDatabase();
    // A bare NotificationService no-ops in tests; pass a recording one to
    // assert on what a run would have put on the shade.
    notifications ??= NotificationService();
    final runner =
        JobRunner(database: database, notifications: notifications);
    final mailAccounts = MailAccountRepository(database);
    final emails = EmailRepository(database);
    final schedule = ScheduleRepository(database);
    final registry = ToolRegistry(
      tasks: TaskRepository(database),
      reminders: ReminderRepository(database),
      schedule: schedule,
      behaviors: BehaviorRepository(database),
      screens: DynamicScreenRepository(database),
      toolCalls: ToolCallRepository(database),
      notifications: notifications,
      database: database,
      jobs: JobRepository(database),
      jobRunner: runner,
      browserContext: BrowserContextRepository(database),
      emails: emails,
      browserBridge: BrowserBridge(),
      mailAccounts: mailAccounts,
      mail: MailService(accounts: mailAccounts, emails: emails),
      deviceCalendar: DeviceCalendarService(schedule: schedule),
      pendingCalendar: PendingCalendarRepository(database),
      idempotency: IdempotencyRepository(database),
    );
    final intelligence =
        AgentIntelligence.standard(database: database, registry: registry);
    if (mockHttp != null) {
      final orchestrator = AgentOrchestrator(
        client: ClaudeClient(httpClient: mockHttp),
        registry: registry,
        chat: ChatRepository(database),
        behaviors: BehaviorRepository(database),
        settings: SettingsRepository(database),
        intelligence: intelligence,
      );
      runner.orchestratorFactory = () => orchestrator;
    }
    return (runner, database, intelligence);
  }

  test('daily_review runs as a full agent turn through the pipeline',
      () async {
    mockApiKey('sk-test-key');

    String? emailId;
    var loopCalls = 0;
    final mockHttp = MockClient((request) async {
      final decoded =
          (jsonDecode(request.body) as Map).cast<String, Object?>();
      final systemText =
          (((decoded['system'] as List).first as Map)['text'] ?? '') as String;
      if (systemText.contains('completing an already-executed')) {
        return endTurn(jsonEncode({
          'message': 'Daily review: 1 new email from Amy about Business '
              'Central reports; created task: Send Amy a report update. '
              'Nothing on the schedule, no meetings or deadlines found, '
              'nothing else needs attention.',
          'included_outputs': [
            'rundown', 'task_list', 'meeting_list', 'deadline_list',
            'attention_items',
          ],
          'claims': [
            {
              'type': 'task_created',
              'description': 'Send Amy a report update',
            },
            {'type': 'emails_digested', 'description': 'Marked 1 digested'},
          ],
          'includes_failure_report': false,
        }));
      }
      if (decoded['tools'] == null) {
        return endTurn(jsonEncode({
          'domains': ['email', 'tasks', 'calendar'],
          'actions': [
            {'description': 'review_emails', 'required': true},
            {'description': 'create_tasks', 'required': true},
          ],
          'response_outputs': ['rundown', 'task_list'],
          'skill': 'digest_emails',
          'skill_confidence': 0.9,
          'requires_confirmation': false,
          'requires_synthesis': true,
          'requires_verification': true,
        }));
      }
      loopCalls++;
      if (loopCalls == 1) {
        return json({
          'stop_reason': 'tool_use',
          'content': [
            {
              'type': 'tool_use',
              'id': 'toolu_read',
              'name': 'read_email_context',
              'input': {'undigested_only': true},
            },
          ],
        });
      }
      if (loopCalls == 2) {
        return json({
          'stop_reason': 'tool_use',
          'content': [
            {
              'type': 'tool_use',
              'id': 'toolu_task',
              'name': 'create_task',
              'input': {'title': 'Send Amy a report update'},
            },
            {
              'type': 'tool_use',
              'id': 'toolu_mark',
              'name': 'mark_email_digested',
              'input': {
                'ids': [emailId],
              },
            },
          ],
        });
      }
      return endTurn('Reviewed.');
    });

    final (runner, database, intelligence) = buildStack(mockHttp);
    await database.open(overridePath: inMemoryDatabasePath);
    addTearDown(database.close);

    final email = await EmailRepository(database).add(
      subject: 'Business Central reports',
      body: 'Please send an update. - Amy',
      sender: 'Amy <amy@example.com>',
    );
    emailId = email.id;

    final job = await JobRepository(database).create(
      name: 'Morning review',
      jobType: 'daily_review',
      scheduleRule: {'frequency': 'daily', 'hour': 7, 'minute': 0},
    );
    final outcome = await runner.runJob(job);

    expect(outcome.success, isTrue);
    expect(outcome.summary, contains('Amy'));

    // The briefing landed in chat as a scheduled-job message, with NO
    // synthetic user bubble.
    final messages = await ChatRepository(database).recent();
    expect(messages.where((m) => m.role == 'user'), isEmpty);
    final brief = messages.lastWhere((m) => m.role == 'assistant');
    expect(brief.meta?['source'], 'scheduled_job');
    expect(brief.meta?['job_title'], 'Your daily review');

    // Full pipeline artifacts exist: entities and a replay trace.
    final entityTypes = (await database.db.query('agent_entities'))
        .map((row) => row['entity_type'])
        .toSet();
    expect(entityTypes, containsAll(['email', 'person', 'task']));
    // But no diary. A scheduled run is isolated: an episodic record of it
    // ("Request: <the same text every day> - Created task ...") is the best
    // retrieval match for the next identical run, which reads it as news.
    final memories = await intelligence.memories.listLive();
    expect(
        memories.where((memory) =>
            memory.type == AgentMemoryType.episodic ||
            memory.type == AgentMemoryType.working),
        isEmpty);
    final trace = await intelligence.replayTraces.latest();
    expect(trace, isNotNull);
    expect(trace!.verificationResult['passed'], isTrue);

    // Real work happened: task created, email digested, run logged.
    final storedEmail = await EmailRepository(database).getById(email.id);
    expect(storedEmail!.digested, isTrue);
    final runs = await database.db.query('job_runs');
    expect(runs.single['status'], isNot('Running'));
  });

  group('a briefing is checked against its own inputs', () {
    /// The AI briefing path: no orchestrator, so `daily_review` falls through
    /// to `_runDailySummary(useAi: true)`, which is where a model paraphrases
    /// deterministic facts. Nobody is watching a background job, and for most
    /// users this notification is the only thing they read about the day.
    Future<(JobRunner, AppDatabase)> briefingRunner(String briefing) async {
      final database = AppDatabase();
      final runner = JobRunner(
        database: database,
        notifications: NotificationService(),
        claudeClient: ClaudeClient(
            httpClient: MockClient((_) async => endTurn(briefing))),
      );
      await database.open(overridePath: inMemoryDatabasePath);
      await TaskRepository(database).create(
        title: 'Yesterday task',
        dueAt: DateTime.now().subtract(const Duration(days: 1)),
      );
      return (runner, database);
    }

    Future<JobRunOutcome> runReview(
        JobRunner runner, AppDatabase database) async {
      final job = await JobRepository(database).create(
        name: 'Morning review',
        jobType: 'daily_review',
        scheduleRule: {'frequency': 'daily', 'hour': 7, 'minute': 0},
      );
      return runner.runJob(job);
    }

    test('one that invents a date is discarded for the deterministic text',
        () async {
      mockApiKey('sk-test-key');
      final (runner, database) = await briefingRunner(
          'All clear today. Your renewal lands on March 3, 2026.');
      addTearDown(database.close);

      final outcome = await runReview(runner, database);

      expect(outcome.summary, isNot(contains('March 3, 2026')),
          reason: 'a confident briefing with the wrong day in it is worse '
              'than a plainer correct one');
      expect(outcome.summary, contains('Overdue'),
          reason: 'the deterministic summary still reports the facts');
      final codes = (await DiagnosticsRepository(database).recent(limit: 100))
          .map((event) => event.code);
      expect(codes, contains('BRIEFING_DATE_FABRICATED'));
    });

    test('one that states no date at all is kept', () async {
      mockApiKey('sk-test-key');
      final (runner, database) =
          await briefingRunner('One task slipped yesterday - worth 10 minutes.');
      addTearDown(database.close);

      final outcome = await runReview(runner, database);

      expect(outcome.summary, contains('worth 10 minutes'));
      final codes = (await DiagnosticsRepository(database).recent(limit: 100))
          .map((event) => event.code);
      expect(codes, isNot(contains('BRIEFING_DATE_FABRICATED')));
    });
  });

  test('daily_review falls back to the deterministic summary when no '
      'provider is available', () async {
    mockApiKey(null); // Remote provider without a key.

    // The mock throws if any HTTP call is attempted - the fallback path
    // must never touch the network.
    final mockHttp = MockClient((request) async {
      throw StateError('The fallback path must not call the model');
    });

    final (runner, database, _) = buildStack(mockHttp);
    await database.open(overridePath: inMemoryDatabasePath);
    addTearDown(database.close);

    await TaskRepository(database).create(
      title: 'Yesterday task',
      dueAt: DateTime.now().subtract(const Duration(days: 1)),
    );

    final job = await JobRepository(database).create(
      name: 'Morning review',
      jobType: 'daily_review',
      scheduleRule: {'frequency': 'daily', 'hour': 7, 'minute': 0},
    );
    final outcome = await runner.runJob(job);

    expect(outcome.success, isTrue);
    expect(outcome.summary, contains('Overdue'),
        reason: 'the deterministic summary still reports the facts');
  });

  test('an ambiguous instruction does not stop an unattended job working',
      () async {
    // The outage: the user's every-30-minutes digest says "Sync new emails and
    // Digest them", the pronoun tripped the bare-reference rule, "email" made
    // the turn high risk, and the whole job went read-only to ask a question
    // nobody could answer - sync_emails refused with awaiting_clarification,
    // run after run, reporting "No emails were digested this time".
    mockApiKey('sk-test-key');

    var loopCalls = 0;
    final mockHttp = MockClient((request) async {
      final decoded = (jsonDecode(request.body) as Map).cast<String, Object?>();
      final systemText =
          (((decoded['system'] as List).first as Map)['text'] ?? '') as String;
      if (decoded['tools'] == null) {
        // Router and the finalization calls.
        return systemText.contains('ONLY valid JSON')
            ? endTurn(jsonEncode({
                'domains': ['email'],
                'required_tools': ['sync_emails'],
                'actions': [
                  {'description': 'sync_emails', 'required': true},
                ],
                'response_outputs': ['summary'],
                'requires_confirmation': false,
                'requires_synthesis': true,
                'risk': 'high',
              }))
            : endTurn('{"message": "Synced your mail.", '
                '"included_outputs": ["summary"]}');
      }
      loopCalls++;
      return loopCalls == 1
          ? json({
              'stop_reason': 'tool_use',
              'content': [
                {
                  'type': 'tool_use',
                  'id': 'toolu_1',
                  'name': 'sync_emails',
                  'input': <String, Object?>{},
                },
              ],
            })
          : endTurn('Done.');
    });

    final (runner, database, _) = buildStack(mockHttp);
    await database.open(overridePath: inMemoryDatabasePath);
    addTearDown(database.close);

    final job = await JobRepository(database).create(
      name: 'Digest Emails Every 30 Minutes',
      jobType: 'agent_task',
      // Opens on the pronoun on purpose, so the in-request-antecedent rule
      // does NOT rescue it and this test isolates the unattended gate.
      description: 'Digest them and mark them digested when complete.',
      scheduleRule: {'frequency': 'interval', 'interval_minutes': 30},
    );
    final outcome = await runner.runJob(job);

    expect(outcome.success, isTrue);
    // The tool actually ran. Before the fix the gate refused it with
    // `awaiting_clarification` and the job reported doing nothing.
    final calls = await database.db.query('tool_calls',
        where: 'tool_name = ?', whereArgs: ['sync_emails']);
    expect(calls, hasLength(1));
    expect(calls.single['status'], isNot('denied'));
  });

  test('an agent_task job runs its instructions with the user\'s behaviors',
      () async {
    mockApiKey('sk-test-key');

    final systemPrompts = <String>[];
    var loopCalls = 0;
    final mockHttp = MockClient((request) async {
      final decoded =
          (jsonDecode(request.body) as Map).cast<String, Object?>();
      final systemText =
          (((decoded['system'] as List).first as Map)['text'] ?? '') as String;
      systemPrompts.add(systemText);
      // Both no-tool finalization calls (synthesis and its one repair
      // attempt) say this; either may write the final message.
      if (systemText.contains('Do not call tools.')) {
        return endTurn(jsonEncode({
          'message': 'One thing slipped this week; I made a task for it.',
          'included_outputs': ['rundown'],
          'claims': [
            {'type': 'task_created', 'description': 'Chase the invoice'},
          ],
          'includes_failure_report': false,
        }));
      }
      if (decoded['tools'] == null) {
        return endTurn(jsonEncode({
          'domains': ['tasks'],
          'actions': [
            {'description': 'create_tasks', 'required': true},
          ],
          'response_outputs': ['rundown'],
          'requires_confirmation': false,
          'requires_synthesis': true,
          'requires_verification': true,
        }));
      }
      loopCalls++;
      if (loopCalls == 1) {
        return json({
          'stop_reason': 'tool_use',
          'content': [
            {
              'type': 'tool_use',
              'id': 'toolu_task',
              'name': 'create_task',
              'input': {'title': 'Chase the invoice'},
            },
          ],
        });
      }
      return endTurn('Reviewed the week.');
    });

    final (runner, database, _) = buildStack(mockHttp);
    await database.open(overridePath: inMemoryDatabasePath);
    addTearDown(database.close);

    await BehaviorRepository(database).createActive(
      title: 'Two bullets',
      behaviorType: 'preference_rule',
      ruleText: 'Always answer in at most two short bullet points.',
    );

    final job = await JobRepository(database).create(
      name: 'Weekly slip check',
      jobType: 'agent_task',
      description: 'List what slipped this week.',
      scheduleRule: {'type': 'weekly', 'weekday': 5, 'time': '17:00'},
    );
    final outcome = await runner.runJob(job);

    expect(outcome.success, isTrue);
    expect(outcome.summary, contains('slipped this week'));
    // The job's own instructions drove the turn, not a fixed prompt.
    expect(await TaskRepository(database).list(), hasLength(1));

    // Both the action phase and the call that writes the final message get
    // the rule - the finalization call is where it used to be dropped.
    final actionPrompt =
        systemPrompts.firstWhere((p) => p.contains('You are Exa'));
    final synthesisPrompt = systemPrompts
        .firstWhere((p) => p.contains('completing an already-executed'));
    expect(actionPrompt, contains('two short bullet points'));
    expect(synthesisPrompt, contains('two short bullet points'));

    // Nobody is watching a scheduled run, and the agent is told so.
    expect(actionPrompt, contains('running unattended'));

    final brief = (await ChatRepository(database).recent())
        .lastWhere((m) => m.role == 'assistant');
    expect(brief.meta?['job_title'], 'Weekly slip check');
  });

  test('a snapshot job keeps the rules it was created with', () async {
    mockApiKey('sk-test-key');

    final systemPrompts = <String>[];
    final mockHttp = MockClient((request) async {
      final decoded =
          (jsonDecode(request.body) as Map).cast<String, Object?>();
      systemPrompts.add(
          (((decoded['system'] as List).first as Map)['text'] ?? '')
              as String);
      if (decoded['tools'] == null &&
          !systemPrompts.last.contains('Do not call tools.')) {
        return endTurn(jsonEncode({
          'domains': ['tasks'],
          'actions': <Object>[],
          'response_outputs': <Object>[],
          'requires_confirmation': false,
          'requires_synthesis': false,
          'requires_verification': false,
        }));
      }
      return endTurn('Done.');
    });

    final (runner, database, _) = buildStack(mockHttp);
    await database.open(overridePath: inMemoryDatabasePath);
    addTearDown(database.close);

    final behaviors = BehaviorRepository(database);
    final original = await behaviors.createActive(
      title: 'Original',
      behaviorType: 'preference_rule',
      ruleText: 'Original rule text.',
    );

    // The job pins the rules as they are now.
    final job = await JobRepository(database).create(
      name: 'Locked task',
      jobType: 'agent_task',
      description: 'Do the pinned thing.',
      scheduleRule: {'type': 'daily', 'time': '07:00'},
      behaviorMode: 'snapshot',
      behaviorSnapshot: jsonEncode([
        for (final rule in await behaviors.listActive()) rule.toRow(),
      ]),
    );

    // The user then changes their mind.
    await behaviors.updateRuleText(original.id, 'Rewritten rule text.');

    await runner.runJob(job);

    final actionPrompt =
        systemPrompts.firstWhere((p) => p.contains('You are Exa'));
    expect(actionPrompt, contains('Original rule text'));
    expect(actionPrompt, isNot(contains('Rewritten rule text')));
  });

  test('an agent_task job with no provider fails with a readable reason',
      () async {
    mockApiKey(null);

    final (runner, database, _) = buildStack(null);
    await database.open(overridePath: inMemoryDatabasePath);
    addTearDown(database.close);

    final job = await JobRepository(database).create(
      name: 'Weekly slip check',
      jobType: 'agent_task',
      description: 'List what slipped this week.',
      scheduleRule: {'type': 'weekly', 'weekday': 5, 'time': '17:00'},
    );
    final outcome = await runner.runJob(job);

    expect(outcome.success, isFalse);
    expect(outcome.summary, contains('AI provider'));
    // First failure schedules a retry rather than giving up.
    final runs = await database.db.query('job_runs');
    expect(runs.single['status'], JobRun.statusRetryWait);
    expect(runs.single['attempt'], 1);
    // And the reason is visible rather than swallowed.
    final events = await DiagnosticsRepository(database).recent();
    expect(events.map((e) => e.code), contains('JOB_FAILED'));
  });

  test('a job that keeps failing is dead-lettered, not retried forever',
      () async {
    mockApiKey(null);

    final (runner, database, _) = buildStack(null);
    await database.open(overridePath: inMemoryDatabasePath);
    addTearDown(database.close);

    final repository = JobRepository(database);
    final job = await repository.create(
      name: 'Doomed task',
      jobType: 'agent_task',
      description: 'Something that cannot run.',
      scheduleRule: {'type': 'interval', 'minutes': 5},
      maxAttempts: 2,
    );

    // Re-read the job each time, exactly as the scheduler does. A failure
    // moves next_run_at to the backoff time, so a runner working from a
    // stale object would compute a different occurrence and silently open a
    // fresh attempt-1 row every round - which is how this went unnoticed.
    for (var i = 0; i < 2; i++) {
      final current = (await repository.getById(job.id))!;
      await runner.runJob(current, triggerSource: 'worker');
    }

    final runs = await repository.listRuns(job.id);
    expect(runs, hasLength(1), reason: 'one row per occurrence, not attempt');
    expect(runs.single.status, JobRun.statusDeadLetter);
    expect(runs.single.attempt, 2, reason: 'attempts accumulate');

    // The abandoned occurrence does not block the schedule: the job moves on
    // and gets a fresh occurrence next time it comes due.
    final third = (await repository.getById(job.id))!;
    await runner.runJob(third, triggerSource: 'worker');
    final afterThird = await repository.listRuns(job.id);
    expect(afterThird, hasLength(2));
    expect(afterThird.first.attempt, 1);
  });

  test('the same occurrence firing twice runs once', () async {
    final (runner, database, _) = buildStack(null);
    await database.open(overridePath: inMemoryDatabasePath);
    addTearDown(database.close);

    await TaskRepository(database).create(
      title: 'Yesterday task',
      dueAt: DateTime.now().subtract(const Duration(days: 1)),
    );
    final job = await JobRepository(database).create(
      name: 'Overdue sweep',
      jobType: 'task_cleanup',
      scheduleRule: {'type': 'daily', 'time': '07:00'},
    );

    // The exact alarm and the WorkManager tick both reach the same job.
    final first = await runner.runJob(job, triggerSource: 'alarm');
    final second = await runner.runJob(job, triggerSource: 'worker');

    expect(first.wasSkipped, isFalse);
    expect(second.wasSkipped, isTrue,
        reason: 'the second wake-up must not re-run the occurrence');
    final runs = await JobRepository(database).listRuns(job.id);
    expect(runs, hasLength(1));
    expect(runs.single.status, JobRun.statusSuccess);
  });

  test('a run abandoned by a killed isolate is taken over, not duplicated',
      () async {
    final (runner, database, _) = buildStack(null);
    await database.open(overridePath: inMemoryDatabasePath);
    addTearDown(database.close);

    final repository = JobRepository(database);
    final job = await repository.create(
      name: 'Overdue sweep',
      jobType: 'task_cleanup',
      scheduleRule: {'type': 'daily', 'time': '07:00'},
    );

    // Simulate a process death: claimed, still Running, lease expired.
    final claimed = await repository.claimRun(job, triggerSource: 'worker');
    expect(claimed, isNotNull);
    await database.db.update(
      'job_runs',
      {
        'lease_until': DateTime.now()
            .subtract(const Duration(minutes: 1))
            .toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [claimed!.id],
    );

    final outcome = await runner.runJob(job, triggerSource: 'worker');
    expect(outcome.wasSkipped, isFalse);
    final runs = await repository.listRuns(job.id);
    expect(runs, hasLength(1), reason: 'taken over, not a second row');
    expect(runs.single.attempt, 2);
    expect(runs.single.status, JobRun.statusSuccess);
  });

  test('a run interrupted on a past occurrence is closed out, not counted '
      'forever', () async {
    final (runner, database, _) = buildStack(null);
    await database.open(overridePath: inMemoryDatabasePath);
    addTearDown(database.close);

    final repository = JobRepository(database);
    final created = await repository.create(
      name: 'Chat digest',
      jobType: 'task_cleanup',
      scheduleRule: {'type': 'interval', 'minutes': 5},
    );
    // The job has been due for an hour; a run claimed back then was killed
    // with its isolate: still Running, lease long expired, and its
    // occurrence has since been replaced by newer ones.
    final hourAgo = DateTime.now().subtract(const Duration(hours: 1));
    await database.db.update(
      'scheduled_jobs',
      {'next_run_at': hourAgo.toIso8601String()},
      where: 'id = ?',
      whereArgs: [created.id],
    );
    final job = (await repository.getById(created.id))!;
    final killed =
        await repository.claimRun(job, now: hourAgo, triggerSource: 'worker');
    expect(killed, isNotNull);
    expect(await repository.staleRuns(), hasLength(1));

    await runner.runDueJobs(triggerSource: 'worker');

    expect(await repository.staleRuns(), isEmpty);
    final runs = await repository.listRuns(job.id);
    final old = runs.firstWhere((run) => run.id == killed!.id);
    expect(old.status, JobRun.statusFailed);
    expect(old.errorCode, 'INTERRUPTED');
    // The current occurrence still ran, on its own row.
    expect(runs.where((run) => run.status == JobRun.statusSuccess),
        hasLength(1));
    final codes = (await DiagnosticsRepository(database).recent())
        .map((event) => event.code);
    expect(codes, contains('JOB_RUN_INTERRUPTED'));
  });

  test('a worker with no budget left defers the rest to the next wake-up',
      () async {
    final (runner, database, _) = buildStack(null);
    await database.open(overridePath: inMemoryDatabasePath);
    addTearDown(database.close);

    final repository = JobRepository(database);
    final job = await repository.create(
      name: 'Overdue sweep',
      jobType: 'task_cleanup',
      scheduleRule: {'type': 'interval', 'minutes': 5},
    );
    await database.db.update(
      'scheduled_jobs',
      {
        'next_run_at': DateTime.now()
            .subtract(const Duration(minutes: 1))
            .toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [job.id],
    );

    final executed =
        await runner.runDueJobs(triggerSource: 'worker', budget: Duration.zero);

    expect(executed, 0);
    expect(await repository.listRuns(job.id), isEmpty,
        reason: 'not started and not failed - simply left for later');
    final codes = (await DiagnosticsRepository(database).recent())
        .map((event) => event.code);
    expect(codes, contains('JOB_DEFERRED_NO_TIME'));
  });

  test('a run that would outlive the worker budget is cut off and retried',
      () async {
    mockApiKey('sk-test-key');
    // A model that never answers: the turn can only end by timing out.
    final never = MockClient((request) => Completer<http.Response>().future);
    final (runner, database, _) = buildStack(never);
    await database.open(overridePath: inMemoryDatabasePath);
    addTearDown(database.close);

    final repository = JobRepository(database);
    final job = await repository.create(
      name: 'Slow digest',
      jobType: 'agent_task',
      description: 'Read everything and summarize it.',
      scheduleRule: {'type': 'interval', 'minutes': 5},
    );

    final outcome = await runner.runJob(job,
        triggerSource: 'worker', timeLimit: const Duration(milliseconds: 300));

    expect(outcome.success, isFalse);
    expect(outcome.summary, contains('background time'));
    final run = (await repository.listRuns(job.id)).single;
    expect(run.status, JobRun.statusRetryWait,
        reason: 'cut off by the runner, so recorded and retried - not left '
            'Running for a dead isolate');
    expect(run.errorCode, 'JOB_TIMEOUT');
    expect(run.leaseUntil, isNull);
  });

  test('an agent_task job without instructions fails rather than doing '
      'nothing', () async {
    final (runner, database, _) = buildStack(null);
    await database.open(overridePath: inMemoryDatabasePath);
    addTearDown(database.close);

    final job = await JobRepository(database).create(
      name: 'Empty task',
      jobType: 'agent_task',
      scheduleRule: {'type': 'daily', 'time': '07:00'},
    );
    final outcome = await runner.runJob(job);

    expect(outcome.success, isFalse);
    expect(outcome.summary, contains('no instructions'));
  });

  group('editing a job', () {
    test('a new schedule takes effect from now, not the old time', () async {
      final (_, database, _) = buildStack(null);
      await database.open(overridePath: inMemoryDatabasePath);
      addTearDown(database.close);

      final repository = JobRepository(database);
      final job = await repository.create(
        name: 'Morning review',
        jobType: 'daily_review',
        scheduleRule: {'type': 'daily', 'time': '07:30'},
      );
      final originalNext = job.nextRunAt;

      final updated = await repository.update(
        job.id,
        name: 'Evening review',
        scheduleRule: {'type': 'daily', 'time': '18:00'},
      );

      expect(updated!.name, 'Evening review');
      expect(updated.scheduleRule['time'], '18:00');
      // Recomputed, or the job would fire once more at the old time.
      expect(updated.nextRunAt, isNot(originalNext));
      expect(updated.nextRunAt!.hour, 18);
    });

    test('an interval job keeps its cadence through an unrelated edit',
        () async {
      final (_, database, _) = buildStack(null);
      await database.open(overridePath: inMemoryDatabasePath);
      addTearDown(database.close);

      final repository = JobRepository(database);
      // The 2-minute sync: a preset-only interval control would silently
      // rewrite this to 30 minutes the moment someone opened the editor.
      final job = await repository.create(
        name: 'Email sync every 2 minutes',
        jobType: 'email_sync',
        scheduleRule: {'type': 'interval', 'minutes': 2},
      );

      final renamed = await repository.update(job.id, name: 'Mail sync');
      expect(renamed!.name, 'Mail sync');
      expect(renamed.scheduleRule['minutes'], 2);
      expect(renamed.scheduleRule['type'], 'interval');
    });

    test('fields left out are not disturbed', () async {
      final (_, database, _) = buildStack(null);
      await database.open(overridePath: inMemoryDatabasePath);
      addTearDown(database.close);

      final repository = JobRepository(database);
      final job = await repository.create(
        name: 'Weekly slip check',
        jobType: 'agent_task',
        description: 'List what slipped.',
        scheduleRule: {'type': 'weekly', 'weekday': 5, 'time': '17:00'},
        behaviorMode: 'snapshot',
        missedRunPolicy: 'skip',
        maxAttempts: 5,
      );

      final updated = await repository.update(job.id, name: 'Slip check');
      expect(updated!.description, 'List what slipped.');
      expect(updated.behaviorMode, 'snapshot');
      expect(updated.missedRunPolicy, 'skip');
      expect(updated.maxAttempts, 5);
      expect(updated.jobType, 'agent_task');
    });

    test('editing an unknown job reports it rather than creating one',
        () async {
      final (_, database, _) = buildStack(null);
      await database.open(overridePath: inMemoryDatabasePath);
      addTearDown(database.close);

      expect(await JobRepository(database).update('nope', name: 'x'), isNull);
      expect(await JobRepository(database).listAll(), isEmpty);
    });
  });

  test('a sync that changes nothing says nothing, however often it runs',
      () async {
    final (runner, database, _) = buildStack(null);
    await database.open(overridePath: inMemoryDatabasePath);
    addTearDown(database.close);

    // The user asked to hear about jobs, so the only thing keeping this
    // quiet is that nothing happened.
    await BehaviorRepository(database).createActive(
      title: 'Keep me posted',
      behaviorType: 'summary_rule',
      ruleText: 'Tell me what you did.',
    );
    final job = await JobRepository(database).create(
      name: 'Email sync every 2 minutes',
      jobType: 'email_sync',
      scheduleRule: {'type': 'interval', 'minutes': 2},
    );

    // No accounts configured: nothing fetched, nothing changed.
    for (var i = 0; i < 5; i++) {
      final current = (await JobRepository(database).getById(job.id))!;
      await runner.runJob(current, triggerSource: 'worker');
    }

    expect(await ChatRepository(database).recent(), isEmpty,
        reason: 'polling and finding nothing is not news');
  });

  test('a behavior armed for new mail digests the backlog', () async {
    mockApiKey('sk-test-key');

    final prompts = <String>[];
    final mockHttp = MockClient((request) async {
      final decoded =
          (jsonDecode(request.body) as Map).cast<String, Object?>();
      prompts.add(jsonEncode(decoded['messages']));
      final systemText =
          (((decoded['system'] as List).first as Map)['text'] ?? '') as String;
      if (systemText.contains('Do not call tools.')) {
        return endTurn(jsonEncode({
          'message': 'Digested 1 email.',
          'included_outputs': ['rundown'],
          'claims': <Object>[],
          'includes_failure_report': false,
        }));
      }
      if (decoded['tools'] == null) {
        return endTurn(jsonEncode({
          'domains': ['email'],
          'actions': <Object>[],
          'response_outputs': <Object>[],
          'requires_confirmation': false,
          'requires_synthesis': false,
          'requires_verification': false,
        }));
      }
      // Reads first, as a digesting model does. A run that calls no tool
      // at all is a run that did nothing: it is failed, not closed out.
      if (!jsonEncode(decoded['messages']).contains('tool_result')) {
        return json({
          'stop_reason': 'tool_use',
          'content': [
            {
              'type': 'tool_use',
              'id': 'toolu_read',
              'name': 'read_email_context',
              'input': {'undigested_only': true, 'limit': 15},
            },
          ],
        });
      }
      return endTurn('Digested.');
    });

    final (runner, database, _) = buildStack(mockHttp);
    await database.open(overridePath: inMemoryDatabasePath);
    addTearDown(database.close);

    // Mail downloaded earlier and never processed - the backlog a rule that
    // fires only on arrival would never pick up.
    await EmailRepository(database).add(
      subject: 'Invoice due',
      body: 'Please pay by Friday.',
      sender: 'billing@example.com',
    );

    await BehaviorRepository(database).createActive(
      title: 'Digest mail as it arrives',
      behaviorType: 'integration_rule',
      ruleText: 'When new email arrives, digest it.',
      params: {
        'trigger': {'on': 'new_mail', 'action': 'digest'},
      },
    );

    final job = await JobRepository(database).create(
      name: 'Email sync every 2 minutes',
      jobType: 'email_sync',
      scheduleRule: {'type': 'interval', 'minutes': 2},
    );
    final outcome = await runner.runJob(job);

    expect(outcome.success, isTrue);
    expect(outcome.summary, contains('on behalf of'));
    expect(jsonEncode(prompts), contains('Digest my email'),
        reason: 'the rule started an agent turn, not just worded a report');
    // The turn is told to work in one bounded batch rather than loading the
    // whole backlog, which is what exhausted the context before.
    expect(jsonEncode(prompts), contains('do NOT try to read them all'));
    // The mock never calls mark_email_digested, but the batch it was handed
    // is closed out anyway, so the queue really does move.
    expect(await EmailRepository(database).countUndigested(), 0);
  });

  test('emails read by a digest run do not stay new when the model forgets '
      'to mark them', () async {
    mockApiKey('sk-test-key');

    // A turn that reads and analyses but never calls mark_email_digested -
    // the exact behaviour of a smaller model, which leaves the same batch
    // to be re-analysed on every run while the backlog never moves.
    final mockHttp = MockClient((request) async {
      final decoded =
          (jsonDecode(request.body) as Map).cast<String, Object?>();
      final systemText =
          (((decoded['system'] as List).first as Map)['text'] ?? '') as String;
      if (systemText.contains('Do not call tools.')) {
        return endTurn(jsonEncode({
          'message': 'Read them all and pulled out the deadlines.',
          'included_outputs': ['rundown'],
          'claims': <Object>[],
          'includes_failure_report': false,
        }));
      }
      if (decoded['tools'] == null) {
        return endTurn(jsonEncode({
          'domains': ['email'],
          'actions': <Object>[],
          'response_outputs': <Object>[],
          'requires_confirmation': false,
          'requires_synthesis': false,
          'requires_verification': false,
        }));
      }
      // Reads first, as a digesting model does. A run that calls no tool
      // at all is a run that did nothing: it is failed, not closed out.
      if (!jsonEncode(decoded['messages']).contains('tool_result')) {
        return json({
          'stop_reason': 'tool_use',
          'content': [
            {
              'type': 'tool_use',
              'id': 'toolu_read',
              'name': 'read_email_context',
              'input': {'undigested_only': true, 'limit': 15},
            },
          ],
        });
      }
      return endTurn('Analysed the batch.');
    });

    final (runner, database, _) = buildStack(mockHttp);
    await database.open(overridePath: inMemoryDatabasePath);
    addTearDown(database.close);

    final emailRepo = EmailRepository(database);
    for (var i = 0; i < 3; i++) {
      await emailRepo.add(subject: 'Message $i', body: 'Body $i');
    }
    await BehaviorRepository(database).createActive(
      title: 'Digest mail as it arrives',
      behaviorType: 'integration_rule',
      ruleText: 'When new email arrives, digest it.',
      params: {
        'trigger': {'on': 'new_mail', 'action': 'digest'},
      },
    );
    final job = await JobRepository(database).create(
      name: 'Email sync',
      jobType: 'email_sync',
      scheduleRule: {'type': 'interval', 'minutes': 2},
    );

    await runner.runJob(job);

    // The app read them, so the app closes them out - otherwise the next
    // run picks up the identical batch forever.
    expect(await emailRepo.countUndigested(), 0);
    // And it is visible rather than silently papered over.
    final events = await DiagnosticsRepository(database).recent();
    expect(events.map((e) => e.code), contains('DIGEST_NOT_MARKED_BY_MODEL'));
  });

  test('a digest run never marks mail it was not given', () async {
    mockApiKey('sk-test-key');

    final mockHttp = MockClient((request) async {
      final decoded =
          (jsonDecode(request.body) as Map).cast<String, Object?>();
      final systemText =
          (((decoded['system'] as List).first as Map)['text'] ?? '') as String;
      if (systemText.contains('Do not call tools.')) {
        return endTurn(jsonEncode({
          'message': 'Done.',
          'included_outputs': <Object>[],
          'claims': <Object>[],
          'includes_failure_report': false,
        }));
      }
      if (decoded['tools'] == null) {
        return endTurn(jsonEncode({
          'domains': ['email'],
          'actions': <Object>[],
          'response_outputs': <Object>[],
          'requires_confirmation': false,
          'requires_synthesis': false,
          'requires_verification': false,
        }));
      }
      // Reads first, as a digesting model does. A run that calls no tool
      // at all is a run that did nothing: it is failed, not closed out.
      if (!jsonEncode(decoded['messages']).contains('tool_result')) {
        return json({
          'stop_reason': 'tool_use',
          'content': [
            {
              'type': 'tool_use',
              'id': 'toolu_read',
              'name': 'read_email_context',
              'input': {'undigested_only': true, 'limit': 5},
            },
          ],
        });
      }
      return endTurn('Analysed.');
    });

    final (runner, database, _) = buildStack(mockHttp);
    await database.open(overridePath: inMemoryDatabasePath);
    addTearDown(database.close);

    final emailRepo = EmailRepository(database);
    for (var i = 0; i < 20; i++) {
      await emailRepo.add(subject: 'Message $i', body: 'Body $i');
    }
    await BehaviorRepository(database).createActive(
      title: 'Digest mail',
      behaviorType: 'integration_rule',
      ruleText: 'When new email arrives, digest it.',
      params: {
        'trigger': {'on': 'new_mail', 'action': 'digest', 'max_items': 5},
      },
    );
    final job = await JobRepository(database).create(
      name: 'Email sync',
      jobType: 'email_sync',
      scheduleRule: {'type': 'interval', 'minutes': 2},
    );

    await runner.runJob(job);

    // Only the five it was handed; the rest wait for the next run.
    expect(await emailRepo.countUndigested(), 15);
  });

  test('a trigger paces itself instead of firing on every 2-minute sync',
      () async {
    mockApiKey('sk-test-key');

    var turns = 0;
    final mockHttp = MockClient((request) async {
      final decoded =
          (jsonDecode(request.body) as Map).cast<String, Object?>();
      final systemText =
          (((decoded['system'] as List).first as Map)['text'] ?? '') as String;
      // One per turn: the first loop call, before any tool has answered.
      if (systemText.contains('You are Exa') &&
          !jsonEncode(decoded['messages']).contains('tool_result')) {
        turns++;
      }
      if (systemText.contains('Do not call tools.')) {
        return endTurn(jsonEncode({
          'message': 'Digested.',
          'included_outputs': <Object>[],
          'claims': <Object>[],
          'includes_failure_report': false,
        }));
      }
      if (decoded['tools'] == null) {
        return endTurn(jsonEncode({
          'domains': ['email'],
          'actions': <Object>[],
          'response_outputs': <Object>[],
          'requires_confirmation': false,
          'requires_synthesis': false,
          'requires_verification': false,
        }));
      }
      // Reads first, as a digesting model does. A run that calls no tool
      // at all is a run that did nothing: it is failed, not closed out.
      if (!jsonEncode(decoded['messages']).contains('tool_result')) {
        return json({
          'stop_reason': 'tool_use',
          'content': [
            {
              'type': 'tool_use',
              'id': 'toolu_read',
              'name': 'read_email_context',
              'input': {'undigested_only': true, 'limit': 15},
            },
          ],
        });
      }
      return endTurn('Digested.');
    });

    final (runner, database, _) = buildStack(mockHttp);
    await database.open(overridePath: inMemoryDatabasePath);
    addTearDown(database.close);

    await EmailRepository(database).add(subject: 'One', body: 'Body');
    await BehaviorRepository(database).createActive(
      title: 'Digest mail as it arrives',
      behaviorType: 'integration_rule',
      ruleText: 'When new email arrives, digest it.',
      params: {
        'trigger': {
          'on': 'new_mail',
          'action': 'digest',
          'min_interval_minutes': 30,
        },
      },
    );
    final job = await JobRepository(database).create(
      name: 'Email sync every 2 minutes',
      jobType: 'email_sync',
      scheduleRule: {'type': 'interval', 'minutes': 2},
    );

    for (var i = 0; i < 4; i++) {
      final current = (await JobRepository(database).getById(job.id))!;
      await runner.runJob(current, triggerSource: 'worker');
    }

    expect(turns, 1,
        reason: 'a 2-minute sync must not start a model turn every 2 minutes');
  });

  group('a recurring job that finds nothing new', () {
    /// The model side of a mail check: the router plans sync + read, the loop
    /// runs both in one go, and the final message is [finalMessage].
    MockClient mailCheckMock(String finalMessage) {
      var loopCalls = 0;
      return MockClient((request) async {
        final decoded =
            (jsonDecode(request.body) as Map).cast<String, Object?>();
        final systemText =
            (((decoded['system'] as List).first as Map)['text'] ?? '')
                as String;
        if (systemText.contains('Do not call tools.')) {
          return endTurn(jsonEncode({
            'message': finalMessage,
            'included_outputs': ['confirmation'],
            'claims': <Object>[],
            'includes_failure_report': false,
          }));
        }
        if (decoded['tools'] == null) {
          return endTurn(jsonEncode({
            'domains': ['email'],
            'actions': [
              {'description': 'sync_emails', 'required': true},
              {'description': 'read_email_context', 'required': true},
            ],
            'response_outputs': ['confirmation'],
            'requires_confirmation': false,
            'requires_synthesis': true,
            'requires_verification': true,
          }));
        }
        loopCalls++;
        if (loopCalls == 1) {
          return json({
            'stop_reason': 'tool_use',
            'content': [
              {
                'type': 'tool_use',
                'id': 'toolu_sync',
                'name': 'sync_emails',
                'input': <String, Object?>{},
              },
              {
                'type': 'tool_use',
                'id': 'toolu_read',
                'name': 'read_email_context',
                'input': {'undigested_only': true},
              },
            ],
          });
        }
        return endTurn('Checked.');
      });
    }

    Future<ScheduledJob> mailCheckJob(AppDatabase database) =>
        JobRepository(database).create(
          name: 'Mail check',
          jobType: 'agent_task',
          description: 'Check my mail for new messages.',
          scheduleRule: {'frequency': 'interval', 'interval_minutes': 5},
        );

    test('posts no chat card and no notification, but the run is logged',
        () async {
      mockApiKey('sk-test-key');
      final notifications = _RecordingNotifications();
      final (runner, database, _) = buildStack(
        mailCheckMock('Checked your mail - nothing new since last time.'),
        notifications: notifications,
      );
      await database.open(overridePath: inMemoryDatabasePath);
      addTearDown(database.close);

      final outcome = await runner.runJob(await mailCheckJob(database));

      expect(outcome.success, isTrue);
      // The text reached the job history...
      expect(outcome.summary, contains('nothing new'));
      final runs = await database.db.query('job_runs');
      expect(runs.single['status'], isNot('Running'));
      // ...and nowhere else: no card every five minutes, no buzz.
      expect(await ChatRepository(database).recent(), isEmpty);
      expect(notifications.posted, isEmpty);
      final tools = (await database.db.query('tool_calls'))
          .map((row) => row['tool_name'])
          .toSet();
      expect(tools, containsAll(['sync_emails', 'read_email_context']),
          reason: 'quiet means it checked and found nothing, not that it '
              'skipped the check');
    });

    test('still posts when something new actually came in', () async {
      mockApiKey('sk-test-key');
      final notifications = _RecordingNotifications();
      final (runner, database, _) = buildStack(
        mailCheckMock('You have 1 new email from Amy about reports.'),
        notifications: notifications,
      );
      await database.open(overridePath: inMemoryDatabasePath);
      addTearDown(database.close);
      await EmailRepository(database).add(
        subject: 'Reports',
        body: 'Can you send the update?',
        sender: 'Amy <amy@example.com>',
      );

      final outcome = await runner.runJob(await mailCheckJob(database));

      expect(outcome.success, isTrue);
      final messages = await ChatRepository(database).recent();
      final card = messages.lastWhere((m) => m.role == 'assistant');
      expect(card.meta?['source'], 'scheduled_job');
      expect(card.meta?['job_title'], 'Mail check');
      expect(card.meta?['quiet'], isNull);
      expect(notifications.posted.single.title, 'Mail check');
    });
  });

  test('the daily review is offered its recipe tools even when the router '
      'names only mail tools', () async {
    mockApiKey('sk-test-key');

    final loopToolNames = <Set<String>>[];
    var loopCalls = 0;
    final mockHttp = MockClient((request) async {
      final decoded =
          (jsonDecode(request.body) as Map).cast<String, Object?>();
      final systemText =
          (((decoded['system'] as List).first as Map)['text'] ?? '') as String;
      if (systemText.contains('Do not call tools.')) {
        return endTurn(jsonEncode({
          'message': 'Nothing new in your mail. Today is clear: no '
              'meetings, no deadlines, nothing overdue.',
          'included_outputs': [
            'rundown', 'task_list', 'meeting_list', 'deadline_list',
            'attention_items',
          ],
          'claims': <Object>[],
          'includes_failure_report': false,
        }));
      }
      if (decoded['tools'] == null) {
        // The router, being a small model, names only the mail tools and
        // nominates the email-only skill. Neither may cost the review its
        // look at the day.
        return endTurn(jsonEncode({
          'domains': ['email', 'tasks', 'calendar'],
          'required_tools': [
            'sync_emails', 'read_email_context', 'create_task',
            'mark_email_digested',
          ],
          'actions': [
            {'description': 'review_emails', 'required': true},
          ],
          'response_outputs': ['rundown', 'task_list'],
          'skill': 'digest_emails',
          'skill_confidence': 0.9,
          'requires_confirmation': false,
          'requires_synthesis': true,
          'requires_verification': true,
        }));
      }
      loopToolNames.add(((decoded['tools'] as List).cast<Map>())
          .map((tool) => tool['name'] as String)
          .toSet());
      loopCalls++;
      if (loopCalls == 1) {
        return json({
          'stop_reason': 'tool_use',
          'content': [
            {
              'type': 'tool_use',
              'id': 'toolu_read',
              'name': 'read_email_context',
              'input': {'undigested_only': true},
            },
          ],
        });
      }
      return endTurn('Reviewed.');
    });

    final (runner, database, intelligence) = buildStack(mockHttp);
    await database.open(overridePath: inMemoryDatabasePath);
    addTearDown(database.close);

    final job = await JobRepository(database).create(
      name: 'Morning review',
      jobType: 'daily_review',
      scheduleRule: {'frequency': 'daily', 'hour': 7, 'minute': 0},
    );
    final outcome = await runner.runJob(job);
    expect(outcome.success, isTrue);

    // The job's prompt matched its own skill, whose recipe looks at the day.
    final trace = await intelligence.replayTraces.latest();
    expect(trace, isNotNull);
    // And the loop could actually call those steps: the router's exact list
    // was widened with the recipe's tools.
    expect(loopToolNames, isNotEmpty);
    expect(
        loopToolNames.first,
        containsAll([
          'sync_emails', 'read_email_context', 'mark_email_digested',
          'list_schedule', 'list_tasks', 'list_reminders',
        ]));
  });

  group('a muted job', () {
    /// Its own runner: the shared stack builds a bare NotificationService,
    /// which no-ops in tests because it is never initialized, so what a run
    /// would have put on the shade has to be captured here instead.
    Future<(JobRunner, AppDatabase, _RecordingNotifications)> stack() async {
      final database = AppDatabase();
      final notifications = _RecordingNotifications();
      final runner =
          JobRunner(database: database, notifications: notifications);
      await database.open(overridePath: inMemoryDatabasePath);
      return (runner, database, notifications);
    }

    /// A job with something to report: an overdue task to flag, and a rule
    /// asking to hear about it (without both, the runner is silent anyway
    /// and the test would pass for the wrong reason).
    Future<ScheduledJob> reportingJob(AppDatabase database,
        {required bool muted}) async {
      await BehaviorRepository(database).createActive(
        title: 'Keep me posted',
        behaviorType: 'summary_rule',
        ruleText: 'Tell me what you did.',
      );
      await TaskRepository(database).create(
        title: 'Yesterday task',
        dueAt: DateTime.now().subtract(const Duration(days: 1)),
      );
      return JobRepository(database).create(
        name: 'Overdue sweep',
        jobType: 'task_cleanup',
        scheduleRule: {'type': 'daily', 'time': '07:00'},
        muteNotifications: muted,
      );
    }

    test('reports into chat without touching the phone', () async {
      final (runner, database, notifications) = await stack();
      addTearDown(database.close);

      final outcome =
          await runner.runJob(await reportingJob(database, muted: true));

      expect(outcome.success, isTrue);
      expect(notifications.posted, isEmpty);
      // Muting hides the buzz, not the result.
      final messages = await ChatRepository(database).recent();
      expect(messages.single.meta?['job_title'], 'Overdue sweep');
    });

    test('is the only reason the same job stays quiet', () async {
      final (runner, database, notifications) = await stack();
      addTearDown(database.close);

      await runner.runJob(await reportingJob(database, muted: false));

      expect(notifications.posted.single.title, 'Overdue sweep');
      expect(notifications.posted.single.channel,
          NotificationPolicy.channelContent);
    });

    test('still says when it has stopped running altogether', () async {
      mockApiKey(null);
      final (runner, database, notifications) = await stack();
      addTearDown(database.close);

      final job = await JobRepository(database).create(
        name: 'Doomed task',
        jobType: 'agent_task',
        description: 'Something that cannot run.',
        scheduleRule: {'type': 'interval', 'minutes': 5},
        maxAttempts: 1,
        muteNotifications: true,
      );
      await runner.runJob(job, triggerSource: 'worker');

      // Muting a job must not turn its outage into an invisible one.
      expect(notifications.posted.single.channel,
          NotificationPolicy.channelSystemHealth);
      expect(notifications.posted.single.title, contains("isn't running"));
    });
  });

  test('deterministic jobs stay silent until a summary rule asks for them',
      () async {
    final (runner, database, _) = buildStack(null);
    await database.open(overridePath: inMemoryDatabasePath);
    addTearDown(database.close);

    await TaskRepository(database).create(
      title: 'Yesterday task',
      dueAt: DateTime.now().subtract(const Duration(days: 1)),
    );
    final job = await JobRepository(database).create(
      name: 'Overdue sweep',
      jobType: 'task_cleanup',
      scheduleRule: {'type': 'daily', 'time': '07:00'},
    );

    final quiet = await runner.runJob(job);
    expect(quiet.success, isTrue);
    expect(await ChatRepository(database).recent(), isEmpty,
        reason: 'no rule asked to hear about this job');

    // With a summary rule AND something to report, the same job speaks up.
    await BehaviorRepository(database).createActive(
      title: 'Tell me about cleanups',
      behaviorType: 'summary_rule',
      ruleText: 'Tell me whenever you tidy up my tasks.',
    );
    await TaskRepository(database).create(
      title: 'Another late task',
      dueAt: DateTime.now().subtract(const Duration(days: 2)),
    );
    final refreshed = (await JobRepository(database).getById(job.id))!;
    final reported = await runner.runJob(refreshed);
    expect(reported.success, isTrue);
    final messages = await ChatRepository(database).recent();
    expect(messages, hasLength(1));
    expect(messages.single.meta?['job_title'], 'Overdue sweep');
  });
}

/// Captures what a run would have shown on the notification shade.
class _RecordingNotifications extends NotificationService {
  final posted = <({String title, String channel})>[];

  @override
  Future<void> showNow({
    required int id,
    required String title,
    required String body,
    String? route,
    bool respectQuietHours = true,
    String channel = NotificationPolicy.channelContent,
  }) async {
    posted.add((title: title, channel: channel));
  }
}
