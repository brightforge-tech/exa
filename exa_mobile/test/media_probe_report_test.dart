import 'dart:convert';
import 'dart:io';

import 'package:exa_mobile/services/messaging/messaging_bridge.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Decodes the exact JSON document the Kotlin probe writes (ChatPackages.
/// recordMediaProbe) through the flat rows the Kotlin report hands over
/// (ChatPackages.mediaProbeReport), then through MessagingBridge's record
/// model — pinning the whole persisted-matrix contract (C11) from the byte
/// shape on disk to the Dart object Settings renders.
///
/// The flattening here mirrors what the Kotlin side documents and does:
/// device facts repeated on every row, so one flat method-result list
/// survives the platform channel intact. If either side renames a field,
/// the pin test in this same group fails.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const messagingDir =
      'android/app/src/main/kotlin/com/brightforge/exa/messaging';

  // The documented prefs document, copied field for field from what
  // ChatPackages.recordMediaProbe writes: device + packages, up to 8
  // records per package, records with origin/bytes/failure/at plus
  // scheme/mime_type only when known. Never a URI.
  const fixtureDocument = '''
{
  "device": {"release": "15", "manufacturer": "Google", "model": "Pixel 9", "api": 35},
  "packages": {
    "com.whatsapp": [
      {
        "origin": "message_attachment",
        "bytes": 3072,
        "failure": "ok",
        "at": 1730000000000,
        "scheme": "content",
        "mime_type": "image/jpeg"
      },
      {
        "origin": "notification_picture",
        "bytes": 0,
        "failure": "security",
        "at": 1730000000500,
        "scheme": "content"
      }
    ],
    "org.thoughtcrime.securesms": [
      {
        "origin": "message_attachment",
        "bytes": 0,
        "failure": "not_found",
        "at": 1730000001000,
        "scheme": "content",
        "mime_type": "audio/ogg; codecs=opus"
      }
    ]
  }
}
''';

  /// ChatPackages.mediaProbeReport flattened to channel rows.
  List<Map<String, Object?>> flatten(String documentJson) {
    final document = jsonDecode(documentJson) as Map<String, Object?>;
    final device = document['device'] as Map<String, Object?>;
    final packages = document['packages'] as Map<String, Object?>;
    return [
      for (final entry in packages.entries)
        for (final record in (entry.value as List))
          {
            'package': entry.key,
            'origin': record['origin'],
            'scheme': record['scheme'],
            'mime_type': record['mime_type'],
            'bytes': record['bytes'],
            'failure': record['failure'],
            'at': record['at'],
            'device_release': device['release'],
            'device_manufacturer': device['manufacturer'],
            'device_model': device['model'],
            'device_api': device['api'],
          },
    ];
  }

  group('the persisted matrix decodes end to end', () {
    test('the documented fixture decodes into complete records', () {
      final rows = flatten(fixtureDocument);
      expect(rows, hasLength(3));

      final records = rows.map(MediaProbeRecord.fromMap).toList();
      final whatsappPhoto = records.first;
      expect(whatsappPhoto.packageName, 'com.whatsapp');
      expect(whatsappPhoto.origin, 'message_attachment');
      expect(whatsappPhoto.scheme, 'content');
      expect(whatsappPhoto.mimeType, 'image/jpeg');
      expect(whatsappPhoto.bytesRead, 3072);
      expect(whatsappPhoto.failure, 'ok');
      expect(whatsappPhoto.at, 1730000000000);
      expect(whatsappPhoto.deviceRelease, '15');
      expect(whatsappPhoto.deviceManufacturer, 'Google');
      expect(whatsappPhoto.deviceModel, 'Pixel 9');
      expect(whatsappPhoto.deviceApi, 35);
      expect(whatsappPhoto.deviceLabel, 'Android 15 Google Pixel 9 API 35');

      // "Absent rather than null-valued when unknown" is the Kotlin side's
      // compactness rule; the Dart side must read a missing key as "no
      // answer", not crash.
      final avatar = records[1];
      expect(avatar.origin, 'notification_picture');
      expect(avatar.mimeType, isNull);
      expect(avatar.failure, 'security');

      expect(records.last.packageName, 'org.thoughtcrime.securesms');
      expect(records.last.mimeType, 'audio/ogg; codecs=opus');
      expect(records.last.bytesRead, 0);
      expect(records.last.failure, 'not_found');
    });

    test(
      'the bridge method round-trips the flat rows over the channel',
      () async {
        const channel = MethodChannel('com.brightforge.exa/messaging');
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              if (call.method == 'mediaProbeReport') {
                return flatten(fixtureDocument);
              }
              return null;
            });
        try {
          final records = await const MessagingBridge().mediaProbeReport();
          expect(records, hasLength(3));
          expect(records.first.packageName, 'com.whatsapp');
          expect(records.first.deviceLabel, 'Android 15 Google Pixel 9 API 35');
          expect(records[1].mimeType, isNull);
        } finally {
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(channel, null);
        }
      },
    );
  });

  group(
    'the wire contract agrees between MessagingChannel.kt and the bridge',
    () {
      final ktChannelSource = File(
        '$messagingDir/MessagingChannel.kt',
      ).readAsStringSync();
      final ktReportSource = File(
        '$messagingDir/ChatPackages.kt',
      ).readAsStringSync();
      final bridgeSource = File(
        'lib/services/messaging/messaging_bridge.dart',
      ).readAsStringSync();

      test('the channel method name is identical on both sides', () {
        expect(ktChannelSource, contains('"mediaProbeReport"'));
        expect(bridgeSource, contains("'mediaProbeReport'"));
      });

      test('every row field is spelled the same on both sides', () {
        // The field names are the whole contract: Kotlin's row map in
        // ChatPackages.mediaProbeReport vs MediaProbeRecord.fromMap. A rename
        // on one side silently zeroes or nulls a column on the other, which
        // is exactly the kind of drift a review cannot catch by reading one
        // language.
        for (final field in [
          'package',
          'origin',
          'scheme',
          'mime_type',
          'bytes',
          'failure',
          'at',
          'device_release',
          'device_manufacturer',
          'device_model',
          'device_api',
        ]) {
          expect(
            ktReportSource,
            contains('"$field"'),
            reason: 'the Kotlin row builder must emit "$field"',
          );
          expect(
            bridgeSource,
            contains("map['$field']"),
            reason: 'MediaProbeRecord.fromMap must read "$field"',
          );
        }
      });

      test('neither side of the contract can name a URI field', () {
        expect(ktReportSource, isNot(contains('"data_uri"')));
        expect(
          bridgeSource,
          isNot(contains("map['uri']")),
          reason: 'the report model must have no way to carry a URI',
        );
      });

      test('the prefs key and the per-package cap are pinned in Kotlin', () {
        // Dart never writes this document (read-only bridge on purpose), so
        // the storage key only needs to be stable inside Kotlin — and the cap
        // is what guarantees the document can never grow SharedPreferences.
        expect(
          ktReportSource,
          contains('KEY_MEDIA_PROBE_REPORT = "media_probe_report"'),
        );
        expect(ktReportSource, contains('MAX_PROBE_RECORDS_PER_PACKAGE = 8'));
        expect(ktReportSource, contains('MAX_PROBE_REPORT_CHARS'));
      });
    },
  );
}
