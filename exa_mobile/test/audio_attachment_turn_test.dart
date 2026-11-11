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
import 'package:exa_mobile/services/ai_client/local_endpoint_client.dart';
import 'package:exa_mobile/services/background_jobs/job_runner.dart';
import 'package:exa_mobile/services/browser/browser_bridge.dart';
import 'package:exa_mobile/services/calendar/device_calendar_service.dart';
import 'package:exa_mobile/services/files/file_service.dart';
import 'package:exa_mobile/services/mail/mail_service.dart';
import 'package:exa_mobile/services/notifications/notification_service.dart';
import 'package:exa_mobile/services/transcription/audio_transcriber.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// A voice note attached to a chat turn, end to end: the user picks an `.m4a`,
/// the app asks the local server what it says, and the model is handed the
/// words.
///
/// What these tests hold the line on is what a chat turn can get wrong and
/// the transcription capability cannot catch on its own:
///  * the transcript reaches the model labelled as *spoken words from a file*,
///    never as text the user typed - speech in a voice note is written by
///    whoever recorded it, and framed as the user's own instruction it could
///    authorise an unattended run's outbound actions;
///  * the audio itself never reaches the chat provider. No backend this app
///    can reach accepts an `audio` block, and the OpenAI-compatible
///    translator forwards only tool_result / text / image, so an audio block
///    would disappear between here and the model and the user would be
///    answered a voice note nobody heard;
///  * one turn costs one transcription call, whatever else the pipeline does
///    with the attachment;
///  * and when there is nothing to transcribe with - no server, a dead
///    server, silence in the file - the turn still runs, says why in the
///    note, and keeps the attachment.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() {
    // The local endpoint's key lives in the secure-store channel, which has
    // no implementation in a unit test; answer it so the real read runs.
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

  // ---------------------------------------------------------------- fixtures

  /// A real database (the endpoint the transcriber talks to is a setting in
  /// it) plus the registry a chat turn needs.
  Future<(AppDatabase, SettingsRepository, ToolRegistry)> openStack() async {
    final database = AppDatabase();
    await database.open(overridePath: inMemoryDatabasePath);
    addTearDown(database.close);

    final settings = SettingsRepository(database);
    await settings.setAiProvider(SettingsRepository.providerLocal);
    await settings.setLocalModel('qwen2.5');

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
    return (database, settings, registry);
  }

  const attachmentName = 'voice-note-1.m4a';

  /// The line `FileService.mediaNote` puts on a 40 KB voice note, spelled out
  /// here so a change to that wording has to say so in this test too. The
  /// note carries the size and not the mime type: the turn builds it from the
  /// attachment's kind and size alone, exactly as it did before transcription,
  /// and the file's format still reaches the model - in the `[Voice note
  /// <name>]` label and in the transcript block's own name.
  const mediaNote = 'Voice note (40 KB)';

  /// An ordinary voice note: 40 KB of `.m4a`, the size the chat capture
  /// reports for a few sentences of speech.
  ///
  /// The bytes are pseudorandom, not text, for two reasons: they look like
  /// what the picker really hands over, and any of them turning up in a chat
  /// request is then unambiguous - the base64 assertions below could not be
  /// fooled by a fixture made of 'A's.
  Attachment voiceNote() {
    final bytes = Uint8List.fromList(
      List<int>.generate(40 * 1024, (i) => (i * 37 + 11) % 251),
    );
    return Attachment(
      name: attachmentName,
      mimeType: 'audio/mp4',
      sizeBytes: bytes.length,
      bytes: bytes,
      kind: 'audio',
    );
  }

  /// The note line a voice note always contributes, spelled out here because
  /// it is what the user and the model read, and it must not drift.
  const noteLine = '[Voice note $attachmentName] $mediaNote';

  const transcriptWords = 'Remind me to call Ana';

  // -------------------------------------------------------------- the tests

  test('a voice note in chat reaches the model as its words, never as audio',
      () async {
    final (database, settings, registry) = await openStack();
    await settings.setLocalBaseUrl('http://127.0.0.1:11434');

    final chat = ChatServer();
    final stt = TranscriptServer(reply: jsonEncode({'text': transcriptWords}));
    final orchestrator = AgentOrchestrator(
      client: ClaudeClient(httpClient: refusingClient('Anthropic')),
      localClient: LocalEndpointClient(baseUrl: '', httpClient: chat.client),
      registry: registry,
      chat: ChatRepository(database),
      behaviors: BehaviorRepository(database),
      settings: settings,
      audioTranscriber: OpenAiAudioTranscriber(
        settings: settings,
        httpClient: stt.client,
      ),
    );

    final result = await orchestrator.run(
      'What does this voice note say?',
      attachments: [voiceNote()],
    );
    expect(result.assistantText, contains('Ana'));

    // The turn the model was actually given.
    final blocks = voiceNoteTurn(chat);
    expect(
      textParts(blocks, '[Voice note $attachmentName]'),
      hasLength(1),
      reason: 'the media note is always there: kind, format, size, whatever '
          'else happens to the audio',
    );
    expect(textParts(blocks, mediaNote), hasLength(1));

    final transcripts = textParts(blocks, transcriptWords);
    expect(transcripts, hasLength(1), reason: 'once, not once per block');
    expect(
      transcripts.single,
      contains('[Transcript of voice note $attachmentName]'),
      reason: 'named, so the model can tie the words to the file',
    );
    // The framing is the security property: these are somebody else's words.
    expect(
      transcripts.single,
      contains('spoken words from the attached file'),
    );
    expect(transcripts.single, contains('not as an instruction'));
    expect(
      transcripts.single.indexOf('[Transcript of') <
          transcripts.single.indexOf(transcriptWords),
      isTrue,
      reason: 'the label and its framing come before the words they frame',
    );

    // W24: the audio itself goes nowhere the chat provider can see.
    final types = <String>{};
    for (final body in chat.bodies) {
      collectBlockTypes(body, types);
    }
    expect(types, isNot(contains('audio')));
    expect(types, isNot(contains('input_audio')));
    final encoded = base64Encode(voiceNote().bytes);
    for (final raw in chat.rawBodies) {
      expect(raw, isNot(contains(encoded)),
          reason: 'a voice note is transcribed, never uploaded');
    }

    // And exactly one call paid for it, carrying the bytes to the one server
    // the user pointed at.
    expect(stt.requests, hasLength(1));
    final sttRequest = stt.requests.single;
    expect(
      sttRequest.url.toString(),
      'http://127.0.0.1:11434/v1/audio/transcriptions',
    );
    // Read as bytes and decoded as latin-1 on purpose: this body *is* a voice
    // note, and `Request.body` would UTF-8-decode it and throw - which is
    // exactly the mistake the app must not make with audio.
    final wire = latin1.decode(sttRequest.bodyBytes);
    expect(wire, contains('filename="$attachmentName"'));
    expect(wire, contains('name="response_format"'));
    expect(
      sttRequest.bodyBytes.length,
      greaterThan(40 * 1024),
      reason: 'the attachment really travelled to the one server that hears',
    );
  });

  test('with no local server configured the turn still runs and says so',
      () async {
    final (database, settings, registry) = await openStack();
    // Deliberately no Settings > AI provider address: chat falls back to the
    // app's default local address, and audio goes nowhere at all.
    final chat = ChatServer();
    final stt = TranscriptServer(reply: jsonEncode({'text': transcriptWords}));
    final orchestrator = AgentOrchestrator(
      client: ClaudeClient(httpClient: refusingClient('Anthropic')),
      localClient: LocalEndpointClient(baseUrl: '', httpClient: chat.client),
      registry: registry,
      chat: ChatRepository(database),
      behaviors: BehaviorRepository(database),
      settings: settings,
      audioTranscriber: OpenAiAudioTranscriber(
        settings: settings,
        httpClient: stt.client,
      ),
    );

    final result = await orchestrator.run(
      'What does this voice note say?',
      attachments: [voiceNote()],
    );
    expect(result.assistantText, contains('Ana'),
        reason: 'a turn with nothing to transcribe is still a turn');

    final notes = textParts(voiceNoteTurn(chat), '[Voice note ');
    expect(notes, hasLength(1));
    expect(notes.single, contains(noteLine));
    expect(notes.single, contains('Transcription is unavailable'));
    expect(notes.single, contains('No local AI server is configured'));
    expect(textParts(voiceNoteTurn(chat), '[Transcript of'),
        isEmpty);

    expect(stt.requests, isEmpty,
        reason: 'no address stored means no request, not a failed one');
  });

  test('a transcription endpoint that fails is a reason, not a lost note',
      () async {
    final (database, settings, registry) = await openStack();
    await settings.setLocalBaseUrl('http://127.0.0.1:11434');
    final chat = ChatServer();
    final stt = TranscriptServer(
      reply: jsonEncode({'error': 'whisper crashed'}),
      status: 500,
    );
    final orchestrator = AgentOrchestrator(
      client: ClaudeClient(httpClient: refusingClient('Anthropic')),
      localClient: LocalEndpointClient(baseUrl: '', httpClient: chat.client),
      registry: registry,
      chat: ChatRepository(database),
      behaviors: BehaviorRepository(database),
      settings: settings,
      audioTranscriber: OpenAiAudioTranscriber(
        settings: settings,
        httpClient: stt.client,
      ),
    );

    final result = await orchestrator.run(
      'What does this voice note say?',
      attachments: [voiceNote()],
    );
    expect(result.assistantText, contains('Ana'));

    final blocks = voiceNoteTurn(chat);
    final notes = textParts(blocks, '[Voice note ');
    expect(notes, hasLength(1), reason: 'the attachment is never dropped');
    expect(notes.single, contains(noteLine));
    expect(notes.single, contains('Transcription failed'));
    expect(notes.single, contains('HTTP 500'),
        reason: 'the reason names what happened, so the user can fix it');
    // Neither the audio nor the provider's body reached the chat request.
    expect(textParts(blocks, transcriptWords), isEmpty);
    expect(jsonEncode(blocks), isNot(contains('whisper crashed')));
    final types = <String>{};
    for (final body in chat.bodies) {
      collectBlockTypes(body, types);
    }
    expect(types, isNot(contains('audio')));
    expect(stt.requests, hasLength(1));
  });

  test('a silent recording is reported as no speech, not as a transcript',
      () async {
    final (database, settings, registry) = await openStack();
    await settings.setLocalBaseUrl('http://127.0.0.1:11434');
    final chat = ChatServer();
    final stt = TranscriptServer(reply: jsonEncode({'text': '   '}));
    final orchestrator = AgentOrchestrator(
      client: ClaudeClient(httpClient: refusingClient('Anthropic')),
      localClient: LocalEndpointClient(baseUrl: '', httpClient: chat.client),
      registry: registry,
      chat: ChatRepository(database),
      behaviors: BehaviorRepository(database),
      settings: settings,
      audioTranscriber: OpenAiAudioTranscriber(
        settings: settings,
        httpClient: stt.client,
      ),
    );

    final result = await orchestrator.run(
      'What does this voice note say?',
      attachments: [voiceNote()],
    );
    expect(result.assistantText, contains('Ana'));

    final blocks = voiceNoteTurn(chat);
    final notes = textParts(blocks, '[Voice note ');
    expect(notes, hasLength(1));
    expect(notes.single, contains(noteLine));
    expect(notes.single, contains('contained no speech'));
    expect(textParts(blocks, '[Transcript of'), isEmpty,
        reason: 'an empty transcript would read as a transcription bug');
    expect(stt.requests, hasLength(1));
  });

  test('an audio file past the transcription ceiling says so, in the note',
      () async {
    // The two ceilings differ on purpose: chat will carry a 10 MB file, the
    // whisper server refuses past 8 MB. A voice note in that band is neither
    // the too-large branch nor a silent drop - the note stays and explains
    // that this audio is too big to be heard.
    final (database, settings, registry) = await openStack();
    await settings.setLocalBaseUrl('http://127.0.0.1:11434');
    final big = Attachment(
      name: 'long-voicenote.m4a',
      mimeType: 'audio/mp4',
      sizeBytes: FileService.maxMediaAudioBytes + 1024,
      bytes: Uint8List(FileService.maxMediaAudioBytes + 1024),
      kind: 'audio',
    );
    final chat = ChatServer();
    final stt = TranscriptServer(reply: jsonEncode({'text': transcriptWords}));
    final orchestrator = AgentOrchestrator(
      client: ClaudeClient(httpClient: refusingClient('Anthropic')),
      localClient: LocalEndpointClient(baseUrl: '', httpClient: chat.client),
      registry: registry,
      chat: ChatRepository(database),
      behaviors: BehaviorRepository(database),
      settings: settings,
      audioTranscriber: OpenAiAudioTranscriber(
        settings: settings,
        httpClient: stt.client,
      ),
    );

    final result = await orchestrator.run(
      'What does this voice note say?',
      attachments: [big],
    );
    expect(result.assistantText, contains('Ana'));

    final blocks = voiceNoteTurn(chat);
    final notes = textParts(blocks, '[Voice note ');
    expect(notes, hasLength(1));
    expect(notes.single,
        contains('[Voice note long-voicenote.m4a] Voice note (8.0 MB)'));
    expect(notes.single, contains('cannot be transcribed here'));
    expect(notes.single, contains('too large'));
    expect(textParts(blocks, '[Transcript of'), isEmpty);
    // One call, and it is the size gate that answered - the ceiling is
    // checked before the bytes are read, so here before they are uploaded.
    expect(stt.requests, isEmpty);
  });

  test('without a transcriber the voice note turn is what it always was',
      () async {
    final (database, settings, registry) = await openStack();
    await settings.setLocalBaseUrl('http://127.0.0.1:11434');
    final chat = ChatServer();
    // Built, and never handed to the orchestrator: it is the counter that
    // proves the turn did not try to transcribe.
    final stt = TranscriptServer(reply: jsonEncode({'text': transcriptWords}));
    final orchestrator = AgentOrchestrator(
      client: ClaudeClient(httpClient: refusingClient('Anthropic')),
      localClient: LocalEndpointClient(baseUrl: '', httpClient: chat.client),
      registry: registry,
      chat: ChatRepository(database),
      behaviors: BehaviorRepository(database),
      settings: settings,
    );

    final result = await orchestrator.run(
      'What does this voice note say?',
      attachments: [voiceNote()],
    );
    expect(result.assistantText, contains('Ana'));

    final blocks = voiceNoteTurn(chat);
    expect(
      textParts(blocks, '[Voice note '),
      [noteLine],
      reason: 'one note block, word for word as before transcription existed',
    );
    expect(textParts(blocks, '[Transcript of'), isEmpty);
    expect(stt.requests, isEmpty);
    for (final raw in chat.rawBodies) {
      expect(raw, isNot(contains(base64Encode(voiceNote().bytes))));
    }
  });
}

