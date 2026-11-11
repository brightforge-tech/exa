/// One photo or voice note carried by a captured chat message.
///
/// The row is the index; the bytes live as a sidecar file under the media
/// directory next to the spool, named by its 32-hex content hash. The row
/// outlives nothing and nothing outlives the row: the repository deletes the
/// file only when this is the last row naming the path, so "where is the
/// photo?" always has exactly one answer.
///
/// A message whose media *could not* be read has no row at all — its note
/// lives on the message's `summary`. This model therefore only ever describes
/// media that is really on disk.
class InboundMedia {
  const InboundMedia({
    required this.id,
    required this.messageId,
    required this.kind,
    this.mimeType,
    required this.filePath,
    this.fileName,
    this.sizeBytes,
    required this.contentHash,
    this.transcriptText,
    this.transcriptStatus = statusNone,
    this.transcriptAttempts = 0,
    this.transcribedAt,
    required this.createdAt,
  });

  final String id;
  final String messageId;

  /// `image` or `audio` — the two kinds Exa copies. Anything else never
  /// reaches this table.
  final String kind;
  final String? mimeType;

  /// Absolute path of the sidecar inside the media directory.
  final String filePath;
  final String? fileName;
  final int? sizeBytes;

  /// 32-hex sha256 of the bytes, computed by the Kotlin capture and verified
  /// by Dart before a row is ever created.
  final String contentHash;

  /// Transcribed words for these bytes, or null when there are none.
  ///
  /// A null here answers nothing on its own — "not yet", "the endpoint was
  /// down", "the audio held no words" and "this file can never be
  /// transcribed" all look identical until [transcriptStatus] says which.
  /// Only `recordTranscription` writes it, and it writes a non-null value
  /// only together with [statusDone], so the pair can never disagree.
  final String? transcriptText;

  /// One of the five [status*] constants below: where this row stands in the
  /// transcription pass. Defaults to [statusNone] — for a row written by any
  /// build before v26 that is also the literal truth: it was never offered.
  final String transcriptStatus;

  /// How many times the pass has asked a provider about this row. Retries
  /// stop at the caller's cap; a terminal status stops them immediately.
  final int transcriptAttempts;

  /// When the transcript landed, or null until it does. Only ever set
  /// together with [statusDone].
  final DateTime? transcribedAt;
  final DateTime createdAt;

  static const kindImage = 'image';
  static const kindAudio = 'audio';

  /// The status vocabulary, spelled once here because the repository's
  /// queries, the pass's decisions and the tests' expectations all have to
  /// agree on the same five strings.
  ///
  /// - [statusNone]: never offered to a transcriber.
  /// - [statusDone]: the provider answered with words; [transcriptText]
  ///   carries them and the row is never offered again — nor is any row
  ///   sharing its [contentHash].
  /// - [statusEmpty]: the provider heard no words. Terminal: re-asking the
  ///   same bytes would only cost the same nothing again.
  /// - [statusFailed]: the endpoint was down, slow or unwell. Retryable
  ///   while [transcriptAttempts] is under the cap.
  /// - [statusUnsupported]: this audio cannot be transcribed here no matter
  ///   how often we ask (missing file, size gate, endpoint rejection).
  ///   Terminal.
  static const statusNone = 'none';
  static const statusDone = 'done';
  static const statusEmpty = 'empty';
  static const statusFailed = 'failed';
  static const statusUnsupported = 'unsupported';

  /// Whether this row carries usable transcribed words. The one question the
  /// read side (display bodies, the tools) actually asks — everything else
  /// about a transcript's history is the pass's business.
  bool get isTranscribed =>
      transcriptStatus == statusDone &&
      transcriptText != null &&
      transcriptText!.trim().isNotEmpty;

  /// The labelled line that stands in for the media wherever text is the
  /// only option: the inbox row, the conversation preview, the digest scope
  /// text, and the note a provider that cannot see images receives.
  ///
  /// It is deliberately honest about what Exa has — kind, mime type and size
  /// — because that is also the whole truth a text-only model can act on,
  /// and it never pretends to describe content Exa has not looked at.
  String get note {
    final label = kind == kindAudio ? 'Voice note' : 'Photo';
    final details = [
      if (mimeType != null && mimeType!.isNotEmpty) mimeType!,
      if (sizeBytes != null && sizeBytes! > 0) formatBytes(sizeBytes!),
    ].join(', ');
    return details.isEmpty ? label : '$label ($details)';
  }

  /// The one sentence that both users and models read when media was
  /// advertised but Exa could not open it. Kept here so the wording cannot
  /// drift between the spool reader, the tools and the digest.
  static String couldNotReadNote(int count) {
    final what = count == 1
        ? 'a photo or voice note'
        : '$count photos or voice notes';
    return 'Exa could not read $what from this message.';
  }

  /// Compact form returned to the agent from the message tools. Never bytes:
  /// media reaches a model only as this metadata until an image is asked for
  /// by id, and audio never reaches it as bytes at all.
  Map<String, Object?> toAgentJson() => {
    'id': id,
    'kind': kind,
    if (mimeType != null) 'mime_type': mimeType,
    if (sizeBytes != null) 'size_bytes': sizeBytes,
    if (transcriptText != null && transcriptText!.isNotEmpty)
      'transcript': transcriptText,
  };

  /// Human-readable byte size for notes and the inbox chip line ("1.2 MB").
  static String formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    const units = ['KB', 'MB', 'GB'];
    var value = bytes / 1024;
    var unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit++;
    }
    final text = value >= 10 || value == value.roundToDouble()
        ? value.toStringAsFixed(0)
        : value.toStringAsFixed(1);
    return '$text ${units[unit]}';
  }

  Map<String, Object?> toRow() => {
    'id': id,
    'message_id': messageId,
    'kind': kind,
    'mime_type': mimeType,
    'file_path': filePath,
    'file_name': fileName,
    'size_bytes': sizeBytes,
    'content_hash': contentHash,
    'transcript_text': transcriptText,
    'transcript_status': transcriptStatus,
    'transcript_attempts': transcriptAttempts,
    'transcribed_at': transcribedAt?.toIso8601String(),
    'created_at': createdAt.toIso8601String(),
  };

  factory InboundMedia.fromRow(Map<String, Object?> row) => InboundMedia(
    id: row['id'] as String,
    messageId: row['message_id'] as String,
    kind: row['kind'] as String,
    mimeType: row['mime_type'] as String?,
    filePath: row['file_path'] as String,
    fileName: row['file_name'] as String?,
    sizeBytes: row['size_bytes'] as int?,
    contentHash: row['content_hash'] as String,
    transcriptText: row['transcript_text'] as String?,
    // The defaults are the pre-v26 truth, spelled out rather than trusted
    // from the column: a hand-built fixture or a row from a build that never
    // saw the migration must still read as "never offered", not crash.
    transcriptStatus: row['transcript_status'] as String? ?? statusNone,
    transcriptAttempts: row['transcript_attempts'] as int? ?? 0,
    transcribedAt:
        DateTime.tryParse(row['transcribed_at'] as String? ?? ''),
    createdAt:
        DateTime.tryParse(row['created_at'] as String? ?? '') ?? DateTime.now(),
  );

  /// Whether a kind string is one Exa treats as message media. Kept as a
  /// helper on the model so FileService and the tools agree on the vocabulary
  /// without importing each other.
  static bool isMediaKind(String kind) =>
      kind == kindImage || kind == kindAudio;
}
