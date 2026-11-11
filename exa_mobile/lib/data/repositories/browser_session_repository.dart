import 'package:uuid/uuid.dart';

import '../database/app_database.dart';

/// Persisted browser tabs, restored when the browser screen reopens.
/// Cookies/logins are managed natively by the WebView itself.
class BrowserSessionRepository {
  BrowserSessionRepository(this._database);

  final AppDatabase _database;
  static const _uuid = Uuid();

  Future<String> addTab(String url, {String? title}) async {
    final id = _uuid.v4();
    final now = DateTime.now().toIso8601String();
    await _database.db.insert('browser_sessions', {
      'id': id,
      'title': title,
      'url': url,
      'created_at': now,
      'updated_at': now,
    });
    return id;
  }

  Future<void> updateTab(String id, {String? url, String? title}) async {
    final updates = <String, Object?>{
      'updated_at': DateTime.now().toIso8601String(),
    };
    if (url != null) updates['url'] = url;
    if (title != null) updates['title'] = title;
    await _database.db.update('browser_sessions', updates,
        where: 'id = ?', whereArgs: [id]);
  }

  Future<void> removeTab(String id) async {
    await _database.db
        .delete('browser_sessions', where: 'id = ?', whereArgs: [id]);
  }

  Future<List<Map<String, Object?>>> listTabs() {
    return _database.db
        .query('browser_sessions', orderBy: 'created_at ASC');
  }

  Future<void> clearAll() => _database.db.delete('browser_sessions');
}
