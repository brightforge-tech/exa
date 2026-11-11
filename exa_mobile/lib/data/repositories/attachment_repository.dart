import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../database/app_database.dart';
import '../models/attachment_record.dart';

/// Persists chat-uploaded files the user asked Exa to keep: bytes go to an
/// app-private `attachments/` directory, metadata + extracted text to the
/// `attachments` table.
class AttachmentRepository {
  AttachmentRepository(this._database);

  final AppDatabase _database;
  static const _uuid = Uuid();

  Future<Directory> _dir() async {
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(base.path, 'attachments'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// Writes [bytes] to disk and inserts a metadata row. Returns the record.
  Future<AttachmentRecord> store({
    required String name,
    required Uint8List bytes,
    String? mimeType,
    String? kind,
    String? extractedText,
    String? summary,
    String source = 'chat',
  }) async {
    final id = _uuid.v4();
    final dir = await _dir();
    final ext = p.extension(name);
    final file = File(p.join(dir.path, '$id$ext'));
    await file.writeAsBytes(bytes, flush: true);

    final record = AttachmentRecord(
      id: id,
      name: name,
      mimeType: mimeType,
      kind: kind,
      sizeBytes: bytes.length,
      filePath: file.path,
      extractedText: extractedText,
      summary: summary,
      source: source,
      createdAt: DateTime.now(),
    );
    await _database.db.insert('attachments', record.toRow());
    return record;
  }

  Future<List<AttachmentRecord>> list() async {
    final rows = await _database.db
        .query('attachments', orderBy: 'created_at DESC');
    return rows.map(AttachmentRecord.fromRow).toList();
  }

  Future<AttachmentRecord?> getById(String id) async {
    final rows = await _database.db
        .query('attachments', where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : AttachmentRecord.fromRow(rows.first);
  }

  Future<bool> delete(String id) async {
    final record = await getById(id);
    if (record == null) return false;
    await _unlink(record.filePath);
    final count = await _database.db
        .delete('attachments', where: 'id = ?', whereArgs: [id]);
    return count > 0;
  }

  /// Removes every stored file and its row. Used by "Clear all data".
  Future<void> clearAll() async {
    final records = await list();
    for (final record in records) {
      await _unlink(record.filePath);
    }
    await _database.db.delete('attachments');
  }

  Future<void> _unlink(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } catch (_) {
      // Best effort: a missing file shouldn't block deleting the row.
    }
  }
}
