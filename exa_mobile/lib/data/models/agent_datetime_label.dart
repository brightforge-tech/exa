import 'package:intl/intl.dart';

/// Renders a datetime the way the agent should repeat it back to the user.
///
/// Every scheduling field the model reads is also emitted as one of these
/// labels next to its ISO value. The ISO string is what tools consume; the
/// label is what the model quotes.
///
/// This exists because smaller local models cannot reliably answer "what
/// weekday is 2026-07-30?". Given only the ISO date they guess, and a wrong
/// guess is worse than no weekday at all: a reminder correctly stored for
/// Thursday gets announced as "set for Tuesday", so the confirmation and the
/// Reminders screen disagree and the user cannot tell which one is real.
/// Handing the model the weekday turns a computation into a copy.
String agentDateTimeLabel(DateTime value) =>
    DateFormat('EEEE, MMMM d, y').format(value) +
    DateFormat(" 'at' HH:mm").format(value);

/// Date-only variant, for fields with no meaningful time component.
String agentDateLabel(DateTime value) =>
    DateFormat('EEEE, MMMM d, y').format(value);

/// The next [days] calendar days as `Weekday = ISO date` lines.
///
/// Resolving "remind me Tuesday" into a date is the same weekday arithmetic
/// in the other direction, and just as unreliable. Listing the mapping turns
/// that into a lookup too, which is the difference between a reminder landing
/// on the day the user asked for and landing two days late.
String upcomingWeekdayMap(DateTime from, {int days = 7}) {
  final buffer = StringBuffer();
  for (var offset = 0; offset < days; offset++) {
    final day = DateTime(from.year, from.month, from.day + offset);
    final name = DateFormat('EEEE').format(day);
    final iso = DateFormat('yyyy-MM-dd').format(day);
    final suffix = switch (offset) {
      0 => ' (today)',
      1 => ' (tomorrow)',
      _ => '',
    };
    buffer.writeln('  $name = $iso$suffix');
  }
  return buffer.toString().trimRight();
}
