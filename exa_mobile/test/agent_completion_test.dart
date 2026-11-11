import 'dart:convert';

import 'package:exa_mobile/agent/models/tool_execution_record.dart';
import 'package:exa_mobile/agent/models/turn_contract.dart';
import 'package:exa_mobile/agent/orchestrator/agent_orchestrator.dart';
import 'package:exa_mobile/agent/tools/tool_registry.dart';
import 'package:exa_mobile/data/database/app_database.dart';
import 'package:exa_mobile/data/repositories/behavior_repository.dart';
import 'package:exa_mobile/data/repositories/browser_context_repository.dart';
import 'package:exa_mobile/data/repositories/chat_repository.dart';
import 'package:exa_mobile/data/repositories/diagnostics_repository.dart';
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

http.Response textReply(String text) => jsonResponse({
      'stop_reason': 'end_turn',
      'content': [
        {'type': 'text', 'text': text},
      ],
    });

http.Response toolUseReply(String id, String name, Map<String, Object?> input) =>
    jsonResponse({
      'stop_reason': 'tool_use',
      'content': [
        {'type': 'tool_use', 'id': id, 'name': name, 'input': input},
      ],
    });

/// end_turn with no text at all - the "agent stops before producing the
/// requested rundown" bug case this upgrade exists to fix.
http.Response emptyReply() => jsonResponse({
      'stop_reason': 'end_turn',
      'content': <Map<String, Object?>>[],
    });

String systemTextOf(Map<String, Object?> body) =>
    (((body['system'] as List).first as Map)['text'] ?? '') as String;

bool isSynthesisCall(Map<String, Object?> body) =>
    systemTextOf(body).contains('already-executed');

bool isRepairCall(Map<String, Object?> body) =>
    systemTextOf(body).contains('requested actions have already been executed');

bool isRouterCall(Map<String, Object?> body) =>
    body['tools'] == null && !isSynthesisCall(body) && !isRepairCall(body);

Set<String> toolNamesOf(Map<String, Object?> requestBody) =>
    ((requestBody['tools'] as List).cast<Map>())
        .map((t) => t['name'] as String)
        .toSet();

