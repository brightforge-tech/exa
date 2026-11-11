import 'dart:convert';

import 'package:exa_mobile/agent/orchestrator/agent_intelligence.dart';
import 'package:exa_mobile/agent/orchestrator/agent_orchestrator.dart';
import 'package:exa_mobile/agent/orchestrator/route_cache.dart';
import 'package:exa_mobile/agent/prompts/system_prompt.dart';
import 'package:exa_mobile/agent/tools/tool_registry.dart';
import 'package:exa_mobile/data/database/app_database.dart';
import 'package:exa_mobile/data/models/inbound_message.dart';
import 'package:exa_mobile/data/models/scheduled_job.dart';
import 'package:exa_mobile/data/repositories/behavior_repository.dart';
import 'package:exa_mobile/data/repositories/browser_context_repository.dart';
import 'package:exa_mobile/data/repositories/chat_repository.dart';
import 'package:exa_mobile/data/repositories/diagnostics_repository.dart';
import 'package:exa_mobile/data/repositories/dynamic_screen_repository.dart';
import 'package:exa_mobile/data/repositories/email_repository.dart';
import 'package:exa_mobile/data/repositories/idempotency_repository.dart';
import 'package:exa_mobile/data/repositories/inbound_message_repository.dart';
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

typedef _Stack = ({
  JobRunner runner,
  AppDatabase database,
  AgentOrchestrator orchestrator,
  ToolRegistry registry,
});

/// One captured request, by what kind of call it was.
class _Seen {
  final routes = <Map<String, Object?>>[];
  final actions = <Map<String, Object?>>[];
  final rewrites = <Map<String, Object?>>[];

  int get total => routes.length + actions.length + rewrites.length;
}

