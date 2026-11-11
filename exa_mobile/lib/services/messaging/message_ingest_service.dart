import 'package:path/path.dart' as p;

import '../../data/models/inbound_media.dart';
import '../../data/models/inbound_message.dart';
import '../../data/repositories/inbound_media_repository.dart';
import '../../data/repositories/inbound_message_repository.dart';
import '../../data/repositories/settings_repository.dart';
import '../transcription/audio_transcriber.dart';
import 'chat_export_importer.dart';
import 'message_channels.dart';
import 'message_spool_reader.dart';

/// The outcome of draining captured chat messages.
///
/// Shaped like [MailSyncSummary] because the job runner asks it the same
/// three questions: did it fail outright, did anything change, and what do we
/// tell the user.
class MessageSyncSummary {
  const MessageSyncSummary({
    required this.added,
    required this.captured,
    required this.pruned,
    required this.summary,
    this.mediaStored = 0,
    this.errors = const [],
  });

  /// Messages that were new. The number that matters.
  final int added;

  /// Everything read out of the spool, duplicates included. WhatsApp re-posts
  /// a chat's recent messages on every arrival, so `captured` is routinely
  /// several times `added` and the difference is normal, not a fault.
  final int captured;
  final int pruned;
  final String summary;

  /// Photos and voice notes newly stored this run. Said out loud because a
  /// user who just watched a photo arrive and sees only "2 new messages"
  /// has no way to know Exa kept the picture too.
  final int mediaStored;
  final List<String> errors;

  bool get hasChanges => added > 0;
  bool get hasErrors => errors.isNotEmpty;

  /// Nothing here can fail the way a mail login can: the spool is a local
  /// file and an unreadable one is retried next run. Kept so the job runner
  /// can treat mail and chat identically.
  bool get failedCompletely => false;
}

/// The outcome of one voice-note transcription pass.
///
/// Shaped like [MessageSyncSummary] because the chat-sync job asks it the
/// same three questions: did the endpoint fail, did anything change, and what
/// do we tell the user. The counts are deliberately about *the pass*, not
/// about the table: [attempted] is how many questions the provider got, which
/// is the number the user is paying for.
class TranscriptPassSummary {
  const TranscriptPassSummary({
    required this.attempted,
    required this.transcribed,
    required this.failed,
    required this.skipped,
    this.unusable = 0,
    this.moreWaiting = false,
    this.blockedWith,
  });

  /// The pass could not run at all — no transcription endpoint, no media
  /// directory. Every count is zero and [summary] is this one sentence, so a
  /// job report says *why* nothing happened instead of reporting nothing.
  TranscriptPassSummary.blocked(String reason)
      : this(
          attempted: 0,
          transcribed: 0,
          failed: 0,
          skipped: 0,
          blockedWith: reason,
        );

  /// Distinct voice notes (content hashes) this pass asked the endpoint about.
  /// The item budget counts these, not rows: the same note carried by two
  /// messages is one question, and [skipped] rows are not questions at all.
  final int attempted;

  /// Attempts that came back with words.
  final int transcribed;

  /// Attempts the endpoint could not answer — down, slow, or in error. These
  /// are retryable, and they are the only count that moves the circuit
  /// breaker: a voice note parked past its attempt cap is still on disk with
  /// its note, not lost.
  final int failed;

  /// Candidates the pass never asked about, because the row's `file_name` is
  /// not a sidecar it may open ([MessageSpoolReader.sidecarOk] said no). The
  /// row is left exactly as it was found: not asked, not attempted, not
  /// failed.
  final int skipped;

  /// Attempts that ended terminally without words: the audio held none, or
  /// the endpoint will not take this audio. Counted apart from [failed]
  /// because these are answers, not faults — they close the breaker's
  /// failure count rather than raising it, and the rows are never offered
  /// again.
  final int unusable;

  /// The pass stopped on its item cap or time slice with candidates still
  /// unasked, so the caller can say "more next run" truthfully.
  final bool moreWaiting;

  /// Why the whole pass was skipped, or null when it ran. Display-safe by
  /// construction: the wording is this file's, never a provider response.
  final String? blockedWith;

  bool get hasChanges => transcribed > 0;
  bool get hasErrors => failed > 0;

