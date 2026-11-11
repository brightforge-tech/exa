import '../../agent/models/creation_provenance.dart';
import '../database/app_database.dart';

/// One agent-created record, with the chain that explains it.
class ProvenancedRecord {
  const ProvenancedRecord({
    required this.table,
    required this.id,
    required this.title,
    required this.provenance,
    required this.createdAt,
    this.undoneAt,
  });

  final String table;
  final String id;
  final String title;
  final CreationProvenance provenance;
  final DateTime createdAt;
  final DateTime? undoneAt;

  bool get isUndone => undoneAt != null;

  String get kind => switch (table) {
        'tasks' => 'task',
        'reminders' => 'reminder',
        'schedule_items' => 'event',
        'day_plan_entries' => 'planned block',
        'scheduled_jobs' => 'job',
        'dynamic_screens' => 'screen',
        _ => table,
      };
}

/// Stamps and reads creation provenance across the tables the agent writes.
///
/// Kept as one small service rather than a field on every model: the
/// provenance is written by the one place that knows the security context
/// (the tool registry), and every repository staying unchanged is what
/// makes this safe to add to a working app.
class ProvenanceRepository {
  ProvenanceRepository(this._database);

  final AppDatabase _database;

  /// Which table each creating tool writes into, and the column holding a
  /// human label for the UI.
  static const Map<String, (String table, String titleColumn)> tablesByTool = {
    'create_task': ('tasks', 'title'),
    'create_reminder': ('reminders', 'title'),
    'create_schedule_event': ('schedule_items', 'title'),
    'plan_day_item': ('day_plan_entries', 'title'),
    'create_scheduled_job': ('scheduled_jobs', 'name'),
    'create_dynamic_screen': ('dynamic_screens', 'title'),
    'save_screen': ('dynamic_screens', 'title'),
  };

  static const undoableTables = {'tasks', 'reminders', 'schedule_items'};

  /// Records why [recordId] exists. Best-effort by design: provenance is
  /// bookkeeping, and failing to write it must never fail the action the
  /// user asked for.
  Future<void> stamp({
    required String toolName,
    required String recordId,
    required CreationProvenance provenance,
  }) async {
    final target = tablesByTool[toolName];
    if (target == null) return;
    try {
      await _database.db.update(
        target.$1,
        provenance.toRow(),
        where: 'id = ?',
        whereArgs: [recordId],
      );
    } catch (_) {
      // Column missing on a database that has not migrated yet, or the row
      // was deleted in between. Neither is worth failing the turn over.
    }
  }

  /// Everything one run created, newest first — the list behind "this job
  /// made these five things".
  Future<List<ProvenancedRecord>> byRun(String runId) =>
      _query('origin_run_id = ?', [runId]);

  /// Everything a job has ever created.
  Future<List<ProvenancedRecord>> byJob(String jobId, {int limit = 100}) =>
      _query('origin_job_id = ?', [jobId], limit: limit);

  /// Recent agent-created records across every table, for the audit view.
  Future<List<ProvenancedRecord>> recentAgentCreated({int limit = 50}) =>
      _query("origin_type IS NOT NULL AND origin_type != 'user'", const [],
          limit: limit);

  Future<List<ProvenancedRecord>> _query(
    String where,
    List<Object?> args, {
    int limit = 200,
  }) async {
    final records = <ProvenancedRecord>[];
    for (final entry in {
      'tasks': 'title',
      'reminders': 'title',
      'schedule_items': 'title',
      'scheduled_jobs': 'name',
      'dynamic_screens': 'title',
    }.entries) {
      try {
        final rows = await _database.db.query(
          entry.key,
          where: where,
          whereArgs: args,
          orderBy: 'created_at DESC',
          limit: limit,
        );
        for (final row in rows) {
          records.add(ProvenancedRecord(
            table: entry.key,
            id: row['id'] as String,
            title: row[entry.value] as String? ?? '(untitled)',
            provenance: CreationProvenance.fromRow(row),
            createdAt:
                DateTime.tryParse(row['created_at'] as String? ?? '') ??
                    DateTime.now(),
            undoneAt: DateTime.tryParse(row['undone_at'] as String? ?? ''),
          ));
        }
      } catch (_) {
        // Table or column absent (older database); skip it.
      }
    }
    records.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return records.take(limit).toList();
  }

  /// Undoes everything one run created. Reversible records are deleted;
  /// anything else is marked undone so it stops being presented as current
  /// without destroying the audit trail.
  ///
  /// Returns how many records were reversed.
  Future<int> undoRun(String runId) async {
    final records = await byRun(runId);
    var undone = 0;
    final now = DateTime.now().toIso8601String();
    for (final record in records) {
      if (record.isUndone) continue;
      try {
        if (undoableTables.contains(record.table)) {
          await _database.db.delete(record.table,
              where: 'id = ?', whereArgs: [record.id]);
        } else {
          await _database.db.update(record.table, {'undone_at': now},
              where: 'id = ?', whereArgs: [record.id]);
        }
        undone++;
      } catch (_) {
        // A foreign key still pointing at it, or the row is already gone.
      }
    }
    return undone;
  }

  /// Undoes one record.
  Future<bool> undoRecord(String table, String id) async {
    try {
      if (undoableTables.contains(table)) {
        final deleted = await _database.db
            .delete(table, where: 'id = ?', whereArgs: [id]);
        return deleted > 0;
      }
      final updated = await _database.db.update(
          table, {'undone_at': DateTime.now().toIso8601String()},
          where: 'id = ?', whereArgs: [id]);
      return updated > 0;
    } catch (_) {
      return false;
    }
  }
}
