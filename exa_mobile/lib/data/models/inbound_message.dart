import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'inbound_media.dart';

/// Where a message came into Exa from.
///
/// The distinction matters to the agent, not just to the log: a
/// [notification] carries only what the shade showed (so a long message may
/// be truncated and media arrives as a copy Exa keeps plus a note, not as
/// model-visible bytes unless an image is asked for), an [export] is
/// verbatim history the user handed over, and [shared] is one message the
/// user deliberately pointed at.
class MessageSource {
  MessageSource._();

  static const notification = 'notification';
  static const export = 'export';
  static const shared = 'shared';
  static const manual = 'manual';

  static const all = {notification, export, shared, manual};
}

/// One message from a chat app.
///
/// Deliberately flatter than [EmailItem]: a chat message has no subject and
/// no thread, and the conversation it belongs to is the only grouping that
/// exists. `conversationId` is whatever the channel can supply as a stable
/// key — the notification's conversation key, or the chat name from an
/// export — and is never assumed to be globally unique across channels,
/// which is why every query that uses it also filters on `channel`.
class InboundMessage {
  const InboundMessage({
    required this.id,
    required this.channel,
    required this.conversationId,
    this.conversationTitle,
    this.isGroup = false,
    this.sender,
    required this.body,
    this.summary,
    this.sentAt,
    this.source = MessageSource.notification,
    this.externalId,
    this.packageName,
    this.canReply = false,
    this.digested = false,
    this.referenced = false,
    required this.createdAt,
    this.media = const [],
  });

  final String id;

  /// `whatsapp`, `signal`, `telegram`, `sms`, … (see `MessageChannels`).
  final String channel;
  final String conversationId;

  /// The chat's display name — a contact or a group.
  final String? conversationTitle;
  final bool isGroup;

  /// Who wrote it. Null when the channel could not say, which happens for
  /// one-to-one notifications where the chat name *is* the sender.
  final String? sender;

  /// The message's text. Empty for a media-only message — the schema keeps
  /// `body` NOT NULL, so "no text" is the empty string and [displayBody] is
  /// what stands in for it everywhere text is shown.
  final String body;
  final String? summary;

  /// When the message was sent, as reported by the channel. Distinct from
  /// [createdAt], which is when Exa learned about it — an export imported
  /// today is full of messages sent months ago, and a digest that sorted by
  /// the wrong one would read the history backwards.
  final DateTime? sentAt;
  final String source;

  /// Content hash used to dedupe. See the v21 migration comment for why this
  /// is not an app-supplied id.
  final String? externalId;
  final String? packageName;

  /// Whether a reply could be delivered when this was captured. Advisory
  /// only: the notification backing it may since have been dismissed, so the
  /// reply tool checks again at send time rather than trusting this.
  final bool canReply;
  final bool digested;

  /// The user handed this specific message to Exa. Independent of [digested]
  /// on purpose — see the v21 migration comment.
  final bool referenced;
  final DateTime createdAt;

  /// Photos and voice notes attached to this message, loaded in batch by
  /// the repository (`withMedia`). Empty on a plain text message — and on
  /// any object built straight from `fromRow` without the batch attach, so
  /// callers that need media go through the repository's read methods.
  final List<InboundMedia> media;

  bool get hasMedia => media.isNotEmpty;

  /// The best available "who said this": the sender when the channel named
  /// one, otherwise the conversation itself.
  String get displaySender => sender ?? conversationTitle ?? 'Unknown';

  /// The text to show or hand to the model wherever text is the only
  /// option: the message's words when it has them, otherwise its
  /// transcript, otherwise its substitute note ("Photo (image/jpeg,
  /// 1.2 MB)"). Without this a media-only message
  /// is a blank row in the inbox, an empty preview in the chat list, and
  /// invisible to every digest scope filter — which is exactly the bug the
  /// inbox and digest tasks exist to fix.
  ///
  /// A transcribed voice note reads as its words because that is what it
  /// says: the transcript sits on the media row (never on `body`, which
  /// [fingerprint] hashes), so it is looked up here rather than written
  /// anywhere else, and every existing text reader — inbox, chat list, the
  /// digest's own scope filter, `read_message_context` — picks it up with no
  /// new read path. The media reference and its note stay attached: the note
  /// is still what `media_id` on that media item answers with.
  String get displayBody {
    if (body.isNotEmpty) return body;
    for (final item in media) {
      if (item.kind == InboundMedia.kindAudio && item.isTranscribed) {
        return item.transcriptText!;
      }
    }
    return summary ?? '';
  }

