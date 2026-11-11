import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Pins, from Dart, the invariants the Kotlin media probe must never break.
///
/// The Robolectric suite (`android/app/src/test/kotlin/.../NotificationMediaTest.kt`)
/// exercises the mapping and the probe directly, but this tree has no Gradle
/// entry point (gradlew and its wrapper jar are not checked in), so nothing
/// here can execute it. These source pins are the executable substitute for
/// the invariants that matter most on a real device:
///
///  - the allowlist gate is the listener's FIRST statement, so a notification
///    from an unticked package provably reaches neither the probe nor its log;
///  - no content-provider or file work runs on the notification callback
///    thread — the one failure that makes the system stop the listener;
///  - nothing media-shaped ever logs a URI, notification text or bytes,
///    because content URIs carry signed, sometimes expiring tokens.
///
/// (What only a phone can prove — whether WhatsApp's provider answers with
/// SecurityException or with bytes — is what the persisted matrix reports.
/// That surface is manual, not pinnable.)
void main() {
  const messagingDir =
      'android/app/src/main/kotlin/com/brightforge/exa/messaging';

  String read(String name) => File('$messagingDir/$name').readAsStringSync();

  final listener = read('ExaNotificationListener.kt');
  final media = read('NotificationMedia.kt');
  final spool = read('MessageSpool.kt');
  final chatPackages = read('ChatPackages.kt');
  final channel = read('MessagingChannel.kt');

  // ------------------------------------------------------------- helpers --

  /// The body of the named function, `{` to its matching `}`, skipping
  /// signature lines the tests never care about. Throws rather than calls
  /// `expect`, because these helpers run while the group is being declared.
  String functionBody(String src, String signature) {
    final start = src.indexOf(signature);
    if (start < 0) throw StateError('missing $signature');
    final open = src.indexOf('{', start + signature.length);
    if (open < 0) throw StateError('no body for $signature');
    var depth = 0;
    for (var i = open; i < src.length; i++) {
      if (src[i] == '{') {
        depth++;
      } else if (src[i] == '}') {
        depth--;
        if (depth == 0) return src.substring(open + 1, i);
      }
    }
    throw StateError('unbalanced braces for $signature');
  }

  /// The text of every `{...}` block that follows a [marker], brace-matched.
  /// This is how "inside the worker submission" is decided without parsing
  /// Kotlin: the blocks the tests extract are exactly the lambda bodies the
  /// executor runs off the callback thread.
  List<String> blocksAfter(String src, String marker) {
    final out = <String>[];
    var from = 0;
    while (true) {
      final at = src.indexOf(marker, from);
      if (at < 0) return out;
      final open = src.indexOf('{', at);
      var depth = 0;
      for (var i = open; i < src.length; i++) {
        if (src[i] == '{') {
          depth++;
        } else if (src[i] == '}') {
          depth--;
          if (depth == 0) {
            out.add(src.substring(open + 1, i));
            break;
          }
        }
      }
      from = open + 1;
    }
  }

  /// Lines that are code (not comments and not inside a block doc), so the
  /// doc-comment prose about URIs can never trip a hygiene pin.
  List<String> codeLines(String src) => src
      .split('\n')
      .map((l) => l.trim())
      .where(
        (l) =>
            l.isNotEmpty &&
            !l.startsWith('//') &&
            !l.startsWith('*') &&
            !l.startsWith('/*'),
      )
      .toList();

  group('the allowlist gate comes before any reading at all', () {
    final body = functionBody(
      listener,
      'override fun onNotificationPosted(sbn: StatusBarNotification)',
    );
    final firstStatement = body
        .split('\n')
        .map((l) => l.trim())
        .firstWhere((l) => l.isNotEmpty && !l.startsWith('//'));

    test('shouldCapture is the first statement of onNotificationPosted', () {
      expect(firstStatement, contains('ChatPackages.shouldCapture'));
      expect(firstStatement, contains('return'));
    });

    test('nothing reads the notification before the gate', () {
      final gate = body.indexOf('ChatPackages.shouldCapture');
      expect(gate, greaterThanOrEqualTo(0));
      final before = body.substring(0, gate);
      // The ExaNotifDbg diagnostic used to sit here and log titles and
      // previews of *every* app on the phone. If it ever migrates back above
      // the gate, that is device-wide notification snooping again — the test
      // fails so nobody has to remember why the ordering is load-bearing.
      for (final forbidden in [
        'sbn.notification',
        'notification.extras',
        '.extras',
        'getCharSequence',
        'Log.',
      ]) {
        expect(
          before,
          isNot(contains(forbidden)),
          reason: '$forbidden must not run before the allowlist gate',
        );
      }
    });

    test('replayActiveNotifications gates the same way', () {
      final replay = functionBody(
        listener,
        'private fun replayActiveNotifications',
      );
      expect(replay, contains('ChatPackages.shouldCapture'));
    });
  });

  group('all media work runs off the notification callback thread', () {
    test('one bounded worker, DiscardOldest, never growing', () {
      // The failure mode the comments keep warning about: a thrown or hung
      // onNotificationPosted callback is the system quietly stopping the
      // listener. The executor's shape is what keeps that impossible.
      expect(listener, contains('ThreadPoolExecutor('));
      expect(listener, contains('ArrayBlockingQueue'));
      expect(listener, contains('DiscardOldestPolicy'));
      final at = listener.indexOf('private val mediaProbeExecutor');
      expect(at, greaterThanOrEqualTo(0));
      final declaration = listener
          .substring(at, at + 400)
          .replaceAll(RegExp(r'\s+'), ' ');
      // core = max = 1: one thread serialises provider reads.
      expect(declaration, contains('ThreadPoolExecutor( 1, 1, 1L'));
    });

    test('the probe and the capture copy both live inside worker bodies', () {
      final workers = blocksAfter(listener, 'mediaProbeExecutor.execute');
      expect(
        workers,
        hasLength(2),
        reason: 'the probe worker and the capture worker',
      );
      final joined = workers.join('\n');
      for (final call in [
        'NotificationMedia.probe(',
        'NotificationMedia.mediaCandidates(',
        'NotificationMedia.capture(',
      ]) {
        final inWorkers = joined.split(call).length - 1;
        final everywhere = listener.split(call).length - 1;
        expect(everywhere, greaterThan(0), reason: '$call should exist at all');
        expect(
          inWorkers,
          equals(everywhere),
          reason: '$call outside a worker body',
        );
      }
    });

    test('onNotificationPosted and capture call no media I/O directly', () {
      // The synchronous bodies may look up *which* messages advertise media
      // (that is a pure Bundle read — see the next test) but must never open
      // a provider or a file: the copy itself is handed to the worker.
      final posted = functionBody(
        listener,
        'override fun onNotificationPosted(sbn: StatusBarNotification)',
      );
      final capture = functionBody(listener, 'private fun capture(');
      for (final body in [posted, capture]) {
        final outsideWorkers = blocksAfter(
          body,
          'mediaProbeExecutor.execute',
        ).fold(body, (acc, block) => acc.replaceAll(block, ''));
        expect(outsideWorkers, isNot(contains('NotificationMedia.probe')));
        expect(outsideWorkers, isNot(contains('NotificationMedia.capture')));
        expect(
          outsideWorkers,
          isNot(contains('NotificationMedia.mediaCandidates')),
        );
      }
    });

    test('the synchronous candidate lookup performs no I/O', () {
      // messageCandidate runs on the callback thread as part of parsing the
      // entry; that is only safe because it only reads the Bundle. If it ever
      // grew a resolver or stream call, the thread guarantee is broken and
      // this pin must fail.
      final body = functionBody(media, 'fun messageCandidate(bundle: Bundle)');
      for (final forbidden in [
        'openInputStream',
        'openAssetFileDescriptor',
        'contentResolver',
        'File(',
        'Log.',
      ]) {
        expect(
          body,
          isNot(contains(forbidden)),
          reason:
              'messageCandidate is called on the callback thread; '
              '$forbidden belongs on the worker',
        );
      }
    });
  });

  group('media logs and reports carry facts, never the media', () {
    test('NotificationMedia.kt itself never logs', () {
      for (final line in codeLines(media)) {
        expect(
          line,
          isNot(matches(RegExp(r'^\s*(android\.util\.)?Log\.'))),
          reason: 'no logging here; the caller logs derived facts only: $line',
        );
      }
    });

    test('probe-path log lines carry no URI, no text, no bytes', () {
      // The only values the probe path may write: package name, URI *scheme*,
      // mime type, byte count, failure class (plus origin and kind labels).
      // Everything else — a Uri variable, notification text, a byte array —
      // is either a signed/expiring token or private content.
      final probePath =
          blocksAfter(listener, 'mediaProbeExecutor.execute').join('\n') +
          functionBody(listener, 'private fun submitMediaCapture');
      final calls = RegExp(r'Log\.\w+\(').allMatches(probePath);
      expect(calls, isNotEmpty, reason: 'the probe path does log something');
      for (final match in calls) {
        final open = match.end - 1;
        var depth = 0;
        var end = open;
        for (var i = open; i < probePath.length; i++) {
          if (probePath[i] == '(') {
            depth++;
          } else if (probePath[i] == ')') {
            depth--;
            if (depth == 0) {
              end = i;
              break;
            }
          }
        }
        final call = probePath.substring(match.start, end + 1);
        for (final forbidden in [
          'bigPicture',
          'candidate.uri',
          '.uri',
          'Uri',
          'extras',
          'getCharSequence',
          'EXTRA_',
          'title',
          'text',
          'bytes[',
        ]) {
          expect(
            call,
            isNot(contains(forbidden)),
            reason:
                'a probe-path log must carry only package, scheme, mime, '
                'byte count, failure class: $call',
          );
        }
      }
      // The persisted report is written from the same derived facts: the
      // recordMediaProbe call inside the probe worker passes exactly the
      // labels and counts, never a URI.
      final probeWorker = blocksAfter(
        listener,
        'mediaProbeExecutor.execute',
      ).first;
      final storeAt = probeWorker.indexOf('ChatPackages.recordMediaProbe');
      expect(storeAt, greaterThanOrEqualTo(0));
      final store = probeWorker.substring(storeAt);
      expect(store, isNot(contains('bigPicture')));
      expect(store, isNot(contains('.uri')));
      expect(store, isNot(contains('extras')));
    });

    test('the report document itself has no URI field', () {
      // ChatPackages stores origin/bytes/failure/at/scheme/mime_type and the
      // device surface — and the URI only ever as its scheme, never itself.
      for (final line in codeLines(chatPackages)) {
        if (!line.contains('put(') && !line.contains('putString')) continue;
        expect(
          line,
          isNot(matches(RegExp(r'''put\(\s*"uri"'''))),
          reason: 'the persisted matrix must not carry URIs: $line',
        );
        expect(
          line,
          isNot(matches(RegExp(r'''put\(\s*"data_uri"'''))),
          reason: 'the persisted matrix must not carry URIs: $line',
        );
      }
      expect(chatPackages, contains('put("scheme"'));
      expect(chatPackages, contains('put("mime_type"'));
    });
  });

  group('the probe is bounded, cached, and content-only', () {
    test('one 32 KiB read cap', () {
      expect(media, contains('const val MAX_PROBE_BYTES = 32 * 1024'));
      expect(media, contains('ByteArray(MAX_PROBE_BYTES)'));
      // And only ONE cap constant — two caps drift apart.
      final caps = RegExp(
        r'const val MAX_\w*_?PROBE\w*_?BYTES',
      ).allMatches(media);
      expect(caps, hasLength(1));
    });

    test('an LRU capped at 200, keyed package + URI', () {
      expect(media, contains('const val MAX_CACHE_ENTRIES = 200'));
      expect(media, contains('removeEldestEntry'));
      expect(media, contains('size > MAX_CACHE_ENTRIES'));
      // The key composes the package with the URI string — a URI readable
      // for one app must never be answered from another app's result.
      expect(media, contains(r'"$packageName|${uri.toString()}"'));
      expect(media, contains(r'"$packageName|${candidate.uri?.toString()}"'));
    });

    test('only the content scheme is ever opened', () {
      final probe = functionBody(media, 'private fun probeUncached(');
      final gate = probe.indexOf('!= "content"');
      expect(gate, greaterThanOrEqualTo(0), reason: 'scheme gate missing');
      final open = probe.indexOf('openInputStream');
      expect(open, greaterThan(gate), reason: 'the gate must precede any open');
      // capture() applies the same rule to the copy path.
      expect(media, contains('uri.scheme != "content"'));
    });

    test('capture sizes and allowlists before reading a byte', () {
      final capture = functionBody(media, 'fun capture(');
      final gate = capture.indexOf('openInputStream');
      expect(gate, greaterThanOrEqualTo(0));
      final before = capture.substring(0, gate);
      expect(before, contains('kindOf(candidate.mimeType)'));
      expect(before, contains('if (kind == "image") MAX_IMAGE_BYTES'));
      expect(before, contains('openAssetFileDescriptor')); // declared length
      expect(media, contains('MAX_IMAGE_BYTES = 3 * 1024 * 1024'));
      expect(media, contains('MAX_AUDIO_BYTES = 8 * 1024 * 1024'));
      expect(media, contains('MAX_MEDIA_ITEMS_PER_MESSAGE = 4'));
    });

    test('EXTRA_PICTURE is recorded, never attached', () {
      // The origin label is what keeps a conversation avatar from being
      // persisted as this message's photo — so it is pinned on BOTH sides of
      // the line the avatar may never cross.
      expect(media, contains('MediaOrigin.NOTIFICATION_PICTURE'));
      final candidates = functionBody(media, 'fun mediaCandidates(');
      expect(candidates, contains('bigPicture'));
      expect(candidates, contains('NOTIFICATION_PICTURE'));
      // capture() refuses everything that is not a per-message attachment.
      final capture = functionBody(media, 'fun capture(');
      expect(
        capture,
        contains('candidate.origin != MediaOrigin.MESSAGE_ATTACHMENT'),
      );
      // The listener's comment about bigPictureUri and the settings copy both
      // rely on the lowercase wire label matching Dart's.
      expect(media, contains('fun label(): String = name.lowercase()'));
    });
  });

  group('the spool wire format and its single owner', () {
    test('no placeholder-body strings', () {
      // The old promise was "photos appear as a placeholder". If a
      // '[photo]'-style body ever reappears in the listener, it is a silent
      // wire-format change that Dart's dedupe was never designed for.
      for (final forbidden in [
        "[photo]",
        "[Photo]",
        '[voice]',
        "[audio]",
        '[Attachment]',
      ]) {
        for (final line in codeLines(listener)) {
          expect(
            line,
            isNot(contains(forbidden)),
            reason: 'the spool carries real media metadata or nothing: $line',
          );
        }
      }
      expect(listener, isNot(contains('Media is a placeholder')));
    });

    test('MessageSpool.kt never names a media path in code', () {
      // The spool may delete its own files (clear() removes the JSONL) —
      // what it may never do is reach for a media directory: a trim that
      // unlinked a sidecar an inbound_media row still references would
      // destroy a photo behind a live message.
      for (final line in codeLines(spool)) {
        expect(line, isNot(contains('exa_media')));
        expect(line, isNot(contains('incoming')));
        expect(line, isNot(contains('deleteRecursively')));
        if (line.contains('delete')) {
          expect(
            line,
            anyOf(
              contains('file(context)'),
              contains('.draining'),
              contains('part'),
            ),
            reason:
                'the spool owns its file; media files belong to Dart: $line',
          );
        }
      }
    });

    test('the media line carries metadata, never bytes', () {
      final worker = blocksAfter(
        listener,
        'mediaProbeExecutor.execute',
      ).last; // the capture worker (second submission)
      for (final key in [
        '"kind"',
        '"mime_type"',
        '"file"',
        '"size_bytes"',
        '"content_hash"',
        '"origin"',
      ]) {
        expect(worker, contains(key));
      }
      expect(worker, contains('media_unreadable'));
      expect(worker, isNot(contains('base64')));
      expect(worker, isNot(contains('readBytes')));
    });
  });

  group('the matrix survives an adb session', () {
    test('persisted per package with the device surface', () {
      expect(
        chatPackages,
        contains('const val KEY_MEDIA_PROBE_REPORT = "media_probe_report"'),
      );
      expect(chatPackages, contains('MAX_PROBE_RECORDS_PER_PACKAGE = 8'));
      for (final deviceField in [
        '"release"',
        '"manufacturer"',
        '"model"',
        '"api"',
      ]) {
        expect(chatPackages, contains(deviceField));
      }
      // A hard cap so a probe can never grow SharedPreferences.
      expect(chatPackages, contains('MAX_PROBE_REPORT_CHARS'));
    });

    test('exposed read-only over the existing channel', () {
      expect(channel, contains('"mediaProbeReport"'));
      expect(channel, contains('ChatPackages.mediaProbeReport'));
      // Read-only: no setter path for the report anywhere on the channel.
      expect(channel, isNot(contains('recordMediaProbe')));
    });
  });
}
