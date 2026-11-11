import 'dart:convert';

import 'package:uuid/uuid.dart';

import '../database/app_database.dart';

/// App-level audit trail beyond tool calls: permission toggles, behavior
/// approvals, data clears/exports, browser sharing, account changes.
class AuditRepository {
  AuditRepository(this._database);

  final AppDatabase _database;
  static const _uuid = Uuid();

  Future<void> log(
    String actor,
    String action, {
    Map<String, Object?>? detail,
  }) async {
    await _database.db.insert('audit_logs', {
      'id': _uuid.v4(),
      'actor': actor,
      'action': action,
      'detail_json': detail == null ? null : jsonEncode(detail),
      'created_at': DateTime.now().toIso8601String(),
    });
  }

  Future<List<Map<String, Object?>>> recent({int limit = 200}) {
    return _database.db.query(
      'audit_logs',
      orderBy: 'created_at DESC',
      limit: limit,
    );
  }
}