  /// The line the job report and the reliability screen show. It always names
  /// voice-note transcription, so a run that failed to transcribe is not
  /// readable as a run that had nothing to do.
  String get summary {
    if (blockedWith != null) return blockedWith!;
    final parts = <String>[
      if (transcribed > 0) '$transcribed transcribed',
      if (failed > 0) '$failed failed',
      if (unusable > 0) '$unusable could not be transcribed',
      if (skipped > 0) '$skipped skipped',
    ];
    if (parts.isEmpty) {
      return moreWaiting
          ? 'Voice-note transcription ran out of time this run; the voice '
                'notes still waiting keep their place in the queue.'
          : 'No voice notes were waiting to be transcribed.';
    }
    return 'Voice-note transcription: ${parts.join(', ')}'
        '${moreWaiting ? ', more next run' : ''}.';
  }
}

/// Brings captured chat messages into the database.
///
/// Everything that reaches [messages] does so through here or through
/// [SharedIntakeService], so dedupe, retention and provenance have one home
/// rather than one per entry point. Media is handled in the same pass as the
/// messages it belongs to: rows first, files then checked by the reader
/// before this ever saw them, spool line last — the order that makes a
/// crash between any two steps lose only work, never bytes a row points at.
class MessageIngestService {
  MessageIngestService({
    required this.messages,
    required this.settings,
    InboundMediaRepository? media,
    MessageSpoolReader? spool,
    this.importer = const ChatExportImporter(),
    this.audioTranscriber,
  }) : spool = spool ?? MessageSpoolReader(settings: settings) {
    // The message repository must be able to take media rows with the
    // messages it prunes and deletes; when both were handed one, they must
    // be the same instance, not two objects counting references apart.
    final wired = messages.mediaRepository;
    if (media == null) {
      _media = wired;
    } else {
      assert(
        wired == null || identical(wired, media),
        'InboundMessageRepository and MessageIngestService were given '
        'different InboundMediaRepository instances',
      );
      _media = media;
    }
  }

  final InboundMessageRepository messages;
  final SettingsRepository settings;
  final MessageSpoolReader spool;
  final ChatExportImporter importer;

  /// The file-audio capability [transcribePending] uses, or null when this
  /// build has no transcription wired. Null is a state, not an oversight: the
  /// pass then reports itself unavailable in one line and touches nothing,
  /// which is what a phone whose user never set a local AI server should do.
  final AudioTranscriber? audioTranscriber;

  /// The media repository, preferring the one already wired into [messages]
  /// so there is exactly one object deciding when a sidecar file dies.
  /// Null only when this build has no media support wired (a bare unit
  /// test): media lines then still store their messages with the honest
  /// could-not-read note, which beats losing them.
  InboundMediaRepository? get mediaRepository => _media;
  InboundMediaRepository? _media;

  /// Mirrors the native capture switch into the database.
  ///
  /// The switch itself lives in SharedPreferences, because the notification
  /// listener has to read it with no Flutter engine alive. This copy exists
  /// for the opposite reason: the background isolate that writes the job
  /// report cannot reach the platform channel, and "captured nothing" needs
  /// to be worded differently depending on whether capture is even on.
  static const captureEnabledKey = 'message_capture_enabled';

  Future<void> recordCaptureEnabled(bool enabled) =>
      settings.setValue(captureEnabledKey, enabled ? '1' : '0');

  Future<bool> isCaptureEnabled() async =>
      (await settings.getValue(captureEnabledKey)) == '1';

  Future<String> syncAll() async => (await syncAllDetailed()).summary;

