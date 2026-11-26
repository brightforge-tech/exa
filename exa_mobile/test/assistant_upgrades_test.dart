import 'dart:async';
import 'dart:convert';

import 'package:exa_mobile/agent/services/user_features.dart';
import 'package:exa_mobile/data/database/app_database.dart';
import 'package:exa_mobile/data/models/dynamic_screen.dart';
import 'package:exa_mobile/data/models/inbound_message.dart';
import 'package:exa_mobile/data/models/user_collection.dart';
import 'package:exa_mobile/data/repositories/inbound_message_repository.dart';
import 'package:exa_mobile/services/ai_client/ai_client.dart';
import 'package:exa_mobile/services/ai_client/deepseek_client.dart';
import 'package:exa_mobile/services/ai_client/local_endpoint_client.dart';
import 'package:exa_mobile/services/messaging/message_channels.dart';
import 'package:exa_mobile/services/voice/speech_output.dart';
import 'package:exa_mobile/services/web/web_search_service.dart';
import 'package:exa_mobile/shared/chat_timestamp.dart';
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

  // ------------------------------------------- streaming + reasoning effort --

  group('the local server', () {
    http.StreamedResponse sse(List<Map<String, Object?>> events) {
      final body = StringBuffer();
      for (final event in events) {
        body.write('data: ${jsonEncode(event)}\n\n');
      }
      body.write('data: [DONE]\n\n');
      return http.StreamedResponse(
        Stream.value(utf8.encode(body.toString())),
        200,
        headers: {'content-type': 'text/event-stream'},
      );
    }

    Map<String, Object?> delta(Map<String, Object?> d) => {
          'choices': [
            {'delta': d},
          ],
        };

    Future<AiResponse> ask(LocalEndpointClient client) => client.createMessage(
          model: 'local',
          system: 'You are Exa.',
          messages: const [
            {'role': 'user', 'content': 'digest my chats'},
          ],
        );

    test('streams even a background request, so a proxy never sees it idle',
        () async {
      final bodies = <Map<String, Object?>>[];
      final client = LocalEndpointClient(
        baseUrl: 'http://localhost:1234',
        httpClient: MockClient.streaming((request, bytes) async {
          bodies.add((jsonDecode(await bytes.bytesToString()) as Map).cast());
          return sse([
            delta({'reasoning_content': 'thinking it over'}),
            delta({'content': 'Two '}),
            delta({'content': 'tasks found.'}),
            delta({
              'tool_calls': [
                {
                  'index': 0,
                  'id': 'call_1',
                  'function': {'name': 'create_task', 'arguments': '{"title"'},
                },
              ],
            }),
            delta({
              'tool_calls': [
                {
                  'index': 0,
                  'function': {'arguments': ': "Call Sam"}'},
                },
              ],
            }),
          ]);
        }),
      );

      final response = await ask(client);

      expect(bodies.single['stream'], isTrue);
      expect(response.text, 'Two tasks found.');
      expect(response.stopReason, 'tool_use');
      expect(response.toolUses.single['input'], {'title': 'Call Sam'});
      expect(response.content.first['type'], 'thinking');
    });

    test('a server that ignores stream still answers, as plain JSON',
        () async {
      final client = LocalEndpointClient(
        baseUrl: 'http://localhost:1234',
        httpClient: MockClient((request) async => http.Response(
              jsonEncode({
                'choices': [
                  {
                    'finish_reason': 'stop',
                    'message': {'role': 'assistant', 'content': 'Done.'},
                  },
                ],
              }),
              200,
              headers: {'content-type': 'application/json'},
            )),
      );
      expect((await ask(client)).text, 'Done.');
    });

    test('a digest asks for low effort; other requests leave the default',
        () async {
      final bodies = <Map<String, Object?>>[];
      final client = LocalEndpointClient(
        baseUrl: 'http://localhost:1234',
        httpClient: MockClient((request) async {
          bodies.add((jsonDecode(request.body) as Map).cast());
          return http.Response(
            jsonEncode({
              'choices': [
                {
                  'message': {'role': 'assistant', 'content': 'ok'},
                },
              ],
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );

      await ReasoningEffort.run(ReasoningEffort.low, () async {
        // Several awaits deep, as the orchestrator's calls are.
        await Future<void>.delayed(Duration.zero);
        await ask(client);
      });
      await ask(client);

      expect(bodies.first['reasoning_effort'], 'low');
      expect(bodies.last.containsKey('reasoning_effort'), isFalse);
    });

    test('a server that rejects reasoning_effort is asked again without it, '
        'and not sent it again', () async {
      final sent = <bool>[];
      final client = LocalEndpointClient(
        baseUrl: 'http://localhost:1234',
        httpClient: MockClient((request) async {
          final body = (jsonDecode(request.body) as Map).cast<String, Object?>();
          final hasEffort = body.containsKey('reasoning_effort');
          sent.add(hasEffort);
          if (hasEffort) {
            return http.Response(
              jsonEncode({
                'error': {'message': 'Unrecognized field reasoning_effort'},
              }),
              400,
              headers: {'content-type': 'application/json'},
            );
          }
          return http.Response(
            jsonEncode({
              'choices': [
                {
                  'message': {'role': 'assistant', 'content': 'ok'},
                },
              ],
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );

      await ReasoningEffort.run(ReasoningEffort.low, () async {
        expect((await ask(client)).text, 'ok');
        expect((await ask(client)).text, 'ok');
      });
      expect(sent, [true, false, false]);
    });

    test('DeepSeek is never sent the field', () async {
      late Map<String, Object?> body;
      final client = DeepSeekClient(
        apiKey: 'key',
        httpClient: MockClient((request) async {
          body = (jsonDecode(request.body) as Map).cast();
          return http.Response(
            jsonEncode({
              'choices': [
                {
                  'message': {'role': 'assistant', 'content': 'ok'},
                },
              ],
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );
      await ReasoningEffort.run(
        ReasoningEffort.low,
        () => client.createMessage(
          model: 'deepseek-chat',
          system: 's',
          messages: const [
            {'role': 'user', 'content': 'hi'},
          ],
        ),
      );
      expect(body.containsKey('reasoning_effort'), isFalse);
      expect(body['stream'], isFalse);
    });
  });

  // ------------------------------------------------------- user features --

  group('features the user had Exa build', () {
    final now = DateTime(2026, 11, 25);
    UserCollection collection(String name, String title) => UserCollection(
          name: name,
          title: title,
          fields: const [
            CollectionField(name: 'title', type: 'text'),
            CollectionField(name: 'body', type: 'text'),
          ],
          createdAt: now,
          updatedAt: now,
        );

    final catalog = UserFeatureCatalog([
      UserFeature(
        collection: collection('notes', 'Notes'),
        recordCount: 4,
        screens: [
          DynamicScreen(
            id: 's1',
            screenKey: 'my_notes',
            title: 'My Notebook',
            schema: const {},
            createdBy: 'agent',
            isSaved: true,
            createdAt: now,
            updatedAt: now,
          ),
        ],
      ),
      UserFeature(
        collection: collection('expense_log', 'Expense log'),
        recordCount: 1,
      ),
    ]);

    List<String> found(String request) =>
        [for (final f in catalog.mentionedIn(request)) f.name];

    test('"save a note" finds the notes feature, singular or plural', () {
      expect(found('save this as a note please'), ['notes']);
      expect(found('what is in my notes?'), ['notes']);
      expect(found('open my notebook'), ['notes']);
    });

    test('a multi-word feature is matched as a phrase', () {
      expect(found('add 12 dollars to my expense log'), ['expense_log']);
      expect(found('log my run'), isEmpty);
    });

    test('an unrelated request names nothing', () {
      expect(found('remind me to call Sam at 5'), isEmpty);
      expect(found('notable events this week'), isEmpty);
    });

    test('the turn context lists every feature and steers the named one', () {
      final text = catalog.describe(mentioned: catalog.mentionedIn('a note'));
      expect(text, contains('Notes (collection "notes"'));
      expect(text, contains('4 entries'));
      expect(text, contains('"My Notebook"'));
      expect(text, contains('Expense log'));
      expect(text, contains('add_record'));
      expect(text, contains('not write_file'));
      expect(UserFeatureCatalog.empty.describe(), isEmpty);
    });
  });

  // -------------------------------------------------------- web search --

  group('web search', () {
    test('reads results out of the HTML page, real addresses not redirects',
        () {
      const html = '''
<div class="result results_links">
  <h2 class="result__title">
    <a rel="nofollow" class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Fhours&amp;rut=abc">Example &amp; Co <b>opening hours</b></a>
  </h2>
  <a class="result__snippet" href="x">Open <b>9am</b> to 5pm, Monday to Friday.</a>
</div>
<div class="result results_links">
  <a rel="nofollow" class="result__a" href="https://duckduckgo.com/y.js?ad=1">An advert</a>
</div>
<div class="result results_links">
  <a rel="nofollow" class="result__a" href="https://other.org/page">Other page</a>
  <div class="result__snippet">Second snippet</div>
</div>
''';
      final results = WebSearchService.parseResults(html);
      expect(results.map((r) => r.url), [
        'https://example.com/hours',
        'https://other.org/page',
      ]);
      expect(results.first.title, 'Example & Co opening hours');
      expect(results.first.snippet, 'Open 9am to 5pm, Monday to Friday.');
      expect(results.last.snippet, 'Second snippet');
    });

    test('a page becomes readable text without scripts or chrome', () {
      final text = WebSearchService.htmlToText('''
<html><head><title>T</title><style>p{}</style></head><body>
<nav>Home | About</nav><script>alert(1)</script>
<h1>Opening hours</h1><p>We open at 9&nbsp;am.</p>
<ul><li>Mon</li><li>Tue</li></ul></body></html>''');
      expect(text, contains('Opening hours'));
      expect(text, contains('We open at 9 am.'));
      expect(text, contains('- Mon'));
      expect(text, isNot(contains('alert')));
      expect(text, isNot(contains('Home | About')));
    });

    test('local-network addresses are refused', () async {
      final service = WebSearchService(
          httpClient: MockClient((_) async => http.Response('', 200)));
      for (final url in [
        'http://192.168.1.20:11434/api',
        'http://localhost/',
        'file:///etc/passwd',
      ]) {
        await expectLater(
            service.read(url), throwsA(isA<WebSearchException>()));
      }
    });
  });

  // ------------------------------------------------ searching saved chats --

  group('searching captured messages', () {
    late AppDatabase database;
    late InboundMessageRepository messages;
    var n = 0;

    Future<void> add(String channel, String body, DateTime at,
        {String title = 'Project team'}) async {
      n++;
      await messages.add(InboundMessage(
        id: 'm$n',
        channel: channel,
        conversationId: title.toLowerCase(),
        conversationTitle: title,
        isGroup: true,
        sender: 'Sam',
        body: body,
        sentAt: at,
        externalId: 'ext$n',
        createdAt: at,
      ));
    }

    setUp(() async {
      database = AppDatabase();
      await database.open(overridePath: inMemoryDatabasePath);
      messages = InboundMessageRepository(database);
    });

    tearDown(() => database.close());

    test('any word matches, within one app and one day', () async {
      final today = DateTime(2026, 11, 25, 9);
      await add(MessageChannels.teams, 'Offsite meeting moved to 3pm', today);
      await add(MessageChannels.teams, 'Lunch is on me', today);
      await add(MessageChannels.teams, 'Team event on Friday',
          today.subtract(const Duration(days: 1)));
      await add(MessageChannels.whatsapp, 'Birthday event tonight', today);

      final found = await messages.find(
        channel: MessageChannels.teams,
        terms: const ['event', 'meeting', 'invite'],
        since: DateTime(2026, 11, 25),
        until: DateTime(2026, 11, 26),
      );
      expect(found.map((m) => m.body), ['Offsite meeting moved to 3pm']);

      final anyDay = await messages.find(
          channel: MessageChannels.teams, terms: const ['event']);
      expect(anyDay.map((m) => m.body), ['Team event on Friday']);

      final everything = await messages.find(
        since: DateTime(2026, 11, 25),
        until: DateTime(2026, 11, 26),
      );
      expect(everything, hasLength(3));
    });

    test('an app is found by the name people use for it', () {
      expect(MessageChannels.normalize('Teams'), MessageChannels.teams);
      expect(MessageChannels.normalize('Microsoft Teams'), MessageChannels.teams);
      expect(MessageChannels.normalize('com.microsoft.teams'),
          MessageChannels.teams);
      expect(MessageChannels.normalize('WhatsApp Business'),
          MessageChannels.whatsappBusiness);
      expect(MessageChannels.normalize('sms'), MessageChannels.sms);
      expect(MessageChannels.normalize('carrier pigeon'), isNull);
    });
  });

  // ----------------------------------------------------- chat timestamps --

  group('chat timestamps', () {
    final now = DateTime(2026, 11, 25, 15, 30);

    test('say the day as briefly as they can', () {
      expect(chatTimestamp(DateTime(2026, 11, 25, 9, 5), now: now),
          'Today, 09:05');
      expect(chatTimestamp(DateTime(2026, 11, 24, 22, 0), now: now),
          'Yesterday, 22:00');
      expect(chatTimestamp(DateTime(2026, 11, 3, 8, 15), now: now),
          'Tue 3 Nov, 08:15');
      expect(chatTimestamp(DateTime(2025, 12, 31, 23, 59), now: now),
          '31 Dec 2025, 23:59');
    });
  });

  // ------------------------------------------------------- reading aloud --

  group('a reply read aloud', () {
    test('drops markdown and links, and pauses after each bullet', () {
      final spoken = SpeechOutput.forSpeech(
          'Here is your day:\n- **Standup** at 9\n- Call Sam\n'
          'Details: https://example.com/x?y=1');
      expect(spoken,
          'Here is your day: Standup at 9. Call Sam. Details: a link.');
    });

    test('a long reply stops at a sentence and points at the screen', () {
      final long = List.filled(200, 'This is one sentence.').join(' ');
      final spoken = SpeechOutput.forSpeech(long);
      expect(spoken.length, lessThan(SpeechOutput.maxSpokenChars + 40));
      expect(spoken, endsWith('sentence. The rest is on your screen.'));
    });

    test('nothing to say is nothing', () {
      expect(SpeechOutput.forSpeech('  \n - \n'), isEmpty);
    });
  });
}
