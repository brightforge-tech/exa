import 'package:uuid/uuid.dart';

import '../database/app_database.dart';
import '../models/transcript.dart';

class TranscriptRepository {
  TranscriptRepository(this._database);

  final AppDatabase _database;
  static const _uuid = Uuid();

  Future<Transcript> create({
    required String title,
    required String content,
    String? summary,
  }) async {
    final now = DateTime.now();
    final transcript = Transcript(
      id: _uuid.v4(),
      title: title,
      content: content,
      summary: summary,
      createdAt: now,
      updatedAt: now,
    );
    await _database.db.insert('transcripts', transcript.toRow());
    return transcript;
  }

  /// Updates the supplied fields and always bumps `updated_at` so the list
  /// stays ordered by most-recently-touched.
  Future<void> update(
    String id, {
    String? title,
    String? content,
    String? summary,
  }) async {
    final values = <String, Object?>{
      'updated_at': DateTime.now().toIso8601String(),
    };
    if (title != null) values['title'] = title;
    if (content != null) values['content'] = content;
    if (summary != null) values['summary'] = summary;
    await _database.db
        .update('transcripts', values, where: 'id = ?', whereArgs: [id]);
  }

  Future<List<Transcript>> list() async {
    final rows = await _database.db.query(
      'transcripts',
      orderBy: 'updated_at DESC',
    );
    return rows.map(Transcript.fromRow).toList();
  }

  Future<Transcript?> get(String id) async {
    final rows = await _database.db.query(
      'transcripts',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    return rows.isEmpty ? null : Transcript.fromRow(rows.first);
  }

  Future<void> delete(String id) =>
      _database.db.delete('transcripts', where: 'id = ?', whereArgs: [id]);
}
