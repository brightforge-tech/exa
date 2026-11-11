import 'package:exa_mobile/data/models/agent_datetime_label.dart';
import 'package:exa_mobile/data/models/reminder.dart';
import 'package:exa_mobile/data/models/schedule_item.dart';
import 'package:exa_mobile/data/models/task_item.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // The reported bug: a reminder stored for Thursday 2026-07-30 was announced
  // as "Tuesday, July 30". The date was right and the weekday invented, so
  // the confirmation and the Reminders screen disagreed.
  final thursday = DateTime(2026, 7, 30, 9);

  group('agentDateTimeLabel', () {
    test('names the weekday that the date actually falls on', () {
      expect(agentDateTimeLabel(thursday), 'Thursday, July 30, 2026 at 09:00');
      expect(agentDateTimeLabel(thursday), isNot(contains('Tuesday')));
    });

    test('keeps 24-hour time so afternoon is unambiguous', () {
      expect(
        agentDateTimeLabel(DateTime(2026, 7, 28, 17, 5)),
        'Tuesday, July 28, 2026 at 17:05',
      );
    });

    test('date-only variant omits the time', () {
      expect(agentDateLabel(thursday), 'Thursday, July 30, 2026');
    });
  });

  group('upcomingWeekdayMap', () {
    test('maps each upcoming weekday to its real date', () {
      // Sunday 2026-07-26, the day the bug was reported.
      final map = upcomingWeekdayMap(DateTime(2026, 7, 26, 19, 55));

      expect(map, contains('Sunday = 2026-07-26 (today)'));
      expect(map, contains('Monday = 2026-07-27 (tomorrow)'));
      // "Remind me Tuesday" must resolve here, not two days later.
      expect(map, contains('Tuesday = 2026-07-28'));
      expect(map, contains('Thursday = 2026-07-30'));
    });

    test('covers a full week so any named weekday resolves', () {
      final lines = upcomingWeekdayMap(DateTime(2026, 7, 26)).split('\n');
      expect(lines, hasLength(7));
      for (final day in const [
        'Monday',
        'Tuesday',
        'Wednesday',
        'Thursday',
        'Friday',
        'Saturday',
        'Sunday',
      ]) {
        expect(lines.where((l) => l.contains(day)), hasLength(1),
            reason: '$day should appear exactly once in a 7-day window');
      }
    });
  });

  group('agent JSON carries a label beside every schedulable ISO field', () {
    test('reminder', () {
      final json = Reminder(
        id: 'r1',
        title: 'Check Koinonia message',
        remindAt: thursday,
        createdAt: thursday,
        updatedAt: thursday,
      ).toAgentJson();

      expect(json['remind_at'], thursday.toIso8601String());
      expect(json['remind_at_label'], 'Thursday, July 30, 2026 at 09:00');
    });

    test('task due date', () {
      final json = TaskItem(
        id: 't1',
        title: 'Implement POS report',
        dueAt: thursday,
        createdAt: thursday,
        updatedAt: thursday,
      ).toAgentJson();

      expect(json['due_at_label'], 'Thursday, July 30, 2026 at 09:00');
    });

    test('schedule event start and end', () {
      final json = ScheduleItem(
        id: 'e1',
        title: 'Standup',
        startAt: thursday,
        endAt: DateTime(2026, 7, 30, 10),
        createdAt: thursday,
        updatedAt: thursday,
      ).toAgentJson();

      expect(json['start_at_label'], 'Thursday, July 30, 2026 at 09:00');
      expect(json['end_at_label'], 'Thursday, July 30, 2026 at 10:00');
    });
  });
}
