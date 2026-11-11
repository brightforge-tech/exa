import 'package:uuid/uuid.dart';

import '../../data/models/inbound_message.dart';
import 'message_channels.dart';

/// What an import produced, including what it had to assume or drop.
class ChatExportResult {
  const ChatExportResult({
    required this.messages,
    required this.chatName,
    required this.isGroup,
    required this.totalLines,
    required this.skippedLines,
    required this.truncated,
    required this.dayFirst,
    required this.dateOrderAssumed,
    this.error,
  });

  const ChatExportResult.failed(this.error)
      : messages = const [],
        chatName = '',
        isGroup = false,
        totalLines = 0,
        skippedLines = 0,
        truncated = 0,
        dayFirst = true,
        dateOrderAssumed = false;

  final List<InboundMessage> messages;
  final String chatName;
  final bool isGroup;
  final int totalLines;

  /// Lines that were not messages: the encryption notice, "X joined", and
  /// anything unparseable.
  final int skippedLines;

  /// Messages dropped because the export was longer than [maxMessages].
  final int truncated;

  /// Whether dates were read as day/month or month/day.
  final bool dayFirst;

  /// True when the file gave no evidence either way and [dayFirst] is a
  /// default rather than a deduction. Surfaced so the UI can say so instead
  /// of presenting a guess as a fact.
  final bool dateOrderAssumed;

  final String? error;

  bool get succeeded => error == null && messages.isNotEmpty;

  String get summary {
    if (error != null) return error!;
    if (messages.isEmpty) {
      return 'No messages found in that file. WhatsApp exports look like '
          '"WhatsApp Chat with <name>.txt" — open a chat, then '
          'More > Export chat.';
    }
    final parts = <String>[
      'Imported ${messages.length} message'
          '${messages.length == 1 ? '' : 's'} from $chatName',
    ];
    if (truncated > 0) {
      parts.add('$truncated older message${truncated == 1 ? '' : 's'} were '
          'skipped (only the most recent $maxMessages are imported)');
    }
    if (dateOrderAssumed) {
      parts.add('dates were read as '
          '${dayFirst ? 'day/month' : 'month/day'} — the file gave no way to '
          'tell');
    }
    return parts.join('; ');
  }

  /// Ceiling on one import. A multi-year export runs to tens of thousands of
  /// lines, which is a database write per line and a digest queue nobody
  /// wanted. The newest are kept, and the count dropped is reported rather
  /// than silently swallowed.
  static const maxMessages = 5000;
}

/// Parses a WhatsApp "Export chat" file.
///
/// This is the only sanctioned way to get chat *history*: the notification
/// listener sees nothing that arrived before it was switched on, so "scan my
/// chat with Alice" is answerable only from an export. Nothing here needs a
/// permission — the user exported the file and handed it over.
///
/// Three formats in the wild, all handled:
/// ```
/// [12/08/2026, 09:14:32] Alice: message      (iOS)
/// 12/08/2026, 09:14 - Alice: message         (Android)
/// 8/12/26, 9:14 AM - Alice: message          (US Android)
/// ```
class ChatExportImporter {
  const ChatExportImporter();

  static const _uuid = Uuid();

  /// iOS: the whole stamp in brackets.
  static final _bracketed = RegExp(
    r'^‎?\[(\d{1,2})[/.\-](\d{1,2})[/.\-](\d{2,4}),?\s+'
    r'(\d{1,2}):(\d{2})(?::(\d{2}))?\s*([APap]\.?[Mm]\.?)?\]\s*(.*)$',
  );

  /// Android: stamp, then " - ".
  static final _dashed = RegExp(
    r'^‎?(\d{1,2})[/.\-](\d{1,2})[/.\-](\d{2,4}),?\s+'
    r'(\d{1,2}):(\d{2})(?::(\d{2}))?\s*([APap]\.?[Mm]\.?)?\s+-\s+(.*)$',
  );

