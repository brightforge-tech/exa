import 'dart:convert';

import 'package:exa_mobile/services/ai_client/ai_client.dart';
import 'package:exa_mobile/services/ai_client/local_endpoint_client.dart';
import 'package:exa_mobile/services/ai_client/openai_compatible_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  group('a model that thinks before it answers', () {
    http.Response reply({String? reasoning, String content = 'Done.'}) =>
        http.Response(
          jsonEncode({
            'choices': [
              {
                'finish_reason': 'stop',
                'message': {
                  'role': 'assistant',
                  'content': content,
                  'reasoning_content': ?reasoning,
                },
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );

    ({LocalEndpointClient client, List<int> sent}) clientReplying(
        List<http.Response> replies) {
      final sent = <int>[];
      var call = 0;
      final client = LocalEndpointClient(
        baseUrl: 'http://localhost:1234',
        httpClient: MockClient((request) async {
          sent.add((jsonDecode(request.body) as Map)['max_tokens'] as int);
          return replies[call++];
        }),
      );
      return (client: client, sent: sent);
    }

    Future<void> ask(LocalEndpointClient client, int maxTokens) =>
        client.createMessage(
          model: 'local',
          system: 'You are Exa.',
          messages: const [
            {'role': 'user', 'content': 'hello'},
          ],
          maxTokens: maxTokens,
        );

    test('room for thinking is there before anything has been seen', () {
      // A background run is a fresh isolate: the reply is often written by
      // a client that has observed nothing yet.
      final fresh = clientReplying(const []).client;
      expect(fresh.reasoningHeadroom,
          LocalEndpointClient.defaultReasoningHeadroom);
      expect(OpenAiCompatibleClient.headroomOf(fresh), 2048);
    });

    test('long thinking earns more room, up to the ceiling', () async {
      final it = clientReplying([
        // ~1,500 tokens of deliberation.
        reply(reasoning: 'weighing the options carefully ' * 180),
        // Far more than any call will be given room for.
        reply(reasoning: 'weighing the options carefully ' * 2000),
      ]);
      await ask(it.client, 512);
      expect(it.client.reasoningHeadroom,
          greaterThan(LocalEndpointClient.defaultReasoningHeadroom));
      expect(it.client.reasoningHeadroom,
          lessThan(LocalEndpointClient.maxReasoningHeadroom));
      await ask(it.client, 512);
      expect(it.client.reasoningHeadroom,
          LocalEndpointClient.maxReasoningHeadroom);
    });

    test('a model that does not think changes nothing', () async {
      final it = clientReplying([reply(), reply()]);
      await ask(it.client, 512);
      await ask(it.client, 512);
      expect(it.client.reasoningHeadroom,
          LocalEndpointClient.defaultReasoningHeadroom);
    });

    test('a request is sent with exactly what the caller asked for',
        () async {
      // The room is the caller's to add. The routing call budgets for
      // thinking itself; adding more there only made a failed route slower.
      final it = clientReplying([reply(reasoning: 'hm ' * 3000), reply()]);
      await ask(it.client, 1024);
      await ask(it.client, 1024);
      expect(it.sent, [1024, 1024]);
    });
  });

  group('a call that should not stop to think', () {
    http.Response ok() => http.Response(
          jsonEncode({
            'choices': [
              {
                'finish_reason': 'stop',
                'message': {'role': 'assistant', 'content': '{"domains": []}'},
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );

    Future<AiResponse> ask(LocalEndpointClient client,
            {bool deliberate = true}) =>
        client.createMessage(
          model: 'local',
          system: 'Reply with JSON only.',
          messages: const [
            {'role': 'user', 'content': 'route this'},
          ],
          maxTokens: 1024,
          deliberate: deliberate,
        );

    test('asks the server to skip the deliberation', () async {
      final bodies = <Map<String, Object?>>[];
      final client = LocalEndpointClient(
        baseUrl: 'http://localhost:1234',
        httpClient: MockClient((request) async {
          bodies.add((jsonDecode(request.body) as Map).cast());
          return ok();
        }),
      );

      await ask(client, deliberate: false);
      await ask(client);

      expect(bodies.first['chat_template_kwargs'], {'enable_thinking': false});
      expect(bodies.first['max_tokens'], 1024);
      expect(bodies.last.containsKey('chat_template_kwargs'), isFalse,
          reason: 'every other call is sent exactly as before');
    });

    test('a server that rejects the request is asked again without it, '
        'and not asked that way twice', () async {
      final bodies = <Map<String, Object?>>[];
      final client = LocalEndpointClient(
        baseUrl: 'http://localhost:1234',
        httpClient: MockClient((request) async {
          final body = (jsonDecode(request.body) as Map).cast<String, Object?>();
          bodies.add(body);
          if (body.containsKey('chat_template_kwargs')) {
            return http.Response(
                jsonEncode({
                  'error': {'message': 'Extra inputs are not permitted'},
                }),
                422,
                headers: {'content-type': 'application/json'});
          }
          return ok();
        }),
      );

      final first = await ask(client, deliberate: false);
      final second = await ask(client, deliberate: false);

      expect(first.text, '{"domains": []}');
      expect(second.text, '{"domains": []}');
      expect([
        for (final body in bodies) body.containsKey('chat_template_kwargs'),
      ], [true, false, false]);
    });

    test('any other failure is still a failure', () async {
      final client = LocalEndpointClient(
        baseUrl: 'http://localhost:1234',
        httpClient: MockClient((request) async => http.Response(
            jsonEncode({
              'error': {'message': 'model not loaded'},
            }),
            503,
            headers: {'content-type': 'application/json'})),
      );
      await expectLater(
          ask(client, deliberate: false), throwsA(isA<AiException>()));
    });
  });

  group('LocalEndpointClient Anthropic <-> OpenAI translation', () {
    test('translates a tool-use turn and round-trips the tool id', () async {
      late Map<String, Object?> firstRequest;
      late Map<String, Object?> secondRequest;
      var calls = 0;

      final mockHttp = MockClient((request) async {
        calls++;
        final decoded =
            (jsonDecode(request.body) as Map).cast<String, Object?>();
        if (calls == 1) {
          firstRequest = decoded;
          // The server asks to call a tool. Note: no id field, to prove the
          // client synthesizes its own stable id.
          return http.Response(
            jsonEncode({
              'choices': [
                {
                  'finish_reason': 'tool_calls',
                  'message': {
                    'role': 'assistant',
                    'content': '',
                    'tool_calls': [
                      {
                        'type': 'function',
                        'function': {
                          'name': 'create_task',
                          'arguments': '{"title":"Buy milk"}',
                        },
                      },
                    ],
                  },
                },
              ],
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        secondRequest = decoded;
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'finish_reason': 'stop',
                'message': {'role': 'assistant', 'content': 'Added it.'},
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final client =
          LocalEndpointClient(baseUrl: 'http://localhost:1234', httpClient: mockHttp);

      // --- Turn 1: a plain user message, tools available.
      final first = await client.createMessage(
        model: 'llama3.1',
        system: 'You are Exa.',
        messages: [
          {'role': 'user', 'content': 'Add a task to buy milk'},
        ],
        tools: [
          {
            'name': 'create_task',
            'description': 'Create a task',
            'input_schema': {
              'type': 'object',
              'properties': {
                'title': {'type': 'string'}
              },
              'required': ['title'],
            },
          },
        ],
      );

      // Request was shaped as OpenAI: system message first, tools as functions.
      final reqMessages =
          (firstRequest['messages'] as List).cast<Map<String, Object?>>();
      expect(reqMessages.first['role'], 'system');
      final reqTools = firstRequest['tools'] as List;
      expect((reqTools.first as Map)['type'], 'function');
      expect(
          ((reqTools.first as Map)['function'] as Map)['name'], 'create_task');

      // Response was normalized to an Anthropic tool_use block with an id.
      expect(first.stopReason, 'tool_use');
      expect(first.toolUses, hasLength(1));
      final toolUse = first.toolUses.single;
      final synthesizedId = toolUse['id'] as String;
      // Template-safe synthesized id (Mistral templates require exactly
      // 9 alphanumeric chars).
      expect(synthesizedId, matches(RegExp(r'^[a-zA-Z0-9]{9}$')));
      expect(toolUse['name'], 'create_task');
      expect((toolUse['input'] as Map)['title'], 'Buy milk');

      // --- Turn 2: echo the assistant block + a tool_result with that id,
      // exactly as the orchestrator does.
      await client.createMessage(
        model: 'llama3.1',
        system: 'You are Exa.',
        messages: [
          {'role': 'user', 'content': 'Add a task to buy milk'},
          {'role': 'assistant', 'content': first.content},
          {
            'role': 'user',
            'content': [
              {
                'type': 'tool_result',
                'tool_use_id': synthesizedId,
                'content': '{"id":"t1","title":"Buy milk"}',
              },
            ],
          },
        ],
      );

      // The echoed assistant turn carries the SAME id on its tool_calls entry,
      // and the tool result becomes a role:tool message keyed to that id.
      final msgs =
          (secondRequest['messages'] as List).cast<Map<String, Object?>>();
      final assistant =
          msgs.firstWhere((m) => m['role'] == 'assistant');
      final toolCalls = (assistant['tool_calls'] as List).cast<Map>();
      expect(toolCalls.single['id'], synthesizedId);
      final toolMsg = msgs.firstWhere((m) => m['role'] == 'tool');
      expect(toolMsg['tool_call_id'], synthesizedId);

      client.dispose();
    });

    test('a server-provided tool-call id is preserved verbatim', () async {
      Map<String, Object?>? secondRequest;
      var calls = 0;
      final mockHttp = MockClient((request) async {
        calls++;
        if (calls == 1) {
          return http.Response(
            jsonEncode({
              'choices': [
                {
                  'finish_reason': 'tool_calls',
                  'message': {
                    'role': 'assistant',
                    'content': null,
                    'tool_calls': [
                      {
                        'id': 'call_abc123',
                        'type': 'function',
                        'function': {
                          'name': 'create_task',
                          'arguments': '{"title":"Buy milk"}',
                        },
                      },
                    ],
                  },
                },
              ],
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        secondRequest =
            (jsonDecode(request.body) as Map).cast<String, Object?>();
        return http.Response(
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
        );
      });

      final client = LocalEndpointClient(
          baseUrl: 'http://localhost:1234', httpClient: mockHttp);
      final first = await client.createMessage(
        model: 'llama3.1',
        system: '',
        messages: [
          {'role': 'user', 'content': 'Add a task'},
        ],
      );
      expect(first.toolUses.single['id'], 'call_abc123');

      await client.createMessage(
        model: 'llama3.1',
        system: '',
        messages: [
          {'role': 'user', 'content': 'Add a task'},
          {'role': 'assistant', 'content': first.content},
          {
            'role': 'user',
            'content': [
              {
                'type': 'tool_result',
                'tool_use_id': 'call_abc123',
                'content': '{"ok":true}',
              },
            ],
          },
        ],
      );
      final msgs =
          (secondRequest!['messages'] as List).cast<Map<String, Object?>>();
      final assistant = msgs.firstWhere((m) => m['role'] == 'assistant');
      expect(((assistant['tool_calls'] as List).single as Map)['id'],
          'call_abc123');
      expect(msgs.firstWhere((m) => m['role'] == 'tool')['tool_call_id'],
          'call_abc123');
      client.dispose();
    });

    test(
        "finish_reason 'tool_calls' without parsed calls maps to end_turn "
        'so the loop cannot send an empty tool_results message', () async {
      final mockHttp = MockClient((request) async {
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'finish_reason': 'tool_calls',
                'message': {'role': 'assistant', 'content': 'Hmm.'},
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final client = LocalEndpointClient(
          baseUrl: 'http://localhost:1234', httpClient: mockHttp);
      final response = await client.createMessage(
        model: 'llama3.1',
        system: '',
        messages: [
          {'role': 'user', 'content': 'Hi'},
        ],
      );
      expect(response.stopReason, 'end_turn');
      expect(response.toolUses, isEmpty);
      client.dispose();
    });

    test('a plain text answer maps to end_turn', () async {
      final mockHttp = MockClient((request) async {
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'finish_reason': 'stop',
                'message': {'role': 'assistant', 'content': 'Hello there.'},
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final client =
          LocalEndpointClient(baseUrl: 'http://localhost:1234/', httpClient: mockHttp);
      final response = await client.createMessage(
        model: 'llama3.1',
        system: '',
        messages: [
          {'role': 'user', 'content': 'Hi'},
        ],
      );
      expect(response.stopReason, 'end_turn');
      expect(response.text, 'Hello there.');
      client.dispose();
    });

    test('vision is off by default and opt-in per the loaded model', () {
      final client = LocalEndpointClient(baseUrl: 'http://localhost:1234');
      // Text-only is the safe assumption: most local models are, and image
      // parts make such a server reject the whole request.
      expect(client.supportsVision, isFalse);
      client.supportsVision = true;
      expect(client.supportsVision, isTrue);
      client.dispose();
    });

    test('sends an image block as an OpenAI image_url data URI', () async {
      late Map<String, Object?> request;
      final mockHttp = MockClient((r) async {
        request = (jsonDecode(r.body) as Map).cast<String, Object?>();
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'finish_reason': 'stop',
                'message': {'role': 'assistant', 'content': 'A receipt.'},
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final client = LocalEndpointClient(
          baseUrl: 'http://localhost:1234', httpClient: mockHttp)
        ..supportsVision = true;

      await client.createMessage(
        model: 'qwen2.5-vl',
        system: '',
        messages: [
          {
            'role': 'user',
            'content': [
              {'type': 'text', 'text': "What's the total?"},
              {
                'type': 'image',
                'source': {
                  'type': 'base64',
                  'media_type': 'image/png',
                  'data': 'QUJD',
                },
              },
            ],
          },
        ],
      );

      final messages = (request['messages'] as List).cast<Map>();
      final parts = (messages.single['content'] as List).cast<Map>();
      expect(parts.first['type'], 'text');
      expect(parts.first['text'], "What's the total?");
      expect(parts.last['type'], 'image_url');
      expect(
        (parts.last['image_url'] as Map)['url'],
        'data:image/png;base64,QUJD',
      );
      client.dispose();
    });
  });
}