  Future<MessageSyncSummary> syncAllDetailed() async {
    final drained = await spool.drain();

    // A drained line is a media line by its shape: no body, and either
    // media that passed validation or a note saying why there is none. The
    // Kotlin capture appends the text line synchronously and the media line
    // later, so the two arrive together in one drain or the media line
    // arrives in a later one — both shapes must land in the same message.
    final textLines = <InboundMessage>[];
    final mediaLines = <InboundMessage>[];
    for (final message in drained) {
      if (message.body.isEmpty &&
          (message.media.isNotEmpty ||
              (message.summary?.isNotEmpty ?? false))) {
        mediaLines.add(message);
      } else {
        textLines.add(message);
      }
    }

    // Text rows first: the media line's whole job is to find its text
    // message, and that only works if the message it identifies — from
    // this drain or an earlier one — is already a row.
    final added = <InboundMessage>[];
    var mediaStored = 0;
    added.addAll(await messages.addAll(textLines));
    for (final line in mediaLines) {
      final outcome = await _ingestMediaLine(line);
      added.addAll(outcome.messages);
      mediaStored += outcome.mediaStored;
    }

    // prune() removes the pruned rows' media through the shared repository
    // before deleting the messages, so no sidecar outlives its last row.
    final prunedIds = await messages.prune();
    final pruned = prunedIds.length;

    await _sweepOrphans();

    if (drained.isEmpty) {
      final enabled = await isCaptureEnabled();
      return MessageSyncSummary(
        added: 0,
        captured: 0,
        pruned: pruned,
        summary: enabled
            ? 'No new chat messages.'
            : 'Chat capture is off. Turn it on in Settings > Chat apps to let '
                'Exa read WhatsApp messages as they arrive.',
      );
    }

    final backlog = await messages.countUndigested();
    final buffer = StringBuffer();
    if (added.isEmpty) {
      // Worth saying out loud: a run that captured 40 and stored 0 looks
      // broken and is the normal steady state once a chat is up to date.
      buffer.write('No new chat messages (${drained.length} already seen).');
    } else {
      final chats = added.map((m) => m.conversationTitle ?? m.conversationId)
          .toSet();
      buffer.write('${added.length} new message'
          '${added.length == 1 ? '' : 's'} from ${chats.length} chat'
          '${chats.length == 1 ? '' : 's'}');
      if (chats.length <= 3) buffer.write(' (${chats.join(', ')})');
      if (mediaStored > 0) {
        buffer.write(
          ' — $mediaStored photo'
          '${mediaStored == 1 ? '' : 's'} or voice note'
          '${mediaStored == 1 ? '' : 's'} saved',
        );
      }
    }
    if (backlog > 0 && added.isNotEmpty) {
      buffer.write('. $backlog message${backlog == 1 ? '' : 's'} '
          '${backlog == 1 ? 'is' : 'are'} waiting to be digested');
    }

    return MessageSyncSummary(
      added: added.length,
      captured: drained.length,
      pruned: pruned,
      mediaStored: mediaStored,
      summary: buffer.toString(),
    );
  }

  /// Attaches one media line's media to the message it identifies, or
  /// stores the line itself as a media-only message.
  ///
  /// Resolution is by identity (channel, conversation, sender, second,
  /// notification-sourced) because the two lines have no shared content
  /// hash — see [InboundMessageRepository.findByIdentity] for why that is
  /// the accepted cost, and why re-posts cannot double up.
  Future<({List<InboundMessage> messages, int mediaStored})> _ingestMediaLine(
    InboundMessage line,
  ) async {
    final found = await messages.findByIdentity(
      channel: line.channel,
      conversationId: line.conversationId,
      sender: line.sender,
      sentAt: line.sentAt,
    );
    // A media-only row that already carries media is someone else's voice
    // note that merely shares this one's second — it is not this line's
    // parent. Only a message with a body (or a body-less row still waiting
    // for media that could not be read the first time) may adopt it.
    final existing =
        found != null && (found.body.isNotEmpty || found.media.isEmpty)
        ? found
        : null;
    if (existing != null) {
      final attached = await _attachMedia(existing, line.media);
      // A text row keeps its body preview; only a row that has nothing
      // text-shaped to show gets the note written into `summary` — which
      // is precisely where the inbox, the chat list and the digest look.
      if (existing.body.isEmpty &&
          (existing.summary == null || existing.summary!.isEmpty)) {
        final note = line.summary;
        if (note != null && note.isNotEmpty) {
          await messages.updateSummary(existing.id, note);
        }
      }
      return (messages: const <InboundMessage>[], mediaStored: attached);
    }
    // Nothing to attach to: this is a media-only message (or a text row the
    // drain somehow never saw). Store it whole — the fingerprint's media
    // digests keep an identical re-post from becoming a second row, while
    // two different voice notes from one sender in one second stay two.
    final stored = await messages.add(line);
    if (stored == null) {
      return (messages: const <InboundMessage>[], mediaStored: 0);
    }
    final count = await _attachMedia(stored, line.media);
    return (messages: [stored], mediaStored: count);
  }

  /// Inserts the candidate media rows for [message], skipping (and keeping
  /// honest notes about) any the file check inside
  /// [InboundMediaRepository.add] refuses. Returns how many were new.
  Future<int> _attachMedia(
    InboundMessage message,
    List<InboundMedia> candidates,
  ) async {
    final mediaRepository = this.mediaRepository;
    if (mediaRepository == null) return 0;
    var stored = 0;
    for (final candidate in candidates) {
      final added = await mediaRepository.add(
        messageId: message.id,
        kind: candidate.kind,
        mimeType: candidate.mimeType,
        filePath: candidate.filePath,
        fileName: candidate.fileName,
        sizeBytes: candidate.sizeBytes,
        contentHash: candidate.contentHash,
      );
      if (added != null) stored++;
    }
    return stored;
  }

