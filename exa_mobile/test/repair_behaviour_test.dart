import 'dart:convert';

import 'package:exa_mobile/agent/models/agent_execution_report.dart';
import 'package:exa_mobile/agent/models/synthesized_response.dart';
import 'package:exa_mobile/agent/models/tool_execution_record.dart';
import 'package:exa_mobile/agent/models/turn_contract.dart';
import 'package:exa_mobile/agent/orchestrator/agent_intelligence.dart';
import 'package:exa_mobile/agent/orchestrator/agent_orchestrator.dart';
import 'package:exa_mobile/agent/orchestrator/route_cache.dart';
import 'package:exa_mobile/agent/prompts/response_voice.dart';
import 'package:exa_mobile/agent/services/response_repairer.dart';
import 'package:exa_mobile/agent/services/response_synthesizer.dart';
import 'package:exa_mobile/agent/services/source_grounding.dart';
import 'package:exa_mobile/agent/services/turn_verifier.dart';
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

import 'helpers/test_contracts.dart';

typedef _Stack = ({
  JobRunner runner,
  AppDatabase database,
  AgentOrchestrator orchestrator,
  ToolRegistry registry,
});

class _Seen {
  final routes = <Map<String, Object?>>[];
  final actions = <Map<String, Object?>>[];
  final summaries = <Map<String, Object?>>[];
  final repairs = <Map<String, Object?>>[];
}

final _everyOutput = [
  for (final output in ResponseOutputType.values) output.wireName,
];

String _envelope(
  String message, {
  List<String>? outputs,
  List<Map<String, String>> claims = const [],
  bool failure = false,
}) =>
    jsonEncode({
      'message': message,
      'included_outputs': outputs ?? _everyOutput,
      'claims': claims,
      'includes_failure_report': failure,
    });

