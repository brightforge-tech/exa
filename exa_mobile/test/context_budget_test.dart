import 'dart:convert';

import 'package:exa_mobile/agent/behaviors/token_estimator.dart';
import 'package:exa_mobile/agent/services/context_budget.dart';
import 'package:flutter_test/flutter_test.dart';

/// A turn is assembled from things that grow without limit - history, tool
/// results, retrieved memories. One oversized piece (57 undigested emails in
/// a single tool result) ends the turn at the context limit.
void main() {
  group('budgets scale with the model', () {
    test('a small on-device window gets smaller allowances', () {
      final small = ContextBudget.forWindow(4096);
      final large = ContextBudget.forWindow(200000);
      expect(small.toolResultTokens, lessThan(large.toolResultTokens));
      expect(small.historyTokens, lessThan(large.historyTokens));
      expect(small.toolResultTokens, greaterThan(0));
    });

    test('an unknown window falls back to a modest assumption', () {
      final unknown = ContextBudget.forWindow(null);
      expect(unknown.windowTokens, ContextBudget.defaultWindow);
    });

    test('the default window is 32k', () {
      // Pinned so a change is deliberate: this value decides how much of a
      // turn fits for every provider that reports no window of its own.
      expect(ContextBudget.defaultWindow, 32000);
    });

    test('the default window has room for the history floor; 16k did not',
        () {
      // The reason the default moved. The floor is only worth having if six
      // replies fit under the REQUEST ceiling too - at 16k they did not, so
      // RequestFitter dropped straight back what HistoryBudget had just
      // held, and the floor was decorative.
      List<Map<String, Object?>> sixLongReplies() => [
            for (var i = 0; i < HistoryBudget.minimumRecentMessages; i++)
              {
                'role': i.isEven ? 'user' : 'assistant',
                // ~2,000 tokens: one of Exa's multi-section reports.
                'content': 'Message $i. ${'padding ' * 900}',
              },
            {'role': 'user', 'content': 'and now this one'},
          ];

      ({int size, int historyCount}) fitAt(int window) => RequestFitter.fit(
            system: 'You are Exa. ${'operating rule. ' * 100}',
            tools: [
              for (var i = 0; i < 20; i++)
                {
                  'name': 'tool_$i',
                  'description': 'A tool that does something. ${'detail ' * 30}',
                  'input_schema': const {'type': 'object'},
                },
            ],
            messages: sixLongReplies(),
            windowTokens: window,
            historyCount: HistoryBudget.minimumRecentMessages,
          );

      expect(fitAt(ContextBudget.defaultWindow).historyCount,
          HistoryBudget.minimumRecentMessages,
          reason: 'the whole floor should survive at the default window');
      expect(fitAt(16000).historyCount,
          lessThan(HistoryBudget.minimumRecentMessages),
          reason: 'and this is what it used to do instead');
    });
  });

  group('tool results', () {
    Map<String, Object?> emailPayload(int count) => {
          'count': count,
          'total_undigested': count,
          'emails': [
            for (var i = 0; i < count; i++)
              {
                'id': 'email-$i',
                'subject': 'Invoice $i for services rendered in the last '
                    'quarter',
                'from': 'billing$i@example.com',
                'summary': 'A long-ish summary of the message body that '
                    'stands in for what a real digest entry looks like, '
                    'repeated for every single message in the backlog.',
              },
          ],
        };

    test('a small result passes through untouched', () {
      final data = emailPayload(2);
      final fitted = ToolResultBudget.fit(data, 2000);
      expect(fitted, same(data));
      expect(ToolResultBudget.wasTruncated(fitted), isFalse);
    });

    test('an oversized list is shortened, not cut mid-JSON', () {
      final fitted = ToolResultBudget.fit(emailPayload(57), 500);
      expect(ToolResultBudget.wasTruncated(fitted), isTrue);
      // Still valid JSON, still the same shape.
      final decoded =
          jsonDecode(jsonEncode(fitted)) as Map<String, Object?>;
      expect(decoded['emails'], isA<List>());
      expect((decoded['emails'] as List).length, lessThan(57));
      expect(TokenEstimator.estimate(jsonEncode(fitted)),
          lessThanOrEqualTo(500));
    });

    test('the model is told how much it did not get', () {
      final fitted =
          ToolResultBudget.fit(emailPayload(57), 500) as Map<String, Object?>;
      final marker =
          fitted[ToolResultBudget.truncatedKey] as Map<String, Object?>;
      expect(marker['total'], 57);
      expect(marker['showing'], isA<int>());
      expect(marker['remaining'], greaterThan(0));
      expect(marker['next_step'], contains('again'));
    });

    test('a single huge string is clipped and flagged', () {
      final fitted = ToolResultBudget.fit(
          {'body': 'x' * 100000, 'id': 'e1'}, 200) as Map<String, Object?>;
      expect(ToolResultBudget.wasTruncated(fitted), isTrue);
      expect((fitted['body'] as String).length, lessThan(100000));
      expect(fitted['id'], 'e1', reason: 'other fields survive');
    });

    test('null and scalars are safe', () {
      expect(ToolResultBudget.fit(null, 100), isNull);
      expect(ToolResultBudget.fit(42, 100), 42);
    });
  });

  group('history', () {
    List<Map<String, Object?>> conversation(int turns) => [
          for (var i = 0; i < turns; i++)
            {
              'role': i.isEven ? 'user' : 'assistant',
              'content': 'Message $i. ${'padding ' * 40}',
            },
        ];

    test('the oldest turns are dropped, the newest kept', () {
      final trimmed = HistoryBudget.fit(conversation(30), 300);
      expect(trimmed.length, lessThan(30));
      expect(trimmed.last['content'], contains('Message 29'));
      expect(
          trimmed.map((m) => m['content'] as String).join(),
          isNot(contains('Message 0.')));
    });

    test('a conversation within budget is untouched', () {
      final short = conversation(2);
      expect(HistoryBudget.fit(short, 100000), hasLength(2));
    });

    test('the recent-message floor survives an impossible budget', () {
      // The point of the floor: a follow-up that refers back ("that screen",
      // "the one you just made") needs the referent still present, and a
      // pure token budget would have cut this to a single message.
      expect(HistoryBudget.fit(conversation(10), 1),
          hasLength(HistoryBudget.minimumRecentMessages));
    });

    test('the floor keeps the NEWEST messages, not the oldest', () {
      final trimmed = HistoryBudget.fit(conversation(10), 1);
      expect(trimmed.last['content'], contains('Message 9'));
      expect(trimmed.first['content'], contains('Message 4'));
    });

    test('a caller may lower the floor explicitly', () {
      expect(HistoryBudget.fit(conversation(10), 1, keepRecent: 1),
          hasLength(1));
    });

    test('the floor never invents messages that do not exist', () {
      expect(HistoryBudget.fit(conversation(2), 1), hasLength(2));
    });
  });

  group('the running conversation', () {
    List<Map<String, Object?>> loopWith(int rounds) => [
          {'role': 'user', 'content': 'digest my email'},
          for (var i = 0; i < rounds; i++) ...[
            {
              'role': 'assistant',
              'content': [
                {
                  'type': 'tool_use',
                  'id': 'toolu_$i',
                  'name': 'read_email_context',
                  'input': {'id': 'e$i'},
                },
              ],
            },
            {
              'role': 'user',
              'content': [
                {
                  'type': 'tool_result',
                  'tool_use_id': 'toolu_$i',
                  'content': 'A full email body. ${'padding ' * 200}',
                },
              ],
            },
          ],
        ];

    test('accumulated results are blanked once the whole turn overflows',
        () {
      final messages = loopWith(6);
      MessageWindow.trim(messages, 400);

      final results = messages
          .expand((m) => m['content'] is List
              ? (m['content'] as List)
              : const [])
          .whereType<Map>()
          .where((b) => b['type'] == 'tool_result')
          .toList();
      final blanked =
          results.where((b) => b['content'] == MessageWindow.placeholder);
      expect(blanked, isNotEmpty, reason: 'the oldest give way first');
      expect(blanked.length, lessThan(results.length),
          reason: 'the newest survive');
    });

    test('every tool_use keeps an answering tool_result', () {
      // Dropping a block outright would make the request invalid; only the
      // payload may shrink.
      final messages = loopWith(6);
      MessageWindow.trim(messages, 100);
      final uses = messages
          .expand((m) => m['content'] is List ? (m['content'] as List) : [])
          .whereType<Map>()
          .where((b) => b['type'] == 'tool_use')
          .length;
      final results = messages
          .expand((m) => m['content'] is List ? (m['content'] as List) : [])
          .whereType<Map>()
          .where((b) => b['type'] == 'tool_result')
          .length;
      expect(results, uses);
    });

    test('the most recent exchange is never touched', () {
      final messages = loopWith(4);
      MessageWindow.trim(messages, 50);
      final last = (messages.last['content'] as List).first as Map;
      expect(last['content'], isNot(MessageWindow.placeholder));
    });

    test('a conversation within budget is left alone', () {
      final messages = loopWith(1);
      final before = jsonEncode(messages);
      MessageWindow.trim(messages, 100000);
      expect(jsonEncode(messages), before);
    });
  });

  group('tool definitions', () {
    test('get their own share of the window', () {
      // The full registry is ~6,700 tokens and is re-sent every iteration,
      // so on a small model it cannot be sent unscoped.
      final small = ContextBudget.forWindow(8192);
      expect(small.toolDefinitionTokens, lessThan(6700),
          reason: 'an 8k model must not be sent the whole registry');
      final large = ContextBudget.forWindow(200000);
      expect(large.toolDefinitionTokens, greaterThan(6700));
    });

    test('the conversation share leaves room for the rest of the turn', () {
      final budget = ContextBudget.forWindow(8192);
      final framing = budget.toolDefinitionTokens + budget.memoryTokens;
      expect(framing + budget.conversationTokens,
          lessThan(budget.windowTokens),
          reason: 'framing plus conversation must leave room to answer');
    });
  });

  group('the assembled request', () {
    // The failure this exists for: every part within its own budget while
    // the total still overflows, which a server rejects outright -
    // "17042 tokens exceeds the available context size (16384)".
    List<Map<String, Object?>> bigConversation() => [
          {'role': 'user', 'content': 'digest my email'},
          for (var i = 0; i < 8; i++) ...[
            {
              'role': 'assistant',
              'content': [
                {
                  'type': 'tool_use',
                  'id': 'toolu_$i',
                  'name': 'read_email_context',
                  'input': const {},
                },
              ],
            },
            {
              'role': 'user',
              'content': [
                {
                  'type': 'tool_result',
                  'tool_use_id': 'toolu_$i',
                  'content': 'body ${'padding ' * 300}',
                },
              ],
            },
          ],
        ];

    test('is trimmed until system + tools + messages actually fit', () {
      final messages = bigConversation();
      final tools = [
        for (var i = 0; i < 20; i++)
          {
            'name': 'tool_$i',
            'description': 'A tool that does something. ${'detail ' * 30}',
            'input_schema': const {'type': 'object'},
          },
      ];
      final system = 'You are Exa. ${'operating rule. ' * 100}';

      final size = RequestFitter.fit(
        system: system,
        tools: tools,
        messages: messages,
        windowTokens: 16384,
      ).size;

      expect(size, lessThanOrEqualTo(16384),
          reason: 'the whole request must fit, not just each part');
      expect(size,
          lessThanOrEqualTo((16384 * RequestFitter.requestShare).round() + 50),
          reason: 'and leave the model room to answer');
    });

    test('a request that already fits is left alone', () {
      final messages = [
        {'role': 'user', 'content': 'hello'},
      ];
      final before = jsonEncode(messages);
      RequestFitter.fit(
        system: 'short',
        tools: const [],
        messages: messages,
        windowTokens: 16384,
      );
      expect(jsonEncode(messages), before);
    });
  });

  /// The history floor is only safe because the request fitter can go below
  /// it. Blanking tool results cannot reach replayed history - those carry
  /// plain strings, not tool_result blocks - and on the first call of a turn
  /// there are no tool results to blank at all. Without this escape hatch a
  /// floor that overshoots the window is sent oversized and the provider
  /// rejects it, which kills the turn instead of degrading the answer.
  group('history as the last resort', () {
    /// [historyTurns] replayed messages, then the current question. Each
    /// history message is deliberately long - roughly 900 tokens, the size
    /// of one of Exa's structured replies - because that is what makes the
    /// floor collide with a small window in the first place.
    List<Map<String, Object?>> turnWith(int historyTurns) => [
          for (var i = 0; i < historyTurns; i++)
            {
              'role': i.isEven ? 'user' : 'assistant',
              'content': 'Message $i. ${'padding ' * 400}',
            },
          {'role': 'user', 'content': 'and now this one'},
        ];

    test('a floor that will not fit is cut down until it does', () {
      final messages = turnWith(HistoryBudget.minimumRecentMessages);

      final fitted = RequestFitter.fit(
        system: 'You are Exa.',
        tools: const [],
        messages: messages,
        windowTokens: 4096,
        historyCount: HistoryBudget.minimumRecentMessages,
      );

      expect(fitted.size, lessThanOrEqualTo(4096),
          reason: 'nothing oversized may leave, floor or no floor');
      expect(fitted.historyCount,
          lessThan(HistoryBudget.minimumRecentMessages),
          reason: 'the floor must yield rather than overflow the window');
    });

    test('the current question is never dropped to make room', () {
      final messages = turnWith(HistoryBudget.minimumRecentMessages);

      RequestFitter.fit(
        system: 'You are Exa.',
        tools: const [],
        messages: messages,
        windowTokens: 2000,
        historyCount: HistoryBudget.minimumRecentMessages,
      );

      expect(messages.last['content'], 'and now this one');
      expect(messages, isNotEmpty);
    });

    test('dropping never leaves the conversation opening on an assistant',
        () {
      // The API rejects that outright, and dropping from the front is
      // exactly how it happens.
      for (var window = 1200; window <= 6000; window += 400) {
        final messages = turnWith(HistoryBudget.minimumRecentMessages);
        RequestFitter.fit(
          system: 'You are Exa.',
          tools: const [],
          messages: messages,
          windowTokens: window,
          historyCount: HistoryBudget.minimumRecentMessages,
        );
        expect(messages.first['role'], 'user',
            reason: 'invalid request shape at window=$window');
      }
    });

    test('history is spared when the request already fits', () {
      final messages = turnWith(4);
      final before = jsonEncode(messages);

      final fitted = RequestFitter.fit(
        system: 'You are Exa.',
        tools: const [],
        messages: messages,
        windowTokens: 200000,
        historyCount: 4,
      );

      expect(jsonEncode(messages), before);
      expect(fitted.historyCount, 4);
    });

    test('omitting historyCount preserves the old behaviour', () {
      // Callers that have not opted in must not silently start losing
      // history: with no eligible prefix, nothing may be dropped.
      final messages = turnWith(HistoryBudget.minimumRecentMessages);
      final lengthBefore = messages.length;

      final fitted = RequestFitter.fit(
        system: 'You are Exa.',
        tools: const [],
        messages: messages,
        windowTokens: 2000,
      );

      expect(messages, hasLength(lengthBefore));
      expect(fitted.historyCount, 0);
    });

    test('tool results are blanked before any history is given up', () {
      // Order matters: a stale tool result is worth less than the
      // conversation that explains what the user is asking for.
      final messages = <Map<String, Object?>>[
        {'role': 'user', 'content': 'first question'},
        {'role': 'assistant', 'content': 'first answer'},
        {'role': 'user', 'content': 'digest my email'},
        {
          'role': 'assistant',
          'content': [
            {
              'type': 'tool_use',
              'id': 'toolu_1',
              'name': 'read_email_context',
              'input': const {},
            },
          ],
        },
        {
          'role': 'user',
          'content': [
            {
              'type': 'tool_result',
              'tool_use_id': 'toolu_1',
              // Big enough to blow the window on its own, so blanking it
              // alone is provably sufficient.
              'content': 'body ${'padding ' * 2000}',
            },
          ],
        },
        {'role': 'assistant', 'content': 'here is the digest'},
      ];

      final fitted = RequestFitter.fit(
        system: 'You are Exa.',
        tools: const [],
        messages: messages,
        windowTokens: 4096,
        historyCount: 2,
      );

      expect(fitted.historyCount, 2,
          reason: 'blanking the oversized result should have been enough');
      expect(messages.first['content'], 'first question');
      final toolTurn = messages[4]['content'] as List;
      expect((toolTurn.first as Map)['content'], MessageWindow.placeholder);
    });

    test('dropOldestHistory reports what survived', () {
      final messages = turnWith(6);

      final remaining = MessageWindow.dropOldestHistory(messages, 300,
          historyCount: 6);

      expect(remaining, lessThan(6));
      expect(messages, hasLength(remaining + 1),
          reason: 'the current question is not history and stays');
    });

    test('dropOldestHistory will not touch a list that fits', () {
      final messages = turnWith(6);
      final before = jsonEncode(messages);

      final remaining = MessageWindow.dropOldestHistory(messages, 1000000,
          historyCount: 6);

      expect(remaining, 6);
      expect(jsonEncode(messages), before);
    });
  });

  group('token estimates', () {
    test('JSON is counted denser than prose', () {
      // Tool definitions and results are JSON; counting them as prose
      // under-counts by roughly a third, which is exactly the gap between
      // a request that fits and one the server refuses.
      const json = '{"id":"e1","subject":"Invoice","from":"a@b.com",'
          '"received_at":"2026-07-27T10:00:00.000","digested":false}';
      final prose = 'x' * json.length;
      expect(TokenEstimator.estimate(json),
          greaterThan(TokenEstimator.estimate(prose)));
    });

    test('ordinary sentences are still counted as prose', () {
      const sentence =
          'Please send the quarterly figures before Friday afternoon.';
      expect(TokenEstimator.estimate(sentence),
          lessThan(sentence.length ~/ 2));
    });
  });

  group('text blocks', () {
    test('clipping happens on a line boundary and says so', () {
      final block = List.generate(50, (i) => 'memory line $i').join('\n');
      final fitted = TextBudget.fit(block, 40);
      expect(fitted, contains('memory line 0'));
      expect(fitted, contains('trimmed'));
      expect(fitted, isNot(contains('memory line 49')));
      // No half-written line.
      expect(fitted.split('\n').where((l) => l.startsWith('memory line')),
          everyElement(matches(RegExp(r'^memory line \d+$'))));
    });

    test('a block within budget is returned unchanged', () {
      expect(TextBudget.fit('short', 1000), 'short');
    });
  });
}
