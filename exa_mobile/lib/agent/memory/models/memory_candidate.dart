import 'agent_memory.dart';

/// A potential memory produced after a turn, before the write policy has
/// judged it. Candidates carry the reason they were proposed so rejects are
/// explainable.
class MemoryCandidate {
  MemoryCandidate({
    required this.type,
    required this.content,
    required this.reason,
    required this.importance,
    required this.confidence,
    required this.entityIds,
    required this.sourceType,
    required this.sourceId,
    this.expiresAt,
    this.requiresUserConfirmation = false,
    this.isSensitive = false,
    MemoryKind? kind,
    this.provenance = MemoryProvenance.deterministicInference,
    this.observedAt,
    this.validFrom,
    this.validUntil,
    this.topicScope,
    this.supersedesMemoryId,
  }) : kind = kind ?? MemoryKind.defaultForType(type);

  final AgentMemoryType type;
  final String content;
  final String reason;
  final double importance;
  final double confidence;
  final List<String> entityIds;
  final String sourceType;
  final String sourceId;
  final DateTime? expiresAt;
  final bool requiresUserConfirmation;
  final bool isSensitive;

  final MemoryKind kind;

  /// Where this came from. Anything the model merely asserted arrives as
  /// [MemoryProvenance.modelSpeculation] and is rejected by the policy.
  final MemoryProvenance provenance;

  final DateTime? observedAt;
  final DateTime? validFrom;

  /// When this stops applying. Temporary working state must always set it.
  final DateTime? validUntil;

  final String? topicScope;

  /// Set when this candidate corrects an existing memory.
  final String? supersedesMemoryId;

  MemoryCandidate copyWith({
    double? confidence,
    double? importance,
    String? topicScope,
    String? supersedesMemoryId,
    DateTime? validUntil,
    MemoryProvenance? provenance,
  }) =>
      MemoryCandidate(
        type: type,
        content: content,
        reason: reason,
        importance: importance ?? this.importance,
        confidence: confidence ?? this.confidence,
        entityIds: entityIds,
        sourceType: sourceType,
        sourceId: sourceId,
        expiresAt: expiresAt,
        requiresUserConfirmation: requiresUserConfirmation,
        isSensitive: isSensitive,
        kind: kind,
        provenance: provenance ?? this.provenance,
        observedAt: observedAt,
        validFrom: validFrom,
        validUntil: validUntil ?? this.validUntil,
        topicScope: topicScope ?? this.topicScope,
        supersedesMemoryId: supersedesMemoryId ?? this.supersedesMemoryId,
      );
}

enum MemoryWriteDecision {
  write,
  writeWithExpiry,
  requestConfirmation,
  reject,
}
