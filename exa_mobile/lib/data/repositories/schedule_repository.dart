import 'package:uuid/uuid.dart';

import '../database/app_database.dart';
import '../models/schedule_item.dart';

class ScheduleRepository {
  ScheduleRepository(this._database);

  final AppDatabase _database;
  static const _uuid = Uuid();

  Future<ScheduleItem> create({
    required String title,
    required DateTime startAt,
    DateTime? endAt,
    String? description,
    String? location,
    int leadTimeMinutes = 0,
    String source = 'local',
  }) async {
    final now = DateTime.now();
    final item = ScheduleItem(
      id: _uuid.v4(),
      title: title,
      description: description,
      location: location,
      startAt: startAt,
      endAt: endAt,
      leadTimeMinutes: leadTimeMinutes,
      source: source,
      createdAt: now,
      updatedAt: now,
    );
    await _database.db.insert('schedule_items', item.toRow());
    return item;
  }

  Future<ScheduleItem?> getById(String id) async {
    final rows = await _database.db
        .query('schedule_items', where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : ScheduleItem.fromRow(rows.first);
  }

  /// Items overlapping [from, to).
  Future<List<ScheduleItem>> listBetween(DateTime from, DateTime to) async {
    final rows = await _database.db.query(
      'schedule_items',
      where: "status != 'Canceled' AND start_at < ? AND "
          '(end_at IS NULL OR end_at >= ?) AND start_at >= ?',
      whereArgs: [
        to.toIso8601String(),
        from.toIso8601String(),
        from.subtract(const Duration(days: 1)).toIso8601String(),
      ],
      orderBy: 'start_at ASC',
    );
    return rows
        .map(ScheduleItem.fromRow)
        .where((item) =>
            item.startAt.isBefore(to) &&
            (item.endAt ?? item.startAt)
                .isAfter(from.subtract(const Duration(seconds: 1))))
        .toList();
  }

  Future<List<ScheduleItem>> listForDay(DateTime day) {
    final start = DateTime(day.year, day.month, day.day);
    return listBetween(start, start.add(const Duration(days: 1)));
  }

  Future<bool> delete(String id) async {
    final count = await _database.db
        .delete('schedule_items', where: 'id = ?', whereArgs: [id]);
    return count > 0;
  }

  /// Records (or clears) the phone-calendar mirror ref of an event.
  Future<void> setDeviceEventId(String id, String? deviceEventId) async {
    await _database.db.update(
        'schedule_items', {'device_event_id': deviceEventId},
        where: 'id = ?', whereArgs: [id]);
  }

  /// Refs ("calendarId:eventId") of every phone-calendar mirror this app
  /// created for a schedule item.
  Future<Set<String>> deviceEventRefs() async {
    final rows = await _database.db.query('schedule_items',
        columns: ['device_event_id'], where: 'device_event_id IS NOT NULL');
    return rows.map((row) => row['device_event_id'] as String).toSet();
  }

  /// Stable notification id for an event, derived from its UUID and kept in a
  /// negative range so it can never collide with reminder notification ids
  /// (which are positive) in the OS notification table.
  static int stableNotificationId(String eventId) {
    var hash = 0;
    for (final unit in eventId.codeUnits) {
      hash = (hash * 31 + unit) & 0x7fffffff;
    }
    return -(hash == 0 ? 1 : hash);
  }

  /// Insert-or-update an externally sourced event (device calendar, future
  /// API syncs), keyed by external_id. Returns true when newly inserted.
  Future<bool> upsertExternal({
    required String externalId,
    required String title,
    required DateTime startAt,
    DateTime? endAt,
    String? location,
    String? description,
    required String source,
  }) async {
    final existing = await _database.db.query('schedule_items',
        where: 'external_id = ?', whereArgs: [externalId], limit: 1);
    final now = DateTime.now();
    if (existing.isEmpty) {
      final item = ScheduleItem(
        id: _uuid.v4(),
        title: title,
        description: description,
        location: location,
        startAt: startAt,
        endAt: endAt,
        source: source,
        externalId: externalId,
        createdAt: now,
        updatedAt: now,
      );
      await _database.db.insert('schedule_items', item.toRow());
      return true;
    }
    await _database.db.update(
      'schedule_items',
      {
        'title': title,
        'description': description,
        'location': location,
        'start_at': startAt.toIso8601String(),
        'end_at': endAt?.toIso8601String(),
        'updated_at': now.toIso8601String(),
      },
      where: 'external_id = ?',
      whereArgs: [externalId],
    );
    return false;
  }

  Future<ScheduleItem?> update(
    String id, {
    String? title,
    String? description,
    String? location,
    DateTime? startAt,
    DateTime? endAt,
    int? leadTimeMinutes,
    String? status,
  }) async {
    final existing = await getById(id);
    if (existing == null) return null;
    final updated = ScheduleItem(
      id: existing.id,
      title: title ?? existing.title,
      description: description ?? existing.description,
      location: location ?? existing.location,
      startAt: startAt ?? existing.startAt,
      endAt: endAt ?? existing.endAt,
      leadTimeMinutes: leadTimeMinutes ?? existing.leadTimeMinutes,
      source: existing.source,
      externalId: existing.externalId,
      status: status ?? existing.status,
      deviceEventId: existing.deviceEventId,
      createdAt: existing.createdAt,
      updatedAt: DateTime.now(),
    );
    await _database.db.update('schedule_items', updated.toRow(),
        where: 'id = ?', whereArgs: [id]);
    return updated;
  }
}
