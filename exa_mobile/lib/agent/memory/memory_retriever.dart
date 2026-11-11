import '../orchestrator/turn_frame.dart';
import 'memory_repository.dart';
import 'models/agent_memory.dart';

/// A memory with the reasoning behind its score, so "why was this in
/// context?" is answerable from a trace instead of guessed at.
class ScoredMemory {
  const ScoredMemory({
    required this.memory,
    required this.score,
    required this.components,
  });

  final AgentMemory memory;
  final double score;

  /// Named contributions, e.g. `{lexical: 0.4, entity: 0.25}`.
  final Map<String, double> components;

  Map<String, Object?> toJson() => {
        'memory_id': memory.id,
        'score': double.parse(score.toStringAsFixed(3)),
        'components': {
          for (final entry in components.entries)
            if (entry.value.abs() > 0.001)
              entry.key: double.parse(entry.value.toStringAsFixed(3)),
        },
      };
}

/// What the retriever hands the prompt builder: a bounded, scored,
/// per-type-capped selection - never the whole memory store.
class MemoryRetrievalResult {
  const MemoryRetrievalResult({
    required this.memories,
    this.scored = const [],
    this.consideredCount = 0,
    this.suppressedCount = 0,
  });

  final List<AgentMemory> memories;

  /// The selection with its scoring, for diagnostics and replay.
  final List<ScoredMemory> scored;

  /// How many live memories were examined.
  final int consideredCount;

  /// How many were dropped: below threshold, stale, contradicted, out of
  /// topic, out of time, or duplicates of something already selected.
  final int suppressedCount;

  List<AgentMemory> ofType(AgentMemoryType type) =>
      [for (final memory in memories) if (memory.type == type) memory];

  bool get isEmpty => memories.isEmpty;
}

/// Relevance retrieval over the memory store.
///
/// Similarity alone is not relevance. A memory can be worded almost like the
/// request and still be the wrong thing to surface: it may be about another
/// topic, from a period the request excludes, already corrected by the user,
/// or an inference that was only ever seen once. The score below combines
/// those signals, and the pipeline filters on them in order:
///
///   TurnFrame → query decomposition → entity expansion → hybrid lexical +
///   semantic → topic and time filter → contradiction/supersession filter →
///   diversity dedupe → relevance threshold → evidence pack
///
/// **Returning nothing is a valid answer.** The memory block has a token
/// budget, but a budget is a ceiling, not a quota: filling it with the
/// best of a bad set is exactly how an assistant ends up repeating stale
/// or irrelevant information back at the user.
class MemoryRetriever {
  MemoryRetriever(this._repository);

  final MemoryRepository _repository;

  /// Per-type caps from the spec (§8.9).
  static const Map<AgentMemoryType, int> caps = {
    AgentMemoryType.working: 5,
    AgentMemoryType.semantic: 5,
    AgentMemoryType.episodic: 3,
    AgentMemoryType.procedural: 3,
    AgentMemoryType.commitment: 5,
  };

  static const double minimumScore = 0.15;

  /// Two selected memories this similar are the same point twice.
  static const double diversityThreshold = 0.75;

