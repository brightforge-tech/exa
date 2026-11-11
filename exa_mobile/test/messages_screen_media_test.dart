import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:exa_mobile/data/database/app_database.dart';
import 'package:exa_mobile/data/models/inbound_message.dart';
import 'package:exa_mobile/data/repositories/inbound_media_repository.dart';
import 'package:exa_mobile/data/repositories/inbound_message_repository.dart';
import 'package:exa_mobile/features/settings/messages_screen.dart';
import 'package:exa_mobile/shared/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Settings -> Captured messages over media-only captures.
///
/// A photo and a voice note have no body, and the plain row under the
/// sender line used to render exactly that: an empty gap the user read as a
/// lost message. The screen now shows the labelled note in its place and a
/// small chip naming the kind and size, so the inbox is honest about what
/// it kept without pretending it can play anything.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Directory work;
  late String mediaDir;
  late AppDatabase database;

  setUp(() async {
    work = Directory.systemTemp.createTempSync('exa_inbox_media');
    mediaDir = p.join(work.path, 'exa_media', 'incoming');
    Directory(mediaDir).createSync(recursive: true);
    database = AppDatabase();
  });

  tearDown(() async {
    await database.close();
    if (work.existsSync()) work.deleteSync(recursive: true);
  });

  final t0 = DateTime.fromMillisecondsSinceEpoch(1786000000000);

  Future<void> seedMediaOnly(
    InboundMessageRepository messages,
    InboundMediaRepository media, {
    required String sender,
    required String kind,
    required String mime,
    required String ext,
    required String note,
    List<int>? bytes,
  }) async {
    final data = bytes ?? List.filled(64, 0x5A);
    final digest = sha256.convert(data).toString().substring(0, 32);
    final name = '$digest.$ext';
    File(p.join(mediaDir, name)).writeAsBytesSync(data, flush: true);
    final message = await messages.add(
      InboundMessage(
        id: '',
        channel: 'whatsapp',
        conversationId: sender.toLowerCase(),
        conversationTitle: sender,
        sender: sender,
        isGroup: false,
        body: '',
        summary: note,
        source: 'notification',
        sentAt: t0,
        createdAt: t0,
        externalId: 'x-$sender',
        media: const [],
      ),
    );
    final stored = await media.add(
      messageId: message!.id,
      kind: kind,
      mimeType: mime,
      filePath: p.join(mediaDir, name),
      fileName: name,
      sizeBytes: data.length,
      contentHash: digest,
      createdAt: t0,
    );
    expect(stored, isNotNull);
  }

  testWidgets('an image-only and a voice-note-only message render as '
      'labelled lines, not blank rows', (tester) async {
    final dbPath = p.join(work.path, 'inbox.db');

    // sqflite's ffi isolate cannot answer inside testWidgets' fake-async
    // zone: every round trip, seeding and screen loads included, runs
    // inside runAsync's real event loop.
    await tester.runAsync(() async {
      await database.open(overridePath: dbPath);
      final media = InboundMediaRepository(database);
      final messages = InboundMessageRepository(database, media: media);
      await seedMediaOnly(
        messages,
        media,
        sender: 'Priya Ravi',
        kind: 'image',
        mime: 'image/jpeg',
        ext: 'jpg',
        bytes: List.generate(1536, (i) => i % 256),
        note: 'Photo (image/jpeg, 1.5 KB)',
      );
      await seedMediaOnly(
        messages,
        media,
        sender: 'Nils Berg',
        kind: 'audio',
        mime: 'audio/ogg; codecs=opus',
        ext: 'ogg',
        bytes: List.filled(9216, 0x11),
        note: 'Voice note (audio/ogg; codecs=opus, 9 KB)',
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appDatabaseProvider.overrideWithValue(database),
            inboundMediaRepositoryProvider.overrideWithValue(media),
            inboundMessageRepositoryProvider.overrideWithValue(messages),
          ],
          child: const MaterialApp(home: MessagesScreen()),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await tester.pump();

      // The chat list: neither tile is a blank line - the summary note is
      // the preview, and the row says it carries media.
      expect(find.text('Priya Ravi'), findsOneWidget);
      expect(find.text('Nils Berg'), findsOneWidget);
      expect(find.textContaining('with media'), findsNWidgets(2));

      // Open the photo chat: the note is the body line, and the chip names
      // the kind and size - an icon, never a player.
      await tester.tap(find.text('Priya Ravi'));
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await tester.pump();
      expect(find.text('Photo (image/jpeg, 1.5 KB)'), findsOneWidget);
      expect(find.text('Photo 1.5 KB'), findsOneWidget);
      expect(find.byIcon(Icons.image_outlined), findsWidgets);
      expect(find.byIcon(Icons.play_circle_outline), findsNothing);

      // And the voice-note chat, expanded the same way: the same honesty,
      // audio shaped.
      await tester.tap(find.text('Nils Berg'));
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await tester.pump();
      expect(
        find.text('Voice note (audio/ogg; codecs=opus, 9 KB)'),
        findsOneWidget,
      );
      expect(find.text('Voice note 9 KB'), findsOneWidget);
      expect(find.byIcon(Icons.play_circle_outline), findsWidgets);
    });
  });
}
