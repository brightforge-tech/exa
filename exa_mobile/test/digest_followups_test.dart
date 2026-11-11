import 'dart:convert';

import 'package:exa_mobile/agent/models/agent_execution_report.dart';
import 'package:exa_mobile/agent/models/agent_turn_diagnostics.dart';
import 'package:exa_mobile/agent/models/synthesized_response.dart';
import 'package:exa_mobile/agent/models/tool_execution_record.dart';
import 'package:exa_mobile/agent/models/turn_contract.dart';
import 'package:exa_mobile/agent/orchestrator/agent_intelligence.dart';
import 'package:exa_mobile/agent/orchestrator/agent_orchestrator.dart';
import 'package:exa_mobile/agent/security/capability_policy.dart';
import 'package:exa_mobile/agent/security/write_scope.dart';
import 'package:exa_mobile/agent/services/duplicate_guard.dart';
import 'package:exa_mobile/agent/services/execution_record_builder.dart';
import 'package:exa_mobile/agent/services/execution_report_builder.dart';
import 'package:exa_mobile/agent/services/response_synthesizer.dart';
import 'package:exa_mobile/agent/services/turn_verifier.dart';
import 'package:exa_mobile/agent/tools/agent_tool.dart';
import 'package:exa_mobile/agent/tools/tool_registry.dart';
import 'package:exa_mobile/data/database/app_database.dart';
import 'package:exa_mobile/data/models/inbound_message.dart';
import 'package:exa_mobile/data/models/scheduled_job.dart';
import 'package:exa_mobile/data/repositories/behavior_repository.dart';
import 'package:exa_mobile/data/repositories/browser_context_repository.dart';
import 'package:exa_mobile/data/repositories/chat_repository.dart';
import 'package:exa_mobile/data/repositories/dynamic_screen_repository.dart';
import 'package:exa_mobile/data/repositories/email_repository.dart';
import 'package:exa_mobile/data/repositories/idempotency_repository.dart';
import 'package:exa_mobile/data/repositories/inbound_message_repository.dart';
import 'package:exa_mobile/data/repositories/job_repository.dart';
import 'package:exa_mobile/data/repositories/mail_account_repository.dart';
import 'package:exa_mobile/data/repositories/pending_calendar_repository.dart';
import 'package:exa_mobile/data/repositories/provenance_repository.dart';
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

import 'helpers/test_contracts.dart';

typedef _Stack = ({
  JobRunner runner,
  AppDatabase database,
  ToolRegistry registry,
});

class _Seen {
  final actions = <Map<String, Object?>>[];
  final summaries = <Map<String, Object?>>[];
  final repairs = <Map<String, Object?>>[];
}

String _envelope(
  String message, {
  List<Map<String, String>> claims = const [],
}) =>
    jsonEncode({
      'message': message,
      'included_outputs': [
        for (final output in ResponseOutputType.values) output.wireName,
      ],
      'claims': claims,
      'includes_failure_report': false,
    });

