import 'package:uuid/uuid.dart';

import '../database/app_database.dart';
import '../models/task_item.dart';

class TaskRepository {
  TaskRepository(this._database);

  final AppDatabase _database;
  static const _uuid = Uuid();

  Future<TaskItem> create({
    required String title,
    String? description,
    String priority = 'Normal',
    String? category,
    DateTime? dueAt,
    String? recurrenceRule,
    String createdBy = 'user',
  }) async {
    final now = DateTime.now();
    final task = TaskItem(
      id: _uuid.v4(),
      title: title,
      description: description,
      priority: priority,
      category: category,
      dueAt: dueAt,
      recurrenceRule: recurrenceRule,
      source: createdBy,
      createdBy: createdBy,
      createdAt: now,
      updatedAt: now,
    );
    await _database.db.insert('tasks', task.toRow());
    return task;
  }

  Future<TaskItem?> getById(String id) async {
    final rows = await _database.db
        .query('tasks', where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : TaskItem.fromRow(rows.first);
  }

  Future<List<TaskItem>> list({
    String? status,
    String? category,
    DateTime? dueBefore,
    bool openOnly = false,
    DateTime? completedSince,
  }) async {
    final where = <String>[];
    final args = <Object?>[];
    if (completedSince != null) {
      // Stored as local ISO text by [update], so the bound is compared in
      // the same form. The status test is not redundant: reopening a task
      // leaves its old completion time in the column.
      where.add("status = 'Completed' AND completed_at IS NOT NULL "
          'AND completed_at >= ?');
      args.add(completedSince.toLocal().toIso8601String());
    }
    if (status != null) {
      where.add('status = ?');
      args.add(status);
    }
    if (openOnly) {
      where.add("status NOT IN ('Completed', 'Canceled')");
    }
    if (category != null) {
      where.add('category = ?');
      args.add(category);
    }
    if (dueBefore != null) {
      where.add('due_at IS NOT NULL AND due_at <= ?');
      args.add(dueBefore.toIso8601String());
    }
    final rows = await _database.db.query(
      'tasks',
      where: where.isEmpty ? null : where.join(' AND '),
      whereArgs: args.isEmpty ? null : args,
      // "What did I finish" reads newest first; everything else is a to-do
      // list and reads by deadline.
      orderBy: completedSince != null
          ? 'completed_at DESC'
          : 'CASE WHEN due_at IS NULL THEN 1 ELSE 0 END, due_at ASC, '
              'created_at DESC',
    );
    return rows.map(TaskItem.fromRow).toList();
  }

  Future<List<TaskItem>> listOverdue() async {
    final rows = await _database.db.query(
      'tasks',
      where: "status NOT IN ('Completed', 'Canceled') "
          'AND due_at IS NOT NULL AND due_at < ?',
      whereArgs: [DateTime.now().toIso8601String()],
      orderBy: 'due_at ASC',
    );
    return rows.map(TaskItem.fromRow).toList();
  }

  Future<TaskItem?> update(
    String id, {
    String? title,
    String? description,
    String? status,
    String? priority,
    String? category,
    DateTime? dueAt,
  }) async {
    final existing = await getById(id);
    if (existing == null) return null;
    final updated = existing.copyWith(
      title: title,
      description: description,
      status: status,
      priority: priority,
      category: category,
      dueAt: dueAt,
      // Stamped on the transition only. Marking an already completed task
      // completed again must not move it to today, now that the model reads
      // this to answer "what did I finish today?".
      completedAt: status == 'Completed' && existing.status != 'Completed'
          ? DateTime.now()
          : null,
    );
    await _database.db
        .update('tasks', updated.toRow(), where: 'id = ?', whereArgs: [id]);

    // Recurring task completed: spawn the next occurrence.
    if (status == 'Completed' &&
        existing.status != 'Completed' &&
        existing.recurrenceRule != null &&
        existing.dueAt != null) {
      await create(
        title: existing.title,
        description: existing.description,
        priority: existing.priority,
        category: existing.category,
        dueAt: _nextOccurrence(existing.dueAt!, existing.recurrenceRule!),
        recurrenceRule: existing.recurrenceRule,
        createdBy: existing.createdBy,
      );
    }
    return updated;
  }

  static DateTime _nextOccurrence(DateTime from, String rule) {
    // Schedule from the original due date, but never in the past.
    var next = from;
    final now = DateTime.now();
    do {
      next = switch (rule) {
        'daily' => next.add(const Duration(days: 1)),
        'weekly' => next.add(const Duration(days: 7)),
        'monthly' => DateTime(next.year, next.month + 1, next.day,
            next.hour, next.minute),
        _ => next.add(const Duration(days: 1)),
      };
    } while (!next.isAfter(now));
    return next;
  }

  Future<TaskItem?> complete(String id) => update(id, status: 'Completed');

  Future<bool> delete(String id) async {
    final count = await _database.db
        .delete('tasks', where: 'id = ?', whereArgs: [id]);
    return count > 0;
  }

  /// Records (or clears) the phone-calendar mirror ref of a task.
  Future<void> setDeviceEventId(String id, String? deviceEventId) async {
    await _database.db.update('tasks', {'device_event_id': deviceEventId},
        where: 'id = ?', whereArgs: [id]);
  }

  /// Refs ("calendarId:eventId") of every phone-calendar mirror this app
  /// created for a task.
  Future<Set<String>> deviceEventRefs() async {
    final rows = await _database.db.query('tasks',
        columns: ['device_event_id'], where: 'device_event_id IS NOT NULL');
    return rows.map((row) => row['device_event_id'] as String).toSet();
  }
}
