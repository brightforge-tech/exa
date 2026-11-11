import 'dart:convert';

class DynamicScreen {
  final String id;
  final String screenKey;
  final String title;
  final String? description;
  final Map<String, Object?> schema;
  final String createdBy;
  final bool isSaved;
  final DateTime createdAt;
  final DateTime updatedAt;

  const DynamicScreen({
    required this.id,
    required this.screenKey,
    required this.title,
    this.description,
    required this.schema,
    this.createdBy = 'agent',
    this.isSaved = false,
    required this.createdAt,
    required this.updatedAt,
  });

  Map<String, Object?> toRow() => {
        'id': id,
        'screen_key': screenKey,
        'title': title,
        'description': description,
        'schema_json': jsonEncode(schema),
        'created_by': createdBy,
        'is_saved': isSaved ? 1 : 0,
        'created_at': createdAt.toIso8601String(),
        'updated_at': updatedAt.toIso8601String(),
      };

  factory DynamicScreen.fromRow(Map<String, Object?> row) {
    Map<String, Object?> schema = const {};
    try {
      schema = (jsonDecode(row['schema_json'] as String? ?? '{}') as Map)
          .cast<String, Object?>();
    } catch (_) {
      // Invalid stored schema renders as an empty screen rather than crashing.
    }
    return DynamicScreen(
      id: row['id'] as String,
      screenKey: row['screen_key'] as String,
      title: row['title'] as String,
      description: row['description'] as String?,
      schema: schema,
      createdBy: row['created_by'] as String? ?? 'agent',
      isSaved: (row['is_saved'] as int? ?? 0) == 1,
      createdAt: DateTime.tryParse(row['created_at'] as String? ?? '') ??
          DateTime.now(),
      updatedAt: DateTime.tryParse(row['updated_at'] as String? ?? '') ??
          DateTime.now(),
    );
  }
}
