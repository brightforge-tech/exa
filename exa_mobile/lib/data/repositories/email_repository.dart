import 'package:uuid/uuid.dart';

import '../database/app_database.dart';
import '../models/email_item.dart';

/// Emails the user added for Exa to digest. Until API integrations land,
/// these are pasted in manually (Settings > Emails for Exa).
class EmailRepository {
  EmailRepository(this._database);

  final AppDatabase _database;
  static const _uuid = Uuid();

  /// Body cap keeps tool results and AI prompts bounded.
  static const maxBodyChars = 16000;

  Future<EmailItem> add({
    required String subject,
    required String body,
    String? sender,
    DateTime? receivedAt,
    String source = 'manual',
    String? externalId,
  }) async {
    final trimmedBody = body.length > maxBodyChars
        ? body.substring(0, maxBodyChars)
        : body;
    final item = EmailItem(
      id: _uuid.v4(),
      subject: subject,
      sender: sender,
      receivedAt: receivedAt,
      body: trimmedBody,
      summary: _firstChars(trimmedBody, 200),
      source: source,
      createdAt: DateTime.now(),
    );
    final row = item.toRow()..['external_id'] = externalId;
    await _database.db.insert('email_items', row);
    return item;
  }

  /// Dedupe check for synced mail (keyed by Message-ID header).
  Future<bool> existsByExternalId(String externalId) async {
    final rows = await _database.db.query(
      'email_items',
      columns: ['id'],
      where: 'external_id = ?',
      whereArgs: [externalId],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  Future<EmailItem?> getById(String id) async {
    final rows = await _database.db
        .query('email_items', where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : EmailItem.fromRow(rows.first);
  }

  Future<List<EmailItem>> recent({int limit = 50}) async {
    final rows = await _database.db.query(
      'email_items',
      orderBy: 'created_at DESC',
      limit: limit,
    );
    return rows.map(EmailItem.fromRow).toList();
  }

  /// Emails still waiting to be processed, oldest first so a backlog is
  /// worked through in the order it arrived rather than newest-first (which
  /// would leave the oldest mail permanently at the back of the queue).
  ///
  /// [limit] bounds a batch; omit it only where the whole set is genuinely
  /// needed (counting, the deterministic summary).
  Future<List<EmailItem>> undigested({int? limit}) async {
    final rows = await _database.db.query(
      'email_items',
      where: 'digested = 0',
      orderBy: 'created_at ASC',
      limit: limit,
    );
    return rows.map(EmailItem.fromRow).toList();
  }

  /// How many are waiting, without loading them.
  Future<int> countUndigested() async {
    final rows = await _database.db
        .rawQuery('SELECT COUNT(*) AS n FROM email_items WHERE digested = 0');
    return (rows.first['n'] as int?) ?? 0;
  }

  Future<List<EmailItem>> addedSince(DateTime since) async {
    final rows = await _database.db.query(
      'email_items',
      where: 'created_at >= ?',
      whereArgs: [since.toIso8601String()],
      orderBy: 'created_at DESC',
    );
    return rows.map(EmailItem.fromRow).toList();
  }

  Future<void> markDigested(String id, {bool digested = true}) async {
    await _database.db.update(
      'email_items',
      {'digested': digested ? 1 : 0},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<bool> delete(String id) async {
    final count = await _database.db
        .delete('email_items', where: 'id = ?', whereArgs: [id]);
    return count > 0;
  }

  Future<void> clearAll() => _database.db.delete('email_items');

  static String _firstChars(String text, int count) {
    final collapsed = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    return collapsed.length <= count
        ? collapsed
        : '${collapsed.substring(0, count)}...';
  }
}
