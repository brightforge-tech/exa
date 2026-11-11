import 'package:uuid/uuid.dart';

import '../../data/models/email_item.dart';
import '../../data/models/inbound_message.dart';
import '../../data/repositories/email_repository.dart';
import '../../data/repositories/inbound_message_repository.dart';
import 'chat_export_importer.dart';
import 'message_channels.dart';
import 'message_ingest_service.dart';
import 'messaging_bridge.dart';

/// What Exa did with something the user shared into it.
///
/// Every case carries [promptPrefill]: the point of sharing a message to an
/// assistant is to ask about it, so the outcome is not "stored" but "stored,
/// and here is the question half-written".
sealed class SharedIntakeOutcome {
  const SharedIntakeOutcome();

  /// One line for the user, stating plainly what was kept.
  String get banner;

  /// Seeds the assistant's input box.
  String get promptPrefill;
}

class ChatHistoryImported extends SharedIntakeOutcome {
  const ChatHistoryImported({required this.result, required this.stored});

  final ChatExportResult result;
  final int stored;

  @override
  String get banner => result.summary;

  @override
  String get promptPrefill =>
      'Summarize my chat with ${result.chatName} — what was agreed, what is '
      'still open, and anything I need to do.';
}

class EmailReferenced extends SharedIntakeOutcome {
  const EmailReferenced(this.email);

  final EmailItem email;

  @override
  String get banner => 'Saved the email "${email.subject}".';

  @override
  String get promptPrefill =>
      'Read the email "${email.subject}" and tell me what it needs from me.';
}

class MessageReferenced extends SharedIntakeOutcome {
  const MessageReferenced(this.messages);

  final List<InboundMessage> messages;

  InboundMessage get first => messages.first;

  @override
  String get banner => messages.length == 1
      ? 'Saved a message from ${first.displaySender}.'
      : 'Saved ${messages.length} messages from ${first.conversationTitle ?? first.displaySender}.';

  @override
  String get promptPrefill => messages.length == 1
      ? 'About this message from ${first.displaySender}: '
      : 'About these messages from '
          '${first.conversationTitle ?? first.displaySender}: ';
}

/// Nothing was stored — the text did not belong in any inbox, so it goes
/// straight to the assistant as context for the next question.
class PlainTextShared extends SharedIntakeOutcome {
  const PlainTextShared(this.text, {this.subject});

  final String text;
  final String? subject;

  @override
  String get banner => 'Added to your next message.';

  @override
  String get promptPrefill {
    final quoted = text.trim();
    return subject == null ? '$quoted\n\n' : '$subject\n\n$quoted\n\n';
  }
}

class SharedIntakeFailed extends SharedIntakeOutcome {
  const SharedIntakeFailed(this.reason);

  final String reason;

  @override
  String get banner => reason;

  @override
  String get promptPrefill => '';
}

/// Routes whatever the user shared into Exa to the right inbox.
///
/// This is the "reference a message" path, and it is the only one that works
/// for *both* chat and mail with no special access at all: WhatsApp's forward
/// sheet, a mail client's share, and the OS text-selection menu all arrive
/// here as an ordinary intent.
///
/// The routing is deliberately explicit rather than heuristic where it can
/// be, because filing something in the wrong inbox is worse than filing it
/// nowhere: a chat export becomes chat history, a share carrying a subject
/// line is an email, a share from a known chat app is a chat message, and
/// anything else is handed to the assistant without being stored.
class SharedIntakeService {
  SharedIntakeService({
    required this.messages,
    required this.emails,
    required this.ingest,
    this.importer = const ChatExportImporter(),
  });

  final InboundMessageRepository messages;
  final EmailRepository emails;
  final MessageIngestService ingest;
  final ChatExportImporter importer;

  static const _uuid = Uuid();

  /// Conversation used for a message shared without its chat.
  ///
  /// A forward carries the text and nothing else — no sender, no timestamp,
  /// no chat. Inventing a conversation for it would put a message under a
  /// name that may be wrong; this bucket says what actually happened.
  static const detachedConversationId = 'shared';
  static const detachedConversationTitle = 'Shared with Exa';

