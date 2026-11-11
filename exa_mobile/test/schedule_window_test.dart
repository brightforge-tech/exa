import 'package:exa_mobile/features/schedule/schedule_screen.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('day window is the single calendar day', () {
    final (from, to) =
        scheduleWindow(ScheduleViewMode.day, DateTime(2026, 6, 17, 14));
    expect(from, DateTime(2026, 6, 17));
    expect(to, DateTime(2026, 6, 18));
  });

  test('week window spans Monday..next Monday and contains the day', () {
    final day = DateTime(2026, 6, 17, 9); // a Wednesday
    final (from, to) = scheduleWindow(ScheduleViewMode.week, day);
    expect(from.weekday, DateTime.monday);
    expect(to, from.add(const Duration(days: 7)));
    expect(!day.isBefore(from) && day.isBefore(to), isTrue);
  });

  test('month window spans the calendar month', () {
    final (from, to) =
        scheduleWindow(ScheduleViewMode.month, DateTime(2026, 2, 17));
    expect(from, DateTime(2026, 2, 1));
    expect(to, DateTime(2026, 3, 1));
  });
}
