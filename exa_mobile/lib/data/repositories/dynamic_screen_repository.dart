import 'package:uuid/uuid.dart';

import '../database/app_database.dart';
import '../models/dynamic_screen.dart';

class DynamicScreenRepository {
  DynamicScreenRepository(this._database);

  final AppDatabase _database;
  static const _uuid = Uuid();

  Future<DynamicScreen> upsert({
    required String screenKey,
    required String title,
    String? description,
    required Map<String, Object?> schema,
    String createdBy = 'agent',
  }) async {
    final existing = await getByKey(screenKey);
    final now = DateTime.now();
    final screen = DynamicScreen(
      id: existing?.id ?? _uuid.v4(),
      screenKey: screenKey,
      title: title,
      description: description,
      schema: schema,
      createdBy: createdBy,
      isSaved: existing?.isSaved ?? false,
      createdAt: existing?.createdAt ?? now,
      updatedAt: now,
    );
    if (existing == null) {
      await _database.db.insert('dynamic_screens', screen.toRow());
    } else {
      await _database.db.update('dynamic_screens', screen.toRow(),
          where: 'screen_key = ?', whereArgs: [screenKey]);
    }
    return screen;
  }

  Future<DynamicScreen?> getByKey(String screenKey) async {
    final rows = await _database.db.query('dynamic_screens',
        where: 'screen_key = ?', whereArgs: [screenKey], limit: 1);
    return rows.isEmpty ? null : DynamicScreen.fromRow(rows.first);
  }

  Future<List<DynamicScreen>> listAll() async {
    final rows = await _database.db
        .query('dynamic_screens', orderBy: 'updated_at DESC');
    return rows.map(DynamicScreen.fromRow).toList();
  }

  Future<void> markSaved(String screenKey, {bool saved = true}) async {
    await _database.db.update(
      'dynamic_screens',
      {
        'is_saved': saved ? 1 : 0,
        'updated_at': DateTime.now().toIso8601String()
      },
      where: 'screen_key = ?',
      whereArgs: [screenKey],
    );
  }

  Future<bool> delete(String screenKey) async {
    final count = await _database.db.delete('dynamic_screens',
        where: 'screen_key = ?', whereArgs: [screenKey]);
    return count > 0;
  }
}
