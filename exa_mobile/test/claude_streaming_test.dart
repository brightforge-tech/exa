import 'dart:convert';

import 'package:exa_mobile/services/ai_client/claude_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// A representative Anthropic SSE stream: a text block (two deltas) followed by
/// a tool_use block whose JSON input arrives as fragments.
const _sse = '''
event: message_start
data: {"type":"message_start","message":{"id":"msg_1"}}

event: content_block_start
data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":" world"}}

event: content_block_stop
data: {"type":"content_block_stop","index":0}

event: content_block_start
data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_1","name":"create_task","input":{}}}

event: content_block_delta
data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\\"title\\":"}}

event: content_block_delta
data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":" \\"Buy milk\\"}"}}

event: content_block_stop
data: {"type":"content_block_stop","index":1}

event: message_delta
data: {"type":"message_delta","delta":{"stop_reason":"tool_use"}}

event: message_stop
data: {"type":"message_stop"}
''';

void main() {
  test('streamMessage forwards text deltas and rebuilds the content blocks',
      () async {
    final bytes = utf8.encode(_sse);
    final mid = bytes.length ~/ 2; // split mid-stream to exercise buffering
    final mock = MockClient.streaming((request, body) async {
      return http.StreamedResponse(
        Stream.fromIterable([bytes.sublist(0, mid), bytes.sublist(mid)]),
        200,
        headers: {'content-type': 'text/event-stream'},
      );
    });

    final client = ClaudeClient(httpClient: mock);
    final deltas = <String>[];
    final response = await client.streamMessage(
      apiKey: 'sk-test',
      model: 'claude-opus-4-8',
      system: 'system',
      messages: [
        {'role': 'user', 'content': 'hi'}
      ],
      tools: const [],
      onText: deltas.add,
    );

    // Text streamed incrementally and reassembled.
    expect(deltas.join(), 'Hello world');
    expect(response.text, 'Hello world');
    expect(response.stopReason, 'tool_use');

    // The tool_use block's fragmented JSON input parsed correctly.
    final toolUse = response.toolUses.single;
    expect(toolUse['name'], 'create_task');
    expect((toolUse['input'] as Map)['title'], 'Buy milk');
  });

  test('streamMessage surfaces an HTTP error body as ClaudeApiException',
      () async {
    final mock = MockClient.streaming((request, body) async {
      return http.StreamedResponse(
        Stream.value(utf8.encode(
            '{"error":{"type":"authentication_error","message":"bad key"}}')),
        401,
        headers: {'content-type': 'application/json'},
      );
    });
    final client = ClaudeClient(httpClient: mock);

    expect(
      () => client.streamMessage(
        apiKey: 'sk-bad',
        model: 'claude-opus-4-8',
        system: 'system',
        messages: [
          {'role': 'user', 'content': 'hi'}
        ],
      ),
      throwsA(isA<ClaudeApiException>()
          .having((e) => e.statusCode, 'statusCode', 401)),
    );
  });
}