  /// `Sender: body`. The sender is bounded so a message whose *body* happens
  /// to contain a colon ("Re: the invoice") is not read as a sender name.
  static final _senderSplit = RegExp(r'^([^:]{1,60}):\s(.*)$', dotAll: true);

  /// Chat name from the export's own filename.
  static final _fileNamePattern = RegExp(
    r'(?:whatsapp )?chat (?:with )?(.+?)(?:\.txt|\.zip)?$',
    caseSensitive: false,
  );

  /// Reads [content] into messages.
  ///
  /// [fileName] is where the chat's name comes from — the file body never
  /// states it. An export taken with media is `_chat.txt` inside a zip and
  /// carries no name at all, which is what [fallbackName] is for.
  ChatExportResult parse(
    String content, {
    String? fileName,
    String? fallbackName,
    String channel = MessageChannels.whatsapp,
    DateTime? importedAt,
  }) {
    if (content.trim().isEmpty) {
      return const ChatExportResult.failed('That file is empty.');
    }

    final chatName = _chatNameFrom(fileName) ??
        (fallbackName?.trim().isNotEmpty == true
            ? fallbackName!.trim()
            : 'Imported chat');
    final conversationId = chatName.toLowerCase();

    final lines = content.split(RegExp(r'\r?\n'));
    final parsed = <_ParsedLine>[];
    var skipped = 0;

    for (final line in lines) {
      if (line.trim().isEmpty) continue;
      final match = _bracketed.firstMatch(line) ?? _dashed.firstMatch(line);
      if (match == null) {
        // A continuation of the previous message: WhatsApp writes multi-line
        // messages with no stamp on lines after the first. Dropping these
        // would silently truncate exactly the long messages worth reading.
        if (parsed.isNotEmpty) {
          parsed.last.body = '${parsed.last.body}\n${line.trim()}';
        } else {
          skipped++;
        }
        continue;
      }

      final remainder = match.group(8) ?? '';
      final split = _senderSplit.firstMatch(remainder);
      if (split == null) {
        // "Messages and calls are end-to-end encrypted", "Alice joined" —
        // system notices, not messages.
        skipped++;
        continue;
      }
      parsed.add(_ParsedLine(
        first: int.parse(match.group(1)!),
        second: int.parse(match.group(2)!),
        year: int.parse(match.group(3)!),
        hour: int.parse(match.group(4)!),
        minute: int.parse(match.group(5)!),
        second_: int.tryParse(match.group(6) ?? '') ?? 0,
        meridiem: match.group(7),
        sender: split.group(1)!.trim(),
        body: split.group(2)!.trim(),
      ));
    }

    if (parsed.isEmpty) {
      return ChatExportResult(
        messages: const [],
        chatName: chatName,
        isGroup: false,
        totalLines: lines.length,
        skippedLines: skipped,
        truncated: 0,
        dayFirst: true,
        dateOrderAssumed: true,
      );
    }

    final order = _resolveDateOrder(parsed);
    final senders = parsed.map((p) => p.sender).toSet();
    // You plus one other is a direct chat; anything more is a group. Read
    // from the export itself because the filename cannot say.
    final isGroup = senders.length > 2;

    var truncated = 0;
    var usable = parsed;
    if (usable.length > ChatExportResult.maxMessages) {
      truncated = usable.length - ChatExportResult.maxMessages;
      usable = usable.sublist(truncated);
    }

    final now = importedAt ?? DateTime.now();
    final messages = <InboundMessage>[];
    for (final line in usable) {
      final sentAt = line.toDateTime(dayFirst: order.dayFirst);
      messages.add(InboundMessage(
        id: _uuid.v4(),
        channel: channel,
        conversationId: conversationId,
        conversationTitle: chatName,
        isGroup: isGroup,
        sender: line.sender,
        body: line.body,
        sentAt: sentAt,
        source: MessageSource.export,
        externalId: InboundMessage.fingerprint(
          channel: channel,
          conversationId: conversationId,
          sender: line.sender,
          sentAt: sentAt,
          body: line.body,
        ),
        packageName: MessageChannels.packageByChannel[channel],
        // An export is a file, not a live notification: there is no reply
        // action attached to any of it.
        canReply: false,
        createdAt: now,
      ));
    }

    return ChatExportResult(
      messages: messages,
      chatName: chatName,
      isGroup: isGroup,
      totalLines: lines.length,
      skippedLines: skipped,
      truncated: truncated,
      dayFirst: order.dayFirst,
      dateOrderAssumed: order.assumed,
    );
  }

