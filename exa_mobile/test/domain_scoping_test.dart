import 'dart:convert';

import 'package:exa_mobile/agent/models/turn_contract.dart';
import 'package:exa_mobile/agent/orchestrator/agent_orchestrator.dart';
import 'package:exa_mobile/agent/tools/tool_domains.dart';
import 'package:exa_mobile/agent/orchestrator/domain_router.dart';
import 'package:exa_mobile/agent/tools/tool_registry.dart';
import 'package:exa_mobile/data/database/app_database.dart';
import 'package:exa_mobile/data/repositories/behavior_repository.dart';
import 'package:exa_mobile/data/repositories/browser_context_repository.dart';
import 'package:exa_mobile/data/repositories/chat_repository.dart';
import 'package:exa_mobile/data/repositories/dynamic_screen_repository.dart';
import 'package:exa_mobile/data/repositories/email_repository.dart';
import 'package:exa_mobile/data/repositories/job_repository.dart';
import 'package:exa_mobile/data/repositories/mail_account_repository.dart';
import 'package:exa_mobile/data/repositories/pending_calendar_repository.dart';
import 'package:exa_mobile/data/repositories/reminder_repository.dart';
import 'package:exa_mobile/data/repositories/schedule_repository.dart';
import 'package:exa_mobile/data/repositories/settings_repository.dart';
import 'package:exa_mobile/data/repositories/task_repository.dart';
import 'package:exa_mobile/data/repositories/tool_call_repository.dart';
import 'package:exa_mobile/services/ai_client/claude_client.dart';
import 'package:exa_mobile/services/ai_client/local_endpoint_client.dart';
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

