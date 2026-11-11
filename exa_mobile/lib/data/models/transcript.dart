/// A saved voice transcript. Audio is never stored - only the transcribed
/// text and an optional AI-generated summary, so a transcript can be edited
/// and revisited later without any recording on disk.
class Transcript {
  final String id;
  final String title;
  final String content;
  final String? summary;
  final DateTime createdAt;
  final DateTime updatedAt;

  const Transcript({
    required this.id,
    required this.title,
    required this.content,
    this.summary,
    required this.createdAt,
    required this.updatedAt,
  });

  Map<String, Object?> toRow() => {
        'id': id,
        'title': title,
        'content': content,
        'summary': summary,
        'created_at': createdAt.toIso8601String(),
        'updated_at': updatedAt.toIso8601String(),
      };

  factory Transcript.fromRow(Map<String, Object?> row) => Transcript(
        id: row['id'] as String,
        title: row['title'] as String,
        content: row['content'] as String,
        summary: row['summary'] as String?,
        createdAt: DateTime.tryParse(row['created_at'] as String? ?? '') ??
            DateTime.now(),
        updatedAt: DateTime.tryParse(row['updated_at'] as String? ?? '') ??
            DateTime.now(),
      );
}
