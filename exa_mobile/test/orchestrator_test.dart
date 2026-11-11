import 'dart:convert';

import 'package:exa_mobile/agent/orchestrator/agent_orchestrator.dart';
import 'package:exa_mobile/agent/tools/tool_registry.dart';
import 'package:exa_mobile/data/database/app_database.dart';
import 'package:exa_mobile/data/models/autonomy_level.dart';
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() {
    // flutter_secure_storage has no platform implementation in unit tests;
    // answer its channel so getApiKey() returns a test key.
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

  /// Reads two tabs in one turn through a scripted model and checks the
  /// loop completed. [autonomy] decides whether the confirmation-gated read
  /// asks at all; [onConfirm] is what the caller offers.
  Future<void> twoTabTurn({
    required AutonomyLevel autonomy,
    required ConfirmToolCall onConfirm,
  }) async {
    final database = AppDatabase();
    await database.open(overridePath: inMemoryDatabasePath);
    addTearDown(database.close);
    await SettingsRepository(database).setAutonomyLevel(autonomy);

    final bridge = BrowserBridge()
      ..register(
        listTabs: () async => const [
          BrowserTabInfo(
              index: 0, title: 'A', url: 'https://a.test', isActive: true),
          BrowserTabInfo(
              index: 1, title: 'B', url: 'https://b.test', isActive: false),
        ],
        snapshotTab: (tabIndex) async => BrowserPageSnapshot(
          title: 'Tab ${tabIndex ?? 0}',
          url: 'https://${tabIndex ?? 0}.test',
          text: 'Content of tab ${tabIndex ?? 0}',
        ),
      );

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
      jobRunner:
          JobRunner(database: database, notifications: notifications),
      browserContext: BrowserContextRepository(database),
      emails: emails,
      browserBridge: bridge,
      mailAccounts: mailAccounts,
      mail: MailService(accounts: mailAccounts, emails: emails),
      deviceCalendar: DeviceCalendarService(schedule: schedule),
      pendingCalendar: PendingCalendarRepository(database),
    );

    // Scripted model: the stage-1 router call (no tools in the request)
    // picks the browser domain; the first loop turn requests both tab
    // reads and the second produces the draft; the final no-tool synthesis
    // call (distinguished by its system prompt) writes the real answer.
    var apiCalls = 0;
    final mockHttp = MockClient((request) async {
      final decoded = (jsonDecode(request.body) as Map).cast<String, Object?>();
      final systemText =
          (((decoded['system'] as List).first as Map)['text'] ?? '') as String;
      if (systemText.contains('already-executed')) {
        return http.Response(
            jsonEncode({
              'stop_reason': 'end_turn',
              'content': [
                {
                  'type': 'text',
                  'text': '{"message": "Compared both tabs.", '
                      '"included_outputs": ["confirmation"]}',
                },
              ],
            }),
            200,
            headers: {'content-type': 'application/json'});
      }
      if (decoded['tools'] == null) {
        return http.Response(
            jsonEncode({
              'stop_reason': 'end_turn',
              'content': [
                {'type': 'text', 'text': '["browser"]'},
              ],
            }),
            200,
            headers: {'content-type': 'application/json'});
      }
      apiCalls++;
      final body = apiCalls == 1
          ? {
              'stop_reason': 'tool_use',
              'content': [
                {
                  'type': 'tool_use',
                  'id': 'toolu_1',
                  'name': 'read_current_browser_page',
                  'input': <String, Object?>{},
                },
                {
                  'type': 'tool_use',
                  'id': 'toolu_2',
                  'name': 'read_current_browser_page',
                  'input': {'tab_index': 1},
                },
              ],
            }
          : {
              'stop_reason': 'end_turn',
              'content': [
                {'type': 'text', 'text': 'Compared both tabs.'},
              ],
            };
      return http.Response(jsonEncode(body), 200,
          headers: {'content-type': 'application/json'});
    });

    final orchestrator = AgentOrchestrator(
      client: ClaudeClient(httpClient: mockHttp),
      registry: registry,
      chat: ChatRepository(database),
      behaviors: BehaviorRepository(database),
      settings: SettingsRepository(database),
    );

    final result =
        await orchestrator.run('Compare my open tabs', onConfirm: onConfirm);

    expect(result.assistantText, 'Compared both tabs.');
    expect(result.toolsUsed,
        ['read_current_browser_page', 'read_current_browser_page']);
    expect(apiCalls, 2);

    // Both pages were read and archived to shared-pages history.
    final stored = await BrowserContextRepository(database).recent();
    expect(stored, hasLength(2));
  }

  test(
      'reading two tabs in one turn asks for confirmation only once '
      'and completes the tool loop', () async {
    var confirmations = 0;
    await twoTabTurn(
      autonomy: AutonomyLevel.guarded,
      onConfirm: (toolName, input) async {
        confirmations++;
        return true;
      },
    );
    // One approval covered both reads in the same turn.
    expect(confirmations, 1);
  });

  test('under full autonomy the same turn asks nobody and still completes',
      () async {
    var confirmations = 0;
    await twoTabTurn(
      autonomy: AutonomyLevel.full,
      onConfirm: (toolName, input) async {
        confirmations++;
        return true;
      },
    );
    expect(confirmations, 0);
  });

  test('a tool-using turn attaches quick actions to the assistant message',
      () async {
    final database = AppDatabase();
    await database.open(overridePath: inMemoryDatabasePath);
    addTearDown(database.close);

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
      jobRunner:
          JobRunner(database: database, notifications: notifications),
      browserContext: BrowserContextRepository(database),
      emails: emails,
      browserBridge: BrowserBridge(),
      mailAccounts: mailAccounts,
      mail: MailService(accounts: mailAccounts, emails: emails),
      deviceCalendar: DeviceCalendarService(schedule: schedule),
      pendingCalendar: PendingCalendarRepository(database),
    );

    var apiCalls = 0;
    final mockHttp = MockClient((request) async {
      final decoded = (jsonDecode(request.body) as Map).cast<String, Object?>();
      final systemText =
          (((decoded['system'] as List).first as Map)['text'] ?? '') as String;
      if (systemText.contains('already-executed')) {
        // Final no-tool synthesis call (a task was created).
        return http.Response(
            jsonEncode({
              'stop_reason': 'end_turn',
              'content': [
                {
                  'type': 'text',
                  'text': '{"message": "Added it.", '
                      '"included_outputs": ["confirmation"]}',
                },
              ],
            }),
            200,
            headers: {'content-type': 'application/json'});
      }
      if (decoded['tools'] == null) {
        // Stage-1 router call.
        return http.Response(
            jsonEncode({
              'stop_reason': 'end_turn',
              'content': [
                {'type': 'text', 'text': '["tasks"]'},
              ],
            }),
            200,
            headers: {'content-type': 'application/json'});
      }
      apiCalls++;
      final body = apiCalls == 1
          ? {
              'stop_reason': 'tool_use',
              'content': [
                {
                  'type': 'tool_use',
                  'id': 'toolu_1',
                  'name': 'create_task',
                  'input': {'title': 'Buy milk'},
                },
              ],
            }
          : {
              'stop_reason': 'end_turn',
              'content': [
                {'type': 'text', 'text': 'Added it.'},
              ],
            };
      return http.Response(jsonEncode(body), 200,
          headers: {'content-type': 'application/json'});
    });

    final orchestrator = AgentOrchestrator(
      client: ClaudeClient(httpClient: mockHttp),
      registry: registry,
      chat: ChatRepository(database),
      behaviors: BehaviorRepository(database),
      settings: SettingsRepository(database),
    );

    await orchestrator.run('Add a task to buy milk');

    final messages = await ChatRepository(database).recent();
    final last = messages.last;
    expect(last.role, 'assistant');
    final actions =
        (last.meta?['quick_actions'] as List?)?.cast<Map>() ?? const [];
    expect(
        actions.any((a) => a['type'] == 'open' && a['value'] == '/tasks'),
        isTrue);
  });
}