  Future<MemoryRetrievalResult> retrieve({
    required String request,
    List<String> entityIds = const [],
    Set<String> domains = const {},
    TurnFrame? frame,
    Set<AgentMemoryType> excludeTypes = const {},
  }) async {
    final live = await _repository.listLive();
    // Whole types can be withheld from a turn - a scheduled run gets no
    // episodic or working memories (see `AgentOrchestrator.run`'s
    // `isolated`). Dropped before scoring so they cannot use up a cap or
    // count as "considered".
    final all = excludeTypes.isEmpty
        ? live
        : [
            for (final memory in live)
              if (!excludeTypes.contains(memory.type)) memory,
          ];
    if (all.isEmpty) return const MemoryRetrievalResult(memories: []);

    final now = DateTime.now();

    // 1-2. Query decomposition and entity expansion. The frame already did
    // this work (request words + entity names + domain vocabulary); without
    // one, fall back to the raw request.
    final queryTerms = frame?.retrievalTerms ??
        {...TurnFrameBuilder.contentTokens(request), ...domains};
    final entitySet = {
      ...entityIds,
      if (frame != null)
        for (final entity in frame.entities) entity.id,
    };
    final topicId = frame?.activeTopicId;
    final timeScope = frame?.timeScope;

    final scored = <ScoredMemory>[];
    var suppressed = 0;

    for (final memory in all) {
      // 3. Validity: expired, or outside the window in which it applies.
      if (memory.isExpiredAt(now) || memory.isOutOfValidityAt(now)) {
        suppressed++;
        continue;
      }
      // 4. Time filter. Only applied to memories that are *about* a moment
      // (episodes, working state); a standing preference is timeless and
      // must not be filtered out by "what's on today?".
      if (timeScope != null && _isTimeBound(memory)) {
        if (!timeScope.contains(memory.observedAt)) {
          suppressed++;
          continue;
        }
      }
      // 5. Supersession: a memory the user replaced is never a candidate.
      // (Contradicted ones survive to be penalized below, so a trace can
      // still show what Exa used to believe.)
      final result = _score(
        memory: memory,
        queryTerms: queryTerms,
        entityIds: entitySet,
        topicId: topicId,
        now: now,
      );
      if (result.score < minimumScore) {
        suppressed++;
        continue;
      }
      scored.add(result);
    }
    scored.sort((a, b) => b.score.compareTo(a.score));

    // 6-7. Diversity dedupe and per-type caps.
    final selected = <AgentMemory>[];
    final selectedScores = <ScoredMemory>[];
    final selectedTokens = <Set<String>>[];
    final countByType = <AgentMemoryType, int>{};

    for (final candidate in scored) {
      final cap = caps[candidate.memory.type] ?? 3;
      final used = countByType[candidate.memory.type] ?? 0;
      if (used >= cap) {
        suppressed++;
        continue;
      }
      final tokens = TurnFrameBuilder.contentTokens(candidate.memory.content);
      final duplicate = selectedTokens.any(
          (existing) => _jaccard(tokens, existing) >= diversityThreshold);
      if (duplicate) {
        suppressed++;
        continue;
      }
      countByType[candidate.memory.type] = used + 1;
      selected.add(candidate.memory);
      selectedScores.add(candidate);
      selectedTokens.add(tokens);
    }

    await _repository.touchAccess([for (final m in selected) m.id]);
    return MemoryRetrievalResult(
      memories: selected,
      scored: selectedScores,
      consideredCount: all.length,
      suppressedCount: suppressed,
    );
  }