  Future<SharedIntakeOutcome> accept(SharedItem item) async {
    // 1. A file that parses as a chat log is history, whatever it is called.
    if (item.hasFile) {
      final content = item.fileText!;
      if (!importer.looksLikeExport(content, fileName: item.fileName)) {
        return const SharedIntakeFailed(
          'That file does not look like a WhatsApp chat export. Open the '
          'chat in WhatsApp, then More > Export chat > Without media, and '
          'share the result to Exa.',
        );
      }
      final imported = await ingest.importExport(
        content,
        fileName: item.fileName,
        fallbackName: item.text,
      );
      if (!imported.result.succeeded) {
        return SharedIntakeFailed(imported.result.summary);
      }
      return ChatHistoryImported(
        result: imported.result,
        stored: imported.stored,
      );
    }

    final text = item.text?.trim() ?? '';
    if (text.isEmpty) {
      return const SharedIntakeFailed('There was nothing in that share.');
    }

    // 2. Several chat messages selected and shared at once come through in
    // the export's own line format, which is enough to recover who said what
    // and when — so they are stored as the messages they are.
    if (importer.looksLikeExport(text)) {
      final parsed = importer.parse(text, fallbackName: _senderHint(text));
      if (parsed.succeeded) {
        final stored = await messages.addAll([
          for (final message in parsed.messages)
            _asReferenced(message),
        ]);
        if (stored.isNotEmpty) return MessageReferenced(stored);
      }
    }

    // 3. A subject line means a mail client shared it. Nothing else puts one
    // there.
    if ((item.subject ?? '').trim().isNotEmpty) {
      final email = await emails.add(
        subject: item.subject!.trim(),
        body: text,
        source: 'shared',
      );
      return EmailReferenced(email);
    }

    // 4. From a chat app Exa knows, with no structure to recover.
    final channel = item.sourcePackage == null
        ? null
        : MessageChannels.channelForPackage(item.sourcePackage!);
    if (channel != null) {
      final now = DateTime.now();
      final stored = await messages.add(InboundMessage(
        id: _uuid.v4(),
        channel: channel,
        conversationId: detachedConversationId,
        conversationTitle: detachedConversationTitle,
        sender: MessageChannels.displayName(channel),
        body: text,
        sentAt: now,
        source: MessageSource.shared,
        externalId: InboundMessage.fingerprint(
          channel: channel,
          conversationId: detachedConversationId,
          sender: MessageChannels.displayName(channel),
          sentAt: now,
          body: text,
        ),
        packageName: item.sourcePackage,
        referenced: true,
        // Referenced, not queued: the user is about to ask about this, so it
        // is not work waiting in a backlog.
        digested: true,
        createdAt: now,
      ));
      if (stored != null) return MessageReferenced([stored]);
    }

    // 5. Selected text from anywhere else. Storing it would put arbitrary
    // prose in a chat inbox; it belongs in the question being asked.
    return PlainTextShared(text, subject: item.subject);
  }

  InboundMessage _asReferenced(InboundMessage message) => InboundMessage(
        id: message.id,
        channel: message.channel,
        conversationId: message.conversationId,
        conversationTitle: message.conversationTitle,
        isGroup: message.isGroup,
        sender: message.sender,
        body: message.body,
        sentAt: message.sentAt,
        source: MessageSource.shared,
        externalId: message.externalId,
        packageName: message.packageName,
        referenced: true,
        digested: true,
        createdAt: message.createdAt,
      );

  /// First sender name in a shared block, used to name the chat it came from.
  static String? _senderHint(String text) {
    for (final line in text.split(RegExp(r'\r?\n')).take(5)) {
      final match = RegExp(r'\]\s*([^:]{1,60}):\s').firstMatch(line) ??
          RegExp(r'\s-\s([^:]{1,60}):\s').firstMatch(line);
      final name = match?.group(1)?.trim();
      if (name != null && name.isNotEmpty) return name;
    }
    return null;
  }
}
