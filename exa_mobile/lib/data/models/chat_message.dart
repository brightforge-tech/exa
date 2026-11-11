import 'dart:convert';

class ChatMessage {
  final String id;

  /// 'user' or 'assistant'.
  final String role;
  final String content;

  /// Optional metadata: tool calls made during the turn, navigation, errors.
  final Map<String, Object?>? meta;
  final DateTime createdAt;

  const ChatMessage({
    required this.id,
    required this.role,
    required this.content,
    this.meta,
    required this.createdAt,
  });

  Map<String, Object?> toRow() => {
        'id': id,
        'role': role,
        'content': content,
        'meta_json': meta == null ? null : jsonEncode(meta),
        'created_at': createdAt.toIso8601String(),
      };

  factory ChatMessage.fromRow(Map<String, Object?> row) {
    Map<String, Object?>? meta;
    final rawMeta = row['meta_json'] as String?;
    if (rawMeta != null && rawMeta.isNotEmpty) {
      try {
        meta = (jsonDecode(rawMeta) as Map).cast<String, Object?>();
      } catch (_) {
        meta = null;
      }
    }
    return ChatMessage(
      id: row['id'] as String,
      role: row['role'] as String,
      content: row['content'] as String,
      meta: meta,
      createdAt: DateTime.tryParse(row['created_at'] as String? ?? '') ??
          DateTime.now(),
    );
  }
}