ToolRegistry buildRegistry(AppDatabase database) {
  final notifications = NotificationService();
  final mailAccounts = MailAccountRepository(database);
  final emails = EmailRepository(database);
  final schedule = ScheduleRepository(database);
  return ToolRegistry(
    tasks: TaskRepository(database),
    reminders: ReminderRepository(database),
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
}

http.Response jsonResponse(Map<String, Object?> body) =>
    http.Response(jsonEncode(body), 200,
        headers: {'content-type': 'application/json'});

http.Response routerResponse(String text) => jsonResponse({
      'stop_reason': 'end_turn',
      'content': [
        {'type': 'text', 'text': text},
      ],
    });

Set<String> toolNamesOf(Map<String, Object?> requestBody) =>
    ((requestBody['tools'] as List).cast<Map>())
        .map((t) => t['name'] as String)
        .toSet();

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

  group('DomainRouter.parseDomains', () {
    test('parses a clean array', () {
      expect(DomainRouter.parseDomains('["email", "calendar"]'),
          {'email', 'calendar'});
    });

    test('tolerates prose around the array and mixed case', () {
      expect(
          DomainRouter.parseDomains(
              'Sure — here you go: ["Tasks", "email"] as requested.'),
          {'tasks', 'email'});
    });

    test('empty array means no domain tools needed', () {
      expect(DomainRouter.parseDomains('[]'), isEmpty);
    });

    test('"all" means no scoping', () {
      expect(DomainRouter.parseDomains('["all"]'), isNull);
    });

    test('garbage or missing array means no scoping', () {
      expect(DomainRouter.parseDomains('I cannot route this.'), isNull);
      expect(DomainRouter.parseDomains('[not json'), isNull);
    });

    test('only unknown names means the router is not trusted', () {
      expect(DomainRouter.parseDomains('["spreadsheets"]'), isNull);
    });

    test('unknown names are dropped from an otherwise valid pick', () {
      expect(DomainRouter.parseDomains('["tasks", "spreadsheets"]'),
          {'tasks'});
    });
  });

  group('DomainRouter examples', () {
    test('the example budget follows the window, and the catalogue wins on '
        'the smallest models', () {
      // On a 4k model the capability catalogue is what keeps the *action* call
      // affordable, so examples must not crowd it out. Above a comfortable
      // window they are nearly free.
      expect(DomainRouter.exampleCountFor(200000), greaterThan(2));
      expect(DomainRouter.exampleCountFor(32768), greaterThan(2));
      expect(DomainRouter.exampleCountFor(8192), 2);
      expect(DomainRouter.exampleCountFor(4096), 0);
      // A provider that reports no window is assumed to be the 32k default
      // the rest of the budgeting uses.
      expect(DomainRouter.exampleCountFor(null),
          DomainRouter.exampleCountFor(32768));
    });

    test('every example is valid input to the parser it demonstrates', () {
      // An example that the router itself could not parse would be teaching
      // the model a shape this code rejects.
      for (var i = 0; i < DomainRouter.exampleCountFor(200000); i++) {
        final example = DomainRouter.exampleAt(i);
        final parsed = DomainRouter.parseRoutingResult(example);
        expect(parsed, isNotNull, reason: example);
        expect(parsed!.structured, isTrue, reason: example);
        expect(parsed.requiredTools, isNotEmpty, reason: example);
        expect(parsed.actions, isNotEmpty, reason: example);
        expect(parsed.primaryGoal, isNotNull, reason: example);
      }
    });

    test('the two-ask example really does show two actions', () {
      // This is the failure the first example exists to correct; if it ever
      // stopped demonstrating it, the example would be decoration.
      final parsed = DomainRouter.parseRoutingResult(DomainRouter.exampleAt(0))!;
      expect(parsed.actions, hasLength(2));
      expect(parsed.requiredTools, containsAll(['create_task', 'send_email']));
    });
  });

  group('DomainRouter.parseRoutingResult', () {
    test('router parses domains and response outputs', () {
      // "Review today's emails, create tasks, and give me a rundown."
      final result = DomainRouter.parseRoutingResult('''
{
  "domains": ["email", "tasks"],
  "actions": ["review_emails", "extract_action_items", "create_tasks"],
  "response_outputs": ["rundown", "task_list"],
  "requires_confirmation": false,
  "requires_synthesis": true
}''');
      expect(result, isNotNull);
      expect(result!.domains, {'email', 'tasks'});
      expect(result.actions.map((action) => action.description),
          ['review_emails', 'extract_action_items', 'create_tasks']);
      expect(result.actions.every((action) => action.required), isTrue,
          reason: 'plain-string actions default to required');
      expect(result.responseOutputs,
          {ResponseOutputType.rundown, ResponseOutputType.taskList});
      expect(result.requiresSynthesis, isTrue);
      expect(result.requiresConfirmation, isFalse);
      expect(result.structured, isTrue);
    });

    test('small talk requires no tools and no synthesis', () {
      // "How are you?"
      final result = DomainRouter.parseRoutingResult(
          '{"domains": [], "actions": [], "response_outputs": [], '
          '"requires_confirmation": false, "requires_synthesis": false}');
      expect(result, isNotNull);
      expect(result!.domains, isEmpty);
      expect(result.actions, isEmpty);
      expect(result.responseOutputs, isEmpty);
      expect(result.requiresSynthesis, isFalse);
    });

    test('consequential deletion requires confirmation and synthesis', () {
      // "Delete all completed tasks and tell me how many were removed."
      final result = DomainRouter.parseRoutingResult(
          '{"domains": ["tasks"], "actions": ["delete_completed_tasks"], '
          '"response_outputs": ["confirmation", "result_list"], '
          '"requires_confirmation": true, "requires_synthesis": true}');
      expect(result!.requiresConfirmation, isTrue);
      expect(result.requiresSynthesis, isTrue);
      expect(result.responseOutputs,
          {ResponseOutputType.confirmation, ResponseOutputType.resultList});
    });

    test('unknown response-output values are rejected, known kept', () {
      final result = DomainRouter.parseRoutingResult(
          '{"domains": ["email"], "actions": [], '
          '"response_outputs": ["rundown", "interpretive_dance"], '
          '"requires_synthesis": true}');
      expect(result!.responseOutputs, {ResponseOutputType.rundown});
    });

    test('"all" domains means no scoping but the contract survives', () {
      final result = DomainRouter.parseRoutingResult(
          '{"domains": ["all"], "actions": ["broad_request"], '
          '"response_outputs": ["summary"], "requires_synthesis": true}');
      expect(result!.domains, isNull);
      expect(result.responseOutputs, {ResponseOutputType.summary});
    });

    test('legacy bare-array reply degrades to a conservative contract', () {
      final result = DomainRouter.parseRoutingResult('["email", "tasks"]');
      expect(result, isNotNull);
      expect(result!.domains, {'email', 'tasks'});
      expect(result.structured, isFalse);
      // Conservative: never skip synthesis when outputs are unknown.
      expect(result.requiresSynthesis, isTrue);
      expect(result.responseOutputs, {ResponseOutputType.confirmation});
    });

    test('invalid router response falls back safely', () {
      expect(DomainRouter.parseRoutingResult('I cannot route this.'), isNull);
      expect(DomainRouter.parseRoutingResult('{not json'), isNull);
    });
  });

  group('ToolRegistry domain scoping', () {
    late AppDatabase database;
    late ToolRegistry registry;

    setUp(() async {
      database = AppDatabase();
      await database.open(overridePath: inMemoryDatabasePath);
      registry = buildRegistry(database);
    });

    tearDown(() => database.close());

    test('every tool belongs to a domain', () {
      for (final tool in registry.all) {
        expect(registry.domainOf(tool.name), isNotNull,
            reason: '${tool.name} has no domain');
      }
    });

    test('scoped list has the domain tools plus core, nothing else', () {
      final names =
          registry.toolsForDomains({'email'}).map((t) => t.name).toSet();
      expect(
          names,
          containsAll([
            'sync_emails', 'read_email_context', 'send_email',
            'list_mail_accounts', 'mark_email_digested', 'delete_email',
            // Core is always present.
            'search', 'open_screen',
          ]));
      expect(names, isNot(contains('create_task')));
      expect(names, isNot(contains('read_current_browser_page')));
      expect(names, isNot(contains('create_dynamic_screen')));
      expect(names, isNot(contains('propose_behavior_change')));
    });

    test('scoping keeps the toolbox small', () {
      final scoped = registry.toolsForDomains({'email', 'calendar', 'tasks'});
      expect(scoped.length, lessThan(registry.all.length ~/ 2));
    });
  });

  group('two-stage agent loop', () {
    late AppDatabase database;

    setUp(() async {
      database = AppDatabase();
      await database.open(overridePath: inMemoryDatabasePath);
    });

    tearDown(() => database.close());

    AgentOrchestrator orchestratorWith(MockClient mockHttp) =>
        AgentOrchestrator(
          client: ClaudeClient(httpClient: mockHttp),
          registry: buildRegistry(database),
          chat: ChatRepository(database),
          behaviors: BehaviorRepository(database),
          settings: SettingsRepository(database),
        );

    test('the routing fallback carries the app builder when the window can',
        () {
      // A failed routing call must not strand "build me a tracker" without
      // its tools - but a 4k on-device window still gets the lean set and
      // reaches the builder via expand_tools.
      expect(AgentOrchestrator.fallbackDomainsFor(32768),
          contains(ToolDomains.dynamicUi));
      expect(AgentOrchestrator.fallbackDomainsFor(4096),
          isNot(contains(ToolDomains.dynamicUi)));
      // The everyday set stays either way.
      expect(AgentOrchestrator.fallbackDomainsFor(4096),
          containsAll([ToolDomains.core, ToolDomains.tasks]));
    });

    test('the loop receives only the routed domains plus core + expand_tools',
        () async {
      final requests = <Map<String, Object?>>[];
      final mockHttp = MockClient((request) async {
        final body =
            (jsonDecode(request.body) as Map).cast<String, Object?>();
        requests.add(body);
        if (body['tools'] == null) {
          return routerResponse('["email", "calendar", "tasks"]');
        }
        return jsonResponse({
          'stop_reason': 'end_turn',
          'content': [
            {'type': 'text', 'text': 'Reviewed your emails.'},
          ],
        });
      });

      await orchestratorWith(mockHttp)
          .run("Review today's emails and add any meetings");

      expect(requests, hasLength(2));
      final names = toolNamesOf(requests[1]);
      expect(
          names,
          containsAll([
            'sync_emails', 'read_email_context', 'mark_email_digested',
            'create_schedule_event', 'list_schedule', 'add_to_phone_calendar',
            'create_task',
            'search', 'open_screen', 'expand_tools',
          ]));
      expect(names, isNot(contains('read_current_browser_page')));
      expect(names, isNot(contains('create_dynamic_screen')));
      expect(names, isNot(contains('propose_behavior_change')));
      expect(names, isNot(contains('store_file')));
      expect(names, isNot(contains('create_scheduled_job')));
      // The scoping-aware operating rule is in the system prompt.
      final system = (requests[1]['system'] as List).cast<Map>();
      expect(system.first['text'], contains('expand_tools'));
    });

    test('expand_tools unlocks another domain mid-turn', () async {
      final requests = <Map<String, Object?>>[];
      var loopCalls = 0;
      final mockHttp = MockClient((request) async {
        final body =
            (jsonDecode(request.body) as Map).cast<String, Object?>();
        requests.add(body);
        if (body['tools'] == null) {
          return routerResponse('["tasks"]');
        }
        loopCalls++;
        if (loopCalls == 1) {
          return jsonResponse({
            'stop_reason': 'tool_use',
            'content': [
              {
                'type': 'tool_use',
                'id': 'toolu_1',
                'name': 'expand_tools',
                'input': {
                  'domains': ['email'],
                },
              },
            ],
          });
        }
        return jsonResponse({
          'stop_reason': 'end_turn',
          'content': [
            {'type': 'text', 'text': 'Done.'},
          ],
        });
      });

      final result = await orchestratorWith(mockHttp)
          .run('Add a task to reply to the contractor email');

      expect(result.toolsUsed, contains('expand_tools'));
      // Request 1 = router, 2 = tasks only, 3 = tasks + email.
      expect(toolNamesOf(requests[1]), isNot(contains('sync_emails')));
      expect(toolNamesOf(requests[2]),
          containsAll(['sync_emails', 'read_email_context', 'create_task']));
      // The tool_result told the model what became available.
      final toolResultContent =
          (((requests[2]['messages'] as List).last as Map)['content'] as List)
              .cast<Map>()
              .first;
      expect(toolResultContent['content'], contains('sync_emails'));
    });

    test('a window too small for the whole toolbox still reaches messages',
        () async {
      // The regression this pins: on a local server the full registry does
      // not fit 30% of the window, so the turn is narrowed to the everyday
      // domains and told expand_tools can fetch the rest. That promise used
      // to be a lie - the narrowed turn kept a null scope, and expand_tools
      // answers a null scope with "all tools are already available". The
      // messages domain was then unreachable for the whole turn, so a
      // WhatsApp digest job never called sync_messages, never drained the
      // capture spool, and reported that its actions had been declined.
      final requests = <Map<String, Object?>>[];
      var loopCalls = 0;
      final mockHttp = MockClient((request) async {
        final decoded =
            (jsonDecode(request.body) as Map).cast<String, Object?>();
        final messages = (decoded['messages'] as List).cast<Map>();
        final systemText = messages.first['role'] == 'system'
            ? messages.first['content'] as String
            : '';

        http.Response reply(Map<String, Object?> message) => http.Response(
              jsonEncode({
                'choices': [
                  {'finish_reason': 'stop', 'message': message},
                ],
                'usage': {'prompt_tokens': 100, 'completion_tokens': 10},
              }),
              200,
              headers: {'content-type': 'application/json'},
            );

        if (systemText.contains('already-executed')) {
          return reply({
            'role': 'assistant',
            'content': '{"message": "Done.", '
                '"included_outputs": ["confirmation"]}',
          });
        }
        // Routing produces nothing at all - the case the fallback exists for.
        if (decoded['tools'] == null) return http.Response('{}', 500);

        requests.add(decoded);
        loopCalls++;
        if (loopCalls == 1) {
          return reply({
            'role': 'assistant',
            'content': null,
            'tool_calls': [
              {
                'id': 'call_0_expand',
                'type': 'function',
                'function': {
                  'name': 'expand_tools',
                  'arguments': '{"domains":["messages"]}',
                },
              },
            ],
          });
        }
        return reply({'role': 'assistant', 'content': 'Done.'});
      });

      final client = LocalEndpointClient(
        baseUrl: 'http://localhost:1234',
        httpClient: mockHttp,
      );
      // The condition that triggers narrowing, stated rather than assumed.
      expect(client.contextWindow,
          SettingsRepository.defaultLocalContextTokens);
      final registry = buildRegistry(database);
      expect(
        registry.estimatedTokensFor(registry.apiDefinitions),
        greaterThan((client.contextWindow! * 0.30).round()),
        reason: 'the full toolbox must not fit, or this tests nothing',
      );

      final result = await AgentOrchestrator(
        client: client,
        registry: registry,
        chat: ChatRepository(database),
        behaviors: BehaviorRepository(database),
        settings: SettingsRepository(database),
      ).run('Digest my new WhatsApp messages');

      Set<String> openAiToolNames(Map<String, Object?> body) =>
          ((body['tools'] as List).cast<Map>())
              .map((t) => ((t['function'] as Map)['name']) as String)
              .toSet();

      expect(requests, hasLength(greaterThanOrEqualTo(2)));
      // First call is the narrowed everyday set: no message tools yet.
      expect(openAiToolNames(requests[0]), isNot(contains('sync_messages')));
      expect(openAiToolNames(requests[0]), contains('expand_tools'));
      // ...and expand_tools widened it instead of refusing.
      expect(
          openAiToolNames(requests[1]),
          containsAll([
            'sync_messages',
            'read_message_context',
            'mark_message_digested',
          ]));
      // The everyday tools it was narrowed to are still there.
      expect(openAiToolNames(requests[1]), contains('create_task'));
      expect(result.toolsUsed, contains('expand_tools'));
    });

    test('router failure falls back to sending every tool', () async {
      final requests = <Map<String, Object?>>[];
      final mockHttp = MockClient((request) async {
        final body =
            (jsonDecode(request.body) as Map).cast<String, Object?>();
        requests.add(body);
        if (body['tools'] == null) {
          return routerResponse('Sorry, I cannot help with that.');
        }
        return jsonResponse({
          'stop_reason': 'end_turn',
          'content': [
            {'type': 'text', 'text': 'Hello!'},
          ],
        });
      });

      await orchestratorWith(mockHttp).run('hi');

      final names = toolNamesOf(requests[1]);
      // Everything is exposed, and the meta-tool is not (nothing to expand).
      expect(
          names,
          containsAll([
            'create_task', 'sync_emails', 'read_current_browser_page',
            'create_dynamic_screen', 'propose_behavior_change', 'store_file',
          ]));
      expect(names, isNot(contains('expand_tools')));
    });

    test('scopeTools: false skips the router call entirely', () async {
      var routerCalls = 0;
      final mockHttp = MockClient((request) async {
        final body =
            (jsonDecode(request.body) as Map).cast<String, Object?>();
        if (body['tools'] == null) routerCalls++;
        return jsonResponse({
          'stop_reason': 'end_turn',
          'content': [
            {'type': 'text', 'text': 'Hello!'},
          ],
        });
      });

      final orchestrator = AgentOrchestrator(
        client: ClaudeClient(httpClient: mockHttp),
        registry: buildRegistry(database),
        chat: ChatRepository(database),
        behaviors: BehaviorRepository(database),
        settings: SettingsRepository(database),
        scopeTools: false,
      );
      await orchestrator.run('hi');

      expect(routerCalls, 0);
    });
  });
}