  /// Removes media files that no row references and no pending spool line
  /// names, after every drain. Cheap, bounded, and the only thing that
  /// cleans up the cases the row-based lifecycle cannot reach: a spool
  /// trimmed away before its media line was ever read.
  Future<void> _sweepOrphans() async {
    final mediaRepository = this.mediaRepository;
    if (mediaRepository == null) return;
    final mediaDir = await spool.resolveMediaDir();
    if (mediaDir == null) return;
    final pending = await spool.pendingMediaNames();
    await mediaRepository.sweepOrphans(
      mediaDir: mediaDir,
      referencedNames: pending,
    );
  }

  /// Transcribes the captured voice notes the last drain stored, and stops
  /// when its budget is spent.
  ///
  /// Deliberately **not** part of the drain, and never called from
  /// [syncAllDetailed], [_ingestMediaLine] or [MessageSpoolReader]: the drain
  /// runs inside a background job whose contract is "read a local file and be
  /// done in seconds", while one transcription is an HTTP call to the user's
  /// local AI server that a whisper run can legitimately spend a minute on.
  /// Transcription therefore has its own entry point, which the chat-sync job
  /// calls right *after* the drain, with its own item cap, its own time slice
  /// and its own circuit breaker.
  ///
  /// What makes it safe to run often, on every wake-up, over a table full of
  /// rows that are mostly photos:
  ///
  /// * **Once each, for the life of the database.** The work list comes from
  ///   [InboundMediaRepository.pendingTranscriptions], which never offers a
  ///   content hash that already has words — the C4 sha256 is the dedupe key,
  ///   and it is what stops a `MessagingStyle` re-post (which re-presents
  ///   every recent message on each arrival) from costing a call per
  ///   notification. Two messages carrying the same forwarded note cost one
  ///   question, and the row that was not asked learns the answer through
  ///   [InboundMediaRepository.recordTranscription]'s mirroring.
  /// * **Bounded twice.** [maxItems] caps the distinct hashes this run may ask
  ///   about — counting *questions*, so a row skipped below costs the pass
  ///   nothing — and [timeBudget] stops it mid-list so the job keeps time for
  ///   what runs after it. [now] is when the pass started (default: now); a
  ///   caller testing the slice without sleeping passes a spent one. What is
  ///   left over is simply still pending next run.
  /// * **Provenanced.** A row's `file_name` is a string that came off a text
  ///   file, so nothing is opened before [MessageSpoolReader.sidecarOk] has
  ///   checked it against the directory [MessageSpoolReader.resolveMediaDir]
  ///   gives — the same single trust check the drain runs, never a second
  ///   implementation. A row that fails it is skipped untouched, which is also
  ///   the answer to a media row pointed at `../../secrets.txt`: no read, no
  ///   request, no attempt spent.
  ///
  /// Transcripts are written to the media row and never into
  /// `inbound_messages.body`, which [InboundMessage.fingerprint] hashes: a
  /// transcript landing must not be able to change a message's identity or
  /// revive it as a duplicate. The sidecar, the media row and its note all
  /// stay attached whichever way a call goes; a voice note is never dropped.
  Future<TranscriptPassSummary> transcribePending({
    int maxItems = 3,
    Duration? timeBudget,
    DateTime? now,
  }) async {
    final transcriber = audioTranscriber;
    if (transcriber == null || !await transcriber.isConfigured) {
      return TranscriptPassSummary.blocked(
        'Voice-note transcription is unavailable: no local AI server is '
        'configured. Set its address in Settings > AI provider to turn voice '
        'notes into text.',
      );
    }
    final mediaRepository = this.mediaRepository;
    if (mediaRepository == null) {
      return TranscriptPassSummary.blocked(
        'Voice-note transcription is unavailable: this build has no media '
        'store, so there is nothing to transcribe.',
      );
    }
    // The one source of the media directory. No directory means the spool
    // itself is unreachable, and a media row whose home cannot be resolved is
    // a row nothing may open — end the pass, owe no attempts.
    final mediaDir = await spool.resolveMediaDir();
    if (mediaDir == null) {
      return TranscriptPassSummary.blocked(
        'Voice-note transcription is unavailable: the media directory could '
        'not be found, so no audio could be checked.',
      );
    }

    // Asked for a little past the item budget on purpose: rows the sidecar
    // check rejects are not questions, and one corrupt name must not cost the
    // run the transcriptions it was allowed to make. The query is indexed and
    // bounded either way.
    final candidates = await mediaRepository.pendingTranscriptions(
      limit: maxItems + _skipHeadroom,
    );
    final deadline =
        timeBudget == null ? null : (now ?? DateTime.now()).add(timeBudget);

    final asked = <String>{};
    var transcribed = 0;
    var failed = 0;
    var unusable = 0;
    var skipped = 0;
    var moreWaiting = false;

    for (final candidate in candidates) {
      if (asked.length >= maxItems) {
        moreWaiting = true;
        break;
      }
      if (deadline != null && !DateTime.now().isBefore(deadline)) {
        moreWaiting = true;
        break;
      }
      final hash = candidate.contentHash;
      if (asked.contains(hash)) {
        // The same bytes on a second message. Already asked above; the answer
        // was written onto this row too, so it needs nothing here.
        continue;
      }
      final name = candidate.fileName;
      if (name == null ||
          !await MessageSpoolReader.sidecarOk(candidate, mediaDir)) {
        // Not a file this pipeline can vouch for. Left exactly as found: not
        // asked, so not counted against the budget, so offered again when its
        // row becomes readable — or swept when it stops being referenced.
        skipped++;
        continue;
      }

      final result = await transcriber.transcribeFile(
        // The path [MessageSpoolReader.sidecarOk] verified: the media
        // directory it checked, plus the name it pattern-locked.
        p.normalize(p.join(mediaDir, name)),
        mimeType: candidate.mimeType,
      );
      switch (result.status) {
        case TranscriptionStatus.done:
          asked.add(hash);
          await mediaRepository.recordTranscription(
            candidate.id,
            text: result.text,
            status: InboundMedia.statusDone,
          );
          transcribed++;
        case TranscriptionStatus.failed:
          asked.add(hash);
          await mediaRepository.recordTranscription(
            candidate.id,
            status: InboundMedia.statusFailed,
          );
          failed++;
        case TranscriptionStatus.empty:
          asked.add(hash);
          await mediaRepository.recordTranscription(
            candidate.id,
            status: InboundMedia.statusEmpty,
          );
          unusable++;
        case TranscriptionStatus.unsupported:
          asked.add(hash);
          await mediaRepository.recordTranscription(
            candidate.id,
            status: InboundMedia.statusUnsupported,
          );
          unusable++;
        case TranscriptionStatus.unavailable:
          // The endpoint went away between the gate and the call (the user
          // cleared its address while this pass ran). Nothing was really
          // asked, so the row owes no attempt: record nothing and stop.
          moreWaiting = true;
      }
      if (result.status == TranscriptionStatus.unavailable) break;
    }

    return TranscriptPassSummary(
      attempted: asked.length,
      transcribed: transcribed,
      failed: failed,
      skipped: skipped,
      unusable: unusable,
      moreWaiting: moreWaiting,
    );
  }

