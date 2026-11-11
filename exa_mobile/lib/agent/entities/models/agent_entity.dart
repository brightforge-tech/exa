/// Kinds of records the entity graph can represent. `custom` covers types
/// the enum does not model yet (stored with a metadata subtype).
enum AgentEntityType {
  person,
  organization,
  project,
  task,
  reminder,
  email,
  calendarEvent,
  file,
  folder,
  screen,
  behaviorRule,
  backgroundJob,
  commitment,
  conversation,
  location,
  custom;

  String get wireName => name;

  static AgentEntityType fromWireName(String name) =>
      AgentEntityType.values.firstWhere(
        (type) => type.name == name.trim(),
        orElse: () => AgentEntityType.custom,
      );
}

/// A persistent node in Exa's entity graph. Points at the authoritative
/// source record ([externalSource] + [externalId]) instead of duplicating
/// it - the original task/email/event table remains the source of truth.
class AgentEntity {
  const AgentEntity({
    required this.id,
    required this.type,
    required this.displayName,
    required this.createdAt,
    required this.updatedAt,
    this.canonicalName,
    this.externalSource,
    this.externalId,
    this.metadata = const {},
    this.confidence = 1.0,
    this.isArchived = false,
  });

  final String id;
  final AgentEntityType type;
  final String displayName;

  /// Lower-cased, trimmed name used for matching ("amy" for "Amy").
  final String? canonicalName;

  /// Example: sqlite_task, sqlite_email, sqlite_schedule, device_calendar.
  final String? externalSource;

  /// ID used by the source system.
  final String? externalId;
  final Map<String, dynamic> metadata;
  final double confidence;
  final bool isArchived;
  final DateTime createdAt;
  final DateTime updatedAt;

  AgentEntity copyWith({
    String? displayName,
    Map<String, dynamic>? metadata,
    double? confidence,
    bool? isArchived,
    DateTime? updatedAt,
  }) =>
      AgentEntity(
        id: id,
        type: type,
        displayName: displayName ?? this.displayName,
        canonicalName: (displayName ?? this.displayName).trim().toLowerCase(),
        externalSource: externalSource,
        externalId: externalId,
        metadata: metadata ?? this.metadata,
        confidence: confidence ?? this.confidence,
        isArchived: isArchived ?? this.isArchived,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'entity_type': type.wireName,
        'display_name': displayName,
        if (canonicalName != null) 'canonical_name': canonicalName,
        if (externalSource != null) 'external_source': externalSource,
        if (externalId != null) 'external_id': externalId,
        if (metadata.isNotEmpty) 'metadata': metadata,
        'confidence': confidence,
        'is_archived': isArchived,
      };
}
