import 'dart:convert';

import 'package:exa_mobile/agent/orchestrator/agent_orchestrator.dart';
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
import 'package:exa_mobile/services/ai_client/deepseek_client.dart';
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

/// The same pipeline the Anthropic tests exercise, run against DeepSeek: the
/// point is that routing, the tool loop and the final synthesis all work over
/// the OpenAI wire format with nothing provider-specific above the client.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() {
    // No secure-storage platform implementation in unit tests; answer the
    // channel so the stored DeepSeek key reads back.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (call) async => call.method == 'read' ? 'sk-deepseek-test' : null,
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      null,
    );
  });

  test('a DeepSeek turn routes, calls a tool, and synthesizes an answer',
      () async {
    final database = AppDatabase();
    await database.open(overridePath: inMemoryDatabasePath);
    addTearDown(database.close);

    final settings = SettingsRepository(database);
    await settings.setAiProvider(SettingsRepository.providerDeepSeek);

    final notifications = NotificationService();
    final mailAccounts = MailAccountRepository(database);
    final emails = EmailRepository(database);
    final schedule = ScheduleRepository(database);
    final tasks = TaskRepository(database);
    final registry = ToolRegistry(
      tasks: tasks,
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

    // Scripted DeepSeek: the stage-1 router call (no tools in the request)
    // picks the tasks domain; the first loop turn asks for create_task; the
    // final no-tool synthesis call (recognized by its system prompt) writes
    // the answer. Everything is in OpenAI shape, as the wire really is.
    var toolLoopCalls = 0;
    final requestedUrls = <String>[];
    final authHeaders = <String>[];
    final mockHttp = MockClient((request) async {
      requestedUrls.add(request.url.toString());
      authHeaders.add(request.headers['authorization'] ?? '');
      final decoded = (jsonDecode(request.body) as Map).cast<String, Object?>();
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
          'content': '{"message": "Added it.", '
              '"included_outputs": ["confirmation"]}',
        });
      }
      if (decoded['tools'] == null) {
        return reply({'role': 'assistant', 'content': '["tasks"]'});
      }
      toolLoopCalls++;
      if (toolLoopCalls == 1) {
        return reply({
          'role': 'assistant',
          'content': null,
          'tool_calls': [
            {
              'id': 'call_0_task',
              'type': 'function',
              'function': {
                'name': 'create_task',
                'arguments': '{"title":"Buy milk"}',
              },
            },
          ],
        });
      }
      return reply({'role': 'assistant', 'content': 'Added it.'});
    });

    final orchestrator = AgentOrchestrator(
      // Present but unused: picking DeepSeek must not fall back to Anthropic.
      client: ClaudeClient(httpClient: MockClient((_) async =>
          http.Response('{"error":{"message":"must not be called"}}', 500))),
      deepSeekClient: DeepSeekClient(httpClient: mockHttp),
      registry: registry,
      chat: ChatRepository(database),
      behaviors: BehaviorRepository(database),
      settings: settings,
    );

    final result = await orchestrator.run('Add a task to buy milk');

    expect(result.assistantText, contains('Added it.'));
    expect(result.toolsUsed, ['create_task']);
    // The tool actually ran against the database, not just in the transcript.
    final stored = await tasks.list();
    expect(stored.map((t) => t.title), contains('Buy milk'));
    // Every call went to DeepSeek, authenticated with the stored key.
    expect(requestedUrls,
        everyElement('https://api.deepseek.com/v1/chat/completions'));
    expect(authHeaders, everyElement('Bearer sk-deepseek-test'));
  });

  test('DeepSeek selected with no key sends the user to the provider screen',
      () async {
    final database = AppDatabase();
    await database.open(overridePath: inMemoryDatabasePath);
    addTearDown(database.close);

    // No secure storage at all: reads throw, which is what an unconfigured
    // key looks like from here.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (call) async => null,
    );

    final settings = SettingsRepository(database);
    await settings.setAiProvider(SettingsRepository.providerDeepSeek);

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
    );

    final orchestrator = AgentOrchestrator(
      client: ClaudeClient(
          httpClient: MockClient((_) async => http.Response('{}', 500))),
      deepSeekClient: DeepSeekClient(
          httpClient: MockClient((_) async => http.Response('{}', 500))),
      registry: registry,
      chat: ChatRepository(database),
      behaviors: BehaviorRepository(database),
      settings: settings,
    );

    final result = await orchestrator.run('Add a task to buy milk');

    // The turn fails where it can be fixed, rather than as a 401 later.
    expect(result.assistantText, contains('no API key is set'));
    expect(result.navigationTargets, ['/settings/ai-provider']);
  });
}
