import 'agent_entity.dart';

/// The per-conversation short-term focus: which entities recent turns
/// touched, how salient each still is, and (for list results) their display
/// position - so "delete the second one" resolves deterministically.
class ActiveEntityContext {
  const ActiveEntityContext({
    required this.conversationId,
    required this.entities,
    required this.updatedAt,
  });

  final String conversationId;

  /// Ordered by salience, highest first.
  final List<ActiveEntityReference> entities;
  final DateTime? updatedAt;

  static const empty = ActiveEntityContext(
    conversationId: 'main',
    entities: [],
    updatedAt: null,
  );

  bool get isEmpty => entities.isEmpty;

  /// Compact summaries for the router / prompt context.
  List<Map<String, Object?>> toSummaries({int limit = 8}) => [
        for (final entity in entities.take(limit))
          {
            'type': entity.entityType.wireName,
            'name': entity.displayName,
            'id': entity.entityId,
            if (entity.externalId != null) 'source_id': entity.externalId,
            if (entity.position != null) 'position': entity.position,
          },
      ];
}

class ActiveEntityReference {
  const ActiveEntityReference({
    required this.entityId,
    required this.entityType,
    required this.displayName,
    required this.salience,
    required this.lastMentionedAt,
    this.externalId,
    this.position,
  });

  final String entityId;
  final AgentEntityType entityType;
  final String displayName;

  /// 1.0 = touched this turn; decays each turn it is not touched.
  final double salience;
  final DateTime lastMentionedAt;

  /// The source-system id, so follow-up tool calls can use it directly.
  final String? externalId;

  /// 1-based rank when the entity appeared in a listed result - used for
  /// phrases such as "the second task".
  final int? position;
}
