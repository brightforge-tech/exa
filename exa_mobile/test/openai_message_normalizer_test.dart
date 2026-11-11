import 'dart:convert';

import 'package:exa_mobile/services/ai_client/ai_client.dart';
import 'package:exa_mobile/services/ai_client/openai_message_normalizer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('normalizeOpenAiMessages', () {
    test('merges every system instruction into one at index 0', () {
      final out = normalizeOpenAiMessages([
        {'role': 'system', 'content': 'You are Exa.'},
        {'role': 'user', 'content': 'Hi'},
        {'role': 'system', 'content': 'Also be brief.'},
        {'role': 'assistant', 'content': 'Hello'},
      ]);

      expect(out.first['role'], 'system');
      expect(out.first['content'], 'You are Exa.\n\nAlso be brief.');
      expect(out.where((m) => m['role'] == 'system'), hasLength(1));
    });

    test('null assistant content becomes an empty string', () {
      final out = normalizeOpenAiMessages([
        {'role': 'user', 'content': 'Add a task'},
        {
          'role': 'assistant',
          'content': null,
          'tool_calls': [
            {
              'id': 'call_1',
              'type': 'function',
              'function': {'name': 'create_task', 'arguments': '{}'},
            },
          ],
        },
      ]);

      expect(out[1]['content'], '');
    });

    test('structured tool results are JSON-encoded to a string', () {
      final out = normalizeOpenAiMessages([
        {'role': 'user', 'content': 'go'},
        {
          'role': 'assistant',
          'content': '',
          'tool_calls': [
            {
              'id': 'call_1',
              'type': 'function',
              'function': {'name': 'create_task', 'arguments': '{}'},
            },
          ],
        },
        {
          'role': 'tool',
          'tool_call_id': 'call_1',
          'content': {'success': true},
        },
      ]);

      expect(out.last['content'], isA<String>());
      expect(jsonDecode(out.last['content'] as String), {'success': true});
    });

    test('merges consecutive user turns and consecutive assistant turns', () {
      final out = normalizeOpenAiMessages([
        {'role': 'user', 'content': 'first'},
        {'role': 'user', 'content': 'second'},
        {'role': 'assistant', 'content': 'a'},
        {'role': 'assistant', 'content': 'b'},
      ]);

      expect(out, hasLength(2));
      expect(out[0]['content'], 'first\n\nsecond');
      expect(out[1]['content'], 'a\n\nb');
    });

    test('never merges an assistant message carrying tool calls', () {
      final out = normalizeOpenAiMessages([
        {'role': 'user', 'content': 'go'},
        {
          'role': 'assistant',
          'content': '',
          'tool_calls': [
            {
              'id': 'call_1',
              'type': 'function',
              'function': {'name': 'a', 'arguments': '{}'},
            },
          ],
        },
        {'role': 'assistant', 'content': 'trailing note'},
      ]);

      // Merging would strand call_1's result with no matching call.
      expect(out, hasLength(3));
      expect((out[1]['tool_calls'] as List), hasLength(1));
    });

    test('keeps several tool calls inside a single assistant message', () {
      final out = normalizeOpenAiMessages([
        {'role': 'user', 'content': 'go'},
        {
          'role': 'assistant',
          'content': '',
          'tool_calls': [
            {
              'id': 'call_1',
              'type': 'function',
              'function': {'name': 'create_task', 'arguments': '{}'},
            },
            {
              'id': 'call_2',
              'type': 'function',
              'function': {'name': 'create_schedule_event', 'arguments': '{}'},
            },
          ],
        },
        {'role': 'tool', 'tool_call_id': 'call_1', 'content': '{}'},
        {'role': 'tool', 'tool_call_id': 'call_2', 'content': '{}'},
      ]);

      expect(out, hasLength(4));
      expect((out[1]['tool_calls'] as List), hasLength(2));
      expect(out[2]['tool_call_id'], 'call_1');
      expect(out[3]['tool_call_id'], 'call_2');
      validateOpenAiMessageSequence(out);
    });
  });

  group('validateOpenAiMessageSequence', () {
    List<Map<String, Object?>> toolTurn(String id) => [
          {'role': 'user', 'content': 'go'},
          {
            'role': 'assistant',
            'content': '',
            'tool_calls': [
              {
                'id': id,
                'type': 'function',
                'function': {'name': 'expand_tools', 'arguments': '{}'},
              },
            ],
          },
          {'role': 'tool', 'tool_call_id': id, 'content': '{"success":true}'},
        ];

    test('accepts a well-formed expand_tools exchange', () {
      expect(
        () => validateOpenAiMessageSequence(toolTurn('expand_001')),
        returnsNormally,
      );
    });

    test('rejects a system message that is not first', () {
      expect(
        () => validateOpenAiMessageSequence([
          {'role': 'user', 'content': 'hi'},
          {'role': 'system', 'content': 'late'},
        ]),
        throwsA(isA<AiException>()),
      );
    });

    test('rejects an unsupported role', () {
      expect(
        () => validateOpenAiMessageSequence([
          {'role': 'function', 'content': 'hi'},
        ]),
        throwsA(isA<AiException>()),
      );
    });

    test('rejects a tool result with no matching earlier tool call', () {
      expect(
        () => validateOpenAiMessageSequence([
          {'role': 'user', 'content': 'go'},
          {'role': 'tool', 'tool_call_id': 'orphan', 'content': '{}'},
        ]),
        throwsA(isA<AiException>()),
      );
    });

    test('rejects an assistant turn with neither text nor tool calls', () {
      expect(
        () => validateOpenAiMessageSequence([
          {'role': 'user', 'content': 'go'},
          {'role': 'assistant', 'content': ''},
        ]),
        throwsA(isA<AiException>()),
      );
    });

    test('rejects a tool message without a tool_call_id', () {
      expect(
        () => validateOpenAiMessageSequence([
          {'role': 'user', 'content': 'go'},
          {'role': 'tool', 'content': '{}'},
        ]),
        throwsA(isA<AiException>()),
      );
    });
  });
}
