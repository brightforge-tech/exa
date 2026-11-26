import 'package:intl/intl.dart';

/// The date-and-time line shown under a chat message.
///
/// As short as it can be while still saying which day: the time alone for
/// today, "Yesterday" for yesterday, the weekday and date within the year,
/// and the full date beyond it - so scrolling back through a long chat
/// never leaves a message without a day.
String chatTimestamp(DateTime at, {DateTime? now}) {
  final local = at.toLocal();
  final reference = (now ?? DateTime.now()).toLocal();
  final time = DateFormat('HH:mm').format(local);
  final day = DateTime(local.year, local.month, local.day);
  final today = DateTime(reference.year, reference.month, reference.day);
  final daysAgo = today.difference(day).inDays;
  if (daysAgo == 0) return 'Today, $time';
  if (daysAgo == 1) return 'Yesterday, $time';
  if (local.year == reference.year) {
    return '${DateFormat('EEE d MMM').format(local)}, $time';
  }
  return '${DateFormat('d MMM y').format(local)}, $time';
}
