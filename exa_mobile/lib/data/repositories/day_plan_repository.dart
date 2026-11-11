import 'package:uuid/uuid.dart';

import '../database/app_database.dart';
import '../models/day_plan_entry.dart';
import '../models/reminder.dart';
import '../models/task_item.dart';

/// Reads and writes the daily planning board.
///
/// Everything here is about one local day at a time: the board is a day's
/// intent, and the queries are keyed on `plan_date` so no other day is ever
/// read to render one.
class DayPlanRepository {
  DayPlanRepository(this._database);

  final AppDatabase _database;
  static const _uuid = Uuid();

  /// The window the board draws, and the range auto-placement will use.
  /// Planning outside it is allowed (a tool can say 05:00) - the board just
  /// grows to include anything already there.
  static const int boardStartMinute = 6 * 60;
  static const int boardEndMinute = 23 * 60;

  Future<List<DayPlanEntry>> listForDay(DateTime day) async {
    final rows = await _database.db.query(
      'day_plan_entries',
      where: 'plan_date = ?',
      whereArgs: [DayPlanEntry.dateKey(day)],
      orderBy: 'start_minute ASC, created_at ASC',
    );
    return rows.map(DayPlanEntry.fromRow).toList();
  }

  Future<DayPlanEntry?> getById(String id) async {
    final rows = await _database.db
        .query('day_plan_entries', where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : DayPlanEntry.fromRow(rows.first);
  }

  /// The board with each card's live task or reminder attached.
  ///
  /// Cards whose source has since been deleted are dropped *and* removed:
  /// a plan entry for a task that no longer exists is not a card the user
  /// can act on, and leaving it would let the board disagree with the app.
  Future<List<DayPlanItem>> viewsForDay(DateTime day) async {
    final entries = await listForDay(day);
    if (entries.isEmpty) return const [];

    final taskIds = {
      for (final e in entries)
        if (e.sourceType == DayPlanEntry.sourceTask && e.sourceId != null)
          e.sourceId!,
    };
    final reminderIds = {
      for (final e in entries)
        if (e.sourceType == DayPlanEntry.sourceReminder && e.sourceId != null)
          e.sourceId!,
    };
    final tasks = {
      for (final task in await _lookup('tasks', taskIds, TaskItem.fromRow))
        task.id: task,
    };
    final reminders = {
      for (final r in await _lookup('reminders', reminderIds, Reminder.fromRow))
        r.id: r,
    };

    final items = <DayPlanItem>[];
    final orphans = <String>[];
    for (final entry in entries) {
      switch (entry.sourceType) {
        case DayPlanEntry.sourceTask:
          final task = tasks[entry.sourceId];
          if (task == null) {
            orphans.add(entry.id);
            continue;
          }
          items.add(DayPlanItem(entry: entry, task: task));
        case DayPlanEntry.sourceReminder:
          final reminder = reminders[entry.sourceId];
          if (reminder == null) {
            orphans.add(entry.id);
            continue;
          }
          items.add(DayPlanItem(entry: entry, reminder: reminder));
        default:
          items.add(DayPlanItem(entry: entry));
      }
    }
    if (orphans.isNotEmpty) await _deleteAll(orphans);
    return items;
  }

  /// Puts [title] (or the given task/reminder) on [day] at [startMinute].
  ///
  /// Planning something already on that day's board *moves* it rather than
  /// adding a second card - the unique index makes that the only possible
  /// behaviour, and it is also the one the user means when they drag a card
  /// they already placed.
  Future<DayPlanEntry> plan({
    required DateTime day,
    required String title,
    required int startMinute,
    String sourceType = DayPlanEntry.sourceNote,
    String? sourceId,
    int durationMinutes = DayPlanEntry.defaultDurationMinutes,
    String? notes,
    String createdBy = 'user',
  }) async {
    final existing = sourceId == null
        ? null
        : await _findSource(day, sourceType, sourceId);
    if (existing != null) {
      return (await move(
            existing.id,
            startMinute: startMinute,
            durationMinutes: durationMinutes,
          )) ??
          existing;
    }

    final now = DateTime.now();
    final entry = DayPlanEntry(
      id: _uuid.v4(),
      planDate: DayPlanEntry.dateKey(day),
      sourceType: sourceType,
      sourceId: sourceId,
      title: title.trim().isEmpty ? 'Untitled block' : title.trim(),
      startMinute: startMinute.clamp(0, 24 * 60 - 1),
      durationMinutes: durationMinutes.clamp(5, 12 * 60),
      notes: notes,
      createdBy: createdBy,
      createdAt: now,
      updatedAt: now,
    );
    await _database.db.insert('day_plan_entries', entry.toRow());
    return entry;
  }

  Future<DayPlanEntry?> move(
    String id, {
    int? startMinute,
    int? durationMinutes,
  }) async {
    final existing = await getById(id);
    if (existing == null) return null;
    final updated = existing.copyWith(
      startMinute: startMinute?.clamp(0, 24 * 60 - 1),
      durationMinutes: durationMinutes?.clamp(5, 12 * 60),
    );
    await _database.db.update('day_plan_entries', updated.toRow(),
        where: 'id = ?', whereArgs: [id]);
    return updated;
  }

  /// Only meaningful for ad-hoc blocks; a task-backed card takes its status
  /// from the task (see [DayPlanItem.done]), and skipping is recorded here
  /// either way.
  Future<DayPlanEntry?> setStatus(String id, String status) async {
    if (!DayPlanEntry.statuses.contains(status)) return null;
    final existing = await getById(id);
    if (existing == null) return null;
    final updated = existing.copyWith(status: status);
    await _database.db.update('day_plan_entries', updated.toRow(),
        where: 'id = ?', whereArgs: [id]);
    return updated;
  }

  Future<bool> unplan(String id) async {
    final count = await _database.db
        .delete('day_plan_entries', where: 'id = ?', whereArgs: [id]);
    return count > 0;
  }

  Future<int> clearDay(DateTime day) => _database.db.delete(
        'day_plan_entries',
        where: 'plan_date = ?',
        whereArgs: [DayPlanEntry.dateKey(day)],
      );

  /// Which of [sourceIds] already have a card on [day] - what the backlog
  /// filters itself by.
  Future<Set<String>> plannedSourceIds(DateTime day) async {
    final rows = await _database.db.query(
      'day_plan_entries',
      columns: ['source_id'],
      where: 'plan_date = ? AND source_id IS NOT NULL',
      whereArgs: [DayPlanEntry.dateKey(day)],
    );
    return {
      for (final row in rows)
        if (row['source_id'] is String) row['source_id'] as String,
    };
  }

  /// The first slot of [durationMinutes] that collides with nothing already
  /// planned, searching forward from [after].
  ///
  /// Pure and static so the placement rule is testable without a database -
  /// it is the part that decides where "plan this for me" lands.
  static int? firstFreeMinute(
    Iterable<DayPlanEntry> entries, {
    int after = boardStartMinute,
    int durationMinutes = DayPlanEntry.defaultDurationMinutes,
    int until = boardEndMinute,
  }) {
    final slot = DayPlanEntry.slotMinutes;
    // Start on the grid, never mid-slot: the board's drop targets are slots,
    // so an off-grid card would be unplaceable by hand afterwards.
    var candidate = (after <= 0 ? 0 : ((after + slot - 1) ~/ slot) * slot);
    final busy = entries.toList()
      ..sort((a, b) => a.startMinute.compareTo(b.startMinute));
    while (candidate + durationMinutes <= until) {
      final clash = busy.firstWhere(
        (e) => e.startMinute < candidate + durationMinutes &&
            candidate < e.endMinute,
        orElse: () => _noEntry,
      );
      if (identical(clash, _noEntry)) return candidate;
      // Jump to the end of what is in the way, rounded up to the grid.
      candidate = ((clash.endMinute + slot - 1) ~/ slot) * slot;
    }
    return null;
  }

  static final DayPlanEntry _noEntry = DayPlanEntry(
    id: '',
    planDate: '',
    sourceType: DayPlanEntry.sourceNote,
    title: '',
    startMinute: -1,
    createdAt: DateTime.fromMillisecondsSinceEpoch(0),
    updatedAt: DateTime.fromMillisecondsSinceEpoch(0),
  );

  Future<DayPlanEntry?> _findSource(
      DateTime day, String sourceType, String sourceId) async {
    final rows = await _database.db.query(
      'day_plan_entries',
      where: 'plan_date = ? AND source_type = ? AND source_id = ?',
      whereArgs: [DayPlanEntry.dateKey(day), sourceType, sourceId],
      limit: 1,
    );
    return rows.isEmpty ? null : DayPlanEntry.fromRow(rows.first);
  }

  Future<List<T>> _lookup<T>(
    String table,
    Set<String> ids,
    T Function(Map<String, Object?>) fromRow,
  ) async {
    if (ids.isEmpty) return const [];
    final placeholders = List.filled(ids.length, '?').join(', ');
    final rows = await _database.db.query(
      table,
      where: 'id IN ($placeholders)',
      whereArgs: ids.toList(),
    );
    return rows.map(fromRow).toList();
  }

  Future<void> _deleteAll(List<String> ids) async {
    final placeholders = List.filled(ids.length, '?').join(', ');
    await _database.db.delete('day_plan_entries',
        where: 'id IN ($placeholders)', whereArgs: ids);
  }
}