  /// The combined score. Positive terms are reasons to surface a memory;
  /// negative ones are reasons it would mislead.
  ScoredMemory _score({
    required AgentMemory memory,
    required Set<String> queryTerms,
    required Set<String> entityIds,
    required String? topicId,
    required DateTime now,
  }) {
    final memoryTokens = TurnFrameBuilder.contentTokens(memory.content);

    // Semantic stand-in: containment overlap, which is more forgiving than
    // Jaccard when one side is much longer. Real embeddings slot in here
    // without changing anything downstream.
    final semantic = _containment(queryTerms, memoryTokens);
    // Lexical: exact rare-word hits. A shared uncommon word ("preconco",
    // "invoice") is a much stronger signal than a shared common one, and
    // averaging it into the semantic score buries it.
    final lexical = _lexicalMatch(queryTerms, memoryTokens);

    final entityMatch = memory.entityIds.isEmpty || entityIds.isEmpty
        ? 0.0
        : memory.entityIds.toSet().intersection(entityIds).length /
            memory.entityIds.length;

    final topicMatch = topicId != null && memory.topicScope == topicId
        ? 1.0
        : 0.0;

    final ageDays = now.difference(memory.updatedAt).inHours / 24.0;
    final recency = ageDays <= 0 ? 1.0 : (1.0 / (1.0 + ageDays / 7.0));

    final explicitPriority =
        (memory.userConfirmed ? 0.6 : 0.0) + (memory.provenance.isExplicit ? 0.4 : 0.0);

    final sourceReliability = switch (memory.provenance) {
      MemoryProvenance.userStatement => 1.0,
      MemoryProvenance.toolResult => 0.9,
      MemoryProvenance.deterministicInference => 0.6,
      MemoryProvenance.modelSpeculation => 0.0,
    };

    // Penalties. A memory the user corrected must be very hard to surface;
    // an inference seen once must not read as a settled preference.
    final contradictionPenalty = memory.isContradicted ? 1.0 : 0.0;
    final stalePenalty = _stalenessOf(memory, now);
    final tentativePenalty = memory.isDurable ? 0.0 : 0.35;

    // Commitments and working memory represent open loops for the current
    // period: they matter even when the request does not name them.
    final typeFloor = memory.type == AgentMemoryType.commitment ||
            memory.type == AgentMemoryType.working
        ? 0.15
        : 0.0;

    final components = <String, double>{
      'semantic': semantic * 0.24,
      'lexical': lexical * 0.14,
      'entity': entityMatch * 0.20,
      'topic': topicMatch * 0.12,
      'recency': recency * 0.10,
      'explicit_priority': explicitPriority * 0.08,
      'source_reliability': sourceReliability * 0.08,
      'importance': memory.importance * 0.12,
      'type_floor': typeFloor,
      'contradiction_penalty': -contradictionPenalty * 0.60,
      'stale_penalty': -stalePenalty * 0.25,
      'tentative_penalty': -tentativePenalty * 0.20,
    };
    var score = components.values.fold(0.0, (sum, value) => sum + value);
    // Shaky memories need much stronger relevance to surface at all.
    score *= (0.5 + memory.confidence * 0.5);

    return ScoredMemory(
      memory: memory,
      score: score < 0 ? 0 : score,
      components: components,
    );
  }

  /// Memories that describe a moment rather than a standing fact. Only
  /// these are subject to the request's time scope.
  static bool _isTimeBound(AgentMemory memory) =>
      memory.type == AgentMemoryType.episodic ||
      memory.type == AgentMemoryType.working ||
      memory.kind == MemoryKind.episodicEvent ||
      memory.kind == MemoryKind.temporaryWorkingState;

  /// 0 when fresh, 1 when long past its last confirmation. Anything the
  /// user confirmed does not go stale on a timer.
  static double _stalenessOf(AgentMemory memory, DateTime now) {
    if (memory.userConfirmed) return 0;
    final reference =
        memory.lastConfirmedAt ?? memory.lastAccessedAt ?? memory.updatedAt;
    final days = now.difference(reference).inDays;
    if (days <= 30) return 0;
    return ((days - 30) / 120).clamp(0.0, 1.0);
  }

  /// Fraction of the query's terms present in the memory. Asymmetric on
  /// purpose: a long memory that contains everything asked about is a good
  /// hit, and Jaccard would punish it for its length.
  static double _containment(Set<String> query, Set<String> memory) {
    if (query.isEmpty || memory.isEmpty) return 0;
    return query.intersection(memory).length / query.length;
  }

  /// Rewards matches on distinctive words. Short common tokens contribute
  /// little; longer ones (which are rarer in practice) contribute more.
  static double _lexicalMatch(Set<String> query, Set<String> memory) {
    if (query.isEmpty || memory.isEmpty) return 0;
    var weight = 0.0;
    var total = 0.0;
    for (final term in query) {
      final termWeight = term.length >= 7
          ? 1.0
          : term.length >= 5
              ? 0.6
              : 0.3;
      total += termWeight;
      if (memory.contains(term)) weight += termWeight;
    }
    return total == 0 ? 0 : weight / total;
  }

  static double _jaccard(Set<String> a, Set<String> b) {
    if (a.isEmpty || b.isEmpty) return 0;
    return a.intersection(b).length / a.union(b).length;
  }
}
