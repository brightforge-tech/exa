import 'package:exa_mobile/features/transcribe/transcript_analysis.dart';
import 'package:flutter_test/flutter_test.dart';

/// The extraction reply is free-form model output, and the transcribe screen
/// turns it into database rows. Everything here is about the reply being
/// wrong in the ways replies actually are - fenced, prefaced with prose, a
/// bare array, a made-up priority - without those becoming bad tasks or a
/// crash.
void main() {
  group('parseExtractedTasks', () {
    test('reads the documented object', () {
      final tasks = parseExtractedTasks('''
{"tasks": [
  {"title": "Send the POS report to Dave", "details": "Q3 numbers",
   "priority": "High", "due_at": "2026-08-07T09:00:00",
   "quote": "I'll get the report over to Dave by Friday"}
]}''');

      expect(tasks, hasLength(1));
      final task = tasks!.single;
      expect(task.title, 'Send the POS report to Dave');
      expect(task.details, 'Q3 numbers');
      expect(task.priority, 'High');
      expect(task.dueAt, DateTime(2026, 8, 7, 9));
      expect(task.quote, "I'll get the report over to Dave by Friday");
    });

    test('tolerates prose and a ```json fence around the object', () {
      final tasks = parseExtractedTasks('''
Sure! Here are the action items I found:

```json
{"tasks": [{"title": "Book the venue"}]}
```

Let me know if you want more detail.''');

      expect(tasks, hasLength(1));
      expect(tasks!.single.title, 'Book the venue');
    });

    test('accepts a bare array, which smaller models answer with', () {
      final tasks = parseExtractedTasks('[{"title": "Call the plumber"}]');

      expect(tasks, hasLength(1));
      expect(tasks!.single.title, 'Call the plumber');
    });

    test('an empty list means "read it, nothing to do" - not a failure', () {
      expect(parseExtractedTasks('{"tasks": []}'), isEmpty);
    });

    test('null means the reply could not be read at all', () {
      // The caller shows a different message for this than for "no tasks",
      // so the two must stay distinguishable.
      expect(parseExtractedTasks('I could not find any tasks, sorry.'), isNull);
      expect(parseExtractedTasks(''), isNull);
      expect(parseExtractedTasks('{"tasks": [ truncated mid-gener'), isNull);
    });

    test('drops entries with no usable title instead of creating blanks', () {
      final tasks = parseExtractedTasks('''
{"tasks": [
  {"title": "  ", "quote": "mumbling"},
  {"details": "no title at all"},
  "not even an object",
  {"title": "Renew the domain"}
]}''');

      expect(tasks, hasLength(1));
      expect(tasks!.single.title, 'Renew the domain');
    });

    test('normalizes a priority the schema does not define', () {
      final tasks = parseExtractedTasks(
          '{"tasks": [{"title": "A", "priority": "critical"}, '
          '{"title": "B", "priority": "Urgent"}]}');

      // 'critical' is not a TaskItem priority; storing it would show a blank
      // chip on the tasks screen and break priority filtering.
      expect(tasks![0].priority, 'Normal');
      expect(tasks[1].priority, 'Urgent');
    });

    test('keeps an unparseable due date out of the task rather than guessing',
        () {
      final tasks = parseExtractedTasks(
          '{"tasks": [{"title": "A", "due_at": "next Friday"}, '
          '{"title": "B", "due_at": null}]}');

      expect(tasks![0].dueAt, isNull);
      expect(tasks[1].dueAt, isNull);
    });

    test('truncates a title long enough to break every list that shows it', () {
      final long = 'Do the thing ' * 20;
      final tasks = parseExtractedTasks('{"tasks": [{"title": "$long"}]}');

      expect(tasks!.single.title.length, lessThanOrEqualTo(120));
      expect(tasks.single.title, endsWith('…'));
    });
  });

  group('describeFrom', () {
    test('records the transcript and the quote as provenance', () {
      final task = ExtractedTask(
        title: 'Send the report',
        details: 'Q3 numbers',
        quote: "I'll get the report over to Dave",
      );

      final description = task.describeFrom('Monday standup')!;
      expect(description, contains('Q3 numbers'));
      expect(description, contains('Monday standup'));
      expect(description, contains("I'll get the report over to Dave"));
    });

    test('stays null when there is nothing to say', () {
      expect(ExtractedTask(title: 'Send the report').describeFrom('Standup'),
          isNull);
    });
  });
}
