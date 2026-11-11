import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../../data/models/inbound_media.dart';
import '../../data/models/inbound_message.dart';
import '../../data/repositories/inbound_media_repository.dart';
import '../../data/repositories/settings_repository.dart';
import 'message_channels.dart';
import 'messaging_bridge.dart';

/// Reads the notification listener's handover file.
///
/// Deliberately file-based rather than a platform channel: the drain runs in
/// the WorkManager isolate, whose Flutter engine never sees the channels
/// `MainActivity` registers, so a channel would work in the foreground and
/// silently do nothing in the background — the half that matters, since the
/// point is Exa noticing messages while the app is closed. See
/// `MessageSpool.kt` for the other side.
///
/// ### Finding the file
///
/// The path is *asked for* over the bridge and then cached in `settings`,
/// rather than derived from `getApplicationSupportDirectory()`. Both resolve
/// to the app's `filesDir` on Android today, but that is path_provider's
/// implementation detail, not a contract — and if it ever changed, the
/// failure mode is capture that appears to work and quietly ingests nothing.
/// The derived path stays as a last resort so a background isolate that has
/// never seen the bridge still has somewhere to look.
///
/// ### Media lines
///
/// Since media capture, a message that carried photo or voice-note bytes is
/// spooled as **two** lines: the text line, unchanged, and a media line the
/// capture worker appends once the copy has finished. The media line repeats
/// the identity fields and adds either `"media": [...]` or
/// `"media_unreadable": <count>`. Neither line ever carries bytes — the
/// spool is a 512 KB append-only buffer, and a single base64 photo would
/// evict half the waiting messages just to arrive. The bytes live in
/// `<dirname(spool)>/exa_media/incoming/<sha256>.<ext>` sidecars, and this
/// reader trusts a media entry only after the sidecar on disk matches its
/// declared size and hash (see [_validatedMessage]).
class MessageSpoolReader {
  MessageSpoolReader({
    this.settings,
    this.bridge = const MessagingBridge(),
    this.overridePath,
  });

  /// Caches the authoritative path so background isolates can find it.
  final SettingsRepository? settings;
  final MessagingBridge bridge;

  /// Test seam; also used by the export importer's tests.
  final String? overridePath;

  static const settingsKey = 'message_spool_path';
  static const fileName = 'exa_message_spool.jsonl';

  /// Suffix for the in-flight copy. A drain renames before reading so
  /// messages arriving mid-drain are not lost with the file.
  static const _drainingSuffix = '.draining';

  /// Sidecar directory, relative to the spool. Mirrors `exa_media/incoming`
  /// in the Kotlin capture; the two strings must stay identical, which is
  /// why neither derives it from an app-specific path API.
  static const mediaDirName = 'exa_media';
  static const mediaIncomingName = 'incoming';

  static const _uuid = Uuid();

  /// Unanchored clone of [InboundMediaRepository.sidecarPattern], with token
  /// boundaries so a name found mid-line is exactly one name: the anchored
  /// pattern only ever matches a whole line, which a JSON spool line never
  /// is. Look-around keeps a 64-hex hash from surrendering a fake
  /// ``32-hex.<ext>`` prefix.
  static final _sidecarToken = RegExp(
    r'(?<![0-9a-f])[0-9a-f]{32}\.[a-z0-9]{1,5}(?![0-9a-z.])',
  );

  Future<String?> resolvePath() async {
    if (overridePath != null) return overridePath;

    final cached = await settings?.getValue(settingsKey);
    if (cached != null && cached.isNotEmpty) return cached;

    // Broad catch, unusually: reaching a MethodChannel needs an initialized
    // binding, and failing that is an assertion rather than the
    // MissingPluginException the bridge already handles. This runs inside a
    // background job whose contract is "never throws", and there is a
    // perfectly good fallback below.
    String? native;
    try {
      native = await bridge.spoolPath();
    } catch (_) {
      native = null;
    }
    if (native != null && native.isNotEmpty) {
      await settings?.setValue(settingsKey, native);
      return native;
    }

    try {
      // Same directory `filesDir` resolves to on Android, kept only as a
      // last resort for the case above.
      final dir = await getApplicationSupportDirectory();
      return p.join(dir.path, fileName);
    } catch (_) {
      // No platform channel at all (tests, desktop): there is nothing to
      // drain, which is a valid answer rather than an error.
      return null;
    }
  }

