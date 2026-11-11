import 'dart:convert';

import 'package:exa_mobile/agent/models/evidence.dart';
import 'package:exa_mobile/agent/models/tool_execution_record.dart';
import 'package:exa_mobile/agent/services/context_budget.dart';
import 'package:flutter_test/flutter_test.dart';

/// The final response is written by a call that did not make the turn's
/// reads; the evidence pack is how it learns what they returned. A morning
/// summary over thirty open tasks came back with no names in it because the
/// pack handed that call a fragment of the list.
ToolExecutionRecord record(String tool, Object? result) => ToolExecutionRecord(
      toolCallId: 'tc_$tool',
      toolName: tool,
      domain: 'tasks',
      arguments: const {},
      status: ToolExecutionStatus.success,
      startedAt: DateTime(2026, 9, 27, 7),
      completedAt: DateTime(2026, 9, 27, 7),
      rawResult: result,
    );

Map<String, Object?> taskList(int count) => {
      'count': count,
      'tasks': [
        for (var i = 1; i <= count; i++)
          {
            'id': '0f8fad5b-d9cb-469f-a165-7086768052$i'.padRight(36, '0'),
            'title': 'Task number $i for the supplier',
            'description': 'Call the supplier about order $i and confirm '
                'the delivery window before the end of the week.',
            'status': 'Pending',
            'priority': 'Medium',
            'due_at': '2026-09-27T17:00:00.000',
            'due_at_label': 'Sunday, September 27, 2026 at 17:00',
          },
      ],
    };

EvidenceLedger morningLedger({int memories = 10, int tasks = 30}) {
  final ledger = EvidenceLedger();
  // Memories are added first, as the orchestrator adds them.
  for (var i = 0; i < memories; i++) {
    ledger.add(
      sourceType: 'memory',
      sourceId: 'mem_$i',
      content: 'The user prefers short summaries, saved note number $i.',
      updatedAt: DateTime(2026, 9, 1),
      confidence: 0.8,
    );
  }
  ledger
    ..addToolRecord(record('list_tasks', taskList(tasks)))
    ..addToolRecord(record('list_schedule', {
      'count': 1,
      'events': [
        {
          'id': 'e1',
          'title': 'Team B cleaning',
          'start_at_label': 'Sunday, September 27, 2026 at 13:00',
        },
      ],
      'reminders': [
        {'id': 'r1', 'title': 'Car service', 'remind_at_label': 'at 09:00'},
      ],
    }))
    ..addToolRecord(record('list_day_plan', {
      'date': '2026-09-27',
      'planned': const [],
      'next_free_slot': '09:00 - 12:00',
    }));
  return ledger;
}

List<Map<String, Object?>> decode(String pack) => [
      for (final item in jsonDecode(pack) as List)
        (item as Map).cast<String, Object?>(),
    ];

void main() {
  final window = ContextBudget.forWindow(45568);

  test('every task of a thirty-task list reaches the writer', () {
    final pack = morningLedger().pack(maxChars: window.evidenceChars);
    expect(pack.length, lessThanOrEqualTo(window.evidenceChars + 2000),
        reason: 'the envelope adds a little; the content must not run away');

    final items = decode(pack);
    final list = items.first['content'] as Map;
    expect(items.first['source_type'], 'tool_result');
    expect(list['tasks'], hasLength(30));
    for (var i = 1; i <= 30; i++) {
      expect(pack, contains('Task number $i for the supplier'));
    }
    expect(pack, contains('Sunday, September 27, 2026 at 17:00'));
    // The small reads are whole too, and nothing was marked as cut.
    expect(pack, contains('Team B cleaning'));
    expect(pack, contains('09:00 - 12:00'));
    expect(pack, isNot(contains(ToolResultBudget.truncatedKey)));
  });

  test('what the turn read comes before what it remembered', () {
    final items = decode(morningLedger().pack(maxChars: window.evidenceChars));
    final kinds = [for (final item in items) item['source_type']];
    expect(kinds.take(3), everyElement('tool_result'));
    expect(kinds.skip(3), everyElement('memory'));
    expect(kinds.skip(3), hasLength(10));
  });

  test('structured results are JSON, not a string of JSON', () {
    final pack = morningLedger().pack(maxChars: window.evidenceChars);
    expect(pack, isNot(contains(r'\"title\"')));
    expect(decode(pack).first['content'], isA<Map>());
  });

  test('a list too large for the pack loses items, not its shape', () {
    final pack = morningLedger(tasks: 200)
        .pack(maxChars: EvidenceLedger.defaultPackChars);
    final list = decode(pack).first['content'] as Map;
    final kept = list['tasks'] as List;
    expect(kept, isNotEmpty);
    expect(kept.length, lessThan(200));
    expect((kept.first as Map)['title'], 'Task number 1 for the supplier');
    // The writer is told how much it is not seeing.
    final cut = list[ToolResultBudget.truncatedKey] as Map;
    expect(cut['total'], 200);
    expect(cut['showing'], kept.length);
  });

  test('memories keep a share when the results want all of it', () {
    final items = decode(morningLedger(tasks: 200)
        .pack(maxChars: EvidenceLedger.defaultPackChars));
    final memories = [
      for (final item in items)
        if (item['source_type'] == 'memory') item['content'] as String,
    ];
    expect(memories, hasLength(10));
    expect(memories.first, contains('saved note number 0'));
  });

  test('the old split is gone: three reads among ten memories', () {
    // 6,000 characters over thirteen items was 461 each - one and a half
    // tasks. At the same size the list now gets most of the pack.
    final pack =
        morningLedger().pack(maxChars: EvidenceLedger.defaultPackChars);
    final list = decode(pack).first['content'] as Map;
    expect((list['tasks'] as List).length, greaterThanOrEqualTo(7));
  });

  test('a ledger of memories alone still packs', () {
    final ledger = EvidenceLedger()
      ..add(
        sourceType: 'memory',
        sourceId: 'm1',
        content: 'Prefers mornings.',
        updatedAt: DateTime(2026),
      );
    expect(decode(ledger.pack()).single['content'], 'Prefers mornings.');
    expect(EvidenceLedger().pack(), isEmpty);
  });

  group('the pack grows with the model', () {
    test('no window gets less than the old fixed size', () {
      expect(ContextBudget.forWindow(4096).evidenceChars,
          ContextBudget.evidenceFloorChars);
      expect(ContextBudget.evidenceFloorChars,
          EvidenceLedger.defaultPackChars);
    });

    test('a 45k local window holds about four times the old pack', () {
      expect(window.evidenceChars, greaterThan(20000));
      expect(window.evidenceChars, lessThan(30000));
    });

    test('a very large window is capped', () {
      expect(ContextBudget.forWindow(200000).evidenceChars,
          ContextBudget.evidenceCeilingChars);
    });
  });
}
