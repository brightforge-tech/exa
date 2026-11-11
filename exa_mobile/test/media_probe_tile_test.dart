import 'package:exa_mobile/features/settings/chat_apps_screen.dart';
import 'package:exa_mobile/services/messaging/messaging_bridge.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Renders the persisted media-probe matrix exactly as Settings does.
///
/// The tile is the only way the spike's answer survives an adb session
/// (C11), so it is pinned like a user-facing contract: every row readable
/// in human words, the tested device named in the header, failure states
/// called out instead of hidden — and no URI anywhere, because a content
/// URI is a signed link into somebody's app-private storage.
void main() {
  Widget screen(List<MediaProbeRecord> records) => MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child: Column(children: [MediaProbeTile(records: records)]),
      ),
    ),
  );

  MediaProbeRecord rec({
    required String package,
    required String origin,
    String? scheme,
    String? mimeType,
    int bytesRead = 0,
    required String failure,
    String deviceRelease = '15',
    String deviceManufacturer = 'Google',
    String deviceModel = 'Pixel 9',
    int deviceApi = 35,
  }) => MediaProbeRecord(
    packageName: package,
    origin: origin,
    scheme: scheme,
    mimeType: mimeType,
    bytesRead: bytesRead,
    failure: failure,
    at: 1730000000000,
    deviceRelease: deviceRelease,
    deviceManufacturer: deviceManufacturer,
    deviceModel: deviceModel,
    deviceApi: deviceApi,
  );

  group('MediaProbeTile', () {
    testWidgets('renders one readable line per probe record', (tester) async {
      await tester.pumpWidget(
        screen([
          rec(
            package: 'com.whatsapp',
            origin: 'message_attachment',
            scheme: 'content',
            mimeType: 'image/jpeg',
            bytesRead: 312453,
            failure: 'ok',
          ),
          rec(
            package: 'org.thoughtcrime.securesms',
            origin: 'message_attachment',
            scheme: 'content',
            mimeType: 'audio/ogg; codecs=opus',
            failure: 'security',
          ),
          rec(
            package: 'com.google.android.apps.messaging',
            origin: 'notification_picture',
            scheme: 'content',
            failure: 'not_found',
          ),
          rec(
            package: 'org.telegram.messenger',
            origin: 'message_attachment',
            mimeType: 'image/png',
            failure: 'null_uri',
          ),
          rec(
            package: 'com.whatsapp',
            origin: 'message_attachment',
            scheme: 'content',
            mimeType: 'image/png',
            failure: 'empty_stream',
          ),
          rec(
            package: 'com.whatsapp',
            origin: 'message_attachment',
            scheme: 'file',
            mimeType: 'image/gif',
            failure: 'unsupported_scheme',
          ),
        ]),
      );

      // A success says how many bytes were read...
      expect(find.textContaining('312453 bytes read'), findsOneWidget);
      // ...and each failure gets a plain word, not an enum name.
      expect(find.textContaining('blocked'), findsOneWidget);
      expect(find.textContaining('not found'), findsOneWidget);
      expect(find.textContaining('no uri'), findsOneWidget);
      expect(find.textContaining('empty'), findsOneWidget);
      expect(find.textContaining('not a media link'), findsOneWidget);
      // Missing mime reads as "no mime" rather than an empty gap.
      expect(find.textContaining('no mime'), findsOneWidget);
      // The unverified big picture is labelled as such — an avatar must
      // never look like this message's photo.
      expect(
        find.textContaining('notification picture (unverified)'),
        findsOneWidget,
      );
      expect(find.textContaining('message attachment'), findsNWidgets(5));
    });

    testWidgets('the header names the tested device', (tester) async {
      await tester.pumpWidget(
        screen([
          rec(
            package: 'com.whatsapp',
            origin: 'message_attachment',
            scheme: 'content',
            mimeType: 'image/jpeg',
            bytesRead: 12,
            failure: 'ok',
          ),
        ]),
      );
      expect(
        find.textContaining('Android 15 Google Pixel 9 API 35'),
        findsOneWidget,
      );
    });

    testWidgets('no URI text ever reaches the screen', (tester) async {
      // The records cannot carry one by construction (no URI field exists),
      // but the tile must not start rendering scheme-plus-path style text
      // either: nothing on screen may look like a content link.
      await tester.pumpWidget(
        screen([
          rec(
            package: 'com.whatsapp',
            origin: 'message_attachment',
            scheme: 'content',
            mimeType: 'image/jpeg',
            bytesRead: 99,
            failure: 'ok',
          ),
          rec(
            package: 'org.telegram.messenger',
            origin: 'notification_picture',
            scheme: 'content',
            failure: 'security',
          ),
        ]),
      );
      final texts = tester.widgetList<Text>(find.byType(Text));
      for (final text in texts) {
        expect(
          text.data ?? '',
          isNot(contains('://')),
          reason: 'a content URI must never be rendered',
        );
      }
    });

    testWidgets('an empty matrix renders nothing', (tester) async {
      // A card announcing "media checks" before the first media notification
      // has ever been seen is noise on an otherwise clean screen.
      await tester.pumpWidget(screen(const []));
      expect(find.byType(MediaProbeTile), findsOneWidget);
      expect(find.textContaining('Media in chat notifications'), findsNothing);
      expect(find.byType(Text), findsNothing);
    });
  });
}