  /// Where the capture stage writes sidecars: next to the spool, so one
  /// cached path tells the drain about both. Null when the spool itself
  /// cannot be located, which also means no media can be validated.
  Future<String?> resolveMediaDir() async {
    final path = await resolvePath();
    if (path == null) return null;
    return p.join(p.dirname(path), mediaDirName, mediaIncomingName);
  }

  /// Takes everything currently spooled.
  ///
  /// Never throws: this runs inside a background job, and a malformed spool
  /// must degrade to "captured nothing this run" rather than failing the run
  /// that also syncs mail.
  Future<List<InboundMessage>> drain() async {
    final path = await resolvePath();
    if (path == null) return const [];

    final messages = <InboundMessage>[];
    final mediaDir = await resolveMediaDir();
    try {
      // A drain killed mid-flight leaves one of these behind. Recovering it
      // first is why the rename is safe: nothing is lost by crashing, only
      // delayed, and the unique index absorbs anything read twice.
      final leftovers = await _leftovers(path);
      for (final leftover in leftovers) {
        messages.addAll(await _consume(leftover, mediaDir: mediaDir));
      }

      final source = File(path);
      if (await source.exists()) {
        final target = File('$path$_drainingSuffix.${_uuid.v4()}');
        await source.rename(target.path);
        messages.addAll(await _consume(target, mediaDir: mediaDir));
      }
    } on FileSystemException {
      // Another isolate renamed it first, or the directory is gone. Both
      // mean "nothing for us this time".
      return messages;
    } catch (_) {
      return messages;
    }
    return messages;
  }

  Future<List<File>> _leftovers(String path) async {
    try {
      final dir = Directory(p.dirname(path));
      if (!await dir.exists()) return const [];
      final base = p.basename(path);
      return dir
          .listSync()
          .whereType<File>()
          .where((f) => p.basename(f.path).startsWith('$base$_drainingSuffix'))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  /// The sidecar names still named by spool lines on disk — the live file
  /// plus any in-flight `.draining` leftovers.
  ///
  /// The orphan sweep asks this before deleting anything, and it asks the
  /// *raw text* rather than parsed messages deliberately: a line this drain
  /// never managed to parse (corrupt JSON, a media line whose sidecar
  /// failed validation) still proves a media line is pending, and deleting
  /// the file it names would destroy bytes a future drain is meant to
  /// attach.
  Future<Set<String>> pendingMediaNames() async {
    final path = await resolvePath();
    if (path == null) return const {};
    final names = <String>{};
    try {
      final dir = Directory(p.dirname(path));
      if (!await dir.exists()) return const {};
      final base = p.basename(path);
      final files = dir.listSync().whereType<File>().where((f) {
        final name = p.basename(f.path);
        return name == base || name.startsWith('$base$_drainingSuffix');
      }).toList();
      for (final file in files) {
        try {
          final lines = await file.readAsLines();
          for (final line in lines) {
            for (final match in _sidecarToken.allMatches(line)) {
              names.add(match.group(0)!);
            }
          }
        } catch (_) {
          // An unreadable spool keeps its files one more sweep cycle; that
          // is the safe direction — the other one is unrecoverable.
        }
      }
    } catch (_) {
      return names;
    }
    return names;
  }

  Future<List<InboundMessage>> _consume(File file, {String? mediaDir}) async {
    try {
      final lines = await file.readAsLines();
      await file.delete();
      // The drain takes the *validated* path: text-only lines are identical
      // either way, and a media line only becomes media rows once its
      // sidecar has actually proven its bytes.
      return mediaDir == null
          ? parseLines(lines)
          : await parseLinesValidated(lines, mediaDir: mediaDir);
    } catch (_) {
      // Leave the file in place: a read that failed once may succeed next
      // run, and deleting it would be the one irreversible move here.
      return const [];
    }
  }

  /// Parses spool lines into messages. Synchronous for the text path;
  /// media entries come back with their **shape** validated only — the
  /// byte-level checks are the async [parseLinesValidated] pass the drain
  /// performs, because a media entry that claims 1.2 MB and hashes to
  /// something else is a corrupt line, not a message.
  ///
  /// A malformed line is skipped rather than aborting the batch: losing one
  /// captured message beats a queue that never moves again.
  static List<InboundMessage> parseLines(
    Iterable<String> lines, {
    String? mediaDir,
  }) {
    final messages = <InboundMessage>[];
    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      Object? decoded;
      try {
        decoded = jsonDecode(trimmed);
      } catch (_) {
        continue;
      }
      if (decoded is! Map) continue;
      final message = fromSpoolEntry(
        decoded.cast<String, Object?>(),
        mediaDir: mediaDir,
      );
      if (message != null) messages.add(message);
    }
    return messages;
  }

  /// [parseLines] plus the sidecar verification (exists, declared size,
  /// declared sha256), with each affected message's substitute note
  /// rewritten to match what actually survived validation. [mediaDir] is
  /// the directory the names resolve in.
  static Future<List<InboundMessage>> parseLinesValidated(
    Iterable<String> lines, {
    required String mediaDir,
  }) async {
    final out = <InboundMessage>[];
    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      Object? decoded;
      try {
        decoded = jsonDecode(trimmed);
      } catch (_) {
        continue;
      }
      if (decoded is! Map) continue;
      final entry = decoded.cast<String, Object?>();
      final message = fromSpoolEntry(entry, mediaDir: mediaDir);
      if (message == null) continue;
      if (message.media.isEmpty) {
        out.add(message);
        continue;
      }
      final unreadable = _unreadableDeclared(entry);
      out.add(await _validatedMessage(message, unreadable, mediaDir));
    }
    return out;
  }

