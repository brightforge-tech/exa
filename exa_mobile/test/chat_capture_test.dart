import 'dart:convert';
import 'dart:io';

import 'package:exa_mobile/agent/behaviors/behavior_triggers.dart';
import 'package:exa_mobile/agent/security/capability_policy.dart';
import 'package:exa_mobile/agent/security/content_trust.dart';
import 'package:exa_mobile/agent/security/write_scope.dart';
import 'package:exa_mobile/data/database/app_database.dart';
import 'package:exa_mobile/data/models/agent_behavior.dart';
import 'package:exa_mobile/data/models/inbound_message.dart';
import 'package:exa_mobile/data/repositories/email_repository.dart';
import 'package:exa_mobile/data/repositories/inbound_message_repository.dart';
import 'package:exa_mobile/data/repositories/settings_repository.dart';
import 'package:exa_mobile/services/messaging/chat_export_importer.dart';
import 'package:exa_mobile/services/messaging/message_channels.dart';
import 'package:exa_mobile/services/messaging/message_ingest_service.dart';
import 'package:exa_mobile/services/messaging/message_spool_reader.dart';
import 'package:exa_mobile/services/messaging/messaging_bridge.dart';
import 'package:exa_mobile/services/messaging/shared_intake_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  // ------------------------------------------------------ the spool wire --

  group('notification spool', () {
    String line(Map<String, Object?> entry) => jsonEncode(entry);

    Map<String, Object?> whatsapp({
      String body = 'Can we move to Thursday?',
      String sender = 'Alice',
      String conversation = 'alice',
      int sentAt = 1786000000000,
      bool canReply = true,
    }) =>
        {
          'channel': 'whatsapp',
          'package': 'com.whatsapp',
          'conversation_id': conversation,
          'conversation_title': 'Alice',
          'is_group': false,
          'sender': sender,
          'body': body,
          'sent_at': sentAt,
          'can_reply': canReply,
        };

    test('parses a MessagingStyle entry into a message', () {
      final parsed = MessageSpoolReader.parseLines([line(whatsapp())]);
      expect(parsed, hasLength(1));
      final message = parsed.single;
      expect(message.channel, MessageChannels.whatsapp);
      expect(message.sender, 'Alice');
      expect(message.body, 'Can we move to Thursday?');
      expect(message.canReply, isTrue);
      expect(message.source, 'notification');
      expect(message.externalId, isNotNull);
    });

    test('a malformed line is skipped without losing the rest of the batch',
        () {
      // The queue must keep moving: one unparseable entry that aborted the
      // drain would stall capture permanently.
      final parsed = MessageSpoolReader.parseLines([
        '{not json',
        '',
        line(whatsapp(body: 'first')),
        '{"channel":"whatsapp"}', // no body
        line(whatsapp(body: 'second')),
      ]);
      expect(parsed.map((m) => m.body), ['first', 'second']);
    });

    test('a channel this build does not know is dropped', () {
      final parsed = MessageSpoolReader.parseLines([
        line({...whatsapp(), 'channel': 'some_future_app'}),
      ]);
      expect(parsed, isEmpty);
    });

    test('the same message re-posted at millisecond drift dedupes', () {
      // WhatsApp re-posts a chat's recent messages whenever a new one lands,
      // and the timestamps differ in their millisecond component between
      // posts. Hashing the raw value would make every re-post look new.
      final first = MessageSpoolReader.parseLines(
          [line(whatsapp(sentAt: 1786000000123))]).single;
      final second = MessageSpoolReader.parseLines(
          [line(whatsapp(sentAt: 1786000000871))]).single;
      expect(first.externalId, second.externalId);
    });

    test('different text in the same second is not deduped', () {
      final first = MessageSpoolReader.parseLines(
          [line(whatsapp(body: 'one'))]).single;
      final second = MessageSpoolReader.parseLines(
          [line(whatsapp(body: 'two'))]).single;
      expect(first.externalId, isNot(second.externalId));
    });
  });

  // -------------------------------------------------------- the repository --

  group('inbound messages', () {
    late AppDatabase database;
    late InboundMessageRepository messages;

    InboundMessage build({
      String body = 'hello',
      String conversation = 'alice',
      String title = 'Alice',
      String sender = 'Alice',
      String channel = MessageChannels.whatsapp,
      DateTime? sentAt,
      bool digested = false,
      bool referenced = false,
      bool group = false,
      DateTime? createdAt,
    }) {
      final at = sentAt ?? DateTime(2026, 8, 12, 9);
      return InboundMessage(
        id: 'id-${body.hashCode}-${conversation.hashCode}',
        channel: channel,
        conversationId: conversation,
        conversationTitle: title,
        isGroup: group,
        sender: sender,
        body: body,
        sentAt: at,
        externalId: InboundMessage.fingerprint(
          channel: channel,
          conversationId: conversation,
          sender: sender,
          sentAt: at,
          body: body,
        ),
        digested: digested,
        referenced: referenced,
        createdAt: createdAt ?? at,
      );
    }

    setUp(() async {
      database = AppDatabase();
      await database.open(overridePath: inMemoryDatabasePath);
      messages = InboundMessageRepository(database);
    });

    tearDown(() => database.close());

    test('conversations count in SQL, not over the fetched page', () async {
      for (var i = 0; i < 30; i++) {
        await messages.add(build(body: 'message $i'));
      }
      final chats = await messages.conversations();
      expect(chats, hasLength(1));
      // Counting the rows a limited query returned would report the page
      // size forever - the same trap dynamic-screen stats avoid.
      expect(chats.single.messageCount, 30);
      expect(chats.single.undigestedCount, 30);
    });

    test('a conversation reads oldest first', () async {
      await messages.add(build(body: 'second', sentAt: DateTime(2026, 8, 12, 10)));
      await messages.add(build(body: 'first', sentAt: DateTime(2026, 8, 12, 9)));
      final thread = await messages.inConversation(
        channel: MessageChannels.whatsapp,
        conversationId: 'alice',
      );
      expect(thread.map((m) => m.body), ['first', 'second']);
    });

    test('marking a conversation digested clears only that chat', () async {
      await messages.add(build(body: 'from alice'));
      await messages.add(
          build(body: 'from bob', conversation: 'bob', title: 'Bob'));
      await messages.markConversationDigested(
        channel: MessageChannels.whatsapp,
        conversationId: 'alice',
      );
      expect(await messages.countUndigested(), 1);
    });

    test('findConversations prefers an exact name over a partial one',
        () async {
      await messages.add(build(conversation: 'alex', title: 'Alex'));
      await messages.add(build(
          body: 'other', conversation: 'alex (work)', title: 'Alex (work)'));
      final exact = await messages.findConversations('Alex');
      expect(exact, hasLength(1));
      expect(exact.single.title, 'Alex');
      // A partial name that matches both stays ambiguous, so the tool asks
      // rather than picking one.
      expect(await messages.findConversations('ale'), hasLength(2));
    });

    test('pruning keeps referenced and undigested messages', () async {
      final old = DateTime(2026, 1, 1);
      await messages.add(build(body: 'old chatter', digested: true, createdAt: old));
      await messages.add(build(body: 'old but asked about',
          digested: true, referenced: true, createdAt: old));
      await messages.add(build(body: 'old and still queued', createdAt: old));

      final removed = await messages.prune(
          olderThan: const Duration(days: 30), now: DateTime(2026, 8, 12));
      // prune reports *which* messages it removed, so their media can be
      // deleted alongside them; the count is the list's length.
      expect(removed, hasLength(1));
      final left = (await messages.recent()).map((m) => m.body).toSet();
      expect(left, {'old but asked about', 'old and still queued'});
    });

    test('a recorded reply is stored as the user speaking, already digested',
        () async {
      await messages.recordOutgoing(
        channel: MessageChannels.whatsapp,
        conversationId: 'alice',
        conversationTitle: 'Alice',
        body: 'Thursday works',
      );
      final stored = (await messages.recent()).single;
      expect(stored.sender, 'You');
      // Without this the next digest reads the incoming question again with
      // no sign it was answered, and answers it twice.
      expect(stored.digested, isTrue);
    });

    test('search finds a message by body, sender or chat name', () async {
      await messages.add(build(body: 'the invoice is attached'));
      expect(await messages.search('invoice'), hasLength(1));
      expect(await messages.search('alice'), hasLength(1));
      expect(await messages.search('nothing here'), isEmpty);
    });
  });

  // ------------------------------------------------------- chat exports --

  group('WhatsApp chat export', () {
    const importer = ChatExportImporter();

    test('reads the Android format', () {
      final result = importer.parse(
        '12/08/2026, 09:14 - Messages are end-to-end encrypted.\n'
        '12/08/2026, 09:15 - Alice: Can we move to Thursday?\n'
        '12/08/2026, 09:16 - You: Thursday works\n',
        fileName: 'WhatsApp Chat with Alice.txt',
      );
      expect(result.succeeded, isTrue);
      expect(result.chatName, 'Alice');
      expect(result.messages, hasLength(2));
      expect(result.messages.first.sender, 'Alice');
      expect(result.messages.first.sentAt, DateTime(2026, 8, 12, 9, 15));
      // The encryption notice has no sender, so it is not a message.
      expect(result.skippedLines, 1);
      expect(result.isGroup, isFalse);
    });

    test('reads the iOS bracketed format with seconds', () {
      final result = importer.parse(
        '[12/08/2026, 09:15:32] Alice: Morning\n',
        fileName: 'WhatsApp Chat with Alice.txt',
      );
      expect(result.messages.single.sentAt, DateTime(2026, 8, 12, 9, 15, 32));
    });

    test('reads the US 12-hour format', () {
      final result = importer.parse(
        '8/12/26, 9:15 PM - Alice: Evening\n',
        fileName: 'WhatsApp Chat with Alice.txt',
      );
      // 8/12 with a first component under 13 is ambiguous on its own; the
      // hour is not, and 9 PM must become 21:00.
      expect(result.messages.single.sentAt!.hour, 21);
      expect(result.messages.single.sentAt!.year, 2026);
    });

    test('deduces day-first from a date that can only be a day', () {
      final result = importer.parse(
        '25/08/2026, 09:15 - Alice: Late August\n',
        fileName: 'WhatsApp Chat with Alice.txt',
      );
      expect(result.dayFirst, isTrue);
      expect(result.dateOrderAssumed, isFalse);
      expect(result.messages.single.sentAt, DateTime(2026, 8, 25, 9, 15));
    });

    test('deduces month-first the same way', () {
      final result = importer.parse(
        '08/25/2026, 09:15 - Alice: Late August\n',
        fileName: 'WhatsApp Chat with Alice.txt',
      );
      expect(result.dayFirst, isFalse);
      expect(result.messages.single.sentAt, DateTime(2026, 8, 25, 9, 15));
    });

    test('says so when the date order was assumed rather than deduced', () {
      final result = importer.parse(
        '03/04/2026, 09:15 - Alice: Ambiguous\n',
        fileName: 'WhatsApp Chat with Alice.txt',
      );
      // Filing a whole conversation under the wrong month is not something
      // to do silently.
      expect(result.dateOrderAssumed, isTrue);
      expect(result.summary, contains('day/month'));
    });

    test('keeps the continuation lines of a multi-line message', () {
      final result = importer.parse(
        '12/08/2026, 09:15 - Alice: Here is the plan:\n'
        '- book the room\n'
        '- send the deck\n'
        '12/08/2026, 09:16 - Alice: Thanks\n',
        fileName: 'WhatsApp Chat with Alice.txt',
      );
      expect(result.messages, hasLength(2));
      expect(result.messages.first.body, contains('book the room'));
      expect(result.messages.first.body, contains('send the deck'));
    });

    test('a message body containing a colon is not read as a sender', () {
      final result = importer.parse(
        '12/08/2026, 09:15 - Alice: Re: the invoice you sent\n',
        fileName: 'WhatsApp Chat with Alice.txt',
      );
      expect(result.messages.single.sender, 'Alice');
      expect(result.messages.single.body, 'Re: the invoice you sent');
    });

    test('three or more senders is a group', () {
      final result = importer.parse(
        '12/08/2026, 09:15 - Alice: hi\n'
        '12/08/2026, 09:16 - Bob: hi\n'
        '12/08/2026, 09:17 - You: hi\n',
        fileName: 'WhatsApp Chat with Family.txt',
      );
      expect(result.isGroup, isTrue);
      expect(result.chatName, 'Family');
    });

    test('an over-long export is truncated newest-first and says so', () {
      final buffer = StringBuffer();
      for (var i = 0; i < ChatExportResult.maxMessages + 10; i++) {
        buffer.writeln('12/08/2026, 09:15 - Alice: message $i');
      }
      final result = importer.parse(buffer.toString(),
          fileName: 'WhatsApp Chat with Alice.txt');
      expect(result.messages, hasLength(ChatExportResult.maxMessages));
      expect(result.truncated, 10);
      // No silent caps: the user is told what was left out.
      expect(result.summary, contains('skipped'));
      // The newest survive.
      expect(result.messages.last.body, contains('message 5009'));
    });

    test('recognizes an export by its shape, not only its filename', () {
      const content = '12/08/2026, 09:15 - Alice: hi\n'
          '12/08/2026, 09:16 - Bob: hello\n';
      expect(importer.looksLikeExport(content), isTrue);
      expect(importer.looksLikeExport('just some notes I wrote'), isFalse);
    });

    test('falls back to a supplied name for _chat.txt from a zip', () {
      final result = importer.parse(
        '12/08/2026, 09:15 - Alice: hi\n',
        fileName: '_chat.txt',
        fallbackName: 'Alice',
      );
      expect(result.chatName, 'Alice');
    });
  });

  // ------------------------------------------------------- ingest + share --

  group('ingestion', () {
    late AppDatabase database;
    late InboundMessageRepository messages;
    late MessageIngestService ingest;

    setUp(() async {
      database = AppDatabase();
      await database.open(overridePath: inMemoryDatabasePath);
      messages = InboundMessageRepository(database);
      ingest = MessageIngestService(
        messages: messages,
        settings: SettingsRepository(database),
      );
    });

    tearDown(() => database.close());

    test('imported history arrives digested, not as a backlog', () async {
      final imported = await ingest.importExport(
        '12/08/2026, 09:15 - Alice: hi\n'
        '12/08/2026, 09:16 - Alice: are you there?\n',
        fileName: 'WhatsApp Chat with Alice.txt',
      );
      expect(imported.stored, 2);
      // A year of back-messages is something to ask about, not a queue of
      // work - otherwise every background run for a week digests a
      // conversation that ended months ago.
      expect(await messages.countUndigested(), 0);
    });

    test('re-importing the same export stores nothing new', () async {
      const content = '12/08/2026, 09:15 - Alice: hi\n';
      await ingest.importExport(content,
          fileName: 'WhatsApp Chat with Alice.txt');
      final second = await ingest.importExport(content,
          fileName: 'WhatsApp Chat with Alice.txt');
      expect(second.stored, 0);
    });

    test('an empty drain says capture is off when it is', () async {
      final summary = await ingest.syncAllDetailed();
      expect(summary.added, 0);
      expect(summary.summary, contains('Chat capture is off'));

      await ingest.recordCaptureEnabled(true);
      expect((await ingest.syncAllDetailed()).summary,
          'No new chat messages.');
    });
  });

  group('shared intake', () {
    late AppDatabase database;
    late SharedIntakeService intake;
    late InboundMessageRepository messages;
    late EmailRepository emails;

    setUp(() async {
      database = AppDatabase();
      await database.open(overridePath: inMemoryDatabasePath);
      messages = InboundMessageRepository(database);
      emails = EmailRepository(database);
      intake = SharedIntakeService(
        messages: messages,
        emails: emails,
        ingest: MessageIngestService(
          messages: messages,
          settings: SettingsRepository(database),
        ),
      );
    });

    tearDown(() => database.close());

    test('a shared chat export becomes history', () async {
      final outcome = await intake.accept(const SharedItem(
        action: 'send',
        fileName: 'WhatsApp Chat with Alice.txt',
        fileText: '12/08/2026, 09:15 - Alice: hi\n',
      ));
      expect(outcome, isA<ChatHistoryImported>());
      expect(outcome.promptPrefill, contains('Alice'));
    });

    test('a share carrying a subject is an email', () async {
      // Nothing but a mail client puts a subject on a share.
      final outcome = await intake.accept(const SharedItem(
        action: 'send',
        subject: 'Invoice 4021',
        text: 'Please find the invoice attached.',
      ));
      expect(outcome, isA<EmailReferenced>());
      expect((await emails.recent()).single.subject, 'Invoice 4021');
    });

    test('a message forwarded from WhatsApp is stored as a chat message',
        () async {
      final outcome = await intake.accept(const SharedItem(
        action: 'send',
        text: 'Can we move to Thursday?',
        sourcePackage: 'com.whatsapp',
      ));
      expect(outcome, isA<MessageReferenced>());
      final stored = (await messages.recent()).single;
      expect(stored.channel, MessageChannels.whatsapp);
      expect(stored.referenced, isTrue);
      // Referenced is not queued work: the user is about to ask about it.
      expect(stored.digested, isTrue);
    });

    test('several selected messages keep their senders and times', () async {
      final outcome = await intake.accept(const SharedItem(
        action: 'send',
        text: '[12/08/2026, 09:15:00] Alice: first\n'
            '[12/08/2026, 09:16:00] Bob: second\n',
        sourcePackage: 'com.whatsapp',
      ));
      expect(outcome, isA<MessageReferenced>());
      final stored = await messages.recent();
      expect(stored.map((m) => m.sender).toSet(), {'Alice', 'Bob'});
    });

    test('text selected in an unknown app is not filed in a chat inbox',
        () async {
      final outcome = await intake.accept(const SharedItem(
        action: 'process_text',
        text: 'a paragraph from a web page',
      ));
      expect(outcome, isA<PlainTextShared>());
      expect(await messages.recent(), isEmpty);
      expect(outcome.promptPrefill, contains('a paragraph from a web page'));
    });

    test('a file that is not a chat log is refused with instructions',
        () async {
      final outcome = await intake.accept(const SharedItem(
        action: 'send',
        fileName: 'notes.txt',
        fileText: 'Shopping list\nmilk\nbread\n',
      ));
      expect(outcome, isA<SharedIntakeFailed>());
      expect(outcome.banner, contains('Export chat'));
    });
  });

  // ------------------------------------------------------------ security --

  group('security classification', () {
    test('replying to a chat is outbound, so no scheduled run can do it', () {
      expect(CapabilityGate.capabilityOf('reply_to_chat'),
          ToolCapability.outbound);
      final decision = const CapabilityGate().authorize(
        tool: 'reply_to_chat',
        arguments: const {'chat': 'Alice', 'text': 'sure'},
        runMode: AgentRunMode.unattended,
      );
      expect(decision.isAllowed, isFalse);
    });

    test('reading and digesting chat is available to a background run', () {
      for (final tool in ['sync_messages', 'read_message_context',
        'read_chat', 'list_chats', 'mark_message_digested']) {
        final decision = const CapabilityGate().authorize(
          tool: tool,
          arguments: const {},
          runMode: AgentRunMode.unattended,
        );
        expect(decision.isAllowed, isTrue, reason: '$tool should be allowed');
      }
    });

    test('every chat tool is classified rather than failing closed by luck',
        () {
      // Unknown names fall back to `outbound`, which would silently make a
      // read tool unavailable to background runs.
      for (final tool in [
        'sync_messages', 'read_message_context', 'read_chat', 'list_chats',
        'mark_message_digested', 'reply_to_chat',
      ]) {
        expect(CapabilityGate.capabilities.containsKey(tool), isTrue,
            reason: '$tool is not classified');
      }
    });

    test('chat content is treated as untrusted external content', () {
      // Anyone can be added to a group, so a sentence shaped like an
      // instruction can arrive from a stranger.
      for (final tool in ['read_message_context', 'read_chat',
        'sync_messages', 'list_chats']) {
        expect(ExternalContentGuard.externalSourceFor(tool), isNotNull,
            reason: '$tool must carry an external-content label');
      }
    });

    test('an unattended run cannot reply once chat content is in the turn',
        () {
      final decision = const CapabilityGate().authorize(
        tool: 'reply_to_chat',
        arguments: const {'chat': 'Alice', 'text': 'sure'},
        runMode: AgentRunMode.unattended,
        externalContentInScope: true,
      );
      expect(decision.isAllowed, isFalse);
    });

    test('the unattended write scope digests chat but never sends', () {
      const scope = WriteScope.unattendedDefault;
      expect(scope.allows(WriteEffect.messageSync), isTrue);
      expect(scope.allows(WriteEffect.messageMarkDigested), isTrue);
      expect(scope.allows(WriteEffect.messageSend), isFalse);
    });

    test('chat tools map to their write effects', () {
      expect(WriteScope.effectOf('sync_messages', const {}),
          WriteEffect.messageSync);
      expect(WriteScope.effectOf('mark_message_digested', const {}),
          WriteEffect.messageMarkDigested);
      expect(WriteScope.effectOf('reply_to_chat', const {}),
          WriteEffect.messageSend);
    });

    test('a trigger firing may close its queue but never answer anyone', () {
      final trigger = BehaviorTrigger.fromBehavior(_behavior(
        title: 'Digest chats',
        params: const {
          'trigger': {'on': 'new_message', 'action': 'digest'},
        },
      ));
      expect(trigger, isNotNull);
      expect(trigger!.event, BehaviorTrigger.eventNewMessage);
      final effects = WriteScope.decode(trigger.writeScopeJson);
      expect(effects.allows(WriteEffect.messageMarkDigested), isTrue);
      // A rule that fires on incoming messages and can also answer them is
      // an assistant holding conversations nobody asked it to have.
      expect(effects.allows(WriteEffect.messageSend), isFalse);
    });

    test('an unknown trigger event is still rejected', () {
      final trigger = BehaviorTrigger.fromBehavior(_behavior(
        title: 'Typo',
        params: const {
          'trigger': {'on': 'new_messages', 'action': 'digest'},
        },
      ));
      expect(trigger, isNull);
    });
  });

  // ------------------------------------------------- the two package lists --

  test('the Dart channel catalogue matches the Kotlin one', () async {
    // ChatPackages.kt decides what the notification listener keeps and has to
    // work with no Flutter engine alive; MessageChannels decides what the UI
    // renders and what a tool result is allowed to name. Two copies is the
    // deliberate cost of that - them disagreeing is not.
    final kotlin = await _kotlinSource();
    for (final entry in MessageChannels.packageByChannel.entries) {
      expect(kotlin, contains('"${entry.value}" to '),
          reason: '${entry.value} is in Dart but not in ChatPackages.kt');
    }
    final kotlinPackages = RegExp(r'"([a-z0-9_.]+)" to [A-Z_]+')
        .allMatches(kotlin)
        .map((m) => m.group(1)!)
        .toSet();
    expect(kotlinPackages, MessageChannels.packageByChannel.values.toSet());
  });
}

AgentBehavior _behavior({
  required String title,
  required Map<String, Object?> params,
}) =>
    AgentBehavior(
      id: 'b-${title.hashCode}',
      behaviorKey: 'key-${title.hashCode}',
      title: title,
      behaviorType: 'integration_rule',
      ruleText: title,
      params: params,
      createdAt: DateTime(2026, 8, 12),
      updatedAt: DateTime(2026, 8, 12),
    );

Future<String> _kotlinSource() async {
  const path = 'android/app/src/main/kotlin/com/brightforge/exa/messaging/'
      'ChatPackages.kt';
  return File(path).readAsString();
}
