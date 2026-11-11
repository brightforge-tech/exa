/// Memory tiers, separated because each has different storage and retrieval
/// rules (working memory expires; semantic facts persist; commitments are
/// tracked until resolved).
enum AgentMemoryType {
  working,
  episodic,
  semantic,
  procedural,
  commitment;

  String get wireName => name;

  static AgentMemoryType fromWireName(String name) =>
      AgentMemoryType.values.firstWhere(
        (type) => type.name == name.trim(),
        orElse: () => AgentMemoryType.episodic,
      );
}

/// What *kind* of thing a memory is, orthogonal to its storage tier.
///
/// The tier ([AgentMemoryType]) decides how long it lives and how it is
/// retrieved; the kind decides how much authority it carries. A stated
/// preference outranks an inferred one; a correction supersedes what it
/// corrects; a temporary working state must never outlive its usefulness.
/// Without this distinction every remembered sentence carried the same
/// weight, which is how a one-off "I'm working from home today" ends up
/// shaping answers six months later.
enum MemoryKind {
  explicitPreference,
  verifiedFact,
  userCommitment,
  episodicEvent,
  projectState,
  inferredPreference,
  temporaryWorkingState,
  correction;

  String get wireName => switch (this) {
        explicitPreference => 'explicit_preference',
        verifiedFact => 'verified_fact',
        userCommitment => 'user_commitment',
        episodicEvent => 'episodic_event',
        projectState => 'project_state',
        inferredPreference => 'inferred_preference',
        temporaryWorkingState => 'temporary_working_state',
        correction => 'correction',
      };

  static MemoryKind fromWireName(String? name) {
    final normalized = name?.trim();
    for (final kind in MemoryKind.values) {
      if (kind.wireName == normalized) return kind;
    }
    return MemoryKind.episodicEvent;
  }

  /// The kind a memory of [type] defaults to when it was stored before
  /// kinds existed (or by a caller that does not set one).
  static MemoryKind defaultForType(AgentMemoryType type) => switch (type) {
        AgentMemoryType.working => MemoryKind.temporaryWorkingState,
        AgentMemoryType.episodic => MemoryKind.episodicEvent,
        AgentMemoryType.semantic => MemoryKind.verifiedFact,
        AgentMemoryType.procedural => MemoryKind.inferredPreference,
        AgentMemoryType.commitment => MemoryKind.userCommitment,
      };

  /// Kinds that must be reinforced by repeated evidence before they are
  /// treated as durable. One unusual request must not permanently distort
  /// future answers.
  bool get decaysWithoutReinforcement =>
      this == MemoryKind.inferredPreference ||
      this == MemoryKind.projectState;

  /// Kinds that always outrank an inferred memory in a contradiction.
  bool get isAuthoritative =>
      this == MemoryKind.correction ||
      this == MemoryKind.explicitPreference ||
      this == MemoryKind.verifiedFact ||
      this == MemoryKind.userCommitment;
}

/// Where a memory came from. This is the hard rule the write policy
/// enforces: **model speculation can never become memory**. Everything
/// stored is traceable to something the user said, something a tool
/// returned, or a deterministic inference that is labelled as inferred.
enum MemoryProvenance {
  /// The user said it.
  userStatement,

  /// A successful tool call returned it.
  toolResult,

  /// Derived in code from application state, and marked as derived.
  deterministicInference,

  /// The model asserted it. Never storable.
  modelSpeculation;

  String get wireName => switch (this) {
        userStatement => 'user_statement',
        toolResult => 'tool_result',
        deterministicInference => 'deterministic_inference',
        modelSpeculation => 'model_speculation',
      };

  static MemoryProvenance fromWireName(String? name) {
    final normalized = name?.trim();
    for (final provenance in MemoryProvenance.values) {
      if (provenance.wireName == normalized) return provenance;
    }
    return MemoryProvenance.deterministicInference;
  }

  bool get isStorable => this != MemoryProvenance.modelSpeculation;

  bool get isExplicit => this == MemoryProvenance.userStatement;
}

/// One remembered item. Content is plain text; entity links live in the
/// memory_entities join table (mirrored here as [entityIds]).
class AgentMemory {
  AgentMemory({
    required this.id,
    required this.type,
    required this.content,
    required this.createdAt,
    required this.updatedAt,
    required this.importance,
    required this.confidence,
    required this.sourceType,
    required this.sourceId,
    this.summary,
    this.entityIds = const [],
    this.expiresAt,
    this.lastAccessedAt,
    this.accessCount = 0,
    this.userConfirmed = false,
    this.isSensitive = false,
    this.isArchived = false,
    MemoryKind? kind,
    this.provenance = MemoryProvenance.deterministicInference,
    DateTime? observedAt,
    DateTime? validFrom,
    this.validUntil,
    this.lastConfirmedAt,
    this.topicScope,
    this.supersedesMemoryId,
    this.contradictedByMemoryId,
    this.reinforcementCount = 1,
  })  :
        // Rows written before schema v19 carry none of these; resolving the
        // defaults here means every consumer sees a complete memory instead
        // of null-checking four fields.
        kind = kind ?? MemoryKind.defaultForType(type),
        observedAt = observedAt ?? createdAt,
        validFrom = validFrom ?? observedAt ?? createdAt;