/// What eighteen chat digests on the device showed once they were running
/// properly (2026-09-28): seven sent for repair with nothing wrong in them,
/// no way to tell from the record which claim had done it, and the same
/// training reminder filed as a new task each time it was reworded.
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

  MockClient scripted({
    required _Seen seen,
    required http.Response Function(int call) loop,
    required String summary,
    String? repair,
  }) {
    var loopCalls = 0;
    return MockClient((request) async {
      final body = (jsonDecode(request.body) as Map).cast<String, Object?>();
      final system =
          (((body['system'] as List).first as Map)['text'] ?? '') as String;
      if (system.contains('Correct only the user-facing response')) {
        seen.repairs.add(body);
        return endTurn(repair ?? summary);
      }
      if (system.contains('already-executed assistant request')) {
        seen.summaries.add(body);
        return endTurn(summary);
      }
      if (body['tools'] == null) {
        return endTurn(jsonEncode({
          'domains': ['messages', 'tasks', 'reminders', 'calendar'],
          'required_tools': [
            'read_message_context',
            'create_task',
            'mark_message_digested',
          ],
          'actions': [
            {'description': 'read_message_context', 'required': true},
            {'description': 'create_task', 'required': true},
            {'description': 'mark_message_digested', 'required': true},
          ],
          'response_outputs': ['confirmation'],
          'requires_confirmation': false,
          'requires_synthesis': true,
          'requires_verification': true,
        }));
      }
      seen.actions.add(body);
      return loop(++loopCalls);
    });
  }

  Future<_Stack> openStack([MockClient? mockHttp]) async {
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
      client: ClaudeClient(
          httpClient: mockHttp ?? MockClient((_) async => endTurn(''))),
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
    return (runner: runner, database: database, registry: registry);
  }

  var seeded = 0;
  Future<InboundMessage> seedMessage(
    AppDatabase database,
    String from,
    String body, {
    String channel = 'outlook',
  }) async {
    final at = DateTime.now().add(Duration(seconds: seeded++));
    final stored = await InboundMessageRepository(database).add(InboundMessage(
      id: '',
      channel: channel,
      conversationId: from.toLowerCase(),
      conversationTitle: from,
      sender: from,
      body: body,
      sentAt: at,
      externalId: InboundMessage.fingerprint(
        channel: channel,
        conversationId: from.toLowerCase(),
        sender: from,
        sentAt: at,
        body: body,
      ),
      createdAt: at,
    ));
    return stored!;
  }

  Future<ScheduledJob> digestJob(AppDatabase database) =>
      JobRepository(database).create(
        name: 'Chat digest',
        jobType: 'agent_task',
        description: 'Go through my new chat messages and add any tasks, '
            'reminders or events you find.',
        scheduleRule: {'type': 'interval', 'minutes': 5},
      );

  Future<Map<Object?, Object?>> turnOf(AppDatabase database) async => [
        for (final log in await ToolCallRepository(database).recent())
          if (log.toolName == 'agent_turn') jsonDecode(log.outputJson!) as Map,
      ].single;

  ToolExecutionRecord ran(String tool, {Object? result}) =>
      ToolExecutionRecord(
        toolCallId: 'call_$tool',
        toolName: tool,
        domain: 'messages',
        arguments: const {},
        status: ToolExecutionStatus.success,
        startedAt: DateTime(2026, 9, 28),
        completedAt: DateTime(2026, 9, 28),
        rawResult: result,
      );

  AgentExecutionReport reportOf(List<ToolExecutionRecord> records) =>
      const ExecutionReportBuilder()
          .build(originalRequest: 'digest', records: records);

  group('marking a chat message handled is a claim the turn can back', () {
    const verifier = TurnVerifier();

    List<String> rejected(String type, List<ToolExecutionRecord> records) =>
        verifier
            .verify(
              contract: testContract(),
              report: reportOf(records),
              response: SynthesizedResponse(
                message: 'I marked it as handled.',
                includedOutputs: const {},
                claims: [
                  ResponseClaim(
                      type: type,
                      description: '1 chat message marked as handled'),
                ],
              ),
              records: records,
            )
            .unsupportedClaims;

    test('under the name the model reached for, and under its own', () {
      final marked = [ran('mark_message_digested', result: {'count': 1})];
      // As filed on the device: the only "handled" the prompt offered.
      expect(rejected('emails_digested', marked), isEmpty);
      expect(rejected('messages_digested', marked), isEmpty);
      expect(
          rejected('messages_read', [
            ran('read_message_context', result: {'count': 1}),
          ]),
          isEmpty);
    });

    test('and mail marked handled backs the same claims', () {
      final marked = [ran('mark_email_digested', result: {'count': 1})];
      expect(rejected('emails_digested', marked), isEmpty);
      expect(rejected('messages_digested', marked), isEmpty);
    });

    test('but not when nothing was marked', () {
      final onlyRead = [ran('read_message_context', result: {'count': 1})];
      expect(rejected('messages_digested', onlyRead), hasLength(1));
      expect(rejected('emails_digested', onlyRead), hasLength(1));
    });

    test('the writer is offered the name, and told a negative is no claim',
        () {
      expect(ResponseSynthesizer.systemPrompt, contains('messages_digested'));
      expect(ResponseSynthesizer.systemPrompt,
          contains('not done or not needed is'));
    });

    test('a digest that says so is not sent for repair', () async {
      final seen = _Seen();
      final stack = await openStack(scripted(
        seen: seen,
        loop: (call) => switch (call) {
          1 => toolUse('read_message_context', {'undigested_only': true}),
          2 => toolUse('mark_message_digested', {'chat': 'Carla Mendes'},
              id: 'toolu_2'),
          _ => endTurn('One photo, nothing to add. Marked it handled.'),
        },
        summary: _envelope(
          'I checked your chats and found one new message, a photo from '
          'Carla Mendes. Nothing in it needed a task. I marked it handled.',
          claims: [
            {
              'type': 'emails_digested',
              'description': '1 chat message read and marked as handled',
            },
          ],
        ),
      ));
      await seedMessage(stack.database, 'Carla Mendes', 'Photo',
          channel: 'whatsapp');

      final outcome = await stack.runner.runJob(await digestJob(stack.database));

      expect(outcome.success, isTrue);
      expect(seen.repairs, isEmpty);
      final turn = await turnOf(stack.database);
      expect(turn['repair_performed'], isFalse);
      expect(turn['rejected_claims'], isNull);
    });
  });

  group('what a repair was sent to correct is kept as it was written', () {
    test('the claim, not only that there was one', () async {
      final seen = _Seen();
      final stack = await openStack(scripted(
        seen: seen,
        loop: (call) => switch (call) {
          1 => toolUse('read_message_context', {'undigested_only': true}),
          2 => toolUse('mark_message_digested', {'chat': 'Omar Reid'},
              id: 'toolu_2'),
          _ => endTurn('Read one message and marked it.'),
        },
        summary: _envelope(
          'Omar Reid sent a quotation to review, so I added a task for it.',
          claims: [
            {'type': 'task_created', 'description': 'Review the quotation'},
          ],
        ),
        repair: _envelope(
          'Omar Reid sent a quotation to review. I did not add a task for '
          'it. The message is marked handled.',
        ),
      ));
      await seedMessage(stack.database, 'Omar Reid',
          'Forwarding the request for quotation. For review.');

      await stack.runner.runJob(await digestJob(stack.database));

      expect(seen.repairs, hasLength(1));
      final turn = await turnOf(stack.database);
      expect(turn['repair_reasons'], contains('unsupported_claim'));
      expect(turn['rejected_claims'], ['task_created: Review the quotation']);
    });

    test('within what a run record has room for', () {
      final kept = AgentTurnDiagnostics.claimsToKeep([
        for (var i = 0; i < 9; i++) 'task_created: ${'x' * 400} $i',
      ]);
      expect(kept, hasLength(AgentTurnDiagnostics.maxRejectedClaims));
      expect(
          kept.every((claim) =>
              claim.length <=
              AgentTurnDiagnostics.maxRejectedClaimChars + 3),
          isTrue);
      expect(AgentTurnDiagnostics.claimsToKeep(const ['a: b']), ['a: b']);
    });
  });

  group('DuplicateGuard: the same sender, reworded', () {
    test('a task names who it came from', () {
      expect(
          DuplicateGuard.names(
              'Finish past due training (KnowBe4)', 'KnowBe4'),
          isTrue);
      expect(
          DuplicateGuard.names(
              'Review the quotation. Forwarded by Omar Reid.', 'Omar Reid'),
          isTrue);
      expect(DuplicateGuard.names('Reid and Sons invoice', 'Omar Reid'), isFalse);
      // In the chat list with a label, in the task without it.
      expect(
          DuplicateGuard.names('From Carla Mendes on WhatsApp',
              'Carla Mendes (Mechanic)'),
          isTrue);
    });

    test('a one-word name is matched as it is written', () {
      expect(DuplicateGuard.names('From Flow (WhatsApp): the server', 'Flow'),
          isTrue);
      expect(DuplicateGuard.names('Check Power Automate flow', 'Flow'),
          isFalse);
      expect(DuplicateGuard.names('Workflow review', 'Flow'), isFalse);
    });

    test('an address is matched on whose it is', () {
      const address = 'do-not-reply@training.knowbe4.com';
      expect(
          DuplicateGuard.names(
              'Complete assigned training from KnowBe4', address),
          isTrue);
      expect(DuplicateGuard.names('Complete assigned training', address),
          isFalse);
      expect(
          DuplicateGuard.names(
              'Reply to Jsmith about the invoice', 'jsmith@gmail.com'),
          isTrue);
      expect(
          DuplicateGuard.names(
              'Renew the domain (Acme)', 'Billing <accounts@acme.co.uk>'),
          isTrue);
    });

    test('the reminders from the device are worth asking about', () {
      expect(
          DuplicateGuard.related(
            title: 'Complete assigned training from KnowBe4',
            existingTitle: 'Finish past due training (KnowBe4)',
            sender: 'KnowBe4',
          ),
          greaterThan(0));
      // Which the title check alone, rightly, lets through.
      expect(
          DuplicateGuard.sameTask(
            title: 'Complete assigned training from KnowBe4',
            existingTitle: 'Finish past due training (KnowBe4)',
          ),
          isFalse);
      // The sender's own address has "training" in it; the subject still
      // counts.
      expect(
          DuplicateGuard.related(
            title: 'Complete assigned training from KnowBe4',
            existingTitle:
                'Complete Security Awareness Foundations (SAF) training',
            sender: 'do-not-reply@training.knowbe4.com',
          ),
          greaterThan(0));
    });

    test('two jobs from one sender that share a verb, or a name, are not',
        () {
      expect(
          DuplicateGuard.related(
            title: 'Send budget to Northgate Technologies',
            existingTitle:
                'Send potential clients list to Northgate Technologies',
            sender: 'Northgate Technologies',
          ),
          0);
      expect(
          DuplicateGuard.related(
            title: 'Call Amy',
            existingTitle: 'Send Amy the report',
            sender: 'Amy',
          ),
          0);
    });

    test('a different number, or a month between them, is a different task',
        () {
      expect(
          DuplicateGuard.related(
            title: 'Process invoice for July 27',
            existingTitle: 'Process invoice for July 20',
            sender: 'Danielle',
          ),
          0);
      expect(
          DuplicateGuard.related(
            title: 'Pay rent to Omar',
            dueAt: DateTime(2026, 11, 1),
            existingTitle: 'Pay rent to Omar',
            existingDueAt: DateTime(2026, 10, 1),
            sender: 'Omar',
          ),
          0);
    });
  });

  group('an unattended create is held when the sender has one like it', () {
    const unattended = CapabilityContext(runMode: AgentRunMode.unattended);
    const reminder = {
      'title': 'Complete assigned training from KnowBe4',
      'description': 'Outlook message from KnowBe4 asks to complete assigned '
          'training. No deadline given.',
    };

    Future<TaskRepository> withOpenTask(_Stack stack) async {
      final tasks = TaskRepository(stack.database);
      await tasks.create(
        title: 'Finish past due training (KnowBe4)',
        description: 'Outlook message from KnowBe4: 1 past-due training '
            'assignment to complete.',
        createdBy: 'agent',
      );
      return tasks;
    }

    Future<Map<String, Object?>> create(
      _Stack stack,
      Map<String, Object?> input, {
      CapabilityContext capabilities = unattended,
    }) async {
      final result = await stack.registry
          .execute('create_task', input, capabilities: capabilities);
      expect(result.success, isTrue, reason: result.error);
      return (result.data as Map).cast<String, Object?>();
    }

    test('nothing is made, and what is already there is shown', () async {
      final stack = await openStack();
      final tasks = await withOpenTask(stack);
      await seedMessage(stack.database, 'KnowBe4',
          'Complete your assigned training. You only have');
      await seedMessage(stack.database, 'Omar Reid', 'See you at ten.');

      final held = await create(stack, reminder);

      expect(held['possible_duplicate'], isTrue);
      expect(held['created'], isFalse);
      expect(held['id'], isNull);
      expect(held['from'], 'KnowBe4');
      expect(
          [
            for (final task in held['similar_open_tasks'] as List)
              (task as Map)['title'],
          ],
          ['Finish past due training (KnowBe4)']);
      expect(held['note'], contains('not_a_duplicate'));
      expect(await tasks.list(), hasLength(1));
    });

    test('the model that says it is different work gets its task', () async {
      final stack = await openStack();
      final tasks = await withOpenTask(stack);
      await seedMessage(stack.database, 'KnowBe4', 'New course assigned.');

      final made =
          await create(stack, {...reminder, 'not_a_duplicate': true});

      expect(made['possible_duplicate'], isNull);
      expect(made['id'], isA<String>());
      expect(await tasks.list(openOnly: true), hasLength(2));
    });

    test('another sender, or another subject, is not held', () async {
      final stack = await openStack();
      final tasks = await withOpenTask(stack);
      await seedMessage(stack.database, 'KnowBe4', 'Your invoice is ready.');
      await seedMessage(stack.database, 'Omar Reid',
          'Can you finish the training deck by Friday?');

      final other = await create(stack, {
        'title': 'Finish the training deck',
        'description': 'Omar Reid asked on Teams, by Friday.',
      });
      final unrelated = await create(stack, {
        'title': 'Download invoice from KnowBe4',
        'description': 'KnowBe4 says the invoice is ready.',
      });

      expect(other['possible_duplicate'], isNull);
      expect(unrelated['possible_duplicate'], isNull);
      expect(await tasks.list(openOnly: true), hasLength(3));
    });

    test('one message waiting is where it came from, named or not', () async {
      final stack = await openStack();
      final tasks = await withOpenTask(stack);
      await seedMessage(stack.database, 'KnowBe4',
          'Complete your assigned training.');

      final held =
          await create(stack, {'title': 'Complete the assigned training'});

      expect(held['possible_duplicate'], isTrue);
      expect(await tasks.list(), hasLength(1));
    });

    test('a task already finished, or nothing waiting, holds nothing',
        () async {
      final stack = await openStack();
      final tasks = await withOpenTask(stack);

      // Nothing waiting: nothing to say who this is from.
      final first = await create(stack, reminder);
      expect(first['possible_duplicate'], isNull);

      for (final task in await tasks.list()) {
        await tasks.complete(task.id);
      }
      await seedMessage(stack.database, 'KnowBe4', 'Training assigned.');
      final second = await create(stack, reminder);
      expect(second['possible_duplicate'], isNull);
    });

    test('someone in the chat is never held', () async {
      final stack = await openStack();
      final tasks = await withOpenTask(stack);
      await seedMessage(stack.database, 'KnowBe4', 'Training assigned.');

      final made = await create(stack, reminder,
          capabilities: CapabilityContext.interactive);

      expect(made['possible_duplicate'], isNull);
      expect(await tasks.list(openOnly: true), hasLength(2));
    });

    test('it is not counted as a write, and signs nothing', () async {
      final stack = await openStack();
      final tasks = await withOpenTask(stack);
      await tasks.create(title: 'Send Amy the report');
      await seedMessage(stack.database, 'KnowBe4', 'Training assigned.');
      final ledger = WriteScopeLedger(WriteScope.unattendedDefault);
      final run = CapabilityContext(
        runMode: AgentRunMode.unattended,
        runId: 'run_held',
        writeLedger: ledger,
      );

      await create(stack, reminder, capabilities: run);
      // And the one that was there all along is not this run's either.
      final existing =
          await create(stack, {'title': 'Send Amy the report'},
              capabilities: run);

      expect(existing['already_exists'], isTrue);
      expect(ledger.total, 0);
      expect(await ProvenanceRepository(stack.database).byRun('run_held'),
          isEmpty);
    });

    test('the report never calls it created', () async {
      final stack = await openStack();
      final result = ToolResult.ok({
        'created': false,
        'possible_duplicate': true,
        'title': reminder['title'],
        'from': 'KnowBe4',
        'similar_open_tasks': [
          {'id': 'task_1', 'title': 'Finish past due training (KnowBe4)'},
        ],
      });
      final record = buildExecutionRecord(
        registry: stack.registry,
        toolUseId: 't',
        toolName: 'create_task',
        input: reminder,
        result: result,
        denied: false,
        isControlPlane: false,
        startedAt: DateTime(2026, 9, 28),
      );
      final report = reportOf([record]);

      expect(record.wasDeduplicated, isTrue);
      expect(record.createdEntityIds, isEmpty);
      expect(report.tasksCreated, isEmpty);
      expect(
          report.actionsCompleted.single,
          'Held back, not added: "Complete assigned training from KnowBe4" '
          'may be the open task "Finish past due training (KnowBe4)" again');
    });

    test('a run that leaves it at that shows no "Created task"', () async {
      final seen = _Seen();
      final stack = await openStack(scripted(
        seen: seen,
        loop: (call) => switch (call) {
          1 => toolUse('read_message_context', {'undigested_only': true}),
          2 => toolUse('create_task', reminder, id: 'toolu_2'),
          3 => toolUse('mark_message_digested', {'chat': 'KnowBe4'},
              id: 'toolu_3'),
          _ => endTurn('Already on the list.'),
        },
        summary: _envelope(
          'KnowBe4 sent another training reminder. That is already on your '
          'list as "Finish past due training (KnowBe4)", so I did not add '
          'it again. The message is marked handled.',
        ),
      ));
      final tasks = await withOpenTask(stack);
      await seedMessage(stack.database, 'KnowBe4',
          'Complete your assigned training. You only have');

      final outcome = await stack.runner.runJob(await digestJob(stack.database));

      expect(outcome.success, isTrue);
      expect(await tasks.list(), hasLength(1));
      expect(seen.repairs, isEmpty);
      // The model was shown what is already there.
      expect(jsonEncode(seen.actions[2]['messages']),
          contains('Finish past due training (KnowBe4)'));
      final turn = await turnOf(stack.database);
      expect(turn['duplicate_actions_blocked'], 1);
      final card = (await ChatRepository(stack.database).recent())
          .where((message) => message.role == 'assistant')
          .single;
      expect(card.meta?['tools_used'], isNot(contains('create_task')));
    });
  });
}