String userPromptOf(Map<String, Object?> body) =>
    ((body['messages'] as List).first as Map)['content'] as String;

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

  test('email digest: actions complete AND the rundown is returned',
      () async {
    final emails = EmailRepository(database);
    await emails.add(
      subject: 'CoinRoutes transfers',
      sender: 'Tanner',
      body: 'Are transfer records exposed separately from trades and orders?',
    );
    await emails.add(
      subject: 'Business Central reports',
      sender: 'Amy',
      body: 'Can you send an update on the affected reports?',
    );

    const synthesizedMessage =
        'I reviewed 2 emails. Tanner asked whether CoinRoutes exposes '
        'transfers separately, and Amy wants a Business Central update. '
        'I created one task: Confirm CoinRoutes transfer availability. '
        'No meetings or deadlines were found.';

    final requests = <Map<String, Object?>>[];
    var loopCalls = 0;
    var repairCalls = 0;
    final mockHttp = MockClient((request) async {
      final body = (jsonDecode(request.body) as Map).cast<String, Object?>();
      requests.add(body);
      if (isSynthesisCall(body)) {
        return textReply(jsonEncode({
          'message': synthesizedMessage,
          'included_outputs': [
            'rundown', 'task_list', 'meeting_list', 'deadline_list',
            'attention_items',
          ],
        }));
      }
      if (isRepairCall(body)) {
        repairCalls++;
        return textReply('{"message": "repaired", "included_outputs": []}');
      }
      if (isRouterCall(body)) {
        return textReply(jsonEncode({
          'domains': ['email', 'tasks'],
          'actions': ['review_emails', 'create_tasks'],
          'response_outputs': ['rundown', 'task_list'],
          'requires_confirmation': false,
          'requires_synthesis': true,
        }));
      }
      loopCalls++;
      return switch (loopCalls) {
        1 => toolUseReply('toolu_1', 'read_email_context',
            {'undigested_only': true}),
        2 => toolUseReply('toolu_2', 'create_task',
            {'title': 'Confirm CoinRoutes transfer availability'}),
        // The action phase ends with NO text - previously the user got
        // nothing; now synthesis must produce the rundown.
        _ => emptyReply(),
      };
    });

    final result = await orchestratorWith(mockHttp)
        .run('Digest my emails, create any tasks, and give me a short '
            'rundown.');

    // The router scoped the toolbox to email + tasks (plus core).
    final firstLoopRequest = requests.firstWhere((r) => r['tools'] != null);
    final names = toolNamesOf(firstLoopRequest);
    expect(names, containsAll(['read_email_context', 'create_task']));
    expect(names, isNot(contains('read_current_browser_page')));
    expect(names, isNot(contains('create_dynamic_screen')));

    // Emails were read and the task was created - exactly once.
    final tasks = await TaskRepository(database).list();
    expect(tasks, hasLength(1));
    expect(tasks.single.title, 'Confirm CoinRoutes transfer availability');

    // A final no-tool synthesis call happened and produced the rundown.
    final synthesisRequest = requests.where(isSynthesisCall).single;
    expect(synthesisRequest['tools'], isNull,
        reason: 'the synthesis call must receive no tool definitions');
    final synthesisPrompt = userPromptOf(synthesisRequest);
    expect(synthesisPrompt, contains('"email_digest_items"'));
    expect(synthesisPrompt, contains('Confirm CoinRoutes'));
    expect(result.assistantText, synthesizedMessage);

    // No repair was needed, and the report preserved the digest data.
    expect(repairCalls, 0);
    expect(result.report!.emailDigestItems, hasLength(2));
    expect(result.report!.tasksCreated, hasLength(1));
    expect(result.diagnostics!.synthesisPerformed, isTrue);
    expect(result.diagnostics!.repairPerformed, isFalse);
    expect(result.diagnostics!.userActionToolCalls, 2);
  });

  test('missing required output triggers exactly one no-tool repair',
      () async {
    final requests = <Map<String, Object?>>[];
    var loopCalls = 0;
    var synthesisCalls = 0;
    var repairCalls = 0;
    final mockHttp = MockClient((request) async {
      final body = (jsonDecode(request.body) as Map).cast<String, Object?>();
      requests.add(body);
      if (isSynthesisCall(body)) {
        synthesisCalls++;
        // Omits the required rundown.
        return textReply(
            '{"message": "Task created!", "included_outputs": []}');
      }
      if (isRepairCall(body)) {
        repairCalls++;
        return textReply('{"message": "Rundown: one task was created - '
            'Buy milk, due tomorrow.", "included_outputs": ["rundown"]}');
      }
      if (isRouterCall(body)) {
        return textReply(jsonEncode({
          'domains': ['tasks'],
          'actions': ['create_task'],
          'response_outputs': ['rundown'],
          'requires_confirmation': false,
          'requires_synthesis': true,
        }));
      }
      loopCalls++;
      return loopCalls == 1
          ? toolUseReply('toolu_1', 'create_task', {'title': 'Buy milk'})
          : emptyReply();
    });

    final result = await orchestratorWith(mockHttp)
        .run('Add a task to buy milk and give me a rundown of what changed.');

    expect(synthesisCalls, 1);
    expect(repairCalls, 1, reason: 'repair runs at most once');
    // The repair prompt names the missing output and cannot execute tools.
    final repairRequest = requests.where(isRepairCall).single;
    expect(repairRequest['tools'], isNull);
    expect(userPromptOf(repairRequest), contains('- rundown'));
    // The corrected response is returned to the user.
    expect(result.assistantText, contains('Rundown: one task was created'));
    // Repair did not duplicate the action.
    expect(await TaskRepository(database).list(), hasLength(1));
    expect(result.diagnostics!.repairPerformed, isTrue);
    expect(result.diagnostics!.missingOutputsBeforeRepair, isNotEmpty);
    expect(result.diagnostics!.missingOutputsAfterRepair, isEmpty);
  });

  test('mid-turn expansion adds calendar tools without consuming the '
      'action limit', () async {
    final requests = <Map<String, Object?>>[];
    var loopCalls = 0;
    final startAt =
        DateTime.now().add(const Duration(days: 1)).toIso8601String();
    final mockHttp = MockClient((request) async {
      final body = (jsonDecode(request.body) as Map).cast<String, Object?>();
      requests.add(body);
      if (isSynthesisCall(body)) {
        return textReply(jsonEncode({
          'message': 'Your client meeting is on the calendar for tomorrow.',
          // Reading email pulls in the email-review output profile, so a
          // coherent answer here has to declare those outputs too.
          'included_outputs': [
            'confirmation', 'result_list', 'warning_list', 'rundown',
            'task_list', 'meeting_list', 'deadline_list', 'attention_items',
          ],
        }));
      }
      if (isRepairCall(body)) {
        return textReply('{"message": "repaired", "included_outputs": []}');
      }
      if (isRouterCall(body)) {
        return textReply(jsonEncode({
          'domains': ['email'],
          'actions': ['review_emails', 'add_meetings'],
          'response_outputs': <String>[],
          'requires_confirmation': false,
          'requires_synthesis': false,
        }));
      }
      loopCalls++;
      return switch (loopCalls) {
        1 => toolUseReply('toolu_1', 'expand_tools', {
            'domains': ['calendar'],
          }),
        // The router asked for two things, so the script has to do both: an
        // action with no tool call behind it is now left unresolved, which
        // would send this turn through a repair instead of the synthesis the
        // expansion assertions below are reading.
        2 => toolUseReply('toolu_2', 'read_email_context', const {}),
        3 => toolUseReply('toolu_3', 'create_schedule_event', {
            'title': 'Client meeting',
            'start_at': startAt,
          }),
        _ => emptyReply(),
      };
    });

    final result = await orchestratorWith(mockHttp)
        .run('Review my emails and add any meetings.');

    // Calendar tools were absent before expansion, present after.
    final loopRequests =
        requests.where((r) => r['tools'] != null).toList();
    expect(toolNamesOf(loopRequests[0]),
        isNot(contains('create_schedule_event')));
    expect(toolNamesOf(loopRequests[0]), contains('expand_tools'));
    expect(toolNamesOf(loopRequests[1]), contains('create_schedule_event'));

    // Expansion is control-plane: it never consumes the action budget.
    expect(result.diagnostics!.scopeExpansionCalls, 1);
    expect(result.diagnostics!.userActionToolCalls, 2);

    // Both routed actions have evidence behind them, so nothing is left
    // unresolved and the turn is not sent to repair.
    expect(result.diagnostics!.requiredActions, 2);
    expect(result.diagnostics!.unresolvedRequiredActions, 0);

    // The event exists and the final synthesis mentions the meeting.
    final now = DateTime.now();
    final events = await ScheduleRepository(database)
        .listBetween(now, now.add(const Duration(days: 2)));
    expect(events.map((e) => e.title), contains('Client meeting'));
    expect(result.assistantText, contains('client meeting'));
    expect(result.report!.eventsCreated, hasLength(1));
  });

  group('the response gateway', () {
    /// A conversational turn: the router says no tools are needed, the loop
    /// answers directly, and no synthesis runs. That is the commonest kind of
    /// turn, and until the gateway existed it was the kind whose text reached
    /// the user without the user's own formatting rules ever being applied.
    MockClient conversationalTurn(String answer) =>
        MockClient((request) async {
          final body = (jsonDecode(request.body) as Map).cast<String, Object?>();
          if (isRouterCall(body)) {
            return textReply(jsonEncode({
              'domains': <String>[],
              'actions': <String>[],
              'response_outputs': <String>[],
              'requires_confirmation': false,
              'requires_synthesis': false,
            }));
          }
          return textReply(answer);
        });

    test('a fast-path answer obeys the user\'s formatting rules', () async {
      await BehaviorRepository(database).createActive(
        behaviorType: 'preference_rule',
        title: 'Two bullets at most',
        ruleText: 'Keep answers to at most two bullet points.',
        params: const {'max_bullets': 2},
      );

      final result = await orchestratorWith(
        conversationalTurn('Some thoughts:\n- one\n- two\n- three\n- four'),
      ).run('what should I focus on?');

      // No synthesis ran, so this is the gateway's only chance to apply the
      // rule - and it took it.
      expect(result.diagnostics!.synthesisPerformed, isFalse);
      expect(result.assistantText, contains('- two'));
      expect(result.assistantText, isNot(contains('- three')));

      // What the user sees in the transcript is what was validated, not the
      // raw text the model produced.
      final stored = await ChatRepository(database).recent();
      expect(stored.last.content, result.assistantText);
    });

    test('a fast-path answer with no rules is delivered unchanged', () async {
      const answer = 'Focus on the invoice - it is the only overdue item.';
      final result =
          await orchestratorWith(conversationalTurn(answer)).run('what now?');
      expect(result.assistantText, answer);
    });

    test('an unsupported date on the fast path is reported, not rewritten',
        () async {
      // Verification never sees this turn, so nothing else would notice. It is
      // reported rather than repaired: on a conversational turn the evidence is
      // thin by nature, and this is the wrong place to second-guess an answer
      // that may be perfectly good.
      final result = await orchestratorWith(
        conversationalTurn('Your renewal lands on March 3, 2026.'),
      ).run('when does my renewal land?');

      expect(result.assistantText, contains('March 3, 2026'));
      final events = await DiagnosticsRepository(database).recent(limit: 50);
      expect(
        events.map((e) => e.code),
        contains('RESPONSE_DATE_UNSUPPORTED_AT_DELIVERY'),
      );
    });
  });

  group('a request Exa cannot interpret', () {
    /// "delete it" on a fresh conversation: high risk, a bare reference, and
    /// nothing anywhere to resolve it against. The frame produces a blocking
    /// slot, which used to set `AssumptionPolicy.askFirst` and then be ignored.
    MockClient ambiguousTurn({
      required List<String> attemptedTools,
      required List<String> synthesisOutputs,
    }) {
      var loopCalls = 0;
      return MockClient((request) async {
        final body = (jsonDecode(request.body) as Map).cast<String, Object?>();
        if (isSynthesisCall(body)) {
          return textReply(jsonEncode({
            'message': "I haven't deleted anything. Two tasks could be "
                '"it": Send invoice to Acme, and Chase the Acme invoice. '
                'Which should I delete?',
            'included_outputs': synthesisOutputs,
            // The blocked write is recorded as a refused action, so the
            // honest answer to one of these turns does two things: it says
            // nothing was done, and it asks. Declaring only the question
            // leaves the verifier's `undisclosed_failure` check unsatisfied -
            // correctly, because "which one?" on its own reads as though the
            // deletion is still pending.
            'includes_failure_report': true,
          }));
        }
        if (isRepairCall(body)) {
          return textReply(jsonEncode({
            'message': "I haven't deleted anything - which of the two Acme "
                'tasks did you mean?',
            'included_outputs': ['follow_up_question'],
            'includes_failure_report': true,
          }));
        }
        if (isRouterCall(body)) {
          return textReply(jsonEncode({
            'domains': ['tasks'],
            'actions': [
              {'description': 'delete_task', 'required': true},
            ],
            'response_outputs': <String>[],
            'requires_confirmation': false,
            'requires_synthesis': false,
          }));
        }
        loopCalls++;
        if (loopCalls <= attemptedTools.length) {
          final tool = attemptedTools[loopCalls - 1];
          return toolUseReply('toolu_$loopCalls', tool,
              tool == 'delete_task' ? const {'id': 'task_x'} : const {});
        }
        return emptyReply();
      });
    }

    test('reads, changes nothing, and asks', () async {
      final task = await TaskRepository(database).create(title: 'Send invoice');

      final result = await orchestratorWith(ambiguousTurn(
        attemptedTools: ['list_tasks', 'delete_task'],
        synthesisOutputs: ['follow_up_question'],
      )).run('delete it', unattended: false);

      final byTool = {
        for (final record in result.executionRecords) record.toolName: record,
      };

      // The read went through - that is how the question can name the
      // candidates instead of asking a bare "which one?".
      expect(byTool['list_tasks']!.status, ToolExecutionStatus.success);

      // The write did not, and was refused by the gate rather than failing.
      expect(byTool['delete_task']!.status, ToolExecutionStatus.denied);
      final surviving = await TaskRepository(database).list();
      expect(surviving, hasLength(1),
          reason: 'nothing may be deleted on a guess');
      expect(surviving.single.id, task.id);

      // The question is a contract requirement, not a suggestion.
      expect(result.contract!.requiredOutputs,
          contains(ResponseOutputType.followUpQuestion));
      expect(result.diagnostics!.blockedOnAmbiguity, isTrue);
      expect(result.diagnostics!.ambiguitySlots, contains('referent'));
      expect(result.assistantText, contains('Which should I delete?'));

      // Asking is not failing. The planned action is `skipped` - terminal, so
      // the resolver leaves it alone - and the completion metric must not
      // report this turn as having dropped work.
      expect(result.contract!.actions.single.status,
          ContractItemStatus.skipped);
      expect(result.diagnostics!.unresolvedRequiredActions, 0);
      expect(result.verification!.passed, isTrue);
    });

    test('an answer that does not actually ask fails verification', () async {
      await TaskRepository(database).create(title: 'Send invoice');

      // Synthesis declares a confirmation instead of the question it owes.
      final result = await orchestratorWith(ambiguousTurn(
        attemptedTools: ['list_tasks'],
        synthesisOutputs: ['confirmation'],
      )).run('delete it', unattended: false);

      expect(result.diagnostics!.missingOutputsBeforeRepair,
          contains(ResponseOutputType.followUpQuestion));
      expect(result.diagnostics!.repairPerformed, isTrue,
          reason: 'the existing verifier already enforces required outputs, '
              'so "did it actually ask?" needed no new checking code');
      expect(result.assistantText,
          "I haven't deleted anything - which of the two Acme tasks did you "
          'mean?');
    });

    test('a deterministic render can never answer one of these turns',
        () async {
      // `analyze_snippet` already declares follow_up_question, so a renderer
      // case added for it would otherwise start answering ambiguous turns in
      // code - with a confirmation, and without asking anything.
      final result = await orchestratorWith(ambiguousTurn(
        attemptedTools: ['list_tasks'],
        synthesisOutputs: ['follow_up_question'],
      )).run('delete it', unattended: false);
      expect(result.diagnostics!.deterministicRender, isNull);
      expect(result.diagnostics!.synthesisPerformed, isTrue);
    });
  });

  test('hitting the action limit is disclosed, never silently dropped',
      () async {
    // The model keeps demanding create_task calls in batches of 13:
    // 24 execute (the cap), excess calls in-batch fail loudly, and the
    // batch requested after the loop exits is recorded as not-executed
    // so the report can never read as "everything completed".
    var loopCalls = 0;
    var taskN = 0;
    final mockHttp = MockClient((request) async {
      final body = (jsonDecode(request.body) as Map).cast<String, Object?>();
      if (isSynthesisCall(body)) {
        return textReply('{"message": "I hit the action limit; some tasks '
            'were not created.", "included_outputs": ["confirmation", '
            '"failure_report"]}');
      }
      if (isRepairCall(body)) {
        return textReply('{"message": "repaired", '
            '"included_outputs": ["confirmation", "failure_report"]}');
      }
      if (isRouterCall(body)) {
        return textReply(jsonEncode({
          'domains': ['tasks'],
          'actions': ['create_many_tasks'],
          'response_outputs': <String>[],
          'requires_confirmation': false,
          'requires_synthesis': false,
        }));
      }
      loopCalls++;
      return jsonResponse({
        'stop_reason': 'tool_use',
        'content': [
          for (var i = 0; i < 13; i++)
            {
              'type': 'tool_use',
              'id': 'toolu_${loopCalls}_$i',
              'name': 'create_task',
              'input': {'title': 'Task ${++taskN}'},
            },
        ],
      });
    });

    final result = await orchestratorWith(mockHttp)
        .run('Create a task for every line in this list.');

    // Exactly the budget executed - nothing beyond it.
    expect(await TaskRepository(database).list(), hasLength(24));
    expect(result.diagnostics!.userActionToolCalls, 24);

    // Both truncation shapes are visible in the report: in-batch refusals
    // and the dropped batch requested after the loop ended.
    final failures = result.report!.actionsFailed;
    expect(failures.where((f) => f.contains('Action limit reached')),
        hasLength(2));
    expect(failures.where((f) => f.contains('was not executed')),
        hasLength(13));
    // And the user-facing response came from synthesis, which saw them.
    expect(result.assistantText, contains('action limit'));
  });

  test('follow-up turns carry domains and active entities to the router',
      () async {
    String? reminderId;
    var phase = 1;
    final routerPrompts = <String>[];
    var turn2LoopCalls = 0;
    final remindAt =
        DateTime.now().add(const Duration(days: 1)).toIso8601String();
    final mockHttp = MockClient((request) async {
      final body = (jsonDecode(request.body) as Map).cast<String, Object?>();
      if (isSynthesisCall(body)) {
        return textReply('{"message": "Canceled your Stretch reminder.", '
            '"included_outputs": ["confirmation"]}');
      }
      if (isRepairCall(body)) {
        return textReply('{"message": "repaired", "included_outputs": []}');
      }
      if (isRouterCall(body)) {
        routerPrompts.add(userPromptOf(body));
        return textReply(jsonEncode({
          'domains': ['reminders'],
          'actions': [phase == 1 ? 'create_reminder' : 'cancel_reminder'],
          'response_outputs':
              phase == 1 ? <String>[] : ['confirmation'],
          'requires_confirmation': false,
          'requires_synthesis': phase != 1,
        }));
      }
      if (phase == 1) {
        // Turn 1: create the reminder, then confirm directly (no synthesis
        // needed for a single reminder write with no required outputs).
        if ((body['messages'] as List).length == 1) {
          return toolUseReply('toolu_1', 'create_reminder', {
            'title': 'Stretch',
            'remind_at': remindAt,
          });
        }
        return textReply('Reminder set for tomorrow.');
      }
      turn2LoopCalls++;
      return turn2LoopCalls == 1
          ? toolUseReply('toolu_2', 'cancel_reminder', {'id': reminderId})
          : emptyReply();
    });

    final orchestrator = orchestratorWith(mockHttp);

    // Turn one.
    await orchestrator.run('Remind me to stretch tomorrow at 8am.');
    final reminders = await ReminderRepository(database).listAll();
    expect(reminders, hasLength(1));
    reminderId = reminders.single.id;

    // The assistant message stored the follow-up context.
    final afterTurn1 = await ChatRepository(database).recent();
    final meta = afterTurn1.last.meta!;
    expect((meta['routed_domains'] as List), contains('reminders'));
    expect((meta['active_entities'] as Map)['reminder_id'], reminderId);

    // Turn two.
    phase = 2;
    final result = await orchestrator.run('Now cancel it.');

    // The router saw structured context: previous request, domains, entity.
    expect(routerPrompts, hasLength(2));
    final secondRouterPrompt = routerPrompts[1];
    expect(secondRouterPrompt, contains('previous_user_message'));
    expect(secondRouterPrompt, contains('Remind me to stretch'));
    expect(secondRouterPrompt, contains('reminders'));
    expect(secondRouterPrompt, contains(reminderId));

    // The correct reminder was canceled and the response confirms it.
    final after = await ReminderRepository(database).listAll();
    expect(after.single.status, 'Canceled');
    expect(result.assistantText, 'Canceled your Stretch reminder.');
  });
}
