/// A file the user uploaded in chat and asked Exa to keep. Bytes live on
/// disk at [filePath]; the row carries metadata and the extracted text so the
/// agent can recall it without re-reading disk.
class AttachmentRecord {
  final String id;
  final String name;
  final String? mimeType;

  /// One of: `image`, `pdf`, `office`, `text`.
  final String? kind;
  final int? sizeBytes;
  final String filePath;
  final String? extractedText;
  final String? summary;
  final String source;
  final DateTime createdAt;

  const AttachmentRecord({
    required this.id,
    required this.name,
    this.mimeType,
    this.kind,
    this.sizeBytes,
    required this.filePath,
    this.extractedText,
    this.summary,
    this.source = 'chat',
    required this.createdAt,
  });

  Map<String, Object?> toRow() => {
        'id': id,
        'name': name,
        'mime_type': mimeType,
        'kind': kind,
        'size_bytes': sizeBytes,
        'file_path': filePath,
        'extracted_text': extractedText,
        'summary': summary,
        'source': source,
        'created_at': createdAt.toIso8601String(),
      };

  factory AttachmentRecord.fromRow(Map<String, Object?> row) =>
      AttachmentRecord(
        id: row['id'] as String,
        name: row['name'] as String,
        mimeType: row['mime_type'] as String?,
        kind: row['kind'] as String?,
        sizeBytes: row['size_bytes'] as int?,
        filePath: row['file_path'] as String,
        extractedText: row['extracted_text'] as String?,
        summary: row['summary'] as String?,
        source: row['source'] as String? ?? 'chat',
        createdAt: DateTime.tryParse(row['created_at'] as String? ?? '') ??
            DateTime.now(),
      );

  /// Compact form returned to the agent from file tools.
  Map<String, Object?> toAgentJson() => {
        'id': id,
        'name': name,
        if (kind != null) 'kind': kind,
        if (sizeBytes != null) 'size_bytes': sizeBytes,
        if (summary != null) 'summary': summary,
        'created_at': createdAt.toIso8601String(),
      };
}
