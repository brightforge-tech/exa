import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:exa_mobile/data/database/app_database.dart';
import 'package:exa_mobile/data/repositories/settings_repository.dart';
import 'package:exa_mobile/services/files/file_service.dart';
import 'package:exa_mobile/services/transcription/audio_transcriber.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// The transcription capability on its own wire: what goes out, and what
/// comes back, for every way the call can end.
///
/// The rules these tests pin are the ones the later callers can only trust if
/// they hold here, before any message row or chat turn depends on them:
/// exactly one multipart POST per attempt (cost), every refusal answered from
/// a stat with zero network calls (the size and emptiness gates), a status
/// for each provider behaviour rather than an exception (nothing to retry on
/// a 415, something to retry on a 500), a transcript that cannot crowd out a
/// budgeted turn (the cap), and - because these results are written into job
/// reports and diagnostics the model reads - a `detail` string that never
/// carries the audio's bytes or anyone's spoken words.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Directory work;
  late AppDatabase database;
  late SettingsRepository settings;

  /// Every request the recorded client saw. Tests assert on this to prove
  /// "zero network calls" for each gate, and "exactly one request" for one
  /// attempt.
  late List<http.Request> sent;

  setUp(() async {
    work = await Directory.systemTemp.createTemp('exa_transcriber');
    database = AppDatabase();
    await database.open(overridePath: inMemoryDatabasePath);
    settings = SettingsRepository(database);
    sent = <http.Request>[];
    // The key store is a platform channel; answer it with a stand-in key so
    // the transcriber's credential read runs for real in the test process.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (call) async => call.method == 'read' ? 'sk-test-key' : null,
    );
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      null,
    );
    await database.close();
    if (await work.exists()) await work.delete(recursive: true);
  });

  // ------------------------------------------------------------- fixtures

  const baseUrl = 'http://127.0.0.1:11434';

  /// Point the app at a local transcription server, the way Settings does.
  Future<void> configure({String url = baseUrl}) =>
      settings.setValue(SettingsRepository.aiLocalBaseUrlKey, url);

  // A string the provider might echo in an error body, and one only the
  // audio bytes carry. Neither may ever appear in a `detail`.
  const providerLeak = 'provider-echo: <signed-token-9f3a>';

  /// A client that records each request and hands it to [answer]. A handler
  /// that must fail the call throws from here, which is how "the socket
  /// closed" is simulated without a socket.
  MockClient recording(
    Future<http.Response> Function(http.Request request) answer,
  ) =>
      MockClient((request) async {
        sent.add(request);
        return answer(request);
      });

  http.Response jsonReply(String text) => http.Response(
        jsonEncode({'text': text}),
        200,
        headers: {'content-type': 'application/json'},
      );

  /// A failing answer whose body is bait: anything that repeats it in a
  /// `detail` would be leaking provider content into a model-readable line.
  http.Response failing(int code) => http.Response(
        jsonEncode({'error': providerLeak}),
        code,
        headers: {'content-type': 'application/json'},
      );

  OpenAiAudioTranscriber transcriber(
          {Future<http.Response> Function(http.Request)? answer}) =>
      OpenAiAudioTranscriber(
        settings: settings,
        httpClient: recording(answer ?? (_) async => jsonReply('ok')),
      );

  /// An ordinary temp file - deliberately inside no media directory, since
  /// the transcriber imposes no directory rule of its own. The bytes are
  /// ASCII on purpose: the tests then read the recorded multipart body as
  /// text to inspect the wire shape.
  Future<File> audioFile({
    String name = 'voice-1.m4a',
    int size = 40 * 1024,
    String? bodyMarker,
  }) async {
    final file = File(p.join(work.path, name));
    if (size == 0) {
      await file.writeAsBytes(const <int>[], flush: true);
      return file;
    }
    final head = utf8.encode('${bodyMarker ?? ''}:');
    await file.writeAsBytes(
      <int>[...head, ...List.filled(size - head.length, 0x61)],
      flush: true,
    );
    return file;
  }

  final audioBytes = Uint8List.fromList(List.filled(4 * 1024, 0x61));

  const bodyMarker = 'VOICEBODY77';

  // ------------------------------------------------- W1: the one request

  group('one attempt is one multipart POST', () {
    test('shape on the wire, words on the way back', () async {
      await configure();
      final file = await audioFile(bodyMarker: bodyMarker);
      final result = await transcriber(
        answer: (_) async => jsonReply('meet me at the station at six'),
      ).transcribeFile(file.path);

      expect(result.status, TranscriptionStatus.done);
      expect(result.text, 'meet me at the station at six');
      expect(result.hasText, isTrue);

      expect(sent, hasLength(1), reason: 'one voice note, one call');
      final request = sent.single;
      expect(request.method, 'POST');
      expect(request.url.toString(), '$baseUrl/v1/audio/transcriptions');
      expect(
        request.headers['content-type'],
        startsWith('multipart/form-data'),
      );

      final body = request.body; // ASCII fixture, so text is inspectable.
      expect(body, contains('name="file"'));
      expect(
        body,
        contains('filename="voice-1.m4a"'),
        reason: 'the extension is the provider\'s format hint',
      );
      expect(body, contains('name="response_format"'));
      expect(body, contains('json'));
      expect(body, contains('$bodyMarker:'), reason: 'the bytes travel');
      // The operator rule: the server answers with whatever it has loaded,
      // and hears whatever language it is spoken in.
      expect(body, isNot(contains('model')));
      expect(body, isNot(contains('language')));

      // The stored local-endpoint key rides along, as it does for chat.
      expect(request.headers['authorization'], 'Bearer sk-test-key');
    });

    test('transcribeBytes names the part from the attachment name', () async {
      await configure();
      final result = await transcriber(
        answer: (_) async => jsonReply('hi'),
      ).transcribeBytes(audioBytes, fileName: 'voice-2.ogg');

      expect(result.status, TranscriptionStatus.done);
      expect(sent.single.body, contains('filename="voice-2.ogg"'));
      expect(sent.single.body, isNot(contains('model')));
    });
  });

  // ----------------------------------------- W2 + W6: no endpoint, no call

  group('without a configured endpoint there is nothing to call', () {
    test('a blank stored URL answers unavailable, zero requests', () async {
      await configure(url: '');
      final file = await audioFile();
      final client = transcriber(
        answer: (_) async => fail('an unconfigured transcriber must not '
            'make requests'),
      );

      expect(
        (await client.transcribeFile(file.path)).status,
        TranscriptionStatus.unavailable,
      );
      expect(
        (await client.transcribeBytes(audioBytes, fileName: 'a.m4a')).status,
        TranscriptionStatus.unavailable,
      );
      expect(sent, isEmpty);
    });

    test('isConfigured follows the stored URL, not any default', () async {
      // Nothing stored yet: the app may hold a default address for the chat
      // provider, but audio never goes to an address the user never chose.
      final client = transcriber();
      expect(await client.isConfigured, isFalse);
      expect(
        (await client.transcribeBytes(audioBytes, fileName: 'a.m4a')).status,
        TranscriptionStatus.unavailable,
      );

      // No priming call: isConfigured answers from the store each time, so
      // a caller typed against the interface alone gets today's answer.
      await configure();
      expect(await client.isConfigured, isTrue);
    });

    test('a freshly built transcriber sees a stored URL at once', () async {
      // The regression this whole pass lives or dies by: the background job
      // constructs its own OpenAiAudioTranscriber(settings) on every run
      // and asks isConfigured before touching anything. An instance that
      // answered from a cache warmed only by a transcribe* call would say
      // false in that isolate forever and silently transcribe nothing.
      await configure();
      final file = await audioFile();
      final client = transcriber(
        answer: (_) async => jsonReply('meet me at the station at six'),
      );

      expect(await client.isConfigured, isTrue,
          reason: 'nothing primed this instance; the store alone must '
              'answer');

      // And the pass it gates actually runs: one request, transcript back.
      final result = await client.transcribeFile(file.path);
      expect(result.status, TranscriptionStatus.done);
      expect(sent, hasLength(1));
    });

    test('a freshly built transcriber with nothing stored is not configured',
        () async {
      final client = transcriber();
      expect(await client.isConfigured, isFalse);
    });
  });

  // ------------------------------------- W3: gates answered before reading

  group('the size and emptiness gate answers before any bytes are read', () {
    setUp(() => configure());

    test('a 0-byte file is unsupported, not transcribed', () async {
      final file = await audioFile(size: 0);
      final result = await transcriber().transcribeFile(file.path);
      expect(result.status, TranscriptionStatus.unsupported);
      expect(result.detail, isNotEmpty);
      expect(result.detail, contains('empty'));
      expect(sent, isEmpty);
    });

    test('a missing path is unsupported, not a crash', () async {
      final result = await transcriber()
          .transcribeFile(p.join(work.path, 'gone.m4a'));
      expect(result.status, TranscriptionStatus.unsupported);
      expect(result.detail, isNotEmpty);
      expect(sent, isEmpty);
    });

    test('past the audio ceiling is unsupported', () async {
      final file = await audioFile(size: FileService.maxMediaAudioBytes + 1);
      final result = await transcriber().transcribeFile(file.path);
      expect(result.status, TranscriptionStatus.unsupported);
      expect(result.detail, isNotEmpty);
      expect(sent, isEmpty);
    });

    test('the same gate guards in-memory bytes', () async {
      final empty = await transcriber()
          .transcribeBytes(Uint8List(0), fileName: 'a.m4a');
      expect(empty.status, TranscriptionStatus.unsupported);
      expect(empty.detail, isNotEmpty);

      final huge = await transcriber().transcribeBytes(
        Uint8List(FileService.maxMediaAudioBytes + 1),
        fileName: 'a.m4a',
      );
      expect(huge.status, TranscriptionStatus.unsupported);
      expect(huge.detail, isNotEmpty);
      expect(sent, isEmpty);
    });
  });

  // ------------------------------------------- W4: status mapping, no leaks

  group('every provider behaviour maps to exactly one status', () {
    setUp(() => configure());

    /// Each failing call must say why without repeating anything it heard:
    /// no audio bytes, no provider response body, no transcript.
    void expectCleanDetail(TranscriptionResult result) {
      expect(result.detail, isNotNull);
      expect(result.detail, isNotEmpty);
      expect(result.detail, isNot(contains(bodyMarker)));
      expect(result.detail, isNot(contains(providerLeak)));
      expect(result.detail, isNot(contains('meet me at the station')));
    }

    test('415 is unsupported: healthy endpoint, this audio not here', () async {
      final file = await audioFile(bodyMarker: bodyMarker);
      final result = await transcriber(
        answer: (_) async => failing(415),
      ).transcribeFile(file.path);
      expect(result.status, TranscriptionStatus.unsupported);
      expectCleanDetail(result);
      expect(sent, hasLength(1));
    });

    test('429 is failed: retryable', () async {
      final file = await audioFile(bodyMarker: bodyMarker);
      final result = await transcriber(
        answer: (_) async => failing(429),
      ).transcribeFile(file.path);
      expect(result.status, TranscriptionStatus.failed);
      expectCleanDetail(result);
    });

    test('500 is failed: retryable', () async {
      final file = await audioFile(bodyMarker: bodyMarker);
      final result = await transcriber(
        answer: (_) async => failing(500),
      ).transcribeFile(file.path);
      expect(result.status, TranscriptionStatus.failed);
      expectCleanDetail(result);
    });

    test('a socket that closes is failed, not a crash', () async {
      final file = await audioFile(bodyMarker: bodyMarker);
      final result = await transcriber(answer: (_) async {
        throw http.ClientException('Connection closed before full header');
      }).transcribeFile(file.path);
      expect(result.status, TranscriptionStatus.failed);
      expectCleanDetail(result);
    });

    test('silence past the timeout is failed, not a hang', () async {
      final file = await audioFile(bodyMarker: bodyMarker);
      final never = Completer<http.Response>(); // never answers
      final result = await transcriber(answer: (_) => never.future)
          .transcribeFile(file.path, timeout: const Duration(milliseconds: 80));
      expect(result.status, TranscriptionStatus.failed);
      expect(result.detail, contains('timed out'));
      expectCleanDetail(result);
      expect(sent, hasLength(1));
    });
  });

  // -------------------------------------- W5: empty answers and long ones

  group('a transcript is bounded by the cap', () {
    setUp(() => configure());

    Future<TranscriptionResult> answerWith(String text) => transcriber(
          answer: (_) async => jsonReply(text),
        ).transcribeBytes(audioBytes, fileName: 'a.m4a');

    test('whitespace-only words are empty, with no text to store', () async {
      final result = await answerWith('   \n  ');
      expect(result.status, TranscriptionStatus.empty);
      expect(result.text, isNull);
      expect(result.hasText, isFalse);
    });

    test('a 20 000-character answer comes back capped and marked', () async {
      final result = await answerWith('x' * 20000);
      expect(result.status, TranscriptionStatus.done);
      expect(result.text, hasLength(lessThanOrEqualTo(
          AudioTranscriber.maxTranscriptChars)));
      expect(result.text, endsWith('[truncated]'));
      expect(result.text, startsWith('xxx'));
    });

    test('an answer under the cap is kept whole', () async {
      final words = 'y' * (AudioTranscriber.maxTranscriptChars - 1);
      final result = await answerWith(words);
      expect(result.status, TranscriptionStatus.done);
      expect(result.text, words);
    });
  });
}
