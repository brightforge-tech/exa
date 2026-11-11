import '../orchestrator/turn_frame.dart';
import 'memory_repository.dart';
import 'models/agent_memory.dart';
import 'models/memory_candidate.dart';

/// What a detected correction did.
class CorrectionOutcome {
  const CorrectionOutcome({
    required this.detected,
    this.supersededMemoryId,
    this.correctionMemoryId,
    this.invalidatedTopicId,
  });

  static const none = CorrectionOutcome(detected: false);

  final bool detected;
  final String? supersededMemoryId;
  final String? correctionMemoryId;

  /// Topic whose cached capsule must be regenerated, because a summary
  /// built before the correction still contains the old value.
  final String? invalidatedTopicId;

  bool get changedSomething => supersededMemoryId != null;

  Map<String, Object?> toJson() => {
        'detected': detected,
        if (supersededMemoryId != null) 'superseded': supersededMemoryId,
        if (correctionMemoryId != null) 'correction': correctionMemoryId,
        if (invalidatedTopicId != null) 'invalidated_topic': invalidatedTopicId,
      };
}

/// Memory validity, supersession and contradiction handling.
///
/// Without this, "No, that meeting is Friday" merely added a second memory
/// alongside the Thursday one, and retrieval could surface either — which is
/// what makes an assistant appear to gaslight the user with something they
/// already corrected. A correction now marks the old memory contradicted,
/// writes a replacement that points at it, and flags the topic's cached
/// summary as stale.
class MemoryLifecycle {
  const MemoryLifecycle(this._memories);

  final MemoryRepository _memories;

  /// Phrasings that mean "what you just recorded is wrong". Deliberately
  /// narrow: a false positive supersedes a correct memory, which is worse
  /// than missing one correction.
  static final _correctionMarkers = RegExp(
    r"^\s*(?:no[,.!\s]|nope[,.!\s]|actually[,\s]|correction[:,\s]|"
    r"that.s (?:wrong|not right|incorrect)|i meant\b|not\s+\w+[,\s]+it.s\b|"
    r"it.s actually\b|wrong[,.!\s])",
    caseSensitive: false,
  );

  /// True when the message reads as a correction of something Exa said or
  /// stored.
  static bool looksLikeCorrection(String userText) =>
      _correctionMarkers.hasMatch(userText) ||
      RegExp(r"\b(?:i said|i told you|as i said)\b", caseSensitive: false)
          .hasMatch(userText);

  /// Applies a user correction. Finds the live memory the correction is
  /// most plainly about, marks it contradicted, and records the correction
  /// itself as an authoritative memory that supersedes it.
  ///
  /// Returns [CorrectionOutcome.none] when nothing matched well enough —
  /// superseding the wrong memory is worse than superseding none.
  Future<CorrectionOutcome> applyCorrection({
    required String userText,
    required String agentTurnId,
    String? topicId,
    List<String> entityIds = const [],
  }) async {
    if (!looksLikeCorrection(userText)) return CorrectionOutcome.none;

    final correctionTokens = TurnFrameBuilder.contentTokens(userText);
    if (correctionTokens.length < 2) return const CorrectionOutcome(detected: true);

    final live = await _memories.listApplicable();
    AgentMemory? best;
    var bestScore = 0.0;
    for (final memory in live) {
      if (memory.isContradicted) continue;
      if (memory.kind == MemoryKind.correction) continue;
      final memoryTokens = TurnFrameBuilder.contentTokens(memory.content);
      if (memoryTokens.isEmpty) continue;
      var score = correctionTokens.intersection(memoryTokens).length /
          memoryTokens.length;
      // A correction is about what is in front of the user: same topic and
      // same entities count for a lot more than raw word overlap.
      if (topicId != null && memory.topicScope == topicId) score += 0.25;
      if (entityIds.isNotEmpty &&
          memory.entityIds.any(entityIds.contains)) {
        score += 0.25;
      }
      // Recency breaks ties: the thing just recorded is the likely target.
      final ageHours = DateTime.now().difference(memory.updatedAt).inHours;
      if (ageHours < 24) score += 0.1;
      if (score > bestScore) {
        bestScore = score;
        best = memory;
      }
    }

    if (best == null || bestScore < minimumSupersessionScore) {
      return const CorrectionOutcome(detected: true);
    }

    final correction = await _memories.insert(
      type: best.type,
      content: userText.trim(),
      importance: (best.importance + 0.1).clamp(0.0, 1.0),
      // The user just said it. Nothing outranks that.
      confidence: 1,
      sourceType: 'user_correction',
      sourceId: agentTurnId,
      entityIds: best.entityIds,
      kind: MemoryKind.correction,
      provenance: MemoryProvenance.userStatement,
      topicScope: topicId ?? best.topicScope,
      supersedesMemoryId: best.id,
      lastConfirmedAt: DateTime.now(),
      userConfirmed: true,
    );
    await _memories.markContradicted(best.id, correction.id);

    return CorrectionOutcome(
      detected: true,
      supersededMemoryId: best.id,
      correctionMemoryId: correction.id,
      invalidatedTopicId: topicId ?? best.topicScope,
    );
  }

  /// How closely a correction must match before it is allowed to supersede.
  static const double minimumSupersessionScore = 0.35;

  /// Deterministic validity window for a candidate that does not state one.
  ///
  /// "I'm working from home today" is true for a day, not forever. Anything
  /// temporary that arrives without an end gets one here rather than
  /// silently becoming permanent.
  static MemoryCandidate withValidityWindow(MemoryCandidate candidate) {
    if (candidate.validUntil != null) return candidate;
    final lifetime = switch (candidate.kind) {
      MemoryKind.temporaryWorkingState => const Duration(hours: 24),
      MemoryKind.projectState => const Duration(days: 30),
      MemoryKind.userCommitment => const Duration(days: 30),
      MemoryKind.episodicEvent => const Duration(days: 180),
      _ => null,
    };
    if (lifetime == null) return candidate;
    return candidate.copyWith(
      validUntil: (candidate.observedAt ?? DateTime.now()).add(lifetime),
    );
  }

  /// Same-meaning memory already stored, so a repeat observation reinforces
  /// the existing one rather than creating a near-duplicate.
  Future<AgentMemory?> findReinforceable(MemoryCandidate candidate) async {
    final existing = await _memories.listLive(type: candidate.type);
    final tokens = TurnFrameBuilder.contentTokens(candidate.content);
    if (tokens.isEmpty) return null;
    for (final memory in existing) {
      if (memory.isContradicted) continue;
      if (memory.kind != candidate.kind) continue;
      final memoryTokens = TurnFrameBuilder.contentTokens(memory.content);
      if (memoryTokens.isEmpty) continue;
      final overlap = tokens.intersection(memoryTokens).length /
          tokens.union(memoryTokens).length;
      if (overlap >= 0.6) return memory;
    }
    return null;
  }
}
