import 'dart:convert';

import 'package:exa_mobile/agent/memory/models/agent_memory.dart';
import 'package:exa_mobile/agent/models/tool_execution_record.dart';
import 'package:exa_mobile/agent/orchestrator/agent_intelligence.dart';
import 'package:exa_mobile/agent/orchestrator/agent_orchestrator.dart';
import 'package:exa_mobile/agent/security/capability_policy.dart';
import 'package:exa_mobile/agent/services/duplicate_guard.dart';
import 'package:exa_mobile/agent/services/execution_report_builder.dart';
import 'package:exa_mobile/agent/services/source_grounding.dart';
import 'package:exa_mobile/agent/tools/tool_domains.dart';
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
  AgentIntelligence intelligence,
  AgentOrchestrator orchestrator,
  ToolRegistry registry,
});

/// A recurring "check my chats and file what you find" job, run on a small
/// model.
///
/// Observed on the device (2026-09-19): the undigested queue was empty, and
/// the job still filed the same three bank tasks again - from its own
/// previous result cards and run memories, with no read call in the run at
/// all - while other runs posted "read 80 messages, created 3 tasks" having
/// called no tool whatsoever. These tests hold the things that stop it: the
/// run inherits nothing from its past, it cannot create from nothing, it
/// cannot report work it did not start, the app - not the model - closes out
/// what was read, and an unattended create returns what already exists.
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

  /// A model whose agent-loop replies are scripted by [loop] (1-based call
  /// count); routing and the no-tool finalization calls are answered
  /// generically. Every request body is kept in [requests].
  MockClient scripted({
    required http.Response Function(int call, Map<String, Object?> body) loop,
    List<String> domains = const ['messages', 'tasks'],
    List<String>? requests,
    // Raw text for the routing call instead of a well-formed reply - what a
    // small model's router output looks like on a bad day.
    String? routerReply,
  }) {
    var loopCalls = 0;
    return MockClient((request) async {
      requests?.add(request.body);
      final body = (jsonDecode(request.body) as Map).cast<String, Object?>();
      final systemText =
          (((body['system'] as List).first as Map)['text'] ?? '') as String;
      if (systemText.contains('Do not call tools.')) {
        return endTurn(jsonEncode({
          'message': 'Went through the new messages.',
          'included_outputs': ['rundown'],
          'claims': <Object>[],
          'includes_failure_report': true,
        }));
      }
      if (body['tools'] == null) {
        if (routerReply != null) return endTurn(routerReply);
        return endTurn(jsonEncode({
          'domains': domains,
          'actions': [
            {'description': 'go_through_new_items', 'required': true},
          ],
          'response_outputs': ['rundown'],
          'requires_confirmation': false,
          'requires_synthesis': true,
          'requires_verification': true,
        }));
      }
      return loop(++loopCalls, body);
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
    final intelligence =
        AgentIntelligence.standard(database: database, registry: registry);
    final orchestrator = AgentOrchestrator(
      client: ClaudeClient(httpClient: mockHttp),
      registry: registry,
      chat: ChatRepository(database),
      behaviors: BehaviorRepository(database),
      settings: SettingsRepository(database),
      intelligence: intelligence,
    );
    runner.orchestratorFactory = () => orchestrator;
    await database.open(overridePath: inMemoryDatabasePath);
    addTearDown(database.close);
    return (
      runner: runner,
      database: database,
      intelligence: intelligence,
      orchestrator: orchestrator,
      registry: registry,
    );
  }

  const instructions = 'Check my chats for new messages and file any tasks, '
      'reminders or events you find.';

  var seeded = 0;
  Future<InboundMessage> seedMessage(
    AppDatabase database, {
    String body = 'Please send me the report by Friday.',
    String chat = 'Amy',
  }) async {
    // Distinct, increasing capture times: the undigested queue is served
    // oldest first, and two rows written in the same millisecond have no
    // order to assert on.
    final at = DateTime.now().add(Duration(seconds: seeded++));
    final stored = await InboundMessageRepository(database).add(InboundMessage(
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
    return stored!;
  }

  Future<ScheduledJob> chatDigestJob(
    AppDatabase database, {
    JobPermissions permissions = JobPermissions.none,
  }) =>
      JobRepository(database).create(
        name: 'Chat digest every 5 min',
        jobType: 'agent_task',
        description: instructions,
        scheduleRule: {'frequency': 'interval', 'interval_minutes': 5},
        permissions: permissions,
      );

  Future<List<String>> diagnosticCodes(AppDatabase database) async => [
        for (final event in await DiagnosticsRepository(database).recent())
          event.code,
      ];

  group('a scheduled run inherits nothing from its own past', () {
    const bait = 'Send personal profile to the bank via Marla Quinn';

    Future<void> seedPast(_Stack stack) async {
      final chat = ChatRepository(stack.database);
      await chat.append('user', 'What did the chat digest find?');
      await chat.append(
        'assistant',
        'I read about 80 new messages. Tasks created:\n- $bait',
        meta: {'source': 'scheduled_job', 'job_title': 'Chat digest'},
      );
      await stack.intelligence.memories.insert(
        type: AgentMemoryType.episodic,
        content: 'Request: "$instructions" - Created task: $bait',
        importance: 0.6,
        confidence: 0.95,
        sourceType: 'agent_turn',
        sourceId: 'turn_previous_run',
      );
      await stack.intelligence.memories.insert(
        type: AgentMemoryType.working,
        content: 'Unresolved from the last request ("$instructions"): '
            'could not mark chat messages - $bait',
        importance: 0.6,
        confidence: 0.95,
        sourceType: 'agent_turn',
        sourceId: 'turn_previous_run',
      );
    }

    http.Response readThenStop(int call, Map<String, Object?> _) => call == 1
        ? toolUse('read_message_context', {'undigested_only': true})
        : endTurn('Nothing new.');

    test('control: the same request as an ordinary turn DOES carry the old '
        'output, so the seeding is what a job used to be given', () async {
      final requests = <String>[];
      final stack =
          await openStack(scripted(requests: requests, loop: readThenStop));
      await seedPast(stack);

      await stack.orchestrator
          .run(instructions, unattended: true, isolated: false);

      expect(requests.any((body) => body.contains(bait)), isTrue);
    });

    test('a scheduled job is sent none of it', () async {
      final requests = <String>[];
      final stack =
          await openStack(scripted(requests: requests, loop: readThenStop));
      await seedPast(stack);

      final outcome =
          await stack.runner.runJob(await chatDigestJob(stack.database));

      expect(outcome.success, isTrue);
      expect(requests, isNotEmpty);
      expect(requests.where((body) => body.contains(bait)), isEmpty,
          reason: 'history, capsule and run memories must all stay out');
      expect(await TaskRepository(stack.database).list(), isEmpty);
    });

    test('and it leaves no run memory or chat referent behind', () async {
      final stack = await openStack(scripted(
        loop: (call, _) => switch (call) {
          1 => toolUse('read_message_context', {'undigested_only': true}),
          2 => toolUse('create_task', {'title': 'Send Amy the report'},
              id: 'toolu_2'),
          _ => endTurn('Filed one task.'),
        },
      ));
      await seedMessage(stack.database);

      final outcome =
          await stack.runner.runJob(await chatDigestJob(stack.database));
      expect(outcome.success, isTrue);
      expect(await TaskRepository(stack.database).list(), hasLength(1));

      final memories = await stack.intelligence.memories.listLive();
      expect(
          memories.where((memory) =>
              memory.type == AgentMemoryType.episodic ||
              memory.type == AgentMemoryType.working),
          isEmpty);
      final active = await stack.intelligence.activeEntities
          .resolveForTurn(stack.intelligence.conversationId);
      expect(active.entities, isEmpty,
          reason: '"cancel it" in chat must not resolve to a job\'s task');
    });
  });

  group('a scheduled digest cannot create from nothing', () {
    test('a create with no read behind it is refused, logged and not made',
        () async {
      final stack = await openStack(scripted(
        loop: (call, _) => call == 1
            ? toolUse('create_task', {'title': 'Call John'})
            : endTurn('Created a task to call John.'),
      ));

      await stack.runner.runJob(await chatDigestJob(stack.database));

      expect(await TaskRepository(stack.database).list(), isEmpty);
      final calls = await stack.database.db.query('tool_calls',
          where: 'tool_name = ?', whereArgs: ['create_task']);
      expect(calls.single['status'], 'denied');
      expect(calls.single['error_message'], contains('ungrounded_create'));
    });

    test('a read that returned nothing new is still nothing to create from',
        () async {
      final stack = await openStack(scripted(
        loop: (call, _) => switch (call) {
          1 => toolUse('read_message_context', {'undigested_only': true}),
          2 => toolUse('create_task', {'title': 'Follow up on the invoice'},
              id: 'toolu_2'),
          _ => endTurn('Done.'),
        },
      ));

      await stack.runner.runJob(await chatDigestJob(stack.database));

      expect(await TaskRepository(stack.database).list(), isEmpty);
    });

    test('when the routing call fails, the words of the request still make '
        'it a digest', () async {
      final stack = await openStack(scripted(
        routerReply: 'Sure! I will check the chats now.',
        loop: (call, _) => call == 1
            ? toolUse('create_task', {'title': 'Call John'})
            : endTurn('Created a task to call John.'),
      ));

      await stack.runner.runJob(await chatDigestJob(stack.database));

      expect(await TaskRepository(stack.database).list(), isEmpty);
      expect(SourceGrounding.impliedDomains(instructions), {'messages'});
      expect(
          SourceGrounding.impliedDomains('Go through my inbox each morning'),
          {'email'});
      expect(SourceGrounding.impliedDomains('Write me a quote'), isEmpty);
    });

    test('a job that was never about messages creates freely', () async {
      final stack = await openStack(scripted(
        domains: const ['tasks'],
        loop: (call, _) => call == 1
            ? toolUse('create_task', {'title': 'Submit my timesheet'})
            : endTurn('Added it.'),
      ));

      final job = await JobRepository(stack.database).create(
        name: 'Timesheet nudge',
        jobType: 'agent_task',
        description: 'Add a task to submit my timesheet.',
        scheduleRule: {'frequency': 'interval', 'interval_minutes': 60},
      );
      final outcome = await stack.runner.runJob(job);

      expect(outcome.success, isTrue);
      expect((await TaskRepository(stack.database).list()).single.title,
          'Submit my timesheet');
    });

    test('SourceGrounding reads the records, not the claim', () {
      ToolExecutionRecord record(String tool, Object? result,
              {ToolExecutionStatus status = ToolExecutionStatus.success}) =>
          ToolExecutionRecord(
            toolCallId: 't',
            toolName: tool,
            agentTurnId: 'turn',
            domain: ToolDomains.messages,
            arguments: const {},
            status: status,
            startedAt: DateTime(2026),
            completedAt: DateTime(2026),
            rawResult: result,
          );

      String? refusal(
        List<ToolExecutionRecord> records, {
        bool isolated = true,
        Set<String>? domains = const {'messages', 'tasks'},
        String tool = 'create_task',
      }) =>
          SourceGrounding.refusalFor(
              tool: tool,
              isolated: isolated,
              routedDomains: domains,
              records: records);

      expect(refusal(const []), isNotNull);
      // A directory of chats and a sync count are not content.
      expect(
          refusal([
            record('sync_messages', {'new_messages': 3}),
            record('list_chats', {
              'count': 4,
              'chats': [1, 2, 3, 4],
            }),
          ]),
          isNotNull);
      expect(
          refusal([
            record('read_message_context', {'count': 0, 'messages': []}),
          ]),
          isNotNull);
      expect(
          refusal([
            record(
                'read_message_context',
                {
                  'count': 2,
                  'messages': [1, 2],
                },
                status: ToolExecutionStatus.failure),
          ]),
          isNotNull);
      expect(
          refusal([
            record('read_message_context', {
              'count': 2,
              'messages': [1, 2],
            }),
          ]),
          isNull);
      expect(refusal([record('read_chat', {'showing': 5, 'total': 9})]),
          isNull);
      expect(
          refusal([
            record('read_message_context', {'id': 'm1', 'body': 'Call me'}),
          ]),
          isNull);
      // Out of scope entirely: chat turns, non-digest runs, other tools.
      expect(refusal(const [], isolated: false), isNull);
      expect(refusal(const [], domains: const {'tasks'}), isNull);
      expect(refusal(const [], domains: null), isNull);
      expect(refusal(const [], tool: 'update_task'), isNull);
    });
  });

  group('a scheduled run cannot report work it did not start', () {
    test('a run that answers without acting is told once to begin',
        () async {
      final loopBodies = <Map<String, Object?>>[];
      final stack = await openStack(scripted(
        loop: (call, body) {
          loopBodies.add(body);
          return switch (call) {
            1 => endTurn('I read 80 messages and created three tasks.'),
            2 => toolUse('read_message_context', {'undigested_only': true}),
            _ => endTurn('Nothing new.'),
          };
        },
      ));

      final outcome =
          await stack.runner.runJob(await chatDigestJob(stack.database));

      expect(outcome.success, isTrue);
      expect(jsonEncode(loopBodies[1]['messages']),
          contains('You have not called any tool'));
      expect(await diagnosticCodes(stack.database),
          contains('SCHEDULED_RUN_NUDGED'));
    });

    test('one that still does nothing fails the run instead of posting its '
        'story', () async {
      var loopCalls = 0;
      final stack = await openStack(scripted(
        loop: (call, _) {
          loopCalls = call;
          return endTurn('I read about 80 new messages and created three '
              'tasks: send your profile to the bank, sign the letters, '
              'collect the document file.');
        },
      ));

      final outcome =
          await stack.runner.runJob(await chatDigestJob(stack.database));

      expect(loopCalls, 2, reason: 'nudged once, never looped');
      expect(outcome.success, isFalse);
      expect(outcome.summary, contains('without checking anything'));
      expect(await ChatRepository(stack.database).recent(), isEmpty,
          reason: 'no card claiming three tasks');
      expect(await diagnosticCodes(stack.database),
          contains('SCHEDULED_RUN_DID_NOTHING'));
      expect(await TaskRepository(stack.database).list(), isEmpty);
    });

    test('a text-only job is delivered as written: never nudged, never '
        'failed', () async {
      var loopCalls = 0;
      final stack = await openStack(scripted(
        domains: const [],
        loop: (call, _) {
          loopCalls = call;
          return endTurn('"The best way out is always through." - Frost');
        },
      ));

      final job = await JobRepository(stack.database).create(
        name: 'Morning quote',
        jobType: 'agent_task',
        description: 'Write me one short motivational quote.',
        scheduleRule: {'frequency': 'interval', 'interval_minutes': 60},
      );
      final outcome = await stack.runner.runJob(job);

      expect(loopCalls, 1);
      expect(outcome.success, isTrue);
      final codes = await diagnosticCodes(stack.database);
      expect(codes, isNot(contains('SCHEDULED_RUN_NUDGED')));
      expect(codes, isNot(contains('SCHEDULED_RUN_DID_NOTHING')));
      expect(await ChatRepository(stack.database).recent(), hasLength(1));
    });

    test('a digest whose routing call failed is held to it all the same',
        () async {
      final stack = await openStack(scripted(
        routerReply: 'Sure! I will check the chats now.',
        loop: (_, _) => endTurn('I read 80 messages and created three tasks.'),
      ));

      final outcome =
          await stack.runner.runJob(await chatDigestJob(stack.database));

      expect(outcome.success, isFalse);
      expect(await ChatRepository(stack.database).recent(), isEmpty);
    });

    test('owesToolWork: a tool domain, a named tool, or neither', () {
      expect(
          SourceGrounding.owesToolWork(
              domains: const {'messages'}, plannedTools: const []),
          isTrue);
      expect(
          SourceGrounding.owesToolWork(domains: const {}, plannedTools: const [
            ['list_tasks'],
          ]),
          isTrue);
      expect(
          SourceGrounding.owesToolWork(
              domains: const {'core'}, plannedTools: const [[]]),
          isFalse);
    });

    test('a chat turn is never nudged', () async {
      var loopCalls = 0;
      final stack = await openStack(scripted(
        loop: (call, _) {
          loopCalls = call;
          return endTurn('Sure - which chat do you mean?');
        },
      ));

      final result =
          await stack.orchestrator.run(instructions, unattended: false);

      expect(loopCalls, 1);
      expect(result.didNothing, isFalse);
    });
  });

  group('the app closes out what a run read', () {
    test('messages the model was shown and never marked are marked for it',
        () async {
      final stack = await openStack(scripted(
        loop: (call, _) => switch (call) {
          1 => toolUse('read_message_context',
              {'undigested_only': true, 'limit': 15}),
          2 => toolUse('create_task', {'title': 'Send Amy the report'},
              id: 'toolu_2'),
          // What the device's model actually sent: the app's name as a chat.
          3 => toolUse('mark_message_digested', {'chat': 'whatsapp'},
              id: 'toolu_3'),
          _ => endTurn('Filed one task and marked everything handled.'),
        },
      ));
      final first = await seedMessage(stack.database);
      final second = await seedMessage(stack.database,
          body: 'Also - lunch on Tuesday?', chat: 'Lisa');

      final outcome =
          await stack.runner.runJob(await chatDigestJob(stack.database));

      expect(outcome.success, isTrue);
      final messages = InboundMessageRepository(stack.database);
      expect((await messages.getById(first.id))!.digested, isTrue);
      expect((await messages.getById(second.id))!.digested, isTrue);
      expect(await messages.countUndigested(), 0);
      expect(await diagnosticCodes(stack.database),
          contains('DIGEST_NOT_MARKED_BY_MODEL'));
    });

    test('a message the read never served is left for the next run',
        () async {
      final stack = await openStack(scripted(
        loop: (call, _) => call == 1
            ? toolUse('read_message_context',
                {'undigested_only': true, 'limit': 1})
            : endTurn('Read it.'),
      ));
      final served = await seedMessage(stack.database);
      final unseen = await seedMessage(stack.database,
          body: 'A later message', chat: 'Dana');

      await stack.runner.runJob(await chatDigestJob(stack.database));

      final messages = InboundMessageRepository(stack.database);
      expect((await messages.getById(served.id))!.digested, isTrue);
      expect((await messages.getById(unseen.id))!.digested, isFalse,
          reason: 'never marks what the turn did not see');
    });

    test('nothing is closed out when a change the run attempted was refused',
        () async {
      final stack = await openStack(scripted(
        loop: (call, _) => switch (call) {
          1 => toolUse('read_message_context', {'undigested_only': true}),
          2 => toolUse('create_task', {'title': 'Send Amy the report'},
              id: 'toolu_2'),
          _ => endTurn('Could not create the task.'),
        },
      ));
      final message = await seedMessage(stack.database);

      await stack.runner.runJob(await chatDigestJob(stack.database,
          permissions: const JobPermissions(blockedTools: {'create_task'})));

      expect(await TaskRepository(stack.database).list(), isEmpty);
      final stored =
          await InboundMessageRepository(stack.database).getById(message.id);
      expect(stored!.digested, isFalse,
          reason: 'the task is still owed, so the message stays queued');
      expect(await diagnosticCodes(stack.database),
          contains('DIGEST_CLOSE_OUT_SKIPPED'));
    });
  });

  group('DuplicateGuard', () {
    test('the copies seen on the device are recognized as copies', () {
      expect(
          DuplicateGuard.similarity(
              'Account Opening appointment - One Harbour Place',
              'Account opening appointment — One Harbour Place'),
          1);
      expect(
          DuplicateGuard.sameTask(
            title: 'Update Google Cloud payment card (expired Visa ••••0525)',
            existingTitle: 'Update expired payment card for Google Cloud '
                'Platform billing (Visa •• 0525)',
          ),
          isTrue);
      expect(
          DuplicateGuard.sameTask(
            title: 'Send your profile to Marla Quinn for the bank',
            existingTitle:
                'Send personal profile/background to the bank (via Marla '
                'Quinn)',
          ),
          isTrue);
    });

    test('related but different jobs stay separate', () {
      expect(
          DuplicateGuard.sameTask(
            title: 'Sign and return letters resent by Marla Quinn',
            existingTitle: 'Sign account documents prepared by Marla Quinn',
          ),
          isFalse);
      expect(
          DuplicateGuard.sameTask(
              title: 'Pay water bill', existingTitle: 'Pay electricity bill'),
          isFalse);
      expect(
          DuplicateGuard.sameTask(
              title: 'Reply to Lisa about lunch',
              existingTitle: 'Reply to Lisa about the meetings'),
          isFalse);
    });

    test('numbers are identifiers: a different number is a different record',
        () {
      expect(DuplicateGuard.similarity('Task 1', 'Task 2'), 0);
      expect(
          DuplicateGuard.sameTask(
              title: 'Process invoice for July 27',
              existingTitle: 'Process Invoice for July 20'),
          isFalse);
      expect(
          DuplicateGuard.sameTask(
              title: 'Process invoice for July 20',
              existingTitle: 'Process Invoice for July 20'),
          isTrue);
    });

    test('the same title a month apart is two occurrences', () {
      expect(
          DuplicateGuard.sameTask(
            title: 'Pay rent',
            dueAt: DateTime(2026, 11, 1),
            existingTitle: 'Pay rent',
            existingDueAt: DateTime(2026, 10, 1),
          ),
          isFalse);
      expect(
          DuplicateGuard.sameTask(
            title: 'Pay rent',
            dueAt: DateTime(2026, 10, 1, 9),
            existingTitle: 'Pay rent',
            existingDueAt: DateTime(2026, 10, 1),
          ),
          isTrue);
    });

    test('timed records must share the minute as well as the subject', () {
      final at = DateTime(2026, 9, 22, 12, 30);
      expect(
          DuplicateGuard.sameTimed(
              title: 'Account opening appointment',
              at: at,
              existingTitle: 'Account Opening appointment - One Harbour',
              existingAt: at),
          isTrue);
      expect(
          DuplicateGuard.sameTimed(
              title: 'Account opening appointment',
              at: at,
              existingTitle: 'Account Opening appointment',
              existingAt: at.add(const Duration(hours: 1))),
          isFalse);
      expect(
          DuplicateGuard.sameTimed(
              title: 'Dentist',
              at: at,
              existingTitle: 'Account Opening appointment',
              existingAt: at),
          isFalse);
    });
  });

  group('unattended creates return what the user already has', () {
    const unattended = CapabilityContext(runMode: AgentRunMode.unattended);
    MockClient idle() => scripted(loop: (_, _) => endTurn(''));

    test('a task', () async {
      final stack = await openStack(idle());
      final tasks = TaskRepository(stack.database);
      final existing = await tasks.create(
          title: 'Update expired payment card for Google Cloud Platform '
              'billing (Visa •• 0525)');

      final result = await stack.registry.execute(
        'create_task',
        {'title': 'Update Google Cloud payment card (expired Visa ••••0525)'},
        capabilities: unattended,
      );

      expect(result.success, isTrue);
      final data = (result.data as Map).cast<String, Object?>();
      expect(data['already_exists'], isTrue);
      expect(data['id'], existing.id);
      expect(await tasks.list(), hasLength(1));
    });

    test('but not once that task is done, and never for someone in the chat',
        () async {
      final stack = await openStack(idle());
      final tasks = TaskRepository(stack.database);
      await tasks.create(title: 'Send Amy the report');

      // Interactive: the person typing it twice meant it twice.
      await stack.registry
          .execute('create_task', {'title': 'Send Amy the report'});
      expect(await tasks.list(), hasLength(2));

      for (final task in await tasks.list()) {
        await tasks.complete(task.id);
      }
      final result = await stack.registry.execute(
          'create_task', {'title': 'Send Amy the report'},
          capabilities: unattended);
      expect((result.data as Map)['already_exists'], isNull);
      expect(await tasks.list(openOnly: true), hasLength(1));
    });

    test('an event at the same moment', () async {
      final stack = await openStack(idle());
      final start = DateTime.now().add(const Duration(days: 3)).copyWith(
          hour: 12, minute: 30, second: 0, millisecond: 0, microsecond: 0);

      Future<Map<String, Object?>> create(String title) async {
        final result = await stack.registry.execute(
          'create_schedule_event',
          {'title': title, 'start_at': start.toIso8601String()},
          capabilities: unattended,
        );
        expect(result.success, isTrue, reason: result.error);
        return (result.data as Map).cast<String, Object?>();
      }

      final first =
          await create('Account Opening appointment - One Harbour Place');
      final second =
          await create('Account opening appointment — One Harbour Place');

      expect(first['already_exists'], isNull);
      expect(second['already_exists'], isTrue);
      expect(second['id'], first['id']);
      expect(await ScheduleRepository(stack.database).listForDay(start),
          hasLength(1));
    });

    test('and the report never calls it created', () {
      const result = {
        'id': 'task_1',
        'title': 'Send Amy the report',
        'already_exists': true,
      };
      final records = [
        ToolExecutionRecord(
          toolCallId: 't',
          toolName: 'create_task',
          agentTurnId: 'turn',
          domain: ToolDomains.tasks,
          arguments: const {'title': 'Send Amy the report'},
          status: ToolExecutionStatus.success,
          startedAt: DateTime(2026),
          completedAt: DateTime(2026),
          rawResult: result,
          wasDeduplicated: true,
          summary: ExecutionReportBuilder.summarize(
            toolName: 'create_task',
            arguments: const {'title': 'Send Amy the report'},
            rawResult: result,
          ),
        ),
      ];
      final report = const ExecutionReportBuilder().build(
          originalRequest: instructions,
          records: records,
          entitiesTouched: const []);

      expect(report.tasksCreated, isEmpty);
      expect(report.actionsCompleted.single,
          'Already on the list, not added again: Send Amy the report');
    });
  });

  group('mark_message_digested says when it marked nothing', () {
    MockClient idle() => scripted(loop: (_, _) => endTurn(''));

    test('an app name matching a chat of that name marks zero, and says so',
        () async {
      final stack = await openStack(idle());
      final messages = InboundMessageRepository(stack.database);
      final system = await seedMessage(stack.database,
          body: 'Checking for new messages', chat: 'WhatsApp');
      await messages.markDigested(system.id);
      final real = await seedMessage(stack.database);

      final result = await stack.registry
          .execute('mark_message_digested', {'chat': 'whatsapp'});

      final data = (result.data as Map).cast<String, Object?>();
      expect(data['count'], 0);
      expect(data['note'], contains('Nothing was marked'));
      expect((await messages.getById(real.id))!.digested, isFalse);
    });

    test('an app name with no such chat is told it is an app', () async {
      final stack = await openStack(idle());
      await seedMessage(stack.database);

      final result = await stack.registry
          .execute('mark_message_digested', {'chat': 'teams'});

      expect(result.success, isFalse);
      expect(result.error, contains('is an app, not a chat'));
    });
  });
}
