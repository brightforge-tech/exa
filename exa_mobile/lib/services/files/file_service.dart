import 'dart:convert';
import 'dart:typed_data';

import 'package:docx_to_text/docx_to_text.dart';
import 'package:excel/excel.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:pdfrx/pdfrx.dart';

import '../../data/models/inbound_media.dart';

/// A file the user attached in chat, held in memory for the current turn.
/// Persisted (to the attachments table + disk) only if the user asks Exa to
/// store it - see AttachmentRepository.
class Attachment {
  Attachment({
    required this.name,
    required this.mimeType,
    required this.sizeBytes,
    required this.bytes,
    required this.kind,
  });

  final String name;
  final String mimeType;
  final int sizeBytes;
  final Uint8List bytes;

  /// One of: `image`, `audio`, `pdf`, `office`, `text`.
  final String kind;

  String get extension {
    final dot = name.lastIndexOf('.');
    return dot == -1 ? '' : name.substring(dot + 1).toLowerCase();
  }
}

/// Picks files and turns them into model-ready text / image content.
class FileService {
  /// Hard ceiling on a single attachment; larger files are rejected before we
  /// read them into the model context.
  static const maxFileBytes = 10 * 1024 * 1024; // 10 MB

  /// Per-file extracted-text cap (mirrors the browser-context limit) to keep
  /// documents from blowing the model's context window.
  static const maxExtractedChars = 12000;

  static const _imageExts = {
    'png',
    'jpg',
    'jpeg',
    'gif',
    'webp',
    'bmp',
    'heic'
  };

  /// Voice notes and audio files. The same kinds the notification capture
  /// copies, so a voice note arriving through either door behaves the same
  /// way downstream — one labelled note, never raw bytes to a provider.
  static const _audioExts = {
    'ogg',
    'opus',
    'm4a',
    'mp3',
    'aac',
    'amr',
    'wav',
    'flac',
  };

  /// Media size ceilings, shared with the Kotlin capture so a 40 MB upload
  /// and a 40 MB photo get the same answer from the same constant. Images
  /// stay at 3 MiB because staging goes through base64 into a vision
  /// provider's per-image limit.
  static const maxMediaImageBytes = 3 * 1024 * 1024;
  static const maxMediaAudioBytes = 8 * 1024 * 1024;

  /// The one media gate, answering *before* any bytes are read: null means
  /// "acceptable", anything else is a human-readable reason to refuse.
  ///
  /// Reject-before-reading is the point — a rejected 200 MB file must cost
  /// a stat, not a read into memory, and a rejection must be worded so the
  /// user (or the model) learns what happened instead of watching a silent
  /// drop. `kindForExtension` deliberately never returns `audio`... except
  /// now it does; anything still unclassifiable as media (video, archives,
  /// executables) is named in the reason rather than read and truncated.
  static String? rejectionReasonFor({
    required String name,
    required int sizeBytes,
  }) {
    final kind = kindForExtension(p.extension(name).replaceFirst('.', ''));
    if (kind != 'image' && kind != 'audio') {
      return 'Unsupported file type for media: ${p.basename(name)}';
    }
    final ceiling = kind == 'image' ? maxMediaImageBytes : maxMediaAudioBytes;
    if (sizeBytes > ceiling) {
      return '${kind == 'image' ? 'Image' : 'Audio'} is too large '
          '(${InboundMedia.formatBytes(sizeBytes)}; limit '
          '${InboundMedia.formatBytes(ceiling)}): ${p.basename(name)}';
    }
    return null;
  }

  Future<List<Attachment>> pick() async {
    final result = await FilePicker.pickFiles(
      allowMultiple: true,
      withData: true,
      type: FileType.any,
    );
    if (result == null) return const [];
    final attachments = <Attachment>[];
    for (final file in result.files) {
      final bytes = file.bytes;
      if (bytes == null) continue;
      // Oversized picks are rejected by name against the *reported* size,
      // before their bytes are turned into content - the picker already
      // loaded them into `bytes`, but nothing past this line pays for them.
      // (Chat uploads keep their own, generous [maxFileBytes] limit; the
      // stricter media ceilings in [rejectionReasonFor] apply to captured
      // media and to staging, where a model has to swallow the bytes.)
      if (bytes.length > maxFileBytes) continue;
      attachments.add(_fromBytes(file.name, bytes));
    }
    return attachments;
  }

  Attachment _fromBytes(String name, Uint8List bytes) {
    final ext = _extOf(name);
    final kind = kindForExtension(ext);
    return Attachment(
      name: name,
      mimeType: mimeTypeForExtension(ext),
      sizeBytes: bytes.length,
      bytes: bytes,
      kind: kind,
    );
  }

  bool isImage(Attachment a) => a.kind == 'image';

