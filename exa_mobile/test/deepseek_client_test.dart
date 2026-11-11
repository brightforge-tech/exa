import 'dart:convert';

import 'package:exa_mobile/services/ai_client/ai_client.dart';
import 'package:exa_mobile/services/ai_client/deepseek_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// A minimal OpenAI-shaped chat completion.
String _completion({String? text, List<Map<String, Object?>>? toolCalls}) =>
    jsonEncode({
      'choices': [
        {
          'finish_reason': toolCalls == null ? 'stop' : 'tool_calls',
          'message': {
            'role': 'assistant',
            'content': text,
            'tool_calls': ?toolCalls,
          },
        },
      ],
      'usage': {
        'prompt_tokens': 120,
        'completion_tokens': 8,
        'prompt_cache_hit_tokens': 64,
        'prompt_cache_miss_tokens': 56,
      },
    });

void main() {
  group('DeepSeekClient', () {
    test('posts to the DeepSeek endpoint with a bearer key', () async {
      late http.Request sent;
      final client = DeepSeekClient(
        apiKey: 'sk-test',
        httpClient: MockClient((request) async {
          sent = request;
          return http.Response(_completion(text: 'Hi.'), 200,
              headers: {'content-type': 'application/json'});
        }),
      );

      final response = await client.createMessage(
        model: 'deepseek-chat',
        system: 'You are Exa.',
        messages: [
          {'role': 'user', 'content': 'Hello'},
        ],
      );

      expect(sent.url.toString(),
          'https://api.deepseek.com/v1/chat/completions');
      expect(sent.headers['authorization'], 'Bearer sk-test');
      final body = (jsonDecode(sent.body) as Map).cast<String, Object?>();
      expect(body['model'], 'deepseek-chat');
      expect(body['stream'], false);
      // System prompt is folded in as the first OpenAI message.
      final messages = (body['messages'] as List).cast<Map>();
      expect(messages.first['role'], 'system');
      expect(response.text, 'Hi.');
      expect(response.stopReason, 'end_turn');
      // Usage, including DeepSeek's cache split, is reported so the token
      // estimator has something real to calibrate against.
      expect(response.inputTokens, 120);
      expect(response.outputTokens, 8);
      expect(response.cacheReadTokens, 64);
      expect(response.cacheWriteTokens, 56);
      client.dispose();
    });

    test('a per-call key overrides the stored one', () async {
      late http.Request sent;
      final client = DeepSeekClient(
        apiKey: 'sk-stored',
        httpClient: MockClient((request) async {
          sent = request;
          return http.Response(_completion(text: 'ok'), 200);
        }),
      );
      await client.createMessage(
        apiKey: 'sk-per-call',
        model: 'deepseek-chat',
        system: '',
        messages: [
          {'role': 'user', 'content': 'Hello'},
        ],
      );
      expect(sent.headers['authorization'], 'Bearer sk-per-call');
      client.dispose();
    });

    test('a missing key fails with an instruction, not a 401', () async {
      final client = DeepSeekClient(
          httpClient: MockClient((_) async =>
              http.Response('{"error":{"message":"unauthorized"}}', 401)));
      await expectLater(
        client.createMessage(
          model: 'deepseek-chat',
          system: '',
          messages: [
            {'role': 'user', 'content': 'Hello'},
          ],
        ),
        // Reported as the configuration error it is, not dressed up as a
        // network failure or bounced off the server as a 401.
        throwsA(isA<AiException>().having((e) => e.message, 'message',
            'No DeepSeek API key is set. Add one in Settings > AI provider.')),
      );
      client.dispose();
    });

    test('a trailing /v1 on the base URL is not doubled up', () async {
      late http.Request sent;
      final client = DeepSeekClient(
        baseUrl: 'https://proxy.example.com/v1/',
        apiKey: 'sk-test',
        httpClient: MockClient((request) async {
          sent = request;
          return http.Response(_completion(text: 'ok'), 200);
        }),
      );
      await client.createMessage(
        model: 'deepseek-chat',
        system: '',
        messages: [
          {'role': 'user', 'content': 'Hi'},
        ],
      );
      expect(sent.url.toString(),
          'https://proxy.example.com/v1/chat/completions');
      client.dispose();
    });

    test('tool calls round-trip as Anthropic blocks', () async {
      var calls = 0;
      Map<String, Object?>? second;
      final client = DeepSeekClient(
        apiKey: 'sk-test',
        httpClient: MockClient((request) async {
          calls++;
          if (calls == 1) {
            return http.Response(
              _completion(toolCalls: [
                {
                  'id': 'call_0_abc',
                  'type': 'function',
                  'function': {
                    'name': 'create_task',
                    'arguments': '{"title":"Buy milk"}',
                  },
                },
              ]),
              200,
            );
          }
          second = (jsonDecode(request.body) as Map).cast<String, Object?>();
          return http.Response(_completion(text: 'Added it.'), 200);
        }),
      );

      final first = await client.createMessage(
        model: 'deepseek-chat',
        system: '',
        messages: [
          {'role': 'user', 'content': 'Add a task to buy milk'},
        ],
        tools: [
          {
            'name': 'create_task',
            'description': 'Create a task',
            'input_schema': {'type': 'object', 'properties': {}},
          },
        ],
      );
      expect(first.stopReason, 'tool_use');
      expect(first.toolUses.single['id'], 'call_0_abc');
      expect((first.toolUses.single['input'] as Map)['title'], 'Buy milk');

      await client.createMessage(
        model: 'deepseek-chat',
        system: '',
        messages: [
          {'role': 'user', 'content': 'Add a task to buy milk'},
          {'role': 'assistant', 'content': first.content},
          {
            'role': 'user',
            'content': [
              {
                'type': 'tool_result',
                'tool_use_id': 'call_0_abc',
                'content': '{"id":"t1"}',
              },
            ],
          },
        ],
      );
      final messages = (second!['messages'] as List).cast<Map>();
      final assistant = messages.firstWhere((m) => m['role'] == 'assistant');
      expect(((assistant['tool_calls'] as List).single as Map)['id'],
          'call_0_abc');
      expect(messages.firstWhere((m) => m['role'] == 'tool')['tool_call_id'],
          'call_0_abc');
      client.dispose();
    });

    test('reasoning content becomes a thinking block, never the answer', () async {
      final client = DeepSeekClient(
        apiKey: 'sk-test',
        httpClient: MockClient((_) async => http.Response(
              jsonEncode({
                'choices': [
                  {
                    'finish_reason': 'stop',
                    'message': {
                      'role': 'assistant',
                      'reasoning_content': 'The user greeted me...',
                      'content': 'Hello!',
                    },
                  },
                ],
              }),
              200,
            )),
      );
      final response = await client.createMessage(
        model: 'deepseek-reasoner',
        system: '',
        messages: [
          {'role': 'user', 'content': 'Hi'},
        ],
      );
      // The chain of thought is preserved as a block but is not part of the
      // text the user sees.
      expect(response.text, 'Hello!');
      expect(response.content.first['type'], 'thinking');
      client.dispose();
    });

    test('an echoed turn drops the thinking block DeepSeek would reject',
        () async {
      late Map<String, Object?> body;
      final client = DeepSeekClient(
        apiKey: 'sk-test',
        httpClient: MockClient((request) async {
          body = (jsonDecode(request.body) as Map).cast<String, Object?>();
          return http.Response(_completion(text: 'ok'), 200);
        }),
      );
      await client.createMessage(
        model: 'deepseek-reasoner',
        system: '',
        messages: [
          {'role': 'user', 'content': 'Hi'},
          {
            'role': 'assistant',
            'content': [
              {'type': 'thinking', 'thinking': 'internal'},
              {'type': 'text', 'text': 'Hello!'},
            ],
          },
          {'role': 'user', 'content': 'Again'},
        ],
      );
      final assistant = (body['messages'] as List)
          .cast<Map>()
          .firstWhere((m) => m['role'] == 'assistant');
      expect(assistant['content'], 'Hello!');
      expect(jsonEncode(body), isNot(contains('internal')));
      client.dispose();
    });

    test('max_tokens is clamped to what the chosen model can emit', () async {
      final bodies = <Map<String, Object?>>[];
      final client = DeepSeekClient(
        apiKey: 'sk-test',
        httpClient: MockClient((request) async {
          bodies.add((jsonDecode(request.body) as Map).cast<String, Object?>());
          return http.Response(_completion(text: 'ok'), 200);
        }),
      );
      for (final model in ['deepseek-chat', 'deepseek-reasoner']) {
        await client.createMessage(
          model: model,
          system: '',
          messages: [
            {'role': 'user', 'content': 'Hi'},
          ],
          maxTokens: 100000,
        );
      }
      // Asking for more than the model can produce is a 400, so the request
      // is trimmed rather than bounced.
      expect(bodies[0]['max_tokens'], DeepSeekClient.maxOutputTokens);
      expect(bodies[1]['max_tokens'], DeepSeekClient.maxReasonerOutputTokens);
      client.dispose();
    });

    test('streams text deltas and reassembles tool calls', () async {
      final chunks = [
        {
          'choices': [
            {
              'delta': {'content': 'Adding'}
            }
          ]
        },
        {
          'choices': [
            {
              'delta': {'content': ' it.'}
            }
          ]
        },
        {
          'choices': [
            {
              'delta': {
                'tool_calls': [
                  {
                    'index': 0,
                    'id': 'call_9',
                    'function': {'name': 'create_task', 'arguments': '{"tit'},
                  },
                ],
              },
            },
          ],
        },
        {
          'choices': [
            {
              'delta': {
                'tool_calls': [
                  {
                    'index': 0,
                    'function': {'arguments': 'le":"Milk"}'},
                  },
                ],
              },
            },
          ],
        },
        {
          'choices': [
            {'delta': {}, 'finish_reason': 'tool_calls'}
          ],
          'usage': {'prompt_tokens': 30, 'completion_tokens': 12},
        },
      ];
      final sse = StringBuffer();
      for (final chunk in chunks) {
        sse.write('data: ${jsonEncode(chunk)}\n\n');
      }
      sse.write('data: [DONE]\n\n');

      late String sentBody;
      final client = DeepSeekClient(
        apiKey: 'sk-test',
        httpClient: MockClient.streaming((request, bodyStream) async {
          sentBody = await bodyStream.bytesToString();
          return http.StreamedResponse(
            Stream.value(utf8.encode(sse.toString())),
            200,
            headers: {'content-type': 'text/event-stream'},
          );
        }),
      );

      final deltas = <String>[];
      final response = await client.streamMessage(
        model: 'deepseek-chat',
        system: '',
        messages: [
          {'role': 'user', 'content': 'Add a task'},
        ],
        onText: deltas.add,
      );

      expect(deltas, ['Adding', ' it.']);
      expect(response.text, 'Adding it.');
      expect(response.stopReason, 'tool_use');
      final toolUse = response.toolUses.single;
      expect(toolUse['id'], 'call_9');
      expect(toolUse['name'], 'create_task');
      expect((toolUse['input'] as Map)['title'], 'Milk');
      expect(response.inputTokens, 30);
      expect(response.outputTokens, 12);
      // Usage only rides along on the final chunk when it is asked for.
      final body = (jsonDecode(sentBody) as Map).cast<String, Object?>();
      expect(body['stream'], true);
      expect((body['stream_options'] as Map)['include_usage'], true);
      client.dispose();
    });

    test('a mid-stream error surfaces as an AiException', () async {
      final client = DeepSeekClient(
        apiKey: 'sk-test',
        httpClient: MockClient.streaming((request, bodyStream) async {
          return http.StreamedResponse(
            Stream.value(utf8.encode(
                'data: {"error":{"message":"rate limited"}}\n\n')),
            200,
          );
        }),
      );
      await expectLater(
        client.streamMessage(
          model: 'deepseek-chat',
          system: '',
          messages: [
            {'role': 'user', 'content': 'Hi'},
          ],
        ),
        throwsA(isA<AiException>()
            .having((e) => e.message, 'message', 'rate limited')),
      );
      client.dispose();
    });

    test('an HTTP error reports DeepSeek\'s own message', () async {
      final client = DeepSeekClient(
        apiKey: 'sk-test',
        httpClient: MockClient((_) async => http.Response(
            jsonEncode({
              'error': {'message': 'Insufficient Balance'}
            }),
            402)),
      );
      await expectLater(
        client.createMessage(
          model: 'deepseek-chat',
          system: '',
          messages: [
            {'role': 'user', 'content': 'Hi'},
          ],
        ),
        throwsA(isA<AiException>()
            .having((e) => e.message, 'message', 'Insufficient Balance')
            .having((e) => e.statusCode, 'statusCode', 402)),
      );
      client.dispose();
    });

    test('declares its real capabilities', () {
      final client = DeepSeekClient();
      // No vision in the API: callers must substitute a text note rather than
      // post image parts that would be rejected.
      expect(client.supportsVision, isFalse);
      expect(client.supportsPdfDocument, isFalse);
      expect(client.contextWindow, DeepSeekClient.contextTokens);
      client.dispose();
    });
  });
}