  /// How many extra candidates to look at beyond the item budget, so skipped
  /// rows cannot eat it. Small on purpose: it bounds the number of file
  /// checks a single pass performs, and the rest are still pending next run.
  static const _skipHeadroom = 5;

  /// Imports a WhatsApp chat export.
  ///
  /// Imported history arrives already digested. A year of back-messages is
  /// not a queue of things to act on — the user imported it to *ask about*,
  /// and dropping 5,000 messages into the digest backlog would have every
  /// background run for the next week working through a conversation that
  /// finished months ago.
  Future<({ChatExportResult result, int stored})> importExport(
    String content, {
    String? fileName,
    String? fallbackName,
    String channel = MessageChannels.whatsapp,
  }) async {
    final result = importer.parse(
      content,
      fileName: fileName,
      fallbackName: fallbackName,
      channel: channel,
    );
    if (!result.succeeded) return (result: result, stored: 0);

    final stored = await messages.addAll([
      for (final message in result.messages)
        InboundMessage(
          id: message.id,
          channel: message.channel,
          conversationId: message.conversationId,
          conversationTitle: message.conversationTitle,
          isGroup: message.isGroup,
          sender: message.sender,
          body: message.body,
          sentAt: message.sentAt,
          source: message.source,
          externalId: message.externalId,
          packageName: message.packageName,
          canReply: message.canReply,
          digested: true,
          createdAt: message.createdAt,
        ),
    ]);
    return (result: result, stored: stored.length);
  }
}
