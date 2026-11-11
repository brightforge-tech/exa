import 'entity_relationship_repository.dart';
import 'entity_repository.dart';
import 'models/agent_entity.dart';
import 'models/entity_relationship.dart';

/// The graph facade: upserts entities that mirror existing app records,
/// links them, and answers traversal queries ("what is related to the
/// Preconco project?"). Archived entities and expired edges are excluded
/// from normal traversal.
class EntityGraphService {
  EntityGraphService({
    required EntityRepository entityRepository,
    required EntityRelationshipRepository relationshipRepository,
  })  : _entities = entityRepository,
        _relationships = relationshipRepository;

  final EntityRepository _entities;
  final EntityRelationshipRepository _relationships;

  EntityRepository get entities => _entities;
  EntityRelationshipRepository get relationships => _relationships;

  Future<AgentEntity> upsertExternalEntity({
    required AgentEntityType type,
    required String displayName,
    required String externalSource,
    required String externalId,
    Map<String, dynamic> metadata = const {},
    double confidence = 1.0,
  }) =>
      _entities.upsert(
        type: type,
        displayName: displayName,
        externalSource: externalSource,
        externalId: externalId,
        metadata: metadata,
        confidence: confidence,
      );

  /// Upserts an entity with no backing record (people, organizations,
  /// projects inferred from content).
  Future<AgentEntity> upsertNamedEntity({
    required AgentEntityType type,
    required String displayName,
    Map<String, dynamic> metadata = const {},
    double confidence = 1.0,
  }) =>
      _entities.upsert(
        type: type,
        displayName: displayName,
        metadata: metadata,
        confidence: confidence,
      );

  Future<EntityRelationship> link({
    required String sourceEntityId,
    required String targetEntityId,
    required EntityRelationshipType type,
    double confidence = 1.0,
    String? source,
    String? customType,
    Map<String, dynamic> metadata = const {},
  }) =>
      _relationships.upsert(
        sourceEntityId: sourceEntityId,
        targetEntityId: targetEntityId,
        type: type,
        customType: customType,
        confidence: confidence,
        source: source,
        metadata: metadata,
      );

  /// Breadth-first traversal from [entityId] up to [depth] hops, both edge
  /// directions, excluding archived entities.
  Future<List<AgentEntity>> getRelatedEntities({
    required String entityId,
    Set<EntityRelationshipType>? relationships,
    Set<AgentEntityType>? entityTypes,
    int depth = 1,
    int limit = 50,
  }) async {
    final visited = <String>{entityId};
    final found = <String>[];
    var frontier = <String>[entityId];

    for (var hop = 0; hop < depth && frontier.isNotEmpty; hop++) {
      final next = <String>[];
      for (final currentId in frontier) {
        final edges =
            await _relationships.forEntity(currentId, types: relationships);
        for (final edge in edges) {
          final otherId = edge.sourceEntityId == currentId
              ? edge.targetEntityId
              : edge.sourceEntityId;
          if (visited.add(otherId)) {
            found.add(otherId);
            next.add(otherId);
            if (found.length >= limit) break;
          }
        }
        if (found.length >= limit) break;
      }
      frontier = next;
    }

    final loaded = await _entities.getByIds(found);
    return loaded
        .where((entity) => !entity.isArchived)
        .where((entity) =>
            entityTypes == null || entityTypes.contains(entity.type))
        .toList();
  }

  Future<void> removeExpiredRelationships() =>
      _relationships.removeExpired().then((_) {});

  Future<void> archiveEntity(String entityId) => _entities.archive(entityId);
}