  /// A stable content hash for
  /// [channel]/[conversationId]/[sender]/[sentAt]/[body or media].
  ///
  /// The timestamp is truncated to the second: WhatsApp's `MessagingStyle`
  /// entries carry millisecond precision that differs between the
  /// notification that first announced a message and the re-post that
  /// carries it alongside a newer one, so hashing the raw value would make
  /// every re-post look like a new message — the exact duplicate storm this
  /// hash exists to prevent.
  ///
  /// [mediaDigests] participates **only when the body is blank**. A
  /// text+media message is already identified by its text; adding media to
  /// its hash would let a spool re-post whose media line arrived separately
  /// (or failed validation) look like a second message. A media-only message
  /// has nothing but its bytes to be identified by, and without the digests
  /// two different voice notes from one sender in the same second would
  /// collide into one row.
  static String fingerprint({
    required String channel,
    required String conversationId,
    String? sender,
    DateTime? sentAt,
    required String body,
    List<String> mediaDigests = const [],
  }) {
    final seconds = sentAt == null
        ? ''
        : (sentAt.millisecondsSinceEpoch ~/ 1000).toString();
    final identity = [
      channel,
      conversationId,
      sender ?? '',
      seconds,
      body.trim(),
    ].join('\u0000');
    final content = body.trim().isEmpty && mediaDigests.isNotEmpty
        ? '$identity\u0000${mediaDigests.toList()..sort()}'
        : identity;
    return sha256.convert(utf8.encode(content)).toString().substring(0, 32);
  }

  Map<String, Object?> toRow() => {
        'id': id,
        'channel': channel,
        'conversation_id': conversationId,
        'conversation_title': conversationTitle,
        'is_group': isGroup ? 1 : 0,
        'sender': sender,
        'body': body,
        'summary': summary,
        'sent_at': sentAt?.toIso8601String(),
        'source': source,
        'external_id': externalId,
        'package_name': packageName,
        'can_reply': canReply ? 1 : 0,
        'digested': digested ? 1 : 0,
        'referenced': referenced ? 1 : 0,
        'created_at': createdAt.toIso8601String(),
      };

  factory InboundMessage.fromRow(Map<String, Object?> row) => InboundMessage(
        id: row['id'] as String,
        channel: row['channel'] as String,
        conversationId: row['conversation_id'] as String,
        conversationTitle: row['conversation_title'] as String?,
        isGroup: (row['is_group'] as int? ?? 0) == 1,
        sender: row['sender'] as String?,
        body: row['body'] as String,
        summary: row['summary'] as String?,
        sentAt: row['sent_at'] is String
            ? DateTime.tryParse(row['sent_at'] as String)
            : null,
        source: row['source'] as String? ?? MessageSource.notification,
        externalId: row['external_id'] as String?,
        packageName: row['package_name'] as String?,
        canReply: (row['can_reply'] as int? ?? 0) == 1,
        digested: (row['digested'] as int? ?? 0) == 1,
        referenced: (row['referenced'] as int? ?? 0) == 1,
        createdAt: DateTime.tryParse(row['created_at'] as String? ?? '') ??
            DateTime.now(),
      );

  /// A copy with different media (and optionally summary): the ingest
  /// service resolves a late media line against an existing row and hands
  /// back the same message with its media attached, without the caller
  /// rebuilding every field by hand.
  InboundMessage copyWith({List<InboundMedia>? media, String? summary}) =>
      InboundMessage(
        id: id,
        channel: channel,
        conversationId: conversationId,
        conversationTitle: conversationTitle,
        isGroup: isGroup,
        sender: sender,
        body: body,
        summary: summary ?? this.summary,
        sentAt: sentAt,
        source: source,
        externalId: externalId,
        packageName: packageName,
        canReply: canReply,
        digested: digested,
        referenced: referenced,
        createdAt: createdAt,
        media: media ?? this.media,
      );

  Map<String, Object?> toAgentJson({bool includeBody = false}) => {
    'id': id,
    'channel': channel,
    'chat': conversationTitle ?? conversationId,
    'from': displaySender,
    'is_group': isGroup,
    if (sentAt != null) 'sent_at': sentAt!.toIso8601String(),
    'captured_at': createdAt.toIso8601String(),
    'source': source,
    'digested': digested,
    'can_reply': canReply,
    'has_media': hasMedia,
    if (hasMedia) 'media': [for (final m in media) m.toAgentJson()],
    if (summary != null) 'preview': summary,
    if (includeBody) 'body': displayBody,
  };
}
