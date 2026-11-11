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
import 'package:exa_mobile/services/ai_client/local_endpoint_client.dart';
import 'package:exa_mobile/services/background_jobs/job_runner.dart';
import 'package:exa_mobile/services/browser/browser_bridge.dart';
import 'package:exa_mobile/services/calendar/device_calendar_service.dart';
import 'package:exa_mobile/services/files/file_service.dart';
import 'package:exa_mobile/services/mail/mail_service.dart';
import 'package:exa_mobile/services/notifications/notification_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// DeepSeek cannot see. These cover where an image goes instead: a declared
/// local vision model first, Anthropic second, and a plain explanation when
/// there is neither.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  /// Answers the secure-storage channel per key, so a test can have a
  /// DeepSeek key and no Anthropic one - the case the fallback turns on.
  void mockSecureStorage({String? anthropic, String? deepSeek}) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (call) async {
        if (call.method != 'read') return null;
        final key = (call.arguments as Map?)?['key']?.toString() ?? '';
        return key.contains('deepseek') ? deepSeek : anthropic;
      },
    );
  }

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      null,
    );
  });

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

  Attachment snippet() => Attachment(
        name: 'snippet.png',
        mimeType: 'image/png',
        sizeBytes: 3,
        bytes: Uint8List.fromList([65, 66, 67]),
        kind: 'image',
      );

  /// A local server that answers everything with plain text, recording what
  /// it was sent.
  (http.Client, List<Map<String, Object?>>) recordingLocalServer() {
    final requests = <Map<String, Object?>>[];
    final client = MockClient((request) async {
      requests.add((jsonDecode(request.body) as Map).cast<String, Object?>());
      return http.Response(
        jsonEncode({
          'choices': [
            {
              'finish_reason': 'stop',
              'message': {'role': 'assistant', 'content': 'A receipt for £12.'},
            },
          ],
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    return (client, requests);
  }

  http.Client refusingClient(String label) => MockClient((_) async =>
      http.Response('{"error":{"message":"$label must not be called"}}', 500));

  test('an image on DeepSeek goes to the declared local vision model',
      () async {
    // An Anthropic key IS available, and still loses to the local model.
    mockSecureStorage(anthropic: 'sk-test-key', deepSeek: 'sk-deepseek');
    final database = AppDatabase();
    await database.open(overridePath: inMemoryDatabasePath);
    addTearDown(database.close);

    final settings = SettingsRepository(database);
    await settings.setAiProvider(SettingsRepository.providerDeepSeek);
    await settings.setLocalVision(true);
    await settings.setLocalBaseUrl('http://192.168.1.20:1234');
    await settings.setLocalModel('qwen2.5-vl');

    final (localHttp, localRequests) = recordingLocalServer();
    final orchestrator = AgentOrchestrator(
      client: ClaudeClient(httpClient: refusingClient('Anthropic')),
      deepSeekClient: DeepSeekClient(httpClient: refusingClient('DeepSeek')),
      localClient:
          LocalEndpointClient(baseUrl: '', httpClient: localHttp),
      registry: buildRegistry(database),
      chat: ChatRepository(database),
      behaviors: BehaviorRepository(database),
      settings: settings,
    );

    final result = await orchestrator.run(
      'What is this?',
      attachments: [snippet()],
      requireVision: true,
    );

    expect(result.assistantText, contains('receipt'));
    // The declared local model wins over the cloud: the image stays on the
    // user's own network and costs nothing.
    expect(localRequests, isNotEmpty);
    expect(localRequests.first['model'], 'qwen2.5-vl');
    // ...and it really carried the picture, not a note about one.
    final withImage = localRequests.where((body) =>
        jsonEncode(body['messages']).contains('data:image/png;base64,QUJD'));
    expect(withImage, isNotEmpty);
    // The image is labelled with its file name. `store_file` resolves an
    // attachment by name, and an image block carries none - without this the
    // model invents a name, the lookup misses, and the user is told the image
    // failed to attach right after it was described correctly.
    expect(jsonEncode(withImage.first['messages']),
        contains('[Image file: snippet.png]'));

    final last = (await ChatRepository(database).recent()).last;
    expect(last.meta?['provider_forced'], 'local');
  });

  test('with no local vision model the image falls back to Anthropic',
      () async {
    mockSecureStorage(anthropic: 'sk-test-key', deepSeek: 'sk-deepseek');
    final database = AppDatabase();
    await database.open(overridePath: inMemoryDatabasePath);
    addTearDown(database.close);

    final settings = SettingsRepository(database);
    await settings.setAiProvider(SettingsRepository.providerDeepSeek);
    // The switch is off, so the local server is assumed text-only.
    await settings.setLocalVision(false);

    var anthropicCalls = 0;
    final anthropicHttp = MockClient((request) async {
      anthropicCalls++;
      return http.Response(
        jsonEncode({
          'stop_reason': 'end_turn',
          'content': [
            {'type': 'text', 'text': 'A receipt for £12.'},
          ],
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    });

    final orchestrator = AgentOrchestrator(
      client: ClaudeClient(httpClient: anthropicHttp),
      deepSeekClient: DeepSeekClient(httpClient: refusingClient('DeepSeek')),
      localClient: LocalEndpointClient(
          baseUrl: '', httpClient: refusingClient('the local server')),
      registry: buildRegistry(database),
      chat: ChatRepository(database),
      behaviors: BehaviorRepository(database),
      settings: settings,
    );

    final result = await orchestrator.run(
      'What is this?',
      attachments: [snippet()],
      requireVision: true,
    );

    expect(result.assistantText, contains('receipt'));
    expect(anthropicCalls, greaterThan(0));
    final last = (await ChatRepository(database).recent()).last;
    expect(last.meta?['provider_forced'], 'remote');
  });

  test('with nothing that can see, the snippet turn says what would fix it',
      () async {
    // A DeepSeek key, but nothing anywhere that can see an image.
    mockSecureStorage(deepSeek: 'sk-deepseek');
    final database = AppDatabase();
    await database.open(overridePath: inMemoryDatabasePath);
    addTearDown(database.close);

    final settings = SettingsRepository(database);
    await settings.setAiProvider(SettingsRepository.providerDeepSeek);
    await settings.setLocalVision(false);

    final orchestrator = AgentOrchestrator(
      client: ClaudeClient(httpClient: refusingClient('Anthropic')),
      deepSeekClient: DeepSeekClient(httpClient: refusingClient('DeepSeek')),
      localClient: LocalEndpointClient(
          baseUrl: '', httpClient: refusingClient('the local server')),
      registry: buildRegistry(database),
      chat: ChatRepository(database),
      behaviors: BehaviorRepository(database),
      settings: settings,
    );

    final result = await orchestrator.run(
      'What is this?',
      attachments: [snippet()],
      requireVision: true,
    );

    expect(result.assistantText, contains('local vision model'));
    expect(result.navigationTargets, ['/settings/ai-provider']);
  });
}
