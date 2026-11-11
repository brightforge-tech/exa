import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:exa_mobile/agent/orchestrator/agent_orchestrator.dart';
import 'package:exa_mobile/agent/tools/tool_registry.dart';
import 'package:exa_mobile/data/database/app_database.dart';
import 'package:exa_mobile/data/models/inbound_message.dart';
import 'package:exa_mobile/data/repositories/behavior_repository.dart';
import 'package:exa_mobile/data/repositories/browser_context_repository.dart';
import 'package:exa_mobile/data/repositories/chat_repository.dart';
import 'package:exa_mobile/data/repositories/dynamic_screen_repository.dart';
import 'package:exa_mobile/data/repositories/email_repository.dart';
import 'package:exa_mobile/data/repositories/inbound_media_repository.dart';
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
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// The chat digest over messages that carry no words at all.
///
/// A photo and a voice note arrive as an empty body plus a media row, and
/// the digest path reads messages two ways at once: the trigger's own scope
/// filter (code, before any model call) and the rows of `read_message_context`
/// (what the model actually sees). If either half looked only at `body`, a
/// media-only message would be invisible - dropped by the filter, or shown
/// as an empty line the model might fill in with an invention. These tests
/// run the real digest job and hold every provider request: both views show
/// the labelled note, and no image or audio byte is ever part of the turn.
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

  late Directory work;
  late String mediaDir;
  late AppDatabase database;
  late InboundMediaRepository mediaRepo;
  late InboundMessageRepository messages;
  late List<String> requests;
  late JobRunner runner;

  // ------------------------------------------------------------- the model

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

  /// The digest turn: read the queue once, then answer. Routing and the
  /// finalization calls are answered generically, as in the sibling
  /// scheduled-run tests, and every request body is recorded.
  MockClient scriptedHttp() {
    var loopCalls = 0;
    return MockClient((request) async {
      requests.add(request.body);
      final body = (jsonDecode(request.body) as Map).cast<String, Object?>();
      final systemText =
          (((body['system'] as List).first as Map)['text'] ?? '') as String;
      if (systemText.contains('Do not call tools.')) {
        return endTurn(jsonEncode({
          'message': 'Went through the new chats.',
          'included_outputs': ['rundown'],
          'claims': <Object>[],
          'includes_failure_report': true,
        }));
      }
      if (body['tools'] == null) {
        return endTurn(jsonEncode({
          'domains': ['messages', 'tasks'],
          'actions': [
            {'description': 'go_through_new_items', 'required': true},
          ],
          'response_outputs': ['rundown'],
          'requires_confirmation': false,
          'requires_synthesis': true,
          'requires_verification': true,
        }));
      }
      loopCalls++;
      return loopCalls == 1
          ? toolUse('read_message_context', {'undigested_only': true})
          : endTurn('Saw the photo and the voice note from Nils.');
    });
  }

  setUp(() async {
    work = await Directory.systemTemp.createTemp('exa_digest_media');
    mediaDir = p.join(work.path, 'exa_media', 'incoming');
    await Directory(mediaDir).create(recursive: true);
    database = AppDatabase();
    await database.open(overridePath: inMemoryDatabasePath);
    mediaRepo = InboundMediaRepository(database);
    messages = InboundMessageRepository(database, media: mediaRepo);
    requests = <String>[];

    final notifications = NotificationService();
    runner = JobRunner(database: database, notifications: notifications);
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
      // Media-loaded: exactly the production wiring, so the digest reads the
      // same rows the inbox does.
      chatMessages: messages,
    );
    final orchestrator = AgentOrchestrator(
      client: ClaudeClient(httpClient: scriptedHttp()),
      registry: registry,
      chat: ChatRepository(database),
      behaviors: BehaviorRepository(database),
      settings: SettingsRepository(database),
    );
    runner.orchestratorFactory = () => orchestrator;
  });

  tearDown(() async {
    await database.close();
    if (await work.exists()) await work.delete(recursive: true);
  });

  // --------------------------------------------------------------- fixtures

  final t0 = DateTime.fromMillisecondsSinceEpoch(1786000000000);

  /// Stores a real sidecar and its `inbound_media` row, the way ingest does:
  /// bytes on disk named by their sha256, a row pointing at them.
  Future<void> attachMedia(
    InboundMessage message, {
    required List<int> bytes,
    required String kind,
    required String mime,
    required String ext,
  }) async {
    final digest = sha256.convert(bytes).toString().substring(0, 32);
    final name = '$digest.$ext';
    await File(p.join(mediaDir, name)).writeAsBytes(bytes, flush: true);
    final stored = await mediaRepo.add(
      messageId: message.id,
      kind: kind,
      mimeType: mime,
      filePath: p.join(mediaDir, name),
      fileName: name,
      sizeBytes: bytes.length,
      contentHash: digest,
      createdAt: t0,
    );
    expect(stored, isNotNull, reason: 'the fixture must store real media');
  }

  int seeded = 0;
  Future<InboundMessage> mediaMessage({
    required String sender,
    required String body,
    required String summary,
  }) async {
    final at = t0.add(Duration(seconds: seeded++));
    final stored = await messages.add(
      InboundMessage(
        id: '',
        channel: 'whatsapp',
        conversationId: sender.toLowerCase(),
        conversationTitle: sender,
        sender: sender,
        // The point of the fixture: an empty body, exactly like a voice note
        // or photo-only capture.
        body: body,
        summary: summary,
        source: 'notification',
        sentAt: at,
        createdAt: at,
        externalId: 'x-$seeded',
        media: const [],
      ),
    );
    return stored!;
  }

  Future<void> armScopedDigest({List<String> senders = const ['Nils']}) async {
    await BehaviorRepository(database).createActive(
      title: 'Digest Nils',
      behaviorType: 'workflow_rule',
      ruleText: 'When messages arrive from Nils, digest them.',
      params: {
        'trigger': {
          'on': 'new_message',
          'action': 'digest',
          'min_interval_minutes': 0,
        },
        'scope': {'senders': senders},
      },
    );
  }

  Future<void> runMessageSync() async {
    final job = await JobRepository(database).create(
      name: 'Message sync',
      jobType: 'message_sync',
      description: 'Drain captured messages',
      scheduleRule: {'frequency': 'interval', 'interval_minutes': 2},
    );
    final outcome = await runner.runJob(job);
    expect(outcome.success, isTrue, reason: outcome.summary);
  }

  // ------------------------------------------------------------------- W13

  test('a digest over a photo-only and a voice-note-only message shows the '
      'model each one as its labelled note, never bytes', () async {
    await armScopedDigest();
    final photo = await mediaMessage(
      sender: 'Nils Berg',
      body: '',
      summary: 'Photo (image/jpeg, 96 B)',
    );
    await attachMedia(
      photo,
      bytes: List.generate(96, (i) => i % 256),
      kind: 'image',
      mime: 'image/jpeg',
      ext: 'jpg',
    );
    final voice = await mediaMessage(
      sender: 'Nils Berg',
      body: '',
      summary: 'Voice note (audio/ogg; codecs=opus, 128 B)',
    );
    await attachMedia(
      voice,
      bytes: List.filled(128, 0xAA),
      kind: 'audio',
      mime: 'audio/ogg; codecs=opus',
      ext: 'ogg',
    );

    await runMessageSync();

    final turnBodies = requests.where((b) => b.contains('tool_result')).toList();
    expect(turnBodies, isNotEmpty,
        reason: 'the digest turn must have run read_message_context');
    // The tool result is a JSON string nested inside the request, so every
    // quote of the payload arrives backslash-escaped. Scope the view to the
    // message history only: the request also carries the tool catalogue,
    // and read_message_context's description now names the transcript
    // field on purpose - what must stay absent is transcript DATA in the
    // payload the model was shown.
    final shown = turnBodies
        .map((b) => jsonEncode((jsonDecode(b) as Map)['messages']))
        .join('\n');
    // What the model sees: the two notes and the media array - not emptiness.
    expect(shown, contains('Photo (image/jpeg, 96 B)'));
    expect(shown, contains('Voice note (audio/ogg; codecs=opus, 128 B)'));
    expect(shown, contains(r'\"has_media\":true'));
    // The media array itself: id, kind, mime type and size, and a transcript
    // key only when a transcript exists (it does not, so it must not appear).
    expect(shown, contains(r'\"kind\":\"audio\"'));
    expect(shown, contains(r'\"kind\":\"image\"'));
    expect(shown, isNot(contains(r'\"transcript\"')));
    // W13, the second half: no media bytes reach the provider during an
    // unattended run. Staging only happens for an explicit media_id call,
    // which this turn never makes.
    final photoB64 = base64Encode(List.generate(96, (i) => i % 256));
    final voiceB64 = base64Encode(List.filled(128, 0xAA));
    for (final body in requests) {
      expect(body, isNot(contains('__image_base64')));
      expect(body, isNot(contains(photoB64.substring(0, 32))),
          reason: 'the photo must not be smuggled into the digest turn');
      expect(body, isNot(contains(voiceB64.substring(0, 32))),
          reason: 'voice bytes never reach a provider at all');
    }

    final after = InboundMessageRepository(database);
    expect((await after.getById(photo.id))!.digested, isTrue);
    expect((await after.getById(voice.id))!.digested, isTrue);
  });

  test('a scoped digest is not blind to media-only messages: an in-scope '
      'photo queues the turn, and a stranger\'s voice note alone never '
      'starts one', () async {
    await armScopedDigest();
    final inScope = await mediaMessage(
      sender: 'Nils Berg',
      body: '',
      summary: 'Photo (image/jpeg, 48 B)',
    );
    await attachMedia(
      inScope,
      bytes: List.filled(48, 0x10),
      kind: 'image',
      mime: 'image/jpeg',
      ext: 'jpg',
    );

    await runMessageSync();

    // An empty body must not read as "nothing in scope": the filter text is
    // displayBody, so the media note - and its sender - is admitted and the
    // rule's turn really runs.
    expect(requests.any((b) => b.contains('Digest my chat messages')), isTrue,
        reason: 'the scoped sender\'s photo belongs to this digest');
    expect((await InboundMessageRepository(database).getById(inScope.id))!
        .digested, isTrue);

    // The same rule, next day, facing only a stranger's voice note: the
    // filter sees the note text and sender, admits neither, and no model
    // turn is spent.
    await InboundMessageRepository(database)
        .markDigested(inScope.id); // last run's batch, already closed out
    final outScope = await mediaMessage(
      sender: 'Mira Sol',
      body: '',
      summary: 'Voice note (audio/mpeg, 40 B)',
    );
    await attachMedia(
      outScope,
      bytes: List.filled(40, 0x20),
      kind: 'audio',
      mime: 'audio/mpeg',
      ext: 'mp3',
    );
    final turnCountBefore =
        requests.where((b) => b.contains('Digest my chat messages')).length;

    // The trigger paces itself; step past the interval for this second run.
    final behavior = (await BehaviorRepository(database).listActive()).single;
    await SettingsRepository(database).setValue(
      'behavior_trigger_last_fired_${behavior.id}',
      DateTime.now()
          .subtract(const Duration(days: 1))
          .toIso8601String(),
    );
    final second = await JobRepository(database).create(
      name: 'Message sync 2',
      jobType: 'message_sync',
      description: 'Drain captured messages',
      scheduleRule: {'frequency': 'interval', 'interval_minutes': 2},
    );
    await runner.runJob(second);

    expect(
        requests.where((b) => b.contains('Digest my chat messages')).length,
        turnCountBefore,
        reason: 'a stranger\'s voice note is not this rule\'s queue');
    expect(
        (await InboundMessageRepository(database).getById(outScope.id))!
            .digested,
        isFalse,
        reason: 'and it stays queued for a rule that covers it');
  });

  test('the digest prompt tells the model media arrives as a note and an '
      'unseen image must not be invented', () {
    // The honesty clause rides with the code that shows notes, not by luck.
    final source = File(
      p.join('lib', 'services', 'background_jobs', 'job_runner.dart'),
    ).readAsStringSync();
    expect(source, contains("m.displayBody"));
    expect(source, contains('never invent what a photo showed'));
  });
}
