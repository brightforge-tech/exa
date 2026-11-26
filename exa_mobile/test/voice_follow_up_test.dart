import 'package:exa_mobile/agent/models/tool_execution_record.dart';
import 'package:exa_mobile/data/database/app_database.dart';
import 'package:exa_mobile/data/repositories/settings_repository.dart';
import 'package:exa_mobile/features/voice/voice_session.dart';
import 'package:exa_mobile/services/voice/follow_ups.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

ToolExecutionRecord record(
  String tool, {
  Map<String, Object?> arguments = const {},
  Object? result,
  ToolExecutionStatus status = ToolExecutionStatus.success,
}) =>
    ToolExecutionRecord(
      toolCallId: 'tc_${tool.hashCode}_${arguments.hashCode}',
      toolName: tool,
      domain: 'tasks',
      arguments: arguments,
      status: status,
      startedAt: DateTime(2026, 11, 25, 9),
      completedAt: DateTime(2026, 11, 25, 9, 0, 1),
      rawResult: result,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('what a run added', () {
    test('is read from what the tools did, with their own date labels', () {
      final added = AddedItem.fromRecords([
        record('create_task', result: {
          'id': 't1',
          'title': 'Send the invoice',
          'due_at_label': 'Fri 28 Nov, 17:00',
        }),
        record('create_schedule_event', result: {
          'event': {
            'id': 'e1',
            'title': 'Offsite',
            'start_at_label': 'Thu 27 Nov, 15:00',
          },
        }),
        record('create_reminder',
            status: ToolExecutionStatus.denied,
            arguments: {'title': 'Refused'}),
        record('list_tasks', result: {'title': 'not a creation'}),
      ]);
      expect([for (final a in added) a.line], [
        'Task: Send the invoice (Fri 28 Nov, 17:00)',
        'Event: Offsite (Thu 27 Nov, 15:00)',
      ]);
    });
  });

  group('an announcement', () {
    final added = [
      const AddedItem(kind: 'task', title: 'Send the invoice', when: 'Fri'),
      const AddedItem(kind: 'event', title: 'Offsite', when: 'Thu 15:00'),
    ];
    final question = FollowUpQuestion(
      id: 'fu_1',
      title: 'Team dinner',
      question: 'Sam mentioned a team dinner but no date - when is it?',
      createdAt: DateTime(2026, 11, 25),
    );

    test('says what was added, then asks the open question', () {
      final m = FollowUpAnnouncer.compose(
          added: added, questions: [question], source: 'Chat digest');
      expect(m.title, 'Exa added a task and an event and has a question');
      expect(m.speak,
          'I added a task, Send the invoice, due Fri and an event, Offsite, '
          'for Thu 15:00. Sam mentioned a team dinner but no date - when is '
          'it?');
      expect(m.body, contains('Team dinner: Sam mentioned'));
      expect(m.prompt, contains('[fu_1]'));
      expect(m.prompt, contains('resolve_follow_up'));
    });

    test('a question alone is titled as one', () {
      final m = FollowUpAnnouncer.compose(
          added: const [], questions: [question], source: 'Email digest');
      expect(m.title, 'Exa has a question');
      expect(m.speak, question.question);
    });

    test('many additions are counted, not read out one by one', () {
      final many = [
        for (var i = 0; i < 5; i++) AddedItem(kind: 'task', title: 'T$i'),
      ];
      final m = FollowUpAnnouncer.compose(
          added: many, questions: const [], source: 'Email digest');
      expect(m.speak, startsWith('I added 5 tasks from Email digest.'));
    });
  });

  group('open questions', () {
    late AppDatabase database;
    late FollowUpStore store;

    setUp(() async {
      database = AppDatabase();
      await database.open(overridePath: inMemoryDatabasePath);
      store = FollowUpStore(SettingsRepository(database));
    });

    tearDown(() => database.close());

    FollowUpQuestion q(String id, String title, {DateTime? at}) =>
        FollowUpQuestion(
          id: id,
          title: title,
          question: 'When is $title?',
          createdAt: at ?? DateTime.now(),
        );

    test('are kept once per item, newest first, until settled', () async {
      await store.add(q('a', 'Offsite'));
      await store.add(q('b', 'Dinner'));
      final again = await store.add(q('c', 'offsite '));
      expect(again.id, 'a', reason: 'the same item is not asked twice');
      expect([for (final x in await store.list()) x.id], ['b', 'a']);

      expect(await store.resolve('a'), isTrue);
      expect(await store.resolve('a'), isFalse);
      expect([for (final x in await store.list()) x.id], ['b']);
    });

    test('a week-old question is no longer asked', () async {
      await store.add(q('old', 'Old thing',
          at: DateTime.now().subtract(const Duration(days: 8))));
      expect(await store.list(), isEmpty);
    });
  });

  group('the voice session', () {
    test('hears goodbye as the end, and anything else as a request', () {
      for (final bye in ['Goodbye', "that's all", 'Okay, stop.', 'bye Exa']) {
        expect(voiceSessionEnd.hasMatch(bye), isTrue, reason: bye);
      }
      for (final ask in ['stop the meeting reminder', 'what is next today']) {
        expect(voiceSessionEnd.hasMatch(ask), isFalse, reason: ask);
      }
    });

    test('understands a spoken yes or no', () {
      expect(spokenYesNo('Yes please'), isTrue);
      expect(spokenYesNo('go ahead'), isTrue);
      expect(spokenYesNo("no, don't"), isFalse);
      expect(spokenYesNo('cancel that'), isFalse);
      expect(spokenYesNo('maybe later'), isNull);
    });
  });
}
