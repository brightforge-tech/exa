import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../database/app_database.dart';
import '../models/inbound_media.dart';

/// Rows and files for message media — the photos and voice notes captured
/// next to the notification spool.
///
/// This repository is the **only** owner of media-file deletion. Kotlin
/// creates sidecar files and unlinks nothing but its own `.part` scratch;
/// every real unlink goes through [_unlinkIfLastReference] here. The reason
/// is concrete: the spool is trimmed by size on a schedule that knows nothing
/// about the database, and a trim (or prune, or a retry after a crash) that
/// deleted a file an `inbound_media` row still points at would silently
/// destroy a photo behind a live message. One owner, a checked reference
/// count, and a sweep for the residue.
class InboundMediaRepository {
  InboundMediaRepository(this._database);

  final AppDatabase _database;
  static const _uuid = Uuid();

  /// The 32-hex sidecar name the Kotlin capture writes and Dart validates.
  /// Pinned here (and in the Kotlin file and the reader) — the three must
  /// agree exactly, or every media line validates as corrupt.
  static final sidecarPattern = RegExp(r'^[0-9a-f]{32}\.[a-z0-9]{1,5}$');

  /// Inserts a media row for [messageId], or returns null when the same
  /// content hash is already attached to that message (an idempotent
  /// re-post), or when the file is missing or its size disagrees with
  /// [sizeBytes].
  ///
  /// The file is checked **before** the insert: a row whose bytes are
  /// already gone is worse than no row, because every later reader trusts
  /// the row. Dedupe is left to the UNIQUE(message_id, content_hash) index
  /// for the same racing-drainers reason as `external_id` in v21.
  Future<InboundMedia?> add({
    required String messageId,
    required String kind,
    String? mimeType,
    required String filePath,
    String? fileName,
    int? sizeBytes,
    required String contentHash,
    String? transcriptText,
    DateTime? createdAt,
  }) async {
    final file = File(filePath);
    if (!await file.exists()) return null;
    if (sizeBytes != null && sizeBytes > 0) {
      final actual = await file.length();
      if (actual != sizeBytes) return null;
    }
    final media = InboundMedia(
      id: _uuid.v4(),
      messageId: messageId,
      kind: kind,
      mimeType: mimeType,
      filePath: filePath,
      fileName: fileName ?? p.basename(filePath),
      sizeBytes: sizeBytes,
      contentHash: contentHash,
      transcriptText: transcriptText,
      createdAt: createdAt ?? DateTime.now(),
    );
    final rowId = await _database.db.insert(
      'inbound_media',
      media.toRow(),
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
    // sqflite reports 0 for an insert the conflict clause dropped: the
    // identical hash is already on this message, which is the normal state
    // of a MessagingStyle re-post.
    return rowId == 0 ? null : media;
  }

  Future<InboundMedia?> get(String id) async {
    final rows = await _database.db.query(
      'inbound_media',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    return rows.isEmpty ? null : InboundMedia.fromRow(rows.first);
  }

  Future<List<InboundMedia>> forMessage(String messageId) async {
    final rows = await _database.db.query(
      'inbound_media',
      where: 'message_id = ?',
      whereArgs: [messageId],
      orderBy: 'created_at ASC',
    );
    return rows.map(InboundMedia.fromRow).toList();
  }

  /// Media for many messages in one query, grouped by id. Batch rather than
  /// per-message: every list read (the inbox page, a digest scope,
  /// `read_chat`) fetches up to a page of rows, and an N+1 on top of that is
  /// paid on every unattended run.
  Future<Map<String, List<InboundMedia>>> forMessages(
    List<String> messageIds,
  ) async {
    if (messageIds.isEmpty) return const {};
    final grouped = <String, List<InboundMedia>>{};
    // Chunked IN() lists stay under SQLite's variable limit even for a big
    // page; the chunk size is an implementation detail, not a policy.
    for (var i = 0; i < messageIds.length; i += 400) {
      final chunk = messageIds.sublist(
        i,
        i + 400 < messageIds.length ? i + 400 : messageIds.length,
      );
      final placeholders = List.filled(chunk.length, '?').join(',');
      final rows = await _database.db.rawQuery(
        'SELECT * FROM inbound_media WHERE message_id IN ($placeholders) '
        'ORDER BY created_at ASC',
        chunk,
      );
      for (final row in rows) {
        final media = InboundMedia.fromRow(row);
        grouped.putIfAbsent(media.messageId, () => []).add(media);
      }
    }
    return grouped;
  }

  /// The next work for the voice-note transcription pass, oldest first.
  ///
  /// Everything the pass must not re-derive from the bytes it is about to
  /// read is answered here, in one indexed query:
  ///
  /// * Only audio: images go to vision-capable providers as images, and the
  ///   transcription endpoint would only reject them (or worse, answer).
  /// * Only `none` and `failed`: the other statuses are terminal — a row
  ///   with words is done, one heard as silence stays silence no matter how
  ///   often it is asked, and `unsupported` says this audio can never be
  ///   transcribed here. Offering any of them again would be the pass
  ///   ignoring its own conclusions.
  /// * Only under [maxAttempts]: a row the endpoint failed on that many
  ///   times is parked, not dropped — it stays on disk with its note, and
  ///   the job report says so. The cap is per row, so a briefly flaky
  ///   endpoint gets its retries while a permanently dead one stops costing
  ///   a call per drain.
  /// * Not a hash already transcribed: the sha256 is the dedupe key for the
  ///   whole database. The same voice note forwarded between chats, or
  ///   re-posted by MessagingStyle, is one question to the provider — the
  ///   second row finds the first row's words through [recordTranscription]'s
  ///   mirroring and never gets asked.
  ///
  /// Oldest first is fairness, not just determinism: under a cap, a backlog
  /// must drain in capture order or the newest voice note is transcribed
  /// while the oldest sits out — and re-offers must present a stable order,
  /// or a row starves at the tail of a changing sort. [limit] is the pass's
  /// per-run slice; `id` breaks same-timestamp ties so two runs agree.
  Future<List<InboundMedia>> pendingTranscriptions({
    int limit = 3,
    int maxAttempts = 3,
  }) async {
    final rows = await _database.db.rawQuery(
      'SELECT * FROM inbound_media '
      "WHERE kind = ? AND transcript_status IN (?, ?) "
      'AND transcript_attempts < ? '
      'AND NOT EXISTS ('
      '  SELECT 1 FROM inbound_media AS done '
      '  WHERE done.content_hash = inbound_media.content_hash '
      "  AND done.transcript_status = ?"
      ') '
      'ORDER BY created_at ASC, id ASC '
      'LIMIT ?',
      [
        InboundMedia.kindAudio,
        InboundMedia.statusNone,
        InboundMedia.statusFailed,
        maxAttempts,
        InboundMedia.statusDone,
        limit,
      ],
    );
    return rows.map(InboundMedia.fromRow).toList();
  }

  /// Records one transcription attempt on [mediaId], and for
  /// [InboundMedia.statusDone] extends the answer to every row sharing the
  /// row's content hash.
  ///
  /// The attempt counter moves whatever the outcome, because the attempt
  /// was really spent — a timeout costs exactly as much of the endpoint's
  /// (and the user's) attention as an answer. The status decides the rest:
  /// only `done` gets `transcript_text` and `transcribed_at`, so the text
  /// column can never hold something the status column contradicts, and a
  /// later reader never has to guess whether null means "silence" or
  /// "haven't looked yet" — [InboundMedia.transcriptStatus] answers that.
  ///
  /// The mirroring is where "one voice note, one provider call for the life
  /// of the database" actually lives: rows are per message, but transcription
  /// is per bytes, so the words a hash earned are written to every row with
  /// that hash. Mirrored rows do not get an attempt credited — they were
  /// never asked, which is exactly what the pass wants true after this call.
  ///
  /// One transaction: a crash between the two writes would leave half the
  /// rows claiming words they never received, and the other half inviting a
  /// second call the mirroring existed to prevent.
  Future<void> recordTranscription(
    String mediaId, {
    String? text,
    required String status,
  }) async {
    final media = await get(mediaId);
    if (media == null) return;
    final done = status == InboundMedia.statusDone;
    await _database.db.transaction((txn) async {
      await txn.rawUpdate(
        'UPDATE inbound_media SET '
        'transcript_text = ?, transcript_status = ?, '
        '${done ? 'transcribed_at = ?, ' : ''}'
        'transcript_attempts = transcript_attempts + 1 '
        'WHERE id = ?',
        done
            ? [text, status, DateTime.now().toIso8601String(), mediaId]
            : [null, status, mediaId],
      );
      if (!done) return;
      await txn.rawUpdate(
        'UPDATE inbound_media SET transcript_text = ?, transcript_status = ? '
        'WHERE content_hash = ? AND id != ?',
        [text, status, media.contentHash, mediaId],
      );
    });
  }

  /// Removes the media rows (and any now-unreferenced files) of one message.
  Future<int> deleteForMessage(String messageId) =>
      deleteForMessages([messageId]);

  /// Removes many messages' media rows in [deleteForMessages] fashion.
  Future<int> deleteForMessages(List<String> messageIds) async {
    if (messageIds.isEmpty) return 0;
    var removed = 0;
    for (var i = 0; i < messageIds.length; i += 400) {
      final chunk = messageIds.sublist(
        i,
        i + 400 < messageIds.length ? i + 400 : messageIds.length,
      );
      final placeholders = List.filled(chunk.length, '?').join(',');
      final rows = await _database.db.rawQuery(
        'SELECT id, file_path FROM inbound_media '
        'WHERE message_id IN ($placeholders)',
        chunk,
      );
      if (rows.isEmpty) continue;
      await _database.db.delete(
        'inbound_media',
        where: 'message_id IN ($placeholders)',
        whereArgs: chunk,
      );
      for (final row in rows) {
        await _unlinkIfLastReference(row['file_path'] as String);
      }
      removed += rows.length;
    }
    return removed;
  }

  /// Prune entry point: media of messages the message repository has
  /// already deleted (or is deleting in the same drain), so a pruned message
  /// never leaves its photo behind and a kept one never loses it. The id
  /// list, not a raw age, is deliberate — the retention rule ("keep
  /// referenced, keep undigested") lives once, in the message repository.
  Future<int> pruneForMessages(List<String> messageIds) =>
      deleteForMessages(messageIds);

  Future<bool> delete(String id) async {
    final media = await get(id);
    if (media == null) return false;
    final count = await _database.db.delete(
      'inbound_media',
      where: 'id = ?',
      whereArgs: [id],
    );
    if (count > 0) await _unlinkIfLastReference(media.filePath);
    return count > 0;
  }

  Future<void> clearAll() async {
    final rows = await _database.db.query(
      'inbound_media',
      columns: ['file_path'],
    );
    await _database.db.delete('inbound_media');
    for (final row in rows) {
      // Every row is gone, so every file this listed is unreferenced.
      await _unlink(row['file_path'] as String);
    }
  }

  /// Deletes files in [mediaDir] that no row references, that no still-live
  /// spool or in-flight `.draining` line names via [referencedNames], and
  /// that are older than [maxAge].
  ///
  /// This is the safety net for what the line-based lifecycle can strand: a
  /// spool trimmed before its media line was ever drained, a drain that died
  /// between copy and insert. The age floor is what makes it safe to run
  /// after every drain — a sidecar written a second ago is not an orphan, it
  /// is mid-flight, and deleting it would race the capture that is about to
  /// reference it.
  Future<int> sweepOrphans({
    required String mediaDir,
    required Set<String> referencedNames,
    Duration maxAge = const Duration(hours: 24),
    DateTime? now,
  }) async {
    final cutoff = (now ?? DateTime.now()).subtract(maxAge);
    var removed = 0;
    final List<File> files;
    try {
      final dir = Directory(mediaDir);
      if (!await dir.exists()) return 0;
      files = dir.listSync().whereType<File>().toList();
    } catch (_) {
      return 0;
    }
    for (final file in files) {
      final name = p.basename(file.path);
      try {
        // Only ever touch files this pipeline created — anything else in the
        // directory is somebody else's, however old.
        if (!sidecarPattern.hasMatch(name)) continue;
        // A name a pending spool or `.draining` line still carries: the row
        // for it has not been written yet, and will be.
        if (referencedNames.contains(name)) continue;
        final stat = await file.stat();
        if (stat.modified.isAfter(cutoff)) continue;
        final referenced = await _database.db.rawQuery(
          'SELECT 1 FROM inbound_media WHERE file_path = ? LIMIT 1',
          [file.path],
        );
        if (referenced.isNotEmpty) continue;
        await file.delete();
        removed++;
      } catch (_) {
        // Best effort: a file that resists one sweep gets another next run.
      }
    }
    return removed;
  }

  /// Unlinks [path] only when no remaining row still names it. The count
  /// runs against the committed database after the caller's row delete, and
  /// deliberately errs toward NOT deleting: two messages can share one
  /// sidecar (the same photo forwarded between chats hashes the same), and
  /// an accidental unlink of a shared photo is unrecoverable while a
  /// stranded file is harmless until the next sweep.
  Future<void> _unlinkIfLastReference(String path) async {
    try {
      final remaining = await _database.db.rawQuery(
        'SELECT 1 FROM inbound_media WHERE file_path = ? LIMIT 1',
        [path],
      );
      if (remaining.isNotEmpty) return;
    } catch (_) {
      // Could not count: keep the file. Same asymmetry as above.
      return;
    }
    await _unlink(path);
  }

  Future<void> _unlink(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } catch (_) {
      // Best effort: a missing or locked file never blocks the row delete.
    }
  }

  /// sha256 of a file as 32 lowercase hex chars — the same digest the Kotlin
  /// capture records, so Dart can verify the bytes on disk are the bytes
  /// that were copied before it trusts a media line.
  static Future<String?> sha256Of(String path) async {
    try {
      final digest = await sha256.bind(File(path).openRead()).first;
      // Truncated to the 32 hex chars the whole contract - Kotlin capture,
      // spool parser, DB rows - agrees on. Returning the full 64 here would
      // make every honest sidecar look corrupt.
      return digest.toString().substring(0, 32);
    } catch (_) {
      return null;
    }
  }
}