  final String id;
  final AgentMemoryType type;
  final String content;
  final String? summary;
  final List<String> entityIds;

  /// 0-1: how useful this is likely to be later.
  final double importance;

  /// 0-1: how sure Exa is that it is true.
  final double confidence;

  /// conversation, email, task, tool_result, user_confirmation, etc.
  final String sourceType;
  final String sourceId;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? expiresAt;
  final DateTime? lastAccessedAt;
  final int accessCount;
  final bool userConfirmed;
  final bool isSensitive;
  final bool isArchived;

  /// What kind of claim this memory makes. Falls back to the tier's default
  /// so rows written before kinds existed behave sensibly.
  final MemoryKind kind;

  /// How it came to be known. Never [MemoryProvenance.modelSpeculation] for
  /// a stored row — the write policy rejects those.
  final MemoryProvenance provenance;

  /// When the fact was true in the world, as opposed to when Exa wrote it
  /// down. For an email-derived memory these differ by however long the
  /// mail sat unread.
  final DateTime observedAt;

  /// Start of the window in which this memory applies.
  final DateTime validFrom;

  /// End of that window. Distinct from [expiresAt], which is a storage
  /// lifetime: a memory can stop *applying* long before it is deleted.
  final DateTime? validUntil;

  /// Last time the user (or a tool) reconfirmed this. Drives decay.
  final DateTime? lastConfirmedAt;

  /// Topic this memory belongs to (see `TurnFrame.activeTopicId`), so a
  /// question about one project does not surface another project's state.
  final String? topicScope;

  /// The memory this one replaced, when it was written as a correction.
  final String? supersedesMemoryId;

  /// Set on a memory that a later one contradicts. Contradicted memories
  /// are heavily penalized in retrieval rather than deleted, so the history
  /// of what Exa believed stays inspectable.
  final String? contradictedByMemoryId;

  /// How many independent times this has been observed. An inferred
  /// preference needs several before it is treated as durable.
  final int reinforcementCount;

  bool isExpiredAt(DateTime moment) =>
      expiresAt != null && moment.isAfter(expiresAt!);

  /// True when the memory's applicability window has closed — "working from
  /// home today", read next March.
  bool isOutOfValidityAt(DateTime moment) =>
      (validUntil != null && moment.isAfter(validUntil!)) ||
      moment.isBefore(validFrom);

  bool get isContradicted => contradictedByMemoryId != null;

  /// An inferred preference seen only once is a guess, not a preference.
  bool get isDurable =>
      userConfirmed ||
      provenance.isExplicit ||
      !kind.decaysWithoutReinforcement ||
      reinforcementCount >= inferredPreferenceEvidenceThreshold;

  /// Independent observations an inferred preference needs before Exa acts
  /// on it as if it were stated.
  static const int inferredPreferenceEvidenceThreshold = 3;

  AgentMemory copyWith({
    String? content,
    double? importance,
    double? confidence,
    DateTime? updatedAt,
    DateTime? expiresAt,
    DateTime? lastAccessedAt,
    int? accessCount,
    bool? userConfirmed,
    bool? isArchived,
    List<String>? entityIds,
    MemoryKind? kind,
    MemoryProvenance? provenance,
    DateTime? observedAt,
    DateTime? validFrom,
    DateTime? validUntil,
    DateTime? lastConfirmedAt,
    String? topicScope,
    String? supersedesMemoryId,
    String? contradictedByMemoryId,
    int? reinforcementCount,
  }) =>
      AgentMemory(
        id: id,
        type: type,
        content: content ?? this.content,
        summary: summary,
        entityIds: entityIds ?? this.entityIds,
        importance: importance ?? this.importance,
        confidence: confidence ?? this.confidence,
        sourceType: sourceType,
        sourceId: sourceId,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
        expiresAt: expiresAt ?? this.expiresAt,
        lastAccessedAt: lastAccessedAt ?? this.lastAccessedAt,
        accessCount: accessCount ?? this.accessCount,
        userConfirmed: userConfirmed ?? this.userConfirmed,
        isSensitive: isSensitive,
        isArchived: isArchived ?? this.isArchived,
        kind: kind ?? this.kind,
        provenance: provenance ?? this.provenance,
        observedAt: observedAt ?? this.observedAt,
        validFrom: validFrom ?? this.validFrom,
        validUntil: validUntil ?? this.validUntil,
        lastConfirmedAt: lastConfirmedAt ?? this.lastConfirmedAt,
        topicScope: topicScope ?? this.topicScope,
        supersedesMemoryId: supersedesMemoryId ?? this.supersedesMemoryId,
        contradictedByMemoryId:
            contradictedByMemoryId ?? this.contradictedByMemoryId,
        reinforcementCount: reinforcementCount ?? this.reinforcementCount,
      );

  /// Compact form for prompt context and replay traces (never includes
  /// bookkeeping columns).
  Map<String, Object?> toContextJson() => {
        'id': id,
        'type': type.wireName,
        'kind': kind.wireName,
        'content': content,
        'confidence': confidence,
        'source': provenance.wireName,
        if (userConfirmed) 'user_confirmed': true,
        if (!isDurable) 'tentative': true,
        if (validUntil != null) 'valid_until': validUntil!.toIso8601String(),
        if (expiresAt != null) 'expires_at': expiresAt!.toIso8601String(),
      };
}