/// Two days of the device's server logs, turned into tests.
///
/// A scheduled run on the local model spent its time on four things that
/// bought nothing: routing the same instructions again, reading the tool
/// definitions again, waking the model to find no new messages, and writing
/// an answer it had already written. Each group here holds one of those
/// shut.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (call) async => call.method == 'read' ? 'sk-test-key' : null,
    );
  });

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

  http.Response toolUse(String name, Map<String, Object?> input,
          {String id = 'toolu_1'}) =>
      json({
        'stop_reason': 'tool_use',
        'content': [
          {'type': 'tool_use', 'id': id, 'name': name, 'input': input},
        ],
      });

  String systemOf(Map<String, Object?> body) =>
      (((body['system'] as List).first as Map)['text'] ?? '') as String;

  /// A model whose agent-loop replies are scripted by [loop] (1-based call
  /// count, restarting when [resetLoop] is called); routing and the rewrite
  /// calls are answered generically, and every request is sorted into
  /// [seen].
  ({MockClient client, void Function() resetLoop}) scripted({
    required http.Response Function(int call, Map<String, Object?> body) loop,
    required _Seen seen,
    List<String> domains = const ['tasks'],
    String? routerReply,
  }) {
    var loopCalls = 0;
    final client = MockClient((request) async {
      final body = (jsonDecode(request.body) as Map).cast<String, Object?>();
      if (systemOf(body).contains('Do not call tools.')) {
        seen.rewrites.add(body);
        return endTurn(jsonEncode({
          'message': 'Rewritten by the second call.',
          'included_outputs': ['rundown'],
          'claims': <Object>[],
          'includes_failure_report': false,
        }));
      }
      if (body['tools'] == null) {
        seen.routes.add(body);
        if (routerReply != null) return endTurn(routerReply);
        return endTurn(jsonEncode({
          'domains': domains,
          'actions': [
            {'description': 'look_things_up', 'required': true},
          ],
          'response_outputs': ['rundown'],
          'requires_confirmation': false,
          'requires_synthesis': true,
          'requires_verification': false,
        }));
      }
      seen.actions.add(body);
      return loop(++loopCalls, body);
    });
    return (client: client, resetLoop: () => loopCalls = 0);
  }

  Future<_Stack> openStack(MockClient mockHttp) async {
    final database = AppDatabase();
    final notifications = NotificationService();
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
    final orchestrator = AgentOrchestrator(
      client: ClaudeClient(httpClient: mockHttp),
      registry: registry,
      chat: ChatRepository(database),
      behaviors: BehaviorRepository(database),
      settings: SettingsRepository(database),
      intelligence:
          AgentIntelligence.standard(database: database, registry: registry),
    );
    runner.orchestratorFactory = () => orchestrator;
    await database.open(overridePath: inMemoryDatabasePath);
    addTearDown(database.close);
    return (
      runner: runner,
      database: database,
      orchestrator: orchestrator,
      registry: registry,
    );
  }

  var seeded = 0;
  Future<void> seedMessage(AppDatabase database) async {
    final at = DateTime.now().add(Duration(seconds: seeded++));
    await InboundMessageRepository(database).add(InboundMessage(
      id: '',
      channel: 'whatsapp',
      conversationId: 'amy',
      conversationTitle: 'Amy',
      sender: 'Amy',
      body: 'Please send me the report by Friday.',
      sentAt: at,
      externalId: InboundMessage.fingerprint(
        channel: 'whatsapp',
        conversationId: 'amy',
        sender: 'Amy',
        sentAt: at,
        body: 'Please send me the report by Friday.',
      ),
      createdAt: at,
    ));
  }

  Future<ScheduledJob> job(
    AppDatabase database, {
    String instructions = 'Read my open tasks and tell me which matter most.',
    String? onlyIf,
  }) =>
      JobRepository(database).create(
        name: 'Morning look',
        jobType: 'agent_task',
        description: instructions,
        scheduleRule: {
          'type': 'interval',
          'minutes': 10,
          'only_if': ?onlyIf,
        },
      );

  Future<List<String>> diagnosticCodes(AppDatabase database) async => [
        for (final event in await DiagnosticsRepository(database).recent())
          event.code,
      ];

  const answer = 'You have one open task: call the bank about the new card. '
      'Nothing else is waiting on you.';

  http.Response listThenAnswer(int call, Map<String, Object?> _) => call == 1
      ? toolUse('list_tasks', {'open_only': true})
      : endTurn(answer);

  group('a job that only goes through what arrived', () {
    const digest = 'Go through my new chat messages and file any tasks.';

    test('does not wake the model when nothing is waiting', () async {
      final seen = _Seen();
      final stack = await openStack(scripted(
        seen: seen,
        domains: const ['messages', 'tasks'],
        loop: (_, _) => endTurn('Nothing.'),
      ).client);
      final scheduled = await job(stack.database,
          instructions: digest, onlyIf: ScheduledJob.onlyIfNewMessages);

      final outcome = await stack.runner.runJob(scheduled);

      expect(outcome.success, isTrue);
      expect(outcome.summary, contains('Nothing new in your chats'));
      expect(seen.total, 0, reason: 'not one request to the model');
      expect(await diagnosticCodes(stack.database),
          contains('JOB_NOTHING_WAITING'));
      // Quiet: the line in Job history is the whole of it.
      expect(await ChatRepository(stack.database).recent(limit: 10), isEmpty);
    });

    test('runs as before once a message is waiting', () async {
      final seen = _Seen();
      final stack = await openStack(scripted(
        seen: seen,
        domains: const ['messages', 'tasks'],
        loop: (call, _) => call == 1
            ? toolUse('read_message_context', {'undigested_only': true})
            : endTurn('Went through one new message from Amy.'),
      ).client);
      await seedMessage(stack.database);
      final scheduled = await job(stack.database,
          instructions: digest, onlyIf: ScheduledJob.onlyIfNewMessages);

      final outcome = await stack.runner.runJob(scheduled);

      expect(outcome.success, isTrue);
      expect(seen.actions, isNotEmpty);
      expect(await diagnosticCodes(stack.database),
          isNot(contains('JOB_NOTHING_WAITING')));
    });

    test('a job with no such condition always runs', () async {
      final seen = _Seen();
      final stack =
          await openStack(scripted(seen: seen, loop: listThenAnswer).client);
      final scheduled = await job(stack.database);

      await stack.runner.runJob(scheduled);

      expect(seen.actions, isNotEmpty);
    });

    test('waiting mail counts only for a job that asked about mail',
        () async {
      final seen = _Seen();
      final stack = await openStack(scripted(
        seen: seen,
        loop: (_, _) => endTurn('Nothing.'),
      ).client);
      await seedMessage(stack.database);
      final scheduled = await job(stack.database,
          instructions: 'Go through my new mail.',
          onlyIf: ScheduledJob.onlyIfNewEmail);

      final outcome = await stack.runner.runJob(scheduled);

      expect(outcome.summary, contains('Nothing new in your mail'));
      expect(seen.total, 0);
    });

    test('an unknown condition is no condition', () {
      ScheduledJob withRule(Map<String, Object?> rule) => ScheduledJob(
            id: 'j',
            name: 'n',
            jobType: 'agent_task',
            scheduleRule: rule,
            createdAt: DateTime(2026),
            updatedAt: DateTime(2026),
          );
      expect(withRule({'type': 'daily', 'only_if': 'full_moon'}).onlyIf,
          isNull);
      expect(withRule({'type': 'daily'}).onlyIf, isNull);
      final both = withRule({'only_if': ScheduledJob.onlyIfNewInbound});
      expect(both.waitsForMessages && both.waitsForEmail, isTrue);
      expect(ScheduledJob.describeOnlyIf(both.onlyIf), contains('or mail'));
    });

    test('the agent can set it when it schedules a digest', () async {
      final stack = await openStack(
          scripted(seen: _Seen(), loop: (_, _) => endTurn('ok')).client);
      final created = await stack.registry.execute('create_scheduled_job', {
        'name': 'Chat digest',
        'job_type': 'agent_task',
        'instructions': digest,
        'frequency': 'interval',
        'interval_minutes': 10,
        'only_if': 'new_messages',
      });
      expect(created.success, isTrue);
      final stored = (await JobRepository(stack.database).listAll()).single;
      expect(stored.onlyIf, ScheduledJob.onlyIfNewMessages);
      expect(stored.scheduleRule['minutes'], 10);
    });
  });

  group('a job is routed once, not every run', () {
    test('the second run asks for no route', () async {
      final seen = _Seen();
      final model = scripted(seen: seen, loop: listThenAnswer);
      final stack = await openStack(model.client);
      final scheduled = await job(stack.database);

      await stack.runner.runJob(scheduled);
      expect(seen.routes, hasLength(1));
      model.resetLoop();
      await stack.runner.runJob(scheduled);

      expect(seen.routes, hasLength(1), reason: 'routed from memory');
      // And it was routed the same way: the same tools were offered.
      expect(seen.actions.last['tools'], seen.actions.first['tools']);
      final turns = [
        for (final log in await ToolCallRepository(stack.database).recent())
          if (log.toolName == 'agent_turn')
            (jsonDecode(log.outputJson!) as Map)['route_source'],
      ];
      expect(turns, contains('cache'));
    });

    test('changed instructions are routed afresh', () async {
      final seen = _Seen();
      final model = scripted(seen: seen, loop: listThenAnswer);
      final stack = await openStack(model.client);

      await stack.runner.runJob(await job(stack.database));
      model.resetLoop();
      await stack.runner.runJob(await job(stack.database,
          instructions: 'Read my open tasks and tell me which are late.'));

      expect(seen.routes, hasLength(2));
    });

    test('a route that will not compute stops being asked for', () async {
      final seen = _Seen();
      final model = scripted(
        seen: seen,
        loop: listThenAnswer,
        // What a reasoning model cut off mid-thought hands back.
        routerReply: 'Let me think about which domains this needs. The',
      );
      final stack = await openStack(model.client);
      final scheduled = await job(stack.database);

      for (var run = 0; run < 4; run++) {
        model.resetLoop();
        await stack.runner.runJob(scheduled);
      }

      expect(seen.routes, hasLength(RouteCache.maxFailures));
      // The runs themselves went ahead, unrouted.
      expect(seen.actions.length, greaterThanOrEqualTo(4));
    });

    test('a plan the run could not follow is not remembered', () async {
      final seen = _Seen();
      final model = scripted(
        seen: seen,
        loop: listThenAnswer,
        // "Write a short list" read as a file to be written: a tool the
        // run never calls, so the plan is never carried out.
        routerReply: jsonEncode({
          'domains': ['tasks', 'files'],
          'required_tools': ['list_tasks', 'write_file'],
          'actions': [
            {'description': 'list_tasks', 'required': true},
            {'description': 'write_file', 'required': true},
          ],
          'response_outputs': ['task_list'],
          'requires_confirmation': false,
          'requires_synthesis': true,
          'requires_verification': false,
        }),
      );
      final stack = await openStack(model.client);
      final scheduled = await job(stack.database);

      await stack.runner.runJob(scheduled);
      model.resetLoop();
      await stack.runner.runJob(scheduled);

      expect(seen.routes, hasLength(2), reason: 'asked again, not replayed');
      expect(
          await SettingsRepository(stack.database)
              .keysWithPrefix(RouteCache.keyPrefix),
          isEmpty);
    });

    test('a remembered plan that stops being followed is dropped',
        () async {
      final seen = _Seen();
      var loopCalls = 0;
      var follow = true;
      final model = scripted(
        seen: seen,
        loop: (_, _) {
          loopCalls++;
          if (loopCalls == 1) return toolUse('list_tasks', {'open_only': true});
          if (loopCalls == 2 && follow) {
            return toolUse('list_schedule', {}, id: 'toolu_2');
          }
          return endTurn(answer);
        },
        routerReply: jsonEncode({
          'domains': ['tasks', 'calendar'],
          'required_tools': ['list_tasks', 'list_schedule'],
          'actions': [
            {'description': 'list_tasks', 'required': true},
            {'description': 'list_schedule', 'required': true},
          ],
          'response_outputs': ['task_list'],
          'requires_confirmation': false,
          'requires_synthesis': true,
          'requires_verification': false,
        }),
      );
      final stack = await openStack(model.client);
      final scheduled = await job(stack.database);
      final settings = SettingsRepository(stack.database);

      await stack.runner.runJob(scheduled);
      expect(await settings.keysWithPrefix(RouteCache.keyPrefix),
          hasLength(1), reason: 'followed in full, so remembered');

      follow = false;
      loopCalls = 0;
      await stack.runner.runJob(scheduled);
      expect(seen.routes, hasLength(1), reason: 'this run used the memory');
      expect(await settings.keysWithPrefix(RouteCache.keyPrefix), isEmpty,
          reason: 'and was the last to');
    });

    test('a chat turn is routed every time', () async {
      final seen = _Seen();
      final model = scripted(seen: seen, loop: listThenAnswer);
      final stack = await openStack(model.client);

      await stack.orchestrator.run('What are my open tasks?');
      model.resetLoop();
      await stack.orchestrator.run('What are my open tasks?');

      expect(seen.routes, hasLength(2));
    });

    test('the cache forgets, retries and stays small', () async {
      final database = AppDatabase();
      await database.open(overridePath: inMemoryDatabasePath);
      addTearDown(database.close);
      var now = DateTime(2026, 9, 27, 7);
      final cache = RouteCache(SettingsRepository(database), now: () => now);
      const reply = '{"domains": ["tasks"], "actions": [], '
          '"response_outputs": ["rundown"], "requires_confirmation": false, '
          '"requires_synthesis": true}';

      final key = RouteCache.keyFor(
          request: 'list my tasks', toolNames: ['list_tasks', 'search']);
      expect(
          key,
          RouteCache.keyFor(
              request: ' list my tasks ',
              toolNames: ['search', 'list_tasks']),
          reason: 'order and padding are not differences');
      expect(
          key,
          isNot(RouteCache.keyFor(
              request: 'list my tasks', toolNames: ['list_tasks'])),
          reason: 'a changed tool set is');

      expect(await cache.read(key), isNull);
      await cache.save(key, reply);
      expect((await cache.read(key))!.routing!.domains, {'tasks'});

      const broken = 'route_cache.broken';
      await cache.recordFailure(broken);
      expect(await cache.read(broken), isNull, reason: 'one failure: retry');
      await cache.recordFailure(broken);
      expect((await cache.read(broken))!.givenUp, isTrue);
      now = now.add(RouteCache.retryAfter);
      expect(await cache.read(broken), isNull, reason: 'a day on: retry');
      await cache.recordFailure(broken);
      expect(await cache.read(broken), isNull,
          reason: 'yesterday\'s failures do not count against today');

      for (var i = 0; i < RouteCache.maxEntries + 5; i++) {
        now = now.add(const Duration(minutes: 1));
        await cache.save('${RouteCache.keyPrefix}extra$i', reply);
      }
      final kept = await SettingsRepository(database)
          .keysWithPrefix(RouteCache.keyPrefix);
      expect(kept, hasLength(RouteCache.maxEntries));
      expect(kept, isNot(contains(key)), reason: 'oldest go first');
    });
  });

  group('what does not change is sent unchanged', () {
    test('the system prompt is the same at any hour', () {
      final first = buildSystemPrompt(behaviors: 'Be brief.');
      final later = buildSystemPrompt(behaviors: 'Be brief.');
      expect(later, first);
      expect(first, isNot(contains('Current local')));
      expect(first, isNot(matches(RegExp(r'\b20\d\d-\d\d-\d\d\b'))));
      expect(first, contains(turnContextHeading));
    });

    test('the clock and the turn travel with the request', () {
      final context = buildTurnContext(
        intelligenceContext: 'This turn: list the open tasks',
        now: DateTime(2026, 9, 27, 7, 0),
      );
      expect(context, startsWith('[$turnContextHeading'));
      expect(context, contains('Sunday, September 27, 2026'));
      expect(context, contains('Current local time: 07:00'));
      expect(context, contains('Monday = 2026-09-28 (tomorrow)'));
      expect(context, contains('This turn: list the open tasks'));
      expect(withTurnContext(context, 'list my tasks'),
          endsWith('[End of context]\n\nlist my tasks'));
      expect(withTurnContext('', 'list my tasks'), 'list my tasks');
    });

    test('two runs of a job share everything before the request',
        () async {
      final seen = _Seen();
      final model = scripted(seen: seen, loop: listThenAnswer);
      final stack = await openStack(model.client);
      final scheduled = await job(stack.database);

      await stack.runner.runJob(scheduled);
      model.resetLoop();
      await stack.runner.runJob(scheduled);

      final first = seen.actions.first;
      final second = seen.actions[2];
      expect(systemOf(second), systemOf(first));
      expect(second['tools'], first['tools']);
      final asked = (second['messages'] as List).first as Map;
      expect(asked['role'], 'user');
      expect(asked['content'], startsWith('[$turnContextHeading'));
      expect(asked['content'],
          endsWith('Read my open tasks and tell me which matter most.'));
      // What the turn is for went with it.
      expect(asked['content'], contains('This turn:'));
      expect(systemOf(first), isNot(contains('This turn:')));
    });

    test('the context is not stored with the message', () async {
      final seen = _Seen();
      final stack =
          await openStack(scripted(seen: seen, loop: listThenAnswer).client);

      await stack.orchestrator.run('What are my open tasks?');

      final stored = await ChatRepository(stack.database).recent(limit: 10);
      expect(stored.first.content, 'What are my open tasks?');
      expect(
          [for (final message in stored) message.content].join('\n'),
          isNot(contains(turnContextHeading)));
    });
  });

  group('an answer already written is not written again', () {
    test('a run that only looked things up sends its own answer', () async {
      final seen = _Seen();
      final stack =
          await openStack(scripted(seen: seen, loop: listThenAnswer).client);
      await TaskRepository(stack.database)
          .create(title: 'Call the bank about the new card');
      final scheduled = await job(stack.database);

      final outcome = await stack.runner.runJob(scheduled);

      expect(outcome.success, isTrue);
      expect(outcome.summary, answer);
      expect(seen.rewrites, isEmpty, reason: 'no second call to write it');
      final turn = [
        for (final log in await ToolCallRepository(stack.database).recent())
          if (log.toolName == 'agent_turn') jsonDecode(log.outputJson!) as Map,
      ].single;
      expect(turn['draft_delivered'], isTrue);
    });

    test('a run that created something is still written up and checked',
        () async {
      final seen = _Seen();
      final stack = await openStack(scripted(
        seen: seen,
        loop: (call, _) => call == 1
            ? toolUse('create_task', {'title': 'Submit my timesheet'})
            : endTurn('I added a task to submit your timesheet, all done.'),
      ).client);
      final scheduled = await job(stack.database,
          instructions: 'Add a task to submit my timesheet.');

      await stack.runner.runJob(scheduled);

      expect(seen.rewrites, isNotEmpty);
    });

    test('an answer naming the machinery is rewritten', () async {
      final seen = _Seen();
      final stack = await openStack(scripted(
        seen: seen,
        loop: (call, _) => call == 1
            ? toolUse('list_tasks', {'open_only': true})
            : endTurn('I called list_tasks and it returned zero tasks, so '
                'there is nothing to report.'),
      ).client);

      await stack.runner.runJob(await job(stack.database));

      expect(seen.rewrites, isNotEmpty);
      final turn = [
        for (final log in await ToolCallRepository(stack.database).recent())
          if (log.toolName == 'agent_turn') jsonDecode(log.outputJson!) as Map,
      ].single;
      expect(turn['draft_rewritten_because'], 'names_a_tool');
    });

    test('a plan that includes writing the answer does not force a rewrite',
        () async {
      // What the router makes of "list my open tasks, then write a short
      // list of them": two actions, one of which no tool call can ever
      // match. Observed on the device, where it sent a finished answer
      // through two more model calls.
      final seen = _Seen();
      final stack = await openStack(scripted(
        seen: seen,
        loop: listThenAnswer,
        routerReply: jsonEncode({
          'domains': ['tasks'],
          'required_tools': ['list_tasks'],
          'actions': [
            {'description': 'list_tasks', 'required': true},
            {'description': 'write_short_list', 'required': true},
          ],
          'response_outputs': ['task_list'],
          'requires_confirmation': false,
          'requires_synthesis': true,
          'requires_verification': false,
        }),
      ).client);
      await TaskRepository(stack.database)
          .create(title: 'Call the bank about the new card');

      final outcome = await stack.runner.runJob(await job(stack.database));

      expect(outcome.summary, answer);
      expect(seen.rewrites, isEmpty);
    });

    test('a plan with tool work that never ran is still rewritten',
        () async {
      final seen = _Seen();
      final stack = await openStack(scripted(
        seen: seen,
        loop: listThenAnswer,
        routerReply: jsonEncode({
          'domains': ['tasks'],
          'actions': [
            {'description': 'list_tasks', 'required': true},
            {'description': 'create_task', 'required': true},
            {'description': 'email_the_summary_to_dana', 'required': true},
          ],
          'response_outputs': ['task_list'],
          'requires_confirmation': false,
          'requires_synthesis': true,
          'requires_verification': false,
        }),
      ).client);

      await stack.runner.runJob(await job(stack.database));

      expect(seen.rewrites, isNotEmpty);
      final turn = [
        for (final log in await ToolCallRepository(stack.database).recent())
          if (log.toolName == 'agent_turn') jsonDecode(log.outputJson!) as Map,
      ].single;
      expect(turn['draft_rewritten_because'], 'unresolved_action');
    });

    test('naming today is not stating a date nobody gave it', () async {
      final now = DateTime.now();
      const months = [
        'January', 'February', 'March', 'April', 'May', 'June', 'July',
        'August', 'September', 'October', 'November', 'December',
      ];
      final today = '${months[now.month - 1]} ${now.day}, ${now.year}';
      final seen = _Seen();
      final stack = await openStack(scripted(
        seen: seen,
        loop: (call, _) => call == 1
            ? toolUse('list_tasks', {'open_only': true})
            : endTurn('As of today, $today, you have one open task: call '
                'the bank about the new card.'),
      ).client);
      await TaskRepository(stack.database)
          .create(title: 'Call the bank about the new card');

      await stack.runner.runJob(await job(stack.database));

      expect(seen.rewrites, isEmpty);
    });

    test('an answer stating a date the run never saw is rewritten',
        () async {
      final seen = _Seen();
      final stack = await openStack(scripted(
        seen: seen,
        loop: (call, _) => call == 1
            ? toolUse('list_tasks', {'open_only': true})
            : endTurn('Your one open task is due on March 3, 2031, so '
                'there is plenty of time.'),
      ).client);
      await TaskRepository(stack.database).create(title: 'Call the bank');

      await stack.runner.runJob(await job(stack.database));

      expect(seen.rewrites, isNotEmpty);
    });
  });
}
