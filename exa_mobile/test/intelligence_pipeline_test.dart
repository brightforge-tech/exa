import 'dart:convert';

import 'package:exa_mobile/agent/orchestrator/agent_intelligence.dart';
import 'package:exa_mobile/agent/orchestrator/agent_orchestrator.dart';
import 'package:exa_mobile/agent/tools/tool_registry.dart';
import 'package:exa_mobile/data/database/app_database.dart';
import 'package:exa_mobile/data/repositories/behavior_repository.dart';
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

/// End-to-end pipeline tests over the full intelligence layer (spec §20):
/// scripted model, real SQLite, real registry - only HTTP is mocked.
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

  (AgentOrchestrator, AppDatabase, ToolRegistry, AgentIntelligence)
      buildStack(MockClient mockHttp) {
    final database = AppDatabase();
    final notifications = NotificationService();
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
      jobRunner: JobRunner(database: database, notifications: notifications),
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
    return (orchestrator, database, registry, intelligence);
  }

  test(
      'scenario 1: email digest runs the full pipeline - contract, skill, '
      'entities, memory, verification, replay trace', () async {
    // Scripted model: router -> loop (read, then create+mark) -> synthesis.
    String? emailId;
    var loopCalls = 0;
    final mockHttp = MockClient((request) async {
      final decoded =
          (jsonDecode(request.body) as Map).cast<String, Object?>();
      final systemText =
          (((decoded['system'] as List).first as Map)['text'] ?? '') as String;
      if (systemText.contains('completing an already-executed')) {
        // Synthesis: declares every required output plus honest claims.
        return endTurn(jsonEncode({
          'message': 'I reviewed 1 email from Amy about Business Central '
              'reports. Created task: Send Amy a report update. No meetings '
              'or deadlines found. Nothing else needs attention.',
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
        // Router: structured contract + skill nomination.
        return endTurn(jsonEncode({
          'domains': ['email', 'tasks'],
          'actions': [
            {'description': 'review_emails', 'required': true},
            {'description': 'create_tasks', 'required': true},
          ],
          'response_outputs': ['rundown', 'task_list'],
          'constraints': ['Do not create duplicate tasks'],
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
      return endTurn('Reviewed and extracted.');
    });

    final (orchestrator, database, registry, intelligence) =
        buildStack(mockHttp);
    await database.open(overridePath: inMemoryDatabasePath);
    addTearDown(database.close);

    final email = await EmailRepository(database).add(
      subject: 'Business Central reports',
      body: 'Please send me an update on the BC reports. - Amy',
      sender: 'Amy <amy@example.com>',
    );
    emailId = email.id;

    final result = await orchestrator.run(
        'Digest my emails, create any tasks, and give me a short rundown.');

    // The turn completed with a real rundown, not a bare confirmation.
    expect(result.assistantText, contains('Amy'));
    expect(result.report, isNotNull);
    expect(result.report!.tasksCreated, hasLength(1));

    // Contract: persisted, actions resolved, digest outputs supplemented.
    final contract = result.contract!;
    expect(contract.skillId, isNotNull, reason: 'digest_emails matched');
    expect(
        contract.actions.every((action) => action.isResolved), isTrue);
    expect(contract.requiredOutputs.map((o) => o.wireName),
        containsAll(['rundown', 'task_list', 'attention_items']));
    final storedContract =
        await intelligence.contracts.getByTurnId(result.agentTurnId);
    expect(storedContract, isNotNull);
    expect(
        storedContract!.actions
            .where((action) => action.status.wireName == 'completed'),
        isNotEmpty);

    // Verification ran and passed; no repair was needed.
    expect(result.verification!.performed, isTrue);
    expect(result.verification!.passed, isTrue,
        reason: result.verification!.issues.map((i) => i.message).join('; '));
    expect(result.diagnostics!.repairPerformed, isFalse);
    expect(result.diagnostics!.skillName, 'digest_emails');

    // Entity graph: email + sender person + task, with sentBy edge.
    final entities = await database.db.query('agent_entities');
    final types = entities.map((row) => row['entity_type']).toSet();
    expect(types, containsAll(['email', 'person', 'task']));
    final relationships =
        await database.db.query('entity_relationships');
    expect(relationships.map((row) => row['relationship_type']),
        contains('sentBy'));

    // Active entity context is populated for follow-ups.
    final context = await intelligence.activeEntities.resolveForTurn('main');
    expect(context.entities, isNotEmpty);

    // Memory: an episodic record of the interaction was written.
    final memories = await intelligence.memories.listLive();
    expect(memories.map((m) => m.type.wireName), contains('episodic'));

    // Replay trace: recorded and redacted (no raw email addresses).
    final trace = await intelligence.replayTraces.latest();
    expect(trace, isNotNull);
    expect(trace!.agentTurnId, result.agentTurnId);
    expect(jsonEncode(trace.toolExecutions),
        isNot(contains('amy@example.com')));
    expect(trace.verificationResult['passed'], isTrue);

    // The email really was marked digested (no phantom claims).
    final storedEmail = await EmailRepository(database).getById(email.id);
    expect(storedEmail!.digested, isTrue);
  });

  test(
      'scenario 4: a response missing the rundown is repaired once, '
      'without repeating side effects', () async {
    var synthesisCalls = 0;
    var loopCalls = 0;
    var repairOfferedTools = false;
    final mockHttp = MockClient((request) async {
      final decoded =
          (jsonDecode(request.body) as Map).cast<String, Object?>();
      final systemText =
          (((decoded['system'] as List).first as Map)['text'] ?? '') as String;
      if (systemText.contains('completing an already-executed')) {
        synthesisCalls++;
        // First synthesis omits everything the contract demands.
        return endTurn(jsonEncode({
          'message': 'Task created!',
          'included_outputs': ['confirmation'],
          'claims': [
            {'type': 'task_created', 'description': 'Buy milk'},
          ],
          'includes_failure_report': false,
        }));
      }
      if (systemText.contains('Correct only the user-facing response')) {
        // Repair: supplies the missing outputs. No tools may be offered.
        repairOfferedTools =
            decoded['tools'] is List && (decoded['tools'] as List).isNotEmpty;
        return endTurn(jsonEncode({
          'message': 'Rundown: you asked for one task. Created task: Buy '
              'milk. Nothing needs attention.',
          'included_outputs': ['rundown', 'task_list', 'confirmation'],
          'claims': [
            {'type': 'task_created', 'description': 'Buy milk'},
          ],
          'includes_failure_report': false,
        }));
      }
      if (decoded['tools'] == null) {
        return endTurn(jsonEncode({
          'domains': ['tasks'],
          'actions': [
            {'description': 'create_task', 'required': true},
          ],
          'response_outputs': ['rundown', 'task_list', 'confirmation'],
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
              'input': {'title': 'Buy milk'},
            },
          ],
        });
      }
      return endTurn('Created.');
    });

    final (orchestrator, database, registry, intelligence) =
        buildStack(mockHttp);
    await database.open(overridePath: inMemoryDatabasePath);
    addTearDown(database.close);

    final result = await orchestrator.run(
        'Create a task to buy milk and give me a rundown of what you did.');

    // Repair happened exactly once and produced the missing outputs.
    expect(synthesisCalls, 1, reason: 'synthesis runs once; repair is a '
        'separate no-tool call');
    expect(repairOfferedTools, isFalse,
        reason: 'repair must never be able to call tools');
    expect(result.diagnostics!.repairPerformed, isTrue);
    expect(result.diagnostics!.missingOutputsBeforeRepair, isNotEmpty);
    expect(result.verification!.passed, isTrue);
    expect(result.assistantText, contains('Rundown'));

    // The side effect was NOT repeated by the repair.
    final tasks = await registry.execute('list_tasks', {});
    expect(((tasks.data as Map)['count']), 1);

    // The trace records that verification initially failed and repair ran.
    final trace = await intelligence.replayTraces.latest();
    expect(trace, isNotNull);
  });
}
