import 'dart:convert';

import 'package:exa_mobile/agent/services/context_budget.dart';
import 'package:exa_mobile/data/database/app_database.dart';
import 'package:exa_mobile/data/models/chat_message.dart';
import 'package:exa_mobile/data/repositories/behavior_repository.dart';
import 'package:exa_mobile/data/repositories/chat_repository.dart';
import 'package:exa_mobile/data/repositories/settings_repository.dart';
import 'package:exa_mobile/agent/orchestrator/agent_orchestrator.dart';
import 'package:exa_mobile/services/ai_client/claude_client.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'domain_scoping_test.dart' show buildRegistry, jsonResponse,
    routerResponse;

/// A provider with a small context, which is where the history floor and the
/// request ceiling actually collide.
class _SmallWindowClient extends ClaudeClient {
  _SmallWindowClient({required super.httpClient, required this.window});

  final int window;

  @override
  int? get contextWindow => window;
}

/// End-to-end cover for the replayed-history floor.
///
/// The unit tests around [HistoryBudget] and [MessageWindow] prove the pieces;
/// this proves the wiring - that the floor survives assembly into a real
/// request, and that the escape hatch keeps an oversized one from being sent.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late AppDatabase database;

  setUp(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (call) async => call.method == 'read' ? 'sk-test-key' : null,
    );
    database = AppDatabase();
    await database.open(overridePath: inMemoryDatabasePath);
  });

  tearDown(() async {
    await database.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      null,
    );
  });

  /// Seeds [pairs] user/assistant exchanges with explicit, staggered
  /// timestamps - `recent()` orders by created_at, and messages appended in
  /// the same millisecond would come back in an arbitrary order.
  Future<void> seedHistory(int pairs, {int paddingWords = 120}) async {
    final base = DateTime(2026, 7, 29, 9);
    for (var i = 0; i < pairs * 2; i++) {
      final message = ChatMessage(
        id: 'seed_$i',
        role: i.isEven ? 'user' : 'assistant',
        content: 'Message $i. ${'padding ' * paddingWords}',
        createdAt: base.add(Duration(minutes: i)),
      );
      await database.db.insert('chat_messages', message.toRow());
    }
  }

  /// Runs one turn and returns the messages array of the tool-loop request.
  Future<List<Map<String, Object?>>> messagesSentWith(int window) async {
    final bodies = <Map<String, Object?>>[];
    final mockHttp = MockClient((request) async {
      final body = (jsonDecode(request.body) as Map).cast<String, Object?>();
      bodies.add(body);
      if (body['tools'] == null) return routerResponse('["tasks"]');
      return jsonResponse({
        'stop_reason': 'end_turn',
        'content': [
          {'type': 'text', 'text': 'Done.'},
        ],
      });
    });

    await AgentOrchestrator(
      client: _SmallWindowClient(httpClient: mockHttp, window: window),
      registry: buildRegistry(database),
      chat: ChatRepository(database),
      behaviors: BehaviorRepository(database),
      settings: SettingsRepository(database),
    ).run('and now this one');

    final loopBody = bodies.firstWhere((b) => b['tools'] != null);
    return (loopBody['messages'] as List)
        .cast<Map>()
        .map((m) => m.cast<String, Object?>())
        .toList();
  }

  test('long replies no longer squeeze the replay down to a couple of turns',
      () async {
    // Sized to the case the floor exists for: each message is a large
    // fraction of the 20% history share, so a pure token budget keeps only
    // two of them, and a follow-up like "make that screen show only unread
    // ones" arrives with its referent already dropped. The window is roomy
    // enough that the request ceiling is not the binding constraint, which
    // is what lets the floor actually deliver.
    await seedHistory(6, paddingWords: 1350);

    final messages = await messagesSentWith(32000);

    expect(messages.length,
        greaterThanOrEqualTo(HistoryBudget.minimumRecentMessages + 1),
        reason: 'the floor of ${HistoryBudget.minimumRecentMessages} plus '
            'the current question');
  });

  test('the request that goes out is never oversized', () async {
    await seedHistory(10, paddingWords: 400);

    for (final window in [4096, 8192, 16000]) {
      await database.db.delete('chat_messages');
      await seedHistory(10, paddingWords: 400);

      final messages = await messagesSentWith(window);
      final tokens = MessageWindow.tokensOf(messages);

      expect(tokens, lessThan(window),
          reason: 'messages alone must leave room for system, tools and the '
              'answer at window=$window');
    }
  });

  test('the conversation always opens on a user message', () async {
    // Dropping history from the front is exactly how an assistant ends up
    // first, and the API rejects that outright.
    for (final window in [4096, 8192, 16000, 200000]) {
      await database.db.delete('chat_messages');
      await seedHistory(10, paddingWords: 400);

      final messages = await messagesSentWith(window);

      expect(messages.first['role'], 'user',
          reason: 'invalid request shape at window=$window');
    }
  });

  test('the current question survives however tight the window', () async {
    await seedHistory(10, paddingWords: 400);

    final messages = await messagesSentWith(4096);

    // The user turn is the last message, whatever else was given up.
    final last = messages.last;
    expect(last['role'], 'user');
    expect(jsonEncode(last['content']), contains('and now this one'));
  });

  test('a roomy window replays the whole fetched history', () async {
    await seedHistory(6);

    final messages = await messagesSentWith(200000);

    // 12 seeded + the current question, none of it trimmed.
    expect(messages, hasLength(13));
  });
}