  /// Verifies each candidate sidecar and rewrites the note to tell the
  /// truth about what is missing. A message never dies here: a media line
  /// whose every sidecar fails still stores the message, empty-bodied, with
  /// the could-not-read note — otherwise "Exa silently lost my photo" is
  /// indistinguishable from "it was never sent".
  static Future<InboundMessage> _validatedMessage(
    InboundMessage message,
    int declaredUnreadable,
    String mediaDir,
  ) async {
    final kept = <InboundMedia>[];
    for (final candidate in message.media) {
      if (await sidecarOk(candidate, mediaDir)) kept.add(candidate);
    }
    final failed = message.media.length - kept.length;
    if (failed == 0) return message;
    // The note is rebuilt from what survived: claiming a stored photo the
    // validator just rejected would be the one lie the inbox must never
    // tell, because the model repeats whatever the note says.
    final note = buildNote(kept, declaredUnreadable + failed);
    return message.copyWith(media: kept, summary: note.isEmpty ? null : note);
  }

  /// The one implementation of media-path trust in the app.
  ///
  /// A media row's `file_name` came off a text file, so nobody may open it
  /// before this has answered: the name is one the capture could have written
  /// ([InboundMediaRepository.sidecarPattern]), the path it resolves to is
  /// inside [mediaDir], the file exists, its length equals the row's declared
  /// size and its sha256 equals the row's content hash. Both readers of
  /// captured media call it — the drain's [_validatedMessage] and the
  /// transcription pass (`MessageIngestService.transcribePending`) — and no
  /// other file re-implements any part of the check. Callers obtain [mediaDir]
  /// from [resolveMediaDir] only.
  static Future<bool> sidecarOk(InboundMedia media, String mediaDir) async {
    final name = media.fileName;
    if (name == null || !InboundMediaRepository.sidecarPattern.hasMatch(name)) {
      return false;
    }
    // The name is pattern-locked, so joining cannot escape, but the check is
    // belt-and-braces because the path string came off a text file.
    final resolved = p.normalize(p.join(mediaDir, name));
    if (!p.isWithin(mediaDir, resolved)) return false;
    try {
      final file = File(resolved);
      if (!await file.exists()) return false;
      if (await file.length() != media.sizeBytes) return false;
      final digest = await InboundMediaRepository.sha256Of(resolved);
      return digest == media.contentHash;
    } catch (_) {
      return false;
    }
  }

  /// The text that stands in for media everywhere only text travels: the
  /// `summary` column (inbox row, chat preview, digest scope text) and the
  /// note a text-only model receives. Composition lives in one function so
  /// the reader, the ingest service and the tools can never drift apart.
  static String buildNote(List<InboundMedia> kept, int unreadable) {
    final parts = <String>[
      if (kept.isNotEmpty) [for (final m in kept) m.note].join(', '),
      if (unreadable > 0) InboundMedia.couldNotReadNote(unreadable),
    ];
    return parts.join(' ');
  }

  static int _unreadableDeclared(Map<String, Object?> entry) {
    final value = entry['media_unreadable'];
    return value is int && value > 0 ? value : 0;
  }

