import 'package:uuid/uuid.dart';

import '../database/app_database.dart';
import '../models/browser_context_item.dart';

/// Pages the user explicitly shared with Exa. Nothing lands here without
/// the user tapping "Send to Exa" in the browser.
class BrowserContextRepository {
  BrowserContextRepository(this._database);

  final AppDatabase _database;
  static const _uuid = Uuid();

  /// Hard cap on stored page text - keeps tool results and prompts sane.
  static const maxExtractedChars = 12000;

  Future<BrowserContextItem> add({
    required String pageTitle,
    required String pageUrl,
    required String extractedText,
    String? sessionId,
  }) async {
    final text = extractedText.length > maxExtractedChars
        ? extractedText.substring(0, maxExtractedChars)
        : extractedText;
    final item = BrowserContextItem(
      id: _uuid.v4(),
      sessionId: sessionId,
      pageTitle: pageTitle,
      pageUrl: pageUrl,
      contentSummary: _firstChars(text, 280),
      extractedText: text,
      createdAt: DateTime.now(),
    );
    await _database.db.insert('browser_context_items', item.toRow());
    return item;
  }

  Future<BrowserContextItem?> getById(String id) async {
    final rows = await _database.db.query('browser_context_items',
        where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : BrowserContextItem.fromRow(rows.first);
  }

  Future<List<BrowserContextItem>> recent({int limit = 20}) async {
    final rows = await _database.db.query(
      'browser_context_items',
      orderBy: 'created_at DESC',
      limit: limit,
    );
    return rows.map(BrowserContextItem.fromRow).toList();
  }

  /// Items shared since [since] (used by the daily review job).
  Future<List<BrowserContextItem>> sharedSince(DateTime since) async {
    final rows = await _database.db.query(
      'browser_context_items',
      where: 'created_at >= ?',
      whereArgs: [since.toIso8601String()],
      orderBy: 'created_at DESC',
    );
    return rows.map(BrowserContextItem.fromRow).toList();
  }

  Future<bool> delete(String id) async {
    final count = await _database.db.delete('browser_context_items',
        where: 'id = ?', whereArgs: [id]);
    return count > 0;
  }

  Future<void> clearAll() =>
      _database.db.delete('browser_context_items');

  static String _firstChars(String text, int count) {
    final collapsed = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    return collapsed.length <= count
        ? collapsed
        : '${collapsed.substring(0, count)}...';
  }
}