  bool isAudio(Attachment a) => a.kind == 'audio';

  bool isTooLarge(Attachment a) => a.sizeBytes > maxFileBytes;

  /// The substitute line for media text must stand in for: the same wording
  /// the inbox row and the message tools show, so the model, the settings
  /// screen and the spool note never say three different things about one
  /// photo.
  static String mediaNote({
    required String kind,
    String? mimeType,
    int? sizeBytes,
  }) => InboundMedia(
    id: '',
    messageId: '',
    kind: kind,
    mimeType: mimeType,
    filePath: '',
    sizeBytes: sizeBytes,
    contentHash: '',
    createdAt: DateTime(2000),
  ).note;

  /// Base64 + media type for image content blocks.
  ({String base64, String mediaType}) encodeImage(Attachment a) =>
      (base64: base64Encode(a.bytes), mediaType: a.mimeType);

  /// Raw base64 of the file bytes (used for the Anthropic PDF document block).
  String pdfBase64(Attachment a) => base64Encode(a.bytes);

  /// Extracts readable text from text/pdf/office attachments. Returns '' for
  /// images. Always truncated to [maxExtractedChars].
  Future<String> extractText(Attachment a) async {
    String text;
    try {
      text = switch (a.kind) {
        'text' => _decodeText(a.bytes),
        'pdf' => await _extractPdf(a.bytes),
        'office' => _extractOffice(a),
        // Audio has no text extractor here: transcription is deliberately
        // not part of this build, and returning '' would read as "the file
        // was empty" rather than "Exa does not transcribe". The caller
        // substitutes the media note; this never runs extractText on bytes.
        _ => '',
      };
    } catch (e) {
      return '[Could not read ${a.name}: $e]';
    }
    return _truncate(text);
  }

  // ----------------------------------------------------------- helpers --

  static String _extOf(String name) {
    final dot = name.lastIndexOf('.');
    return dot == -1 ? '' : name.substring(dot + 1).toLowerCase();
  }

  static String kindForExtension(String ext) {
    if (_imageExts.contains(ext)) return 'image';
    if (_audioExts.contains(ext)) return 'audio';
    if (ext == 'pdf') return 'pdf';
    if (ext == 'docx' || ext == 'xlsx') return 'office';
    return 'text';
  }

  static String mimeTypeForExtension(String ext) => switch (ext) {
    'png' => 'image/png',
    'jpg' || 'jpeg' => 'image/jpeg',
    'gif' => 'image/gif',
    'webp' => 'image/webp',
    'bmp' => 'image/bmp',
    'heic' => 'image/heic',
    'ogg' || 'opus' => 'audio/ogg',
    'm4a' => 'audio/mp4',
    'mp3' => 'audio/mpeg',
    'aac' => 'audio/aac',
    'amr' => 'audio/amr',
    'wav' => 'audio/wav',
    'flac' => 'audio/flac',
    'pdf' => 'application/pdf',
    'docx' =>
      'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'xlsx' =>
      'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    'csv' => 'text/csv',
    'md' => 'text/markdown',
    'json' => 'application/json',
    _ => 'text/plain',
  };

  static String _decodeText(Uint8List bytes) =>
      utf8.decode(bytes, allowMalformed: true);

  /// Reads the text layer page by page with PDFium (via pdfrx, MIT). Stops
  /// once there is more than [maxExtractedChars] of text, since the rest
  /// would be truncated anyway.
  static Future<String> _extractPdf(Uint8List bytes) async {
    await pdfrxFlutterInitialize();
    final document = await PdfDocument.openData(bytes);
    try {
      final out = StringBuffer();
      for (final page in document.pages) {
        final text = await page.loadText();
        if (text != null && text.fullText.isNotEmpty) {
          if (out.isNotEmpty) out.writeln();
          out.write(text.fullText);
        }
        if (out.length > maxExtractedChars) break;
      }
      return out.toString();
    } finally {
      await document.dispose();
    }
  }

  static String _extractOffice(Attachment a) {
    if (a.extension == 'docx') {
      return docxToText(a.bytes);
    }
    // xlsx: flatten every sheet into tab-separated rows.
    final excel = Excel.decodeBytes(a.bytes);
    final buffer = StringBuffer();
    for (final entry in excel.tables.entries) {
      buffer.writeln('# ${entry.key}');
      for (final row in entry.value.rows) {
        final cells = row
            .map((cell) => cell?.value?.toString() ?? '')
            .toList();
        if (cells.any((c) => c.isNotEmpty)) {
          buffer.writeln(cells.join('\t'));
        }
      }
    }
    return buffer.toString();
  }

  static String _truncate(String text) {
    if (text.length <= maxExtractedChars) return text;
    return '${text.substring(0, maxExtractedChars)}\n[truncated]';
  }
}
