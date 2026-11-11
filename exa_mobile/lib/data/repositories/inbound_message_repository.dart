import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../database/app_database.dart';
import '../models/inbound_message.dart';
import 'inbound_media_repository.dart';

/// One conversation, with the counts the UI and the agent both need.
class ConversationSummary {
  const ConversationSummary({
    required this.channel,
    required this.conversationId,
    required this.title,
    required this.isGroup,
    required this.messageCount,
    required this.undigestedCount,
    required this.canReply,
    this.hasMedia = false,
    this.lastMessageAt,
    this.lastSender,
    this.lastPreview,
  });

  final String channel;
  final String conversationId;
  final String title;
  final bool isGroup;
  final int messageCount;
  final int undigestedCount;

  /// True when *any* message in the chat was captured with a live reply
  /// action. Per-chat rather than per-message because that is the question
  /// the model is actually asking ("can I answer this chat?").
  final bool canReply;

  /// True when at least one message in the chat has stored media. The model
  /// reads this to decide whether a media-bearing `media_id` read of
  /// `read_message_context` is worth making; without it a photo-only chat
  /// looks empty from the list.
  final bool hasMedia;
  final DateTime? lastMessageAt;
  final String? lastSender;
  final String? lastPreview;

  Map<String, Object?> toAgentJson() => {
    'channel': channel,
    'chat': title,
    'conversation_id': conversationId,
    'is_group': isGroup,
    'messages': messageCount,
    'undigested': undigestedCount,
    'can_reply': canReply,
    'has_media': hasMedia,
    if (lastMessageAt != null)
      'last_message_at': lastMessageAt!.toIso8601String(),
    if (lastSender != null) 'last_from': lastSender,
    if (lastPreview != null) 'last_preview': lastPreview,
  };
}

/// Chat messages Exa has been given: captured from notifications, imported
/// from a chat export, or shared one at a time by the user.
class InboundMessageRepository {
  /// [media] is optional so unit tests and older call sites keep compiling,
  /// but everywhere it is wired (providers, the ingest service) the media
  /// repository travels with the messages: a message row and its media rows
  /// have exactly one lifecycle, and two constructors each half-knowing it
  /// is how photos get stranded or destroyed.
  InboundMessageRepository(this._database, {InboundMediaRepository? media})
    : mediaRepository = media;

  final AppDatabase _database;
  final InboundMediaRepository? mediaRepository;
  static const _uuid = Uuid();

  /// Body cap, matching [EmailRepository.maxBodyChars]. A single chat message
  /// never approaches this; a mis-parsed export line could.
  static const maxBodyChars = 16000;

  /// Retention for captured chat traffic. A notification listener produces
  /// far more rows than a mail sync — every group message the user was going
  /// to ignore anyway — and none of it is a record the user would miss.
  static const retention = Duration(days: 30);