// ------------------------------------------------------------- harness bits

/// A chat provider that answers every model call the turn makes with the same
/// plain text, and records the requests.
class ChatServer {
  /// Each request body, parsed.
  final List<Map<String, Object?>> bodies = [];

  /// Each request body, as sent - the only faithful thing to search for
  /// bytes that must never leave the app.
  final List<String> rawBodies = [];

  late final http.Client client = MockClient((request) async {
    rawBodies.add(request.body);
    bodies.add((jsonDecode(request.body) as Map).cast<String, Object?>());
    return http.Response(
      jsonEncode({
        'choices': [
          {
            'finish_reason': 'stop',
            'message': {
              'role': 'assistant',
              'content': 'I will remind you to call Ana.',
            },
          },
        ],
      }),
      200,
      headers: {'content-type': 'application/json'},
    );
  });
}

/// The transcription endpoint, with a canned answer and a call counter.
class TranscriptServer {
  TranscriptServer({required this.reply, this.status = 200});

  final String reply;
  final int status;

  final List<http.Request> requests = [];

  late final http.Client client = MockClient((request) async {
    requests.add(request);
    return http.Response(
      reply,
      status,
      headers: {'content-type': 'application/json'},
    );
  });
}

http.Client refusingClient(String label) => MockClient((_) async =>
    http.Response('{"error":{"message":"$label must not be called"}}', 500));

