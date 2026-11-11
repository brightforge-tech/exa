/// Typed, directional edges between graph entities.
enum EntityRelationshipType {
  belongsTo,
  relatedTo,
  createdFrom,
  sentBy,
  sentTo,
  mentions,
  assignedTo,
  dependsOn,
  blockedBy,
  scheduledFor,
  worksAt,
  participantIn,
  storedIn,
  references,
  followsUp,
  waitingOn,
  supersedes,
  generatedBy,
  custom;

  String get wireName => name;

  static EntityRelationshipType fromWireName(String name) =>
      EntityRelationshipType.values.firstWhere(
        (type) => type.name == name.trim(),
        orElse: () => EntityRelationshipType.custom,
      );
}

/// One edge: source --type--> target. Relationship types outside the enum
/// use [EntityRelationshipType.custom] plus [customType].
class EntityRelationship {
  const EntityRelationship({
    required this.id,
    required this.sourceEntityId,
    required this.targetEntityId,
    required this.type,
    required this.createdAt,
    this.customType,
    this.metadata = const {},
    this.confidence = 1.0,
    this.validFrom,
    this.validUntil,
    this.source,
  });

  final String id;
  final String sourceEntityId;
  final String targetEntityId;
  final EntityRelationshipType type;
  final String? customType;
  final Map<String, dynamic> metadata;
  final double confidence;
  final DateTime createdAt;
  final DateTime? validFrom;
  final DateTime? validUntil;

  /// What created this edge (e.g. entity_extractor, user).
  final String? source;

  bool isValidAt(DateTime moment) =>
      (validFrom == null || !moment.isBefore(validFrom!)) &&
      (validUntil == null || moment.isBefore(validUntil!));

  Map<String, Object?> toJson() => {
        'id': id,
        'source_entity_id': sourceEntityId,
        'target_entity_id': targetEntityId,
        'relationship_type': type.wireName,
        if (customType != null) 'custom_type': customType,
        'confidence': confidence,
      };
}