  /// Inserts [message], or returns null when an identical one is already
  /// stored.
  ///
  /// Dedupe is left to the partial unique index on `external_id` rather than
  /// a select-then-insert: the app, the overlay and two background isolates
  /// all drain the same notification spool, so a check in Dart would be a
  /// race that lets duplicates through under exactly the concurrency this
  /// app treats as normal.
  Future<InboundMessage?> add(InboundMessage message) async {
    final body = message.body.length > maxBodyChars
        ? message.body.substring(0, maxBodyChars)
        : message.body;
    final stored = InboundMessage(
      id: message.id.isEmpty ? _uuid.v4() : message.id,
      channel: message.channel,
      conversationId: message.conversationId,
      conversationTitle: message.conversationTitle,
      isGroup: message.isGroup,
      sender: message.sender,
      body: body,
      summary: message.summary ?? _firstChars(body, 160),
      sentAt: message.sentAt,
      source: message.source,
      externalId: message.externalId,
      packageName: message.packageName,
      canReply: message.canReply,
      digested: message.digested,
      referenced: message.referenced,
      createdAt: message.createdAt,
      // Carried through so the ingest service can persist the media rows
      // for a message it just stored — the message row itself never holds
      // media (that is inbound_media's job), but the object handed back to
      // the caller should still describe the message it saved.
      media: message.media,
    );
    final rowId = await _database.db.insert(
      'inbound_messages',
      stored.toRow(),
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
    // sqflite reports 0 for an insert the conflict clause dropped.
    return rowId == 0 ? null : stored;
  }

  /// Inserts many, returning only those that were new. Used by every
  /// ingestion path, all of which re-present messages Exa has already seen.
  Future<List<InboundMessage>> addAll(Iterable<InboundMessage> messages) async {
    final added = <InboundMessage>[];
    for (final message in messages) {
      final stored = await add(message);
      if (stored != null) added.add(stored);
    }
    return added;
  }

  /// Attaches media to [messages] with one batch query. Every read the
  /// inbox, the agent tools and the digest perform goes through this —
  /// without it `has_media` would be false on the very messages that carry
  /// the photo, and the note substitution would never fire.
  Future<List<InboundMessage>> withMedia(List<InboundMessage> messages) async {
    final mediaRepository = this.mediaRepository;
    if (mediaRepository == null || messages.isEmpty) return messages;
    final grouped = await mediaRepository.forMessages([
      for (final m in messages) m.id,
    ]);
    if (grouped.isEmpty) return messages;
    return [
      for (final m in messages)
        if (grouped.containsKey(m.id)) m.copyWith(media: grouped[m.id]) else m,
    ];
  }

  Future<InboundMessage?> getById(String id) async {
    final rows = await _database.db.query(
      'inbound_messages',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return (await withMedia([InboundMessage.fromRow(rows.first)])).first;
  }

  /// Newest first, for "what came in?".
  Future<List<InboundMessage>> recent({int limit = 50, String? channel}) async {
    final rows = await _database.db.query(
      'inbound_messages',
      where: channel == null ? null : 'channel = ?',
      whereArgs: channel == null ? null : [channel],
      orderBy: 'created_at DESC',
      limit: limit,
    );
    return withMedia(rows.map(InboundMessage.fromRow).toList());
  }

  /// Oldest first, so a backlog is worked through in the order it arrived
  /// rather than leaving the oldest permanently at the back of the queue —
  /// the same reason [EmailRepository.undigested] does it.
  Future<List<InboundMessage>> undigested({int? limit, String? channel}) async {
    final rows = await _database.db.query(
      'inbound_messages',
      where: channel == null ? 'digested = 0' : 'digested = 0 AND channel = ?',
      whereArgs: channel == null ? null : [channel],
      orderBy: 'created_at ASC',
      limit: limit,
    );
    return withMedia(rows.map(InboundMessage.fromRow).toList());
  }

  Future<int> countUndigested({String? channel}) async {
    final rows = await _database.db.rawQuery(
      'SELECT COUNT(*) AS n FROM inbound_messages WHERE digested = 0'
      '${channel == null ? '' : ' AND channel = ?'}',
      channel == null ? null : [channel],
    );
    return (rows.first['n'] as int?) ?? 0;
  }

  /// Every message in one chat, oldest first — the shape a conversation has
  /// to be read in to make sense of it.
  Future<List<InboundMessage>> inConversation({
    required String channel,
    required String conversationId,
    int limit = 50,
  }) async {
    final rows = await _database.db.query(
      'inbound_messages',
      where: 'channel = ? AND conversation_id = ?',
      whereArgs: [channel, conversationId],
      // sent_at is null for a pasted message; created_at always exists, so
      // it decides the order in that case rather than the row dropping to
      // the top or the bottom depending on SQLite's null collation.
      orderBy: 'COALESCE(sent_at, created_at) ASC',
      limit: limit,
    );
    return withMedia(rows.map(InboundMessage.fromRow).toList());
  }

  /// Resolves a spool **media line** to the message it describes.
  ///
  /// Media rides its own JSONL line because the copy happens off the
  /// notification callback thread, and that line can be drained after its
  /// text row is already stored — so "which message is this photo for?"
  /// can only be answered by identity: the same channel, conversation,
  /// sender and second as the text line carried. Matching on content hash
  /// is impossible across the two lines (the text hash excludes media and
  /// vice versa), which is also why a photo and an unrelated text from one
  /// sender in the same second can merge — the accepted cost, stated in the
  /// plan. Only notification-sourced rows qualify: an imported export row
  /// from "the same second" is a coincidence, not the same message.
  Future<InboundMessage?> findByIdentity({
    required String channel,
    required String conversationId,
    String? sender,
    DateTime? sentAt,
    String source = MessageSource.notification,
  }) async {
    // Without a timestamp identity there is nothing to match on, and a
    // blind "latest message in this chat" would happily attach a photo to
    // an unrelated older message.
    if (sentAt == null) return null;
    // sent_at is stored at whole-second resolution by the spool reader, and
    // the search window tolerates the capture-to-capture jitter between a
    // notification's first post and its re-posts.
    final rows = await _database.db.rawQuery(
      '''
      SELECT * FROM inbound_messages
      WHERE channel = ? AND conversation_id = ? AND source = ?
        AND COALESCE(sender, '') = ?
        AND sent_at IS NOT NULL
        AND sent_at BETWEEN ? AND ?
      ORDER BY created_at DESC
      LIMIT 1
      ''',
      [
        channel,
        conversationId,
        source,
        sender ?? '',
        // The media line repeats the text line's sent_at exactly, but a
        // re-post can carry it a second apart; the ±2 s window is for that
        // jitter, not a licence to attach a photo to any message nearby.
        // Compared as ISO strings — the format [toRow] writes, fixed-width
        // so BETWEEN is chronological — because CAST(strftime('%s')) would
        // read the string as UTC while it records *local* wall time, and
        // every identity match would drift by the device's timezone offset.
        sentAt.subtract(const Duration(seconds: 2)).toIso8601String(),
        sentAt.add(const Duration(seconds: 2)).toIso8601String(),
      ],
    );
    if (rows.isEmpty) return null;
    return (await withMedia([InboundMessage.fromRow(rows.first)])).first;
  }

  /// Resolves a chat by name, case-insensitively. Returns every candidate:
  /// "Alex" matching both "Alex" and "Alex (work)" is an ambiguity the
  /// caller has to surface, not one this should pick a winner for.
  Future<List<ConversationSummary>> findConversations(String name) async {
    final all = await conversations();
    final needle = name.trim().toLowerCase();
    if (needle.isEmpty) return const [];
    final exact = all
        .where((c) => c.title.toLowerCase() == needle)
        .toList();
    if (exact.isNotEmpty) return exact;
    return all
        .where((c) => c.title.toLowerCase().contains(needle))
        .toList();
  }

  /// Chats, most recently active first.
  Future<List<ConversationSummary>> conversations({
    int limit = 40,
    String? channel,
  }) async {
    // Aggregated in SQL rather than over fetched rows: counting in Dart
    // would report the row limit as the message count, which is the same
    // trap `stat` components avoid on dynamic screens.
    final rows = await _database.db.rawQuery('''
      SELECT channel, conversation_id,
             MAX(COALESCE(conversation_title, conversation_id)) AS title,
             MAX(is_group) AS is_group,
             COUNT(*) AS message_count,
             SUM(CASE WHEN digested = 0 THEN 1 ELSE 0 END) AS undigested,
             MAX(can_reply) AS can_reply,
             MAX(EXISTS (
               SELECT 1 FROM inbound_media im
               WHERE im.message_id = inbound_messages.id
             )) AS has_media,
             MAX(COALESCE(sent_at, created_at)) AS last_at
      FROM inbound_messages
      ${channel == null ? '' : 'WHERE channel = ?'}
      GROUP BY channel, conversation_id
      ORDER BY last_at DESC
      LIMIT ?
    ''', [?channel, limit]);

    final summaries = <ConversationSummary>[];
    for (final row in rows) {
      final chatChannel = row['channel'] as String;
      final conversationId = row['conversation_id'] as String;
      final last = await _database.db.query(
        'inbound_messages',
        columns: ['sender', 'conversation_title', 'summary'],
        where: 'channel = ? AND conversation_id = ?',
        whereArgs: [chatChannel, conversationId],
        orderBy: 'COALESCE(sent_at, created_at) DESC',
        limit: 1,
      );
      summaries.add(
        ConversationSummary(
          channel: chatChannel,
          conversationId: conversationId,
          title: row['title'] as String? ?? conversationId,
          isGroup: (row['is_group'] as int? ?? 0) == 1,
          messageCount: (row['message_count'] as int?) ?? 0,
          undigestedCount: (row['undigested'] as int?) ?? 0,
          canReply: (row['can_reply'] as int? ?? 0) == 1,
          hasMedia: (row['has_media'] as int? ?? 0) == 1,
          lastMessageAt: row['last_at'] is String
              ? DateTime.tryParse(row['last_at'] as String)
              : null,
          lastSender: last.isEmpty
              ? null
              : (last.first['sender'] as String?) ??
                    (last.first['conversation_title'] as String?),
          lastPreview: last.isEmpty ? null : last.first['summary'] as String?,
        ),
      );
    }
    return summaries;
  }

  /// Case-insensitive substring search over bodies, senders and chat names.
  Future<List<InboundMessage>> search(String query, {int limit = 20}) async {
    final needle = '%${query.toLowerCase()}%';
    final rows = await _database.db.rawQuery('''
      SELECT * FROM inbound_messages
      WHERE LOWER(body) LIKE ?
         OR LOWER(COALESCE(sender, '')) LIKE ?
         OR LOWER(COALESCE(conversation_title, '')) LIKE ?
      ORDER BY COALESCE(sent_at, created_at) DESC
      LIMIT ?
    ''', [needle, needle, needle, limit]);
    return rows.map(InboundMessage.fromRow).toList();
  }

  Future<List<InboundMessage>> addedSince(DateTime since) async {
    final rows = await _database.db.query(
      'inbound_messages',
      where: 'created_at >= ?',
      whereArgs: [since.toIso8601String()],
      orderBy: 'created_at DESC',
    );
    return rows.map(InboundMessage.fromRow).toList();
  }

  Future<void> markDigested(String id, {bool digested = true}) async {
    await _database.db.update(
      'inbound_messages',
      {'digested': digested ? 1 : 0},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Marks a whole chat digested. The user saying "I've dealt with that
  /// group" is one action, not forty.
  Future<int> markConversationDigested({
    required String channel,
    required String conversationId,
  }) =>
      _database.db.update(
        'inbound_messages',
        {'digested': 1},
        where: 'channel = ? AND conversation_id = ? AND digested = 0',
        whereArgs: [channel, conversationId],
      );

  /// Writes a media substitute note into a row that has no text of its own.
  ///
  /// Only ever called with a note for a message whose `summary` is empty:
  /// a text row's summary is its body preview, and overwriting that with
  /// "Photo (image/jpeg...)" would trade real information for a label.
  Future<void> updateSummary(String id, String summary) async {
    await _database.db.update(
      'inbound_messages',
      {'summary': summary},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> markReferenced(String id, {bool referenced = true}) async {
    await _database.db.update(
      'inbound_messages',
      {'referenced': referenced ? 1 : 0},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Records that a reply was delivered, as a message from the user.
  ///
  /// Stored rather than fired and forgotten so the chat reads as a
  /// conversation next time Exa looks at it — without this, a digest sees
  /// the incoming question again with no sign it was ever answered, and
  /// answers it twice.
  Future<InboundMessage?> recordOutgoing({
    required String channel,
    required String conversationId,
    String? conversationTitle,
    required String body,
    String? packageName,
  }) {
    final now = DateTime.now();
    return add(InboundMessage(
      id: _uuid.v4(),
      channel: channel,
      conversationId: conversationId,
      conversationTitle: conversationTitle,
      sender: 'You',
      body: body,
      sentAt: now,
      source: MessageSource.manual,
      externalId: InboundMessage.fingerprint(
        channel: channel,
        conversationId: conversationId,
        sender: 'You',
        sentAt: now,
        body: body,
      ),
      packageName: packageName,
      // Nothing to digest about the user's own words.
      digested: true,
      createdAt: now,
    ));
  }

  /// Removes one message and, through the media repository, its media rows
  /// and any files that end up unreferenced.
  ///
  /// The media rows are deleted explicitly rather than leaning on the
  /// ON DELETE CASCADE: the cascade removes rows, but a cascade has no way to
  /// ask "is this sidecar still referenced by the *other* message sharing
  /// it?" — only the media repository can, and only if it is the one doing
  /// the deleting.
  Future<bool> delete(String id) async {
    await mediaRepository?.deleteForMessage(id);
    final count = await _database.db.delete(
      'inbound_messages',
      where: 'id = ?',
      whereArgs: [id],
    );
    return count > 0;
  }

  /// Drops captured traffic older than [retention] and **returns the ids it
  /// deleted**, not just a count — because every one of those rows may name
  /// a media sidecar, and "delete the photo too" is only safe when it is
  /// asked message by message through the media repository.
  ///
  /// Referenced messages are kept regardless: the user pointed at those, and
  /// a follow-up question weeks later is exactly why they were kept in the
  /// first place. Undigested ones are kept too — expiring the queue would
  /// mean a phone left in a drawer silently loses the backlog it was meant
  /// to work through.
  Future<List<String>> prune({Duration? olderThan, DateTime? now}) async {
    final cutoff = (now ?? DateTime.now()).subtract(olderThan ?? retention);
    final doomed = await _database.db.query(
      'inbound_messages',
      columns: ['id'],
      where: 'created_at < ? AND referenced = 0 AND digested = 1',
      whereArgs: [cutoff.toIso8601String()],
    );
    final ids = [for (final row in doomed) row['id'] as String];
    if (ids.isEmpty) return ids;
    // Media first, and through the media repository: the FK cascade would
    // happily remove the media rows, but a cascade cannot unlink files, and
    // with the rows gone nothing remembers which files to look at.
    await mediaRepository?.deleteForMessages(ids);
    for (var i = 0; i < ids.length; i += 400) {
      final chunk = ids.sublist(i, i + 400 < ids.length ? i + 400 : ids.length);
      final placeholders = List.filled(chunk.length, '?').join(',');
      await _database.db.delete(
        'inbound_messages',
        where: 'id IN ($placeholders)',
        whereArgs: chunk,
      );
    }
    return ids;
  }

  Future<void> clearAll() async {
    // Media first: clearAll on the messages would otherwise leave every
    // sidecar file orphaned until a sweep that may never come.
    await mediaRepository?.clearAll();
    await _database.db.delete('inbound_messages');
  }

  static String _firstChars(String text, int count) {
    final collapsed = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    return collapsed.length <= count
        ? collapsed
        : '${collapsed.substring(0, count)}...';
  }
}
