import 'memory_lifecycle.dart';
import 'memory_repository.dart';
import 'models/agent_memory.dart';
import 'models/memory_candidate.dart';

/// Decides which memory candidates are worth storing. Exa must not save
/// everything: low-confidence guesses, trivia, and sensitive inferences are
/// rejected; near-duplicates merge into the existing memory instead of
/// piling up.
class MemoryWritePolicy {
  const MemoryWritePolicy({
    this.minimumConfidence = 0.45,
    this.minimumImportance = 0.35,
  });

  final double minimumConfidence;
  final double minimumImportance;

  MemoryWriteDecision evaluate(MemoryCandidate candidate) {
    // Rule 1, and the one that has no exceptions: model speculation can
    // never become memory. Everything Exa remembers traces back to
    // something the user said, something a tool returned, or a labelled
    // deterministic inference. A model's assertion is none of those, and a
    // remembered hallucination is repeated back as fact forever.
    if (!candidate.provenance.isStorable) {
      return MemoryWriteDecision.reject;
    }
    if (_looksLikeSecret(candidate.content)) {
      return MemoryWriteDecision.reject;
    }
    if (candidate.isSensitive && !candidate.requiresUserConfirmation) {
      // Sensitive inferred facts are never stored silently.
      return MemoryWriteDecision.requestConfirmation;
    }
    if (candidate.confidence < minimumConfidence) {
      return MemoryWriteDecision.reject;
    }
    if (candidate.importance < minimumImportance) {
      return MemoryWriteDecision.reject;
    }
    if (candidate.requiresUserConfirmation) {
      return MemoryWriteDecision.requestConfirmation;
    }
    // A first-time inferred preference is a guess. It is stored (so it can
    // accumulate evidence) but with a validity window, so a single unusual
    // request cannot quietly become a standing rule.
    if (candidate.type == AgentMemoryType.working ||
        candidate.kind == MemoryKind.temporaryWorkingState ||
        candidate.kind == MemoryKind.inferredPreference) {
      return MemoryWriteDecision.writeWithExpiry;
    }
    return MemoryWriteDecision.write;
  }

  /// Credentials and tokens must never become memories, whatever the score.
  static bool _looksLikeSecret(String content) {
    final lower = content.toLowerCase();
    const markers = [
      'password', 'passcode', 'api key', 'api_key', 'apikey', 'secret',
      'token', 'private key', 'seed phrase', 'credential',
    ];
    return markers.any(lower.contains);
  }
}

/// Applies the policy: writes accepted candidates, merges near-duplicates,
/// and returns what happened for diagnostics.
class MemoryWriter {
  MemoryWriter({
    required MemoryRepository repository,
    MemoryWritePolicy policy = const MemoryWritePolicy(),
  })  : _memories = repository,
        _writePolicy = policy;

  final MemoryRepository _memories;
  final MemoryWritePolicy _writePolicy;

  /// Default lifetime for working memories that arrive without one.
  static const workingMemoryLifetime = Duration(hours: 24);

  /// Default lifetime for a first-seen inferred preference. Long enough to
  /// be reinforced by a genuine habit, short enough that a one-off does not
  /// become permanent.
  static const inferredPreferenceLifetime = Duration(days: 21);

  Future<MemoryWriteOutcome> processCandidates(
      List<MemoryCandidate> candidates) async {
    var written = 0;
    var merged = 0;
    var rejected = 0;
    var reinforced = 0;
    final awaitingConfirmation = <MemoryCandidate>[];

    for (final raw in candidates) {
      // Anything temporary gets an explicit validity window before the
      // policy sees it, so "today only" facts cannot outlive the day.
      final candidate = MemoryLifecycle.withValidityWindow(raw);
      final decision = _writePolicy.evaluate(candidate);
      switch (decision) {
        case MemoryWriteDecision.reject:
          rejected++;
        case MemoryWriteDecision.requestConfirmation:
          awaitingConfirmation.add(candidate);
        case MemoryWriteDecision.write:
        case MemoryWriteDecision.writeWithExpiry:
          final duplicate = await _findNearDuplicate(candidate);
          if (duplicate != null) {
            merged++;
            // Seeing the same thing again is evidence, and evidence is what
            // an inferred preference needs before it counts as durable.
            if (duplicate.kind.decaysWithoutReinforcement) reinforced++;
            await _memories.update(duplicate.copyWith(
              importance: duplicate.importance > candidate.importance
                  ? duplicate.importance
                  : candidate.importance,
              confidence: duplicate.confidence > candidate.confidence
                  ? duplicate.confidence
                  : candidate.confidence,
              reinforcementCount: duplicate.reinforcementCount + 1,
              // A reinforced memory's window restarts from now; otherwise a
              // habit Exa keeps re-observing would still expire on the
              // first sighting's clock.
              validUntil: candidate.validUntil,
              updatedAt: DateTime.now(),
            ));
            continue;
          }
          written++;
          await _memories.insert(
            type: candidate.type,
            content: candidate.content,
            importance: candidate.importance,
            confidence: candidate.confidence,
            sourceType: candidate.sourceType,
            sourceId: candidate.sourceId,
            entityIds: candidate.entityIds,
            isSensitive: candidate.isSensitive,
            kind: candidate.kind,
            provenance: candidate.provenance,
            observedAt: candidate.observedAt,
            validFrom: candidate.validFrom,
            validUntil: candidate.validUntil,
            topicScope: candidate.topicScope,
            supersedesMemoryId: candidate.supersedesMemoryId,
            expiresAt: decision == MemoryWriteDecision.writeWithExpiry
                ? candidate.expiresAt ??
                    DateTime.now().add(
                        candidate.kind == MemoryKind.inferredPreference
                            ? inferredPreferenceLifetime
                            : workingMemoryLifetime)
                : candidate.expiresAt,
          );
      }
    }
    return MemoryWriteOutcome(
      written: written,
      merged: merged,
      rejected: rejected,
      reinforced: reinforced,
      awaitingConfirmation: awaitingConfirmation,
    );
  }

  /// Same-type memory whose token set overlaps heavily with the candidate.
  Future<AgentMemory?> _findNearDuplicate(MemoryCandidate candidate) async {
    final existing = await _memories.listLive(type: candidate.type);
    final candidateTokens = _tokens(candidate.content);
    if (candidateTokens.isEmpty) return null;
    for (final memory in existing) {
      // A memory the user already corrected must not absorb a new
      // observation - that would resurrect the value they rejected.
      if (memory.isContradicted) continue;
      final memoryTokens = _tokens(memory.content);
      if (memoryTokens.isEmpty) continue;
      final overlap = candidateTokens.intersection(memoryTokens).length;
      final union = candidateTokens.union(memoryTokens).length;
      if (overlap / union >= 0.8) return memory;
    }
    return null;
  }

  static Set<String> _tokens(String text) => text
      .toLowerCase()
      .split(RegExp(r'[^a-z0-9]+'))
      .where((token) => token.length > 2)
      .toSet();
}

class MemoryWriteOutcome {
  const MemoryWriteOutcome({
    required this.written,
    required this.merged,
    required this.rejected,
    required this.awaitingConfirmation,
    this.reinforced = 0,
  });

  final int written;
  final int merged;
  final int rejected;

  /// Merges that were another independent sighting of a decaying kind
  /// (inferred preference, project state) rather than plain deduplication.
  final int reinforced;

  /// Candidates the user must approve before they are stored (surfaced in
  /// the chat/settings; never silently written).
  final List<MemoryCandidate> awaitingConfirmation;
}