  /// Whether this looks like a chat export at all, so a shared file can be
  /// routed without asking the user what it is.
  bool looksLikeExport(String content, {String? fileName}) {
    final name = (fileName ?? '').toLowerCase();
    if (name.contains('whatsapp chat') || name == '_chat.txt') return true;
    // Two parseable stamped lines in the first stretch of the file: one
    // could be a coincidence in ordinary prose, two in a row is a log.
    var hits = 0;
    for (final line in content.split(RegExp(r'\r?\n')).take(40)) {
      if (_bracketed.hasMatch(line) || _dashed.hasMatch(line)) {
        if (++hits >= 2) return true;
      }
    }
    return false;
  }

  static String? _chatNameFrom(String? fileName) {
    if (fileName == null) return null;
    final base = fileName.replaceAll(RegExp(r'\.(txt|zip)$', caseSensitive: false), '');
    if (base.trim().isEmpty || base.trim() == '_chat') return null;
    final match = _fileNamePattern.firstMatch(base.trim());
    final name = match?.group(1)?.trim();
    if (name == null || name.isEmpty) return null;
    return name;
  }

  /// Decides day/month vs month/day from the file's own dates.
  ///
  /// A component over 12 can only be a day, which settles it outright. When
  /// every date in the file is ambiguous (all components ≤ 12), day-first is
  /// used — it is WhatsApp's format in most locales — and the caller is told
  /// it was assumed rather than deduced. Reading 03/04 as the wrong month is
  /// a whole conversation filed under the wrong date, so it must not be
  /// silent.
  static ({bool dayFirst, bool assumed}) _resolveDateOrder(
      List<_ParsedLine> lines) {
    for (final line in lines) {
      if (line.first > 12) return (dayFirst: true, assumed: false);
      if (line.second > 12) return (dayFirst: false, assumed: false);
    }
    return (dayFirst: true, assumed: true);
  }
}

class _ParsedLine {
  _ParsedLine({
    required this.first,
    required this.second,
    required this.year,
    required this.hour,
    required this.minute,
    required this.second_,
    required this.meridiem,
    required this.sender,
    required this.body,
  });

  final int first;
  final int second;
  final int year;
  final int hour;
  final int minute;
  final int second_;
  final String? meridiem;
  final String sender;
  String body;

  DateTime toDateTime({required bool dayFirst}) {
    final day = dayFirst ? first : second;
    final month = dayFirst ? second : first;
    // Two-digit years: WhatsApp has not existed since 1926, so the 2000s are
    // the only reading that can be right.
    final fullYear = year < 100 ? 2000 + year : year;
    var resolvedHour = hour;
    final am = meridiem?.toLowerCase().replaceAll('.', '');
    if (am == 'pm' && resolvedHour < 12) resolvedHour += 12;
    if (am == 'am' && resolvedHour == 12) resolvedHour = 0;
    // Clamped rather than thrown: a corrupt stamp should cost one message's
    // precision, not the whole import.
    return DateTime(
      fullYear,
      month.clamp(1, 12),
      day.clamp(1, 31),
      resolvedHour.clamp(0, 23),
      minute.clamp(0, 59),
      second_.clamp(0, 59),
    );
  }
}