  /// One spool entry → one message, or null when it is unusable.
  ///
  /// With [mediaDir] given, media entries are parsed into candidates rooted
  /// there (their bytes verified later); without it a media-bearing entry
  /// still parses, because rejecting the *message* for a file this call
  /// cannot even look at would throw away text that shares the line.
  static InboundMessage? fromSpoolEntry(
    Map<String, Object?> entry, {
    String? mediaDir,
  }) {
    final channel = entry['channel'] as String?;
    final body = (entry['body'] as String?)?.trim();
    final conversationId = entry['conversation_id'] as String?;
    if (channel == null || conversationId == null || conversationId.isEmpty) {
      return null;
    }
    // A channel this build does not know about cannot be rendered or replied
    // to, so storing it would only produce rows nothing can act on.
    if (!MessageChannels.isKnown(channel)) return null;

    final media = _parseMedia(entry, mediaDir: mediaDir);
    final unreadable = _unreadableDeclared(entry);
    // A body-less entry used to be dropped unconditionally. It is still
    // dropped unless the line says *why* it has no body — either media was
    // captured or the capture failed — because that media line is exactly
    // what a media-only message is, and throwing it away would keep media
    // invisible while making it look like it never arrived.
    if (body == null || body.isEmpty) {
      if (media.isEmpty && unreadable == 0) return null;
    }
    final effectiveBody = body ?? '';

    final sentAtMillis = entry['sent_at'];
    final sentAt = sentAtMillis is int && sentAtMillis > 0
        ? DateTime.fromMillisecondsSinceEpoch(sentAtMillis)
        : null;
    final sender = (entry['sender'] as String?)?.trim();
    final now = DateTime.now();

    final note = media.isEmpty && unreadable == 0
        ? null
        : buildNote(media, unreadable);

    return InboundMessage(
      id: _uuid.v4(),
      channel: channel,
      conversationId: conversationId,
      conversationTitle: entry['conversation_title'] as String?,
      isGroup: entry['is_group'] == true,
      sender: sender == null || sender.isEmpty ? null : sender,
      body: effectiveBody,
      // The note, not a body preview: for a media-only message this *is*
      // its preview, and the inbox, the chat list and the digest's scope
      // filter all read `summary`, which is the point.
      summary: note,
      sentAt: sentAt,
      source: MessageSource.notification,
      externalId: InboundMessage.fingerprint(
        channel: channel,
        conversationId: conversationId,
        sender: sender,
        sentAt: sentAt,
        body: effectiveBody,
        // Only meaningful (and only included by fingerprint) when the body
        // is blank — see InboundMessage.fingerprint.
        mediaDigests: [for (final m in media) m.contentHash],
      ),
      packageName: entry['package'] as String?,
      canReply: entry['can_reply'] == true,
      createdAt: now,
      media: media,
    );
  }

  /// Parses and *shape*-checks the `media` array: bare 32-hex sidecar names
  /// only — a path separator, a `..`, an absolute path, or any name the
  /// capture could not have written, is dropped as a bad entry while the
  /// rest of the line is kept. Byte-level verification is later
  /// ([_validatedMessage]).
  static List<InboundMedia> _parseMedia(
    Map<String, Object?> entry, {
    String? mediaDir,
  }) {
    final raw = entry['media'];
    if (raw is! List) return const [];
    final hashPattern = RegExp(r'^[0-9a-f]{32}$');
    final out = <InboundMedia>[];
    for (final item in raw) {
      if (item is! Map) continue;
      final kind = item['kind'] as String?;
      final file = item['file'] as String?;
      final hash = item['content_hash'] as String?;
      if (kind != InboundMedia.kindImage && kind != InboundMedia.kindAudio) {
        continue;
      }
      if (file == null ||
          !InboundMediaRepository.sidecarPattern.hasMatch(file)) {
        continue;
      }
      if (hash == null || !hashPattern.hasMatch(hash.toLowerCase())) {
        continue;
      }
      final size = (item['size_bytes'] as num?)?.toInt();
      final mime = (item['mime_type'] as String?)?.trim();
      // The path is rooted in the media directory the moment the name is
      // parsed, so no later reader ever has to guess where a bare basename
      // lives; without a media directory (a pure unit test) the name alone
      // stays, and [sidecarOk] rejects the candidate — the message still
      // lands with the honest could-not-read note.
      final filePath = mediaDir == null ? file : p.join(mediaDir, file);
      out.add(
        InboundMedia(
          id: _uuid.v4(),
          // The ingest service knows the row this ends up on; a candidate
          // parsed here does not yet.
          messageId: '',
          kind: kind!,
          mimeType: mime == null || mime.isEmpty ? null : mime,
          filePath: filePath,
          fileName: file,
          sizeBytes: size,
          contentHash: hash.toLowerCase(),
          createdAt: DateTime.now(),
        ),
      );
    }
    return out;
  }
}
