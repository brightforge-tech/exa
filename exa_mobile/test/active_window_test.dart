import 'package:exa_mobile/data/models/scheduled_job.dart';
import 'package:flutter_test/flutter_test.dart';

/// An interval job with a daily active window only runs inside it, so the
/// digest stays silent overnight. The window lives in the JSON schedule rule,
/// so no migration is involved.
void main() {
  Map<String, Object?> rule(int minutes) => {
        'type': 'interval',
        'minutes': minutes,
        'active_from': '07:00',
        'active_to': '19:00',
      };

  DateTime at(int h, int m) => DateTime(2026, 9, 14, h, m);

  test('inside the window, it is just now + interval', () {
    final next = ScheduledJob.computeNextRun(rule(10), from: at(9, 5));
    expect(next, at(9, 15));
  });

  test('a run that would land after close waits for the next morning', () {
    // 18:55 + 10 = 19:05, past 19:00 -> tomorrow 07:00.
    final next = ScheduledJob.computeNextRun(rule(10), from: at(18, 55));
    expect(next, DateTime(2026, 9, 15, 7, 0));
  });

  test('before opening, it snaps up to today 07:00', () {
    final next = ScheduledJob.computeNextRun(rule(10), from: at(3, 0));
    expect(next, at(7, 0));
  });

  test('overnight (before open) stays before open', () {
    final next = ScheduledJob.computeNextRun(rule(10), from: at(23, 30));
    expect(next, DateTime(2026, 9, 15, 7, 0));
  });

  test('no window means the plain interval, unchanged', () {
    final next = ScheduledJob.computeNextRun(
        {'type': 'interval', 'minutes': 10}, from: at(23, 30));
    expect(next, at(23, 40));
  });

  test('an overnight window (22:00-06:00) is honoured', () {
    final overnight = {
      'type': 'interval',
      'minutes': 30,
      'active_from': '22:00',
      'active_to': '06:00',
    };
    // 23:00 is inside -> 23:30.
    expect(ScheduledJob.computeNextRun(overnight, from: at(23, 0)),
        at(23, 30));
    // 12:00 is outside -> today 22:00.
    expect(ScheduledJob.computeNextRun(overnight, from: at(12, 0)),
        at(22, 0));
  });
}
