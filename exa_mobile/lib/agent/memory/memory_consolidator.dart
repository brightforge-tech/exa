import 'memory_repository.dart';
import 'models/agent_memory.dart';
import 'models/memory_candidate.dart';

/// Periodic memory maintenance: expiry, duplicate merging, confidence decay
/// for stale items, and promotion of repeated episodes into routine
/// candidates the user can confirm. Cheap enough to run opportunistically
/// after turns (all local SQLite).
class MemoryConsolidator {
  MemoryConsolidator(this._repository);

  final MemoryRepository _repository;

  /// Repeated similar episodes needed before proposing a routine.
  static const int routineThreshold = 3;

  /// Semantic/episodic memories untouched this long lose confidence.
  static const staleAfter = Duration(days: 30);

  Future<MemoryConsolidationOutcome> run() async {
    await _repository.expireDue();
    final merged = await _mergeDuplicates();
    final decayed = await _decayStale();
    final routineCandidates = await _identifyRoutineCandidates();
    return MemoryConsolidationOutcome(
      merged: merged,
      decayed: decayed,
      routineCandidates: routineCandidates,
    );
  }

  /// Same-type memories with near-identical content collapse into the
  /// oldest one (which keeps the highest scores).
  Future<int> _mergeDuplicates() async {
    final live = await _repository.listLive();
    var merged = 0;
    final byType = <AgentMemoryType, List<AgentMemory>>{};
    for (final memory in live) {
      byType.putIfAbsent(memory.type, () => []).add(memory);
    }
    for (final group in byType.values) {
      // Oldest first, so later duplicates merge into the original.
      group.sort((a, b) => a.createdAt.compareTo(b.createdAt));
      final kept = <AgentMemory>[];
      for (final memory in group) {
        AgentMemory? duplicateOf;
        for (final keeper in kept) {
          if (_similarity(keeper.content, memory.content) >= 0.8) {
            duplicateOf = keeper;
            break;
          }
        }
        if (duplicateOf == null) {
          kept.add(memory);
          continue;
        }
        merged++;
        await _repository.update(duplicateOf.copyWith(
          importance: duplicateOf.importance > memory.importance
              ? duplicateOf.importance
              : memory.importance,
          confidence: duplicateOf.confidence > memory.confidence
              ? duplicateOf.confidence
              : memory.confidence,
          accessCount: duplicateOf.accessCount + memory.accessCount,
          userConfirmed: duplicateOf.userConfirmed || memory.userConfirmed,
          updatedAt: DateTime.now(),
        ));
        await _repository.delete(memory.id);
      }
    }
    return merged;
  }

  /// Unconfirmed semantic/episodic memories decay when stale; anything that
  /// falls below usefulness is archived (never silently deleted).
  Future<int> _decayStale() async {
    final live = await _repository.listLive();
    final cutoff = DateTime.now().subtract(staleAfter);
    var decayed = 0;
    for (final memory in live) {
      if (memory.userConfirmed) continue;
      if (memory.type == AgentMemoryType.working ||
          memory.type == AgentMemoryType.commitment) {
        continue; // These expire instead of decaying.
      }
      final lastTouched = memory.lastAccessedAt ?? memory.updatedAt;
      if (lastTouched.isAfter(cutoff)) continue;
      decayed++;
      final newConfidence = memory.confidence * 0.8;
      if (newConfidence < 0.2) {
        await _repository.archive(memory.id);
      } else {
        await _repository.update(memory.copyWith(
          confidence: newConfidence,
          updatedAt: DateTime.now(),
        ));
      }
    }
    return decayed;
  }

  /// Clusters of similar episodic memories become procedural-routine
  /// candidates. They REQUIRE user confirmation - a repeated pattern is a
  /// suggestion, never an automatically adopted behavior.
  Future<List<MemoryCandidate>> _identifyRoutineCandidates() async {
    final episodes = await _repository.listLive(type: AgentMemoryType.episodic);
    final candidates = <MemoryCandidate>[];
    final used = <String>{};
    for (var i = 0; i < episodes.length; i++) {
      if (used.contains(episodes[i].id)) continue;
      final cluster = [episodes[i]];
      for (var j = i + 1; j < episodes.length; j++) {
        if (used.contains(episodes[j].id)) continue;
        if (_similarity(episodes[i].content, episodes[j].content) >= 0.6) {
          cluster.add(episodes[j]);
        }
      }
      if (cluster.length >= routineThreshold) {
        for (final memory in cluster) {
          used.add(memory.id);
        }
        candidates.add(MemoryCandidate(
          type: AgentMemoryType.procedural,
          content: 'Recurring routine observed: ${cluster.first.content}',
          reason:
              'The same kind of interaction occurred ${cluster.length} times.',
          importance: 0.8,
          confidence: 0.7,
          entityIds: cluster.first.entityIds,
          sourceType: 'memory_consolidation',
          sourceId: cluster.first.id,
          requiresUserConfirmation: true,
        ));
      }
    }
    return candidates;
  }

  static double _similarity(String a, String b) {
    final ta = _tokens(a);
    final tb = _tokens(b);
    if (ta.isEmpty || tb.isEmpty) return 0;
    return ta.intersection(tb).length / ta.union(tb).length;
  }

  static Set<String> _tokens(String text) => text
      .toLowerCase()
      .split(RegExp(r'[^a-z0-9]+'))
      .where((token) => token.length > 2)
      .toSet();
}

class MemoryConsolidationOutcome {
  const MemoryConsolidationOutcome({
    required this.merged,
    required this.decayed,
    required this.routineCandidates,
  });

  final int merged;
  final int decayed;
  final List<MemoryCandidate> routineCandidates;
}