/// A repair call exists to correct a message that is wrong. Measured against
/// the device's model it does that - and was also being sent messages with
/// nothing wrong in them, scored as failing whatever it returned, and
/// trusted over the message it replaced even when it came back worse.
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

  MockClient scripted({
    required _Seen seen,
    required http.Response Function(int call) loop,
    required Map<String, Object?> route,
    required String summary,
    String? repair,
  }) {
    var loopCalls = 0;
    return MockClient((request) async {
      final body = (jsonDecode(request.body) as Map).cast<String, Object?>();
      final system = systemOf(body);
      if (system.contains('Correct only the user-facing response')) {
        seen.repairs.add(body);
        return endTurn(repair ?? summary);
      }
      if (system.contains('already-executed assistant request')) {
        seen.summaries.add(body);
        return endTurn(summary);
      }
      if (body['tools'] == null) {
        seen.routes.add(body);
        return endTurn(jsonEncode(route));
      }
      seen.actions.add(body);
      return loop(++loopCalls);
    });
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
  Future<void> seedMessage(AppDatabase database, String chat, String body) async {
    final at = DateTime.now().add(Duration(seconds: seeded++));
    await InboundMessageRepository(database).add(InboundMessage(
      id: '',
      channel: 'whatsapp',
      conversationId: chat.toLowerCase(),
      conversationTitle: chat,
      sender: chat,
      body: body,
      sentAt: at,
      externalId: InboundMessage.fingerprint(
        channel: 'whatsapp',
        conversationId: chat.toLowerCase(),
        sender: chat,
        sentAt: at,
        body: body,
      ),
      createdAt: at,
    ));
  }

  Future<ScheduledJob> job(AppDatabase database, String instructions) =>
      JobRepository(database).create(
        name: 'Chat digest',
        jobType: 'agent_task',
        description: instructions,
        scheduleRule: {'type': 'interval', 'minutes': 10},
      );

  Future<Map<Object?, Object?>> turnOf(AppDatabase database) async => [
        for (final log in await ToolCallRepository(database).recent())
          if (log.toolName == 'agent_turn') jsonDecode(log.outputJson!) as Map,
      ].single;

  Future<List<String>> diagnosticCodes(AppDatabase database) async => [
        for (final event in await DiagnosticsRepository(database).recent())
          event.code,
      ];

  const digest = 'Go through my new chat messages and add any tasks, '
      'reminders or events you find.';

  Map<String, Object?> digestRoute() => {
        'domains': ['messages', 'tasks', 'reminders', 'calendar'],
        'required_tools': [
          'read_message_context',
          'create_task',
          'create_reminder',
          'create_schedule_event',
        ],
        'actions': [
          {'description': 'read_message_context', 'required': true},
          {'description': 'create_task', 'required': true},
          {'description': 'create_reminder', 'required': true},
          {'description': 'create_schedule_event', 'required': true},
        ],
        'response_outputs': ['confirmation'],
        'requires_confirmation': false,
        'requires_synthesis': true,
        'requires_verification': true,
      };

  group('a planned create that had nothing to create', () {
    test('is not work left undone, and nothing is sent to be repaired',
        () async {
      final seen = _Seen();
      final stack = await openStack(scripted(
        seen: seen,
        route: digestRoute(),
        loop: (call) => switch (call) {
          1 => toolUse('read_message_context', {'undigested_only': true}),
          2 => toolUse(
              'create_task', {'title': 'Send the signed contract to Amy'},
              id: 'toolu_2'),
          _ => endTurn('Amy asked for the contract; task added.'),
        },
        summary: _envelope(
          'I went through 2 new messages. Amy asked for the signed '
          'contract, so I added a task for that. The other needed nothing.',
          claims: [
            {'type': 'task_created', 'description': 'Send the contract'},
          ],
        ),
      ));
      await seedMessage(stack.database, 'Amy',
          'Please send me the signed contract when you can.');
      await seedMessage(stack.database, 'Mum', 'Thanks for dinner!');

      final outcome =
          await stack.runner.runJob(await job(stack.database, digest));

      expect(outcome.success, isTrue);
      expect(seen.summaries, hasLength(1));
      expect(seen.repairs, isEmpty);
      final turn = await turnOf(stack.database);
      expect(turn['unresolved_required_actions'], 0);
      expect(turn['repair_performed'], isFalse);
      expect(await diagnosticCodes(stack.database),
          isNot(contains('REQUIRED_ACTION_UNRESOLVED')));
      // The writer was told it was not needed, not that it was skipped.
      final shown = jsonEncode(seen.summaries.single['messages']);
      expect(shown, contains('set a reminder - not needed'));
      expect(shown, isNot(contains('set a reminder - skipped')));
      // And a plan that was carried out is a plan worth remembering.
      expect(
          await SettingsRepository(stack.database)
              .keysWithPrefix(RouteCache.keyPrefix),
          hasLength(1));
    });

    ToolExecutionRecord record(String tool, Object? result,
            {ToolExecutionStatus status = ToolExecutionStatus.success}) =>
        ToolExecutionRecord(
          toolCallId: 'tc_$tool',
          toolName: tool,
          domain: 'messages',
          arguments: const {},
          status: status,
          startedAt: DateTime(2026, 9, 28),
          completedAt: DateTime(2026, 9, 28),
          rawResult: result,
        );

    const known = {
      'read_message_context', 'create_task', 'create_reminder',
      'create_schedule_event', 'add_to_phone_calendar', 'send_email',
      'mark_message_digested', 'list_tasks',
    };
    final read = record('read_message_context', {
      'count': 2,
      'messages': [1, 2],
    });

    CompletionContract planned(List<String> labels) =>
        testContract(originalRequest: digest, actionLabels: labels);

    List<ContractItemStatus> settle(
      CompletionContract contract,
      List<ToolExecutionRecord> records, {
      bool isolated = true,
      Set<String>? domains = const {'messages', 'tasks'},
    }) =>
        [
          for (final action in SourceGrounding.settleUnneededCreates(
            contract: contract,
            isolated: isolated,
            routedDomains: domains,
            records: records,
            knownToolNames: known,
          ).actions)
            action.status,
        ];

    test('only creates are settled; other planned work still stands', () {
      expect(
          settle(planned(['create_reminder', 'send_email', 'list_tasks']),
              [read]),
          [
            ContractItemStatus.skipped,
            ContractItemStatus.pending,
            ContractItemStatus.pending,
          ]);
    });

    test('a run that read nothing settles nothing here', () {
      expect(
          settle(planned(['create_reminder']), [
            record('read_message_context', {'count': 0, 'messages': []}),
          ]),
          [ContractItemStatus.pending]);
      expect(settle(planned(['create_reminder']), const []),
          [ContractItemStatus.pending]);
    });

    test('a chat turn, and a run that was not a digest, are left alone', () {
      expect(settle(planned(['create_reminder']), [read], isolated: false),
          [ContractItemStatus.pending]);
      expect(
          settle(planned(['create_reminder']), [read],
              domains: const {'tasks'}),
          [ContractItemStatus.pending]);
      expect(settle(planned(['create_reminder']), [read], domains: null),
          [ContractItemStatus.pending]);
    });

    test('a create that was tried and did not succeed is not excused', () {
      expect(
          settle(planned(['create_reminder']), [
            read,
            record('create_reminder', null,
                status: ToolExecutionStatus.failure),
          ]),
          [ContractItemStatus.pending]);
    });
  });

  group('what a repair may replace', () {
    const timesheet = 'Add a task to submit my timesheet.';
    final route = {
      'domains': ['tasks'],
      'required_tools': ['create_task'],
      'actions': [
        {'description': 'create_task', 'required': true},
      ],
      // More than a confirmation, so the message is written by the model
      // and not rendered in code.
      'response_outputs': ['confirmation', 'recommendation'],
      'requires_confirmation': false,
      'requires_synthesis': true,
      'requires_verification': true,
    };
    http.Response createThenStop(int call) => call == 1
        ? toolUse('create_task', {'title': 'Submit my timesheet'})
        : endTurn('Added it.');
    const claim = [
      {'type': 'task_created', 'description': 'Submit my timesheet'},
    ];
    const wrong = 'I added a task to submit your timesheet, due on '
        'March 3, 2031.';

    test('a correction that checks out worse is set aside', () async {
      final seen = _Seen();
      final stack = await openStack(scripted(
        seen: seen,
        route: route,
        loop: createThenStop,
        summary: _envelope(wrong, claims: claim),
        repair: _envelope(
            'I added a task to submit your timesheet for March 3, 2031, '
            'and another one for April 4, 2032.',
            claims: claim),
      ));

      final outcome =
          await stack.runner.runJob(await job(stack.database, timesheet));

      expect(seen.repairs, hasLength(1));
      expect((await turnOf(stack.database))['repair_reasons'],
          ['unsupported_date']);
      expect(outcome.summary, contains('March 3, 2031'));
      expect(outcome.summary, isNot(contains('April 4, 2032')));
      expect((await turnOf(stack.database))['repair_discarded'], isTrue);
      expect(await diagnosticCodes(stack.database),
          contains('REPAIR_DISCARDED'));
    });

    test('a correction that fixes the message is used, and keeps credit '
        'for what the first message covered', () async {
      // What the device's model returns: the right message, and an empty
      // list where the parts it covers should be named again.
      final seen = _Seen();
      final stack = await openStack(scripted(
        seen: seen,
        route: route,
        loop: createThenStop,
        summary: _envelope(wrong, claims: claim),
        repair: _envelope('I added a task to submit your timesheet.',
            outputs: const [], claims: claim),
      ));

      final outcome =
          await stack.runner.runJob(await job(stack.database, timesheet));

      expect(outcome.summary, 'I added a task to submit your timesheet.');
      final turn = await turnOf(stack.database);
      expect(turn['repair_performed'], isTrue);
      expect(turn['repair_discarded'], isNull);
      expect(turn['missing_outputs_after_repair'], isEmpty);
      expect(turn['verification_passed'], isTrue);
    });
  });

  group('a repair is told what is wrong', () {
    final report = AgentExecutionReport(
      originalRequest: 'Add a task and email Dana.',
      toolsCalled: const ['create_task'],
      actionsCompleted: const ['Created task: Chase the invoice'],
      actionsFailed: const [],
      tasksCreated: const [
        {'id': 'task_1', 'title': 'Chase the invoice'},
      ],
      eventsCreated: const [],
      eventsModified: const [],
      emailDigestItems: const [],
      filesAffected: const [],
      screensCreated: const [],
      rulesChanged: const [],
      warnings: const [],
      uncertainItems: const [],
      partialFailures: const [],
    );
    final contract = testContract(
      originalRequest: 'Add a task and email Dana.',
      actions: const [
        ContractAction(
            id: 'a1',
            description: 'create_task',
            status: ContractItemStatus.completed),
        ContractAction(id: 'a2', description: 'send_email'),
      ],
      requiredOutputs: {ResponseOutputType.confirmation},
    );
    SynthesizedResponse said(String message, {bool failure = false}) =>
        SynthesizedResponse(
          message: message,
          includedOutputs: const {ResponseOutputType.confirmation},
          includesFailureReport: failure,
        );

    test('planned steps that were not carried out are named to it', () {
      final prompt = ResponseRepairer.buildPrompt(
        originalResponse: said('All done.'),
        missingOutputs: const {},
        contract: contract,
        report: report,
      );
      expect(prompt, contains('NOT carried out'));
      expect(prompt, contains('- send an email'));
      expect(prompt, isNot(contains('- create a task')));
      expect(prompt, isNot(contains('send_email')));
    });

    test('with nothing undone there is no such section', () {
      final prompt = ResponseRepairer.buildPrompt(
        originalResponse: said('All done.'),
        missingOutputs: const {},
        contract: testContract(actions: const [
          ContractAction(
              id: 'a1',
              description: 'create_task',
              status: ContractItemStatus.completed),
        ]),
        report: report,
      );
      expect(prompt, isNot(contains('NOT carried out')));
    });

    test('saying what was not done is a repair that can pass', () {
      List<String> issues(SynthesizedResponse response) => [
            for (final issue in const TurnVerifier()
                .verify(contract: contract, report: report, response: response)
                .issues)
              issue.code,
          ];
      expect(issues(said('All done.')), contains('unresolved_action'));
      expect(
          issues(said('I added the task. I did not email Dana.',
              failure: true)),
          isNot(contains('unresolved_action')));
    });

    test('it is told to correct, not to rewrite, and to promise nothing',
        () {
      expect(ResponseRepairer.systemPrompt, contains('not a rewrite'));
      expect(ResponseVoice.rules, contains('Never promise'));
      expect(ResponseSynthesizer.systemPrompt, contains('Never promise'));
    });

    test('it is no longer than the message it corrects could be', () async {
      final sent = <int>[];
      final client = LocalEndpointClient(
        baseUrl: 'http://localhost:1234',
        httpClient: MockClient((request) async {
          sent.add((jsonDecode(request.body) as Map)['max_tokens'] as int);
          return http.Response(
            jsonEncode({
              'choices': [
                {
                  'finish_reason': 'stop',
                  'message': {
                    'role': 'assistant',
                    'content': _envelope('ok'),
                  },
                },
              ],
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );
      for (final budget in [180, 1040, 4000, null]) {
        await const ResponseRepairer().repair(
          client: client,
          model: 'local',
          originalResponse: said('All done.'),
          missingOutputs: const {},
          contract: contract,
          report: report,
          responseTokenBudget: budget,
        );
      }
      expect(sent, [
        512 + LocalEndpointClient.defaultReasoningHeadroom,
        ResponseRepairer.maxRepairTokens,
        ResponseRepairer.maxRepairTokens,
        ResponseRepairer.maxRepairTokens,
      ]);
    });
  });

  test('a repaired response is credited with what it is given', () {
    const repaired = SynthesizedResponse(
      message: 'Fixed.',
      includedOutputs: {ResponseOutputType.taskList},
    );
    expect(
        repaired.coveringAlso({ResponseOutputType.confirmation}).includedOutputs,
        {ResponseOutputType.taskList, ResponseOutputType.confirmation});
    expect(repaired.coveringAlso(const {}).message, 'Fixed.');
  });
}
