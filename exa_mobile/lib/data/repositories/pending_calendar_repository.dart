import 'package:uuid/uuid.dart';

import '../database/app_database.dart';

class PendingCalendarEvent {
  final String id;
  final String title;
  final DateTime startAt;
  final DateTime? endAt;
  final String? location;
  final String? description;

  /// Pending | Approved | Rejected | Failed
  final String status;
  final String? externalEventId;
  final String source;
  final String? errorMessage;
  final DateTime createdAt;
  final DateTime? decidedAt;

  const PendingCalendarEvent({
    required this.id,
    required this.title,
    required this.startAt,
    this.endAt,
    this.location,
    this.description,
    this.status = 'Pending',
    this.externalEventId,
    this.source = 'agent',
    this.errorMessage,
    required this.createdAt,
    this.decidedAt,
  });

  Map<String, Object?> toRow() => {
        'id': id,
        'title': title,
        'start_at': startAt.toIso8601String(),
        'end_at': endAt?.toIso8601String(),
        'location': location,
        'description': description,
        'status': status,
        'external_event_id': externalEventId,
        'source': source,
        'error_message': errorMessage,
        'created_at': createdAt.toIso8601String(),
        'decided_at': decidedAt?.toIso8601String(),
      };

  factory PendingCalendarEvent.fromRow(Map<String, Object?> row) =>
      PendingCalendarEvent(
        id: row['id'] as String,
        title: row['title'] as String,
        startAt: DateTime.tryParse(row['start_at'] as String? ?? '') ??
            DateTime.now(),
        endAt: row['end_at'] is String
            ? DateTime.tryParse(row['end_at'] as String)
            : null,
        location: row['location'] as String?,
        description: row['description'] as String?,
        status: row['status'] as String? ?? 'Pending',
        externalEventId: row['external_event_id'] as String?,
        source: row['source'] as String? ?? 'agent',
        errorMessage: row['error_message'] as String?,
        createdAt: DateTime.tryParse(row['created_at'] as String? ?? '') ??
            DateTime.now(),
        decidedAt: row['decided_at'] is String
            ? DateTime.tryParse(row['decided_at'] as String)
            : null,
      );
}

class PendingCalendarRepository {
  PendingCalendarRepository(this._database);

  final AppDatabase _database;
  static const _uuid = Uuid();

  Future<PendingCalendarEvent> queue({
    required String title,
    required DateTime startAt,
    DateTime? endAt,
    String? location,
    String? description,
    String source = 'agent',
  }) async {
    final event = PendingCalendarEvent(
      id: _uuid.v4(),
      title: title,
      startAt: startAt,
      endAt: endAt,
      location: location,
      description: description,
      source: source,
      createdAt: DateTime.now(),
    );
    await _database.db.insert('pending_calendar_events', event.toRow());
    return event;
  }

  Future<PendingCalendarEvent?> getById(String id) async {
    final rows = await _database.db.query('pending_calendar_events',
        where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty
        ? null
        : PendingCalendarEvent.fromRow(rows.first);
  }

  Future<List<PendingCalendarEvent>> listPending() async {
    final rows = await _database.db.query(
      'pending_calendar_events',
      where: "status = 'Pending'",
      orderBy: 'created_at DESC',
    );
    return rows.map(PendingCalendarEvent.fromRow).toList();
  }

  Future<int> pendingCount() async {
    final rows = await _database.db.rawQuery(
        "SELECT COUNT(*) AS c FROM pending_calendar_events "
        "WHERE status = 'Pending'");
    return (rows.first['c'] as int?) ?? 0;
  }

  Future<List<PendingCalendarEvent>> recent({int limit = 50}) async {
    final rows = await _database.db.query(
      'pending_calendar_events',
      orderBy: 'created_at DESC',
      limit: limit,
    );
    return rows.map(PendingCalendarEvent.fromRow).toList();
  }

  Future<void> markApproved(String id, {required String externalEventId}) {
    return _database.db.update(
      'pending_calendar_events',
      {
        'status': 'Approved',
        'external_event_id': externalEventId,
        'decided_at': DateTime.now().toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> markFailed(String id, String error) {
    return _database.db.update(
      'pending_calendar_events',
      {'status': 'Failed', 'error_message': error},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> markRejected(String id) {
    return _database.db.update(
      'pending_calendar_events',
      {
        'status': 'Rejected',
        'decided_at': DateTime.now().toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }
}
