import 'package:uuid/uuid.dart';

import '../database/app_database.dart';
import '../models/reminder.dart';

class ReminderRepository {
  ReminderRepository(this._database);

  final AppDatabase _database;
  static const _uuid = Uuid();

  Future<Reminder> create({
    required String title,
    required DateTime remindAt,
    String? description,
    String? recurrenceRule,
    String? taskId,
    String createdBy = 'agent',
  }) async {
    final now = DateTime.now();
    final id = _uuid.v4();
    final reminder = Reminder(
      id: id,
      taskId: taskId,
      title: title,
      description: description,
      remindAt: remindAt,
      recurrenceRule: recurrenceRule,
      notificationId: stableNotificationId(id),
      createdBy: createdBy,
      createdAt: now,
      updatedAt: now,
    );
    await _database.db.insert('reminders', reminder.toRow());
    return reminder;
  }

  Future<Reminder?> getById(String id) async {
    final rows = await _database.db
        .query('reminders', where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : Reminder.fromRow(rows.first);
  }

  Future<List<Reminder>> listAll() async {
    final rows =
        await _database.db.query('reminders', orderBy: 'remind_at ASC');
    return rows.map(Reminder.fromRow).toList();
  }

  Future<List<Reminder>> listByStatus(String status) async {
    final rows = await _database.db.query(
      'reminders',
      where: 'status = ?',
      whereArgs: [status],
      orderBy: 'remind_at ASC',
    );
    return rows.map(Reminder.fromRow).toList();
  }

  Future<Reminder?> update(
    String id, {
    String? title,
    String? description,
    DateTime? remindAt,
    String? recurrenceRule,
    String? status,
    bool clearRecurrence = false,
  }) async {
    final existing = await getById(id);
    if (existing == null) return null;
    var updated = existing.copyWith(
      title: title,
      description: description,
      remindAt: remindAt,
      recurrenceRule: recurrenceRule,
      status: status,
    );
    // copyWith can't set a field back to null, so rebuild when the caller
    // explicitly turns a repeating reminder back into a one-time one.
    if (clearRecurrence) {
      updated = Reminder(
        id: updated.id,
        taskId: updated.taskId,
        title: updated.title,
        description: updated.description,
        remindAt: updated.remindAt,
        recurrenceRule: null,
        status: updated.status,
        notificationId: updated.notificationId,
        createdBy: updated.createdBy,
        createdAt: updated.createdAt,
        updatedAt: DateTime.now(),
      );
    }
    await _database.db.update('reminders', updated.toRow(),
        where: 'id = ?', whereArgs: [id]);
    return updated;
  }

  /// Active reminders expanded into the concrete occurrences that fall within
  /// [from, to), as (reminder, fire-time) pairs sorted by time. Recurring
  /// reminders contribute one entry per matching day. The expansion window is
  /// capped so an unbounded range can't blow up. Used to show reminders on the
  /// calendar.
  Future<List<MapEntry<Reminder, DateTime>>> occurrencesBetween(
      DateTime from, DateTime to) async {
    final active = await listByStatus('Active');
    final cappedTo = to.isAfter(from.add(const Duration(days: 90)))
        ? from.add(const Duration(days: 90))
        : to;
    final out = <MapEntry<Reminder, DateTime>>[];
    for (final reminder in active) {
      if (reminder.recurrenceRule == null) {
        if (!reminder.remindAt.isBefore(from) &&
            reminder.remindAt.isBefore(cappedTo)) {
          out.add(MapEntry(reminder, reminder.remindAt));
        }
        continue;
      }
      var day = DateTime(from.year, from.month, from.day);
      while (day.isBefore(cappedTo)) {
        final at = reminder.occurrenceOn(day);
        if (at != null && !at.isBefore(from) && at.isBefore(cappedTo)) {
          out.add(MapEntry(reminder, at));
        }
        day = day.add(const Duration(days: 1));
      }
    }
    out.sort((a, b) => a.value.compareTo(b.value));
    return out;
  }

  Future<Reminder?> cancel(String id) => update(id, status: 'Canceled');

  Future<Reminder?> complete(String id) => update(id, status: 'Completed');

  Future<bool> delete(String id) async {
    final count = await _database.db
        .delete('reminders', where: 'id = ?', whereArgs: [id]);
    return count > 0;
  }

  /// Derives a stable 31-bit notification id from the reminder UUID so the
  /// same reminder always maps to the same OS notification slot.
  static int stableNotificationId(String reminderId) {
    var hash = 0;
    for (final unit in reminderId.codeUnits) {
      hash = (hash * 31 + unit) & 0x7fffffff;
    }
    return hash == 0 ? 1 : hash;
  }
}
