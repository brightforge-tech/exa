import 'dart:convert';

import 'package:uuid/uuid.dart';

import '../database/app_database.dart';

enum DiagnosticSeverity { info, warning, error }

/// One recorded operational event: a denied tool call, a job that could not
/// find a model, a behavior rule that failed to load.
class DiagnosticEvent {
  const DiagnosticEvent({
    required this.id,
    required this.code,
    required this.severity,
    required this.message,
    required this.context,
    required this.createdAt,
  });

  final String id;

  /// Stable machine code, e.g. `JOB_MODEL_SELECTION_FAILED`. Screens group
  /// by this, so it must not carry variable detail - that goes in [context].
  final String code;
  final DiagnosticSeverity severity;
  final String message;
  final Map<String, Object?> context;
  final DateTime createdAt;

  factory DiagnosticEvent.fromRow(Map<String, Object?> row) {
    Map<String, Object?> context = const {};
    try {
      final decoded = jsonDecode(row['context_json'] as String? ?? '{}');
      if (decoded is Map) context = decoded.cast<String, Object?>();
    } catch (_) {}
    return DiagnosticEvent(
      id: row['id'] as String,
      code: row['code'] as String,
      severity: DiagnosticSeverity.values.firstWhere(
        (s) => s.name == row['severity'],
        orElse: () => DiagnosticSeverity.info,
      ),
      message: row['message'] as String? ?? '',
      context: context,
      createdAt: DateTime.tryParse(row['created_at'] as String? ?? '') ??
          DateTime.now(),
    );
  }
}

/// Durable operational log for things that are deliberately swallowed at the
/// call site.
///
/// Background work must never crash because a model, a network, or a
/// permission is unavailable - but "never crash" easily becomes "never
/// visible". Every `catch (_)` that hides a real configuration problem
/// records here instead, so the Reliability screen can answer "why did
/// nothing happen last night?".
///
/// Recording never throws and never blocks the caller's own error handling.
class DiagnosticsRepository {
  DiagnosticsRepository(this._database);

  final AppDatabase _database;
  static const _uuid = Uuid();

  /// Kept small - this is a rolling window, not an audit trail.
  static const maxEvents = 300;

  Future<void> record({
    required String code,
    required String message,
    DiagnosticSeverity severity = DiagnosticSeverity.info,
    Map<String, Object?> context = const {},
    Object? error,
  }) async {
    try {
      await _database.db.insert('diagnostic_events', {
        'id': _uuid.v4(),
        'code': code,
        'severity': severity.name,
        'message': message,
        'context_json': jsonEncode({
          ...context,
          if (error != null) 'error': '$error',
        }),
        'created_at': DateTime.now().toIso8601String(),
      });
      await _trim();
    } catch (_) {
      // Diagnostics are best-effort by definition: failing to record a
      // problem must not become a second problem.
    }
  }

  Future<void> warn({
    required String code,
    required String message,
    Map<String, Object?> context = const {},
    Object? error,
  }) =>
      record(
        code: code,
        message: message,
        severity: DiagnosticSeverity.warning,
        context: context,
        error: error,
      );

  Future<List<DiagnosticEvent>> recent({int limit = 100}) async {
    try {
      final rows = await _database.db.query('diagnostic_events',
          orderBy: 'created_at DESC', limit: limit);
      return rows.map(DiagnosticEvent.fromRow).toList();
    } catch (_) {
      return const [];
    }
  }

  /// Counts per code over the given window, for the health summary.
  Future<Map<String, int>> countsSince(DateTime since) async {
    try {
      final rows = await _database.db.rawQuery(
        'SELECT code, COUNT(*) AS n FROM diagnostic_events '
        'WHERE created_at >= ? GROUP BY code ORDER BY n DESC',
        [since.toIso8601String()],
      );
      return {
        for (final row in rows) row['code'] as String: row['n'] as int,
      };
    } catch (_) {
      return const {};
    }
  }

  Future<void> clear() async {
    try {
      await _database.db.delete('diagnostic_events');
    } catch (_) {}
  }

  Future<void> _trim() async {
    final rows = await _database.db.rawQuery(
        'SELECT created_at FROM diagnostic_events '
        'ORDER BY created_at DESC LIMIT 1 OFFSET ?',
        [maxEvents]);
    if (rows.isEmpty) return;
    await _database.db.delete('diagnostic_events',
        where: 'created_at < ?', whereArgs: [rows.first['created_at']]);
  }
}