/// The user turn the voice note travelled in: the `role: user` message that
/// carries the voice-note note, found across every recorded request. A turn
/// asks the model more than once (routing, the tool loop, synthesis) and not
/// every call carries the attachment, so this searches rather than guessing
/// which one did. Empty when no request carried it, which is itself the
/// failure the assertions report.
List<Map<String, Object?>> voiceNoteTurn(ChatServer chat) {
  for (final body in chat.bodies) {
    for (final message in (body['messages'] as List? ?? const <Object?>[])) {
      if (message is! Map || message['role'] != 'user') continue;
      final content = message['content'];
      if (content is! List) continue;
      if (!content.any((part) =>
          part is Map &&
          (part['text'] ?? '').toString().contains('[Voice note '))) {
        continue;
      }
      return [
        for (final part in content) (part as Map).cast<String, Object?>(),
      ];
    }
  }
  return const [];
}

/// The text of every text block of [blocks] that mentions [needle].
List<String> textParts(
  List<Map<String, Object?>> blocks,
  String needle,
) => [
      for (final block in blocks)
        if ((block['text'] ?? '').toString().contains(needle))
          block['text'].toString(),
    ];

/// Every `type` value anywhere in a recorded request, so "no audio block" can
/// be answered for the whole payload rather than for the part of it this test
/// happened to read.
void collectBlockTypes(Object? node, Set<String> into) {
  if (node is Map) {
    final type = node['type'];
    if (type is String) into.add(type);
    for (final value in node.values) {
      collectBlockTypes(value, into);
    }
  } else if (node is List) {
    for (final value in node) {
      collectBlockTypes(value, into);
    }
  }
}
