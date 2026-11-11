import '../models/agent_execution_report.dart';
import '../models/turn_contract.dart';
import '../models/verification_result.dart';
import 'models/agent_memory.dart';
import 'models/memory_candidate.dart';

/// Deterministic memory candidate generation after a turn.
///
/// Everything proposed here is derived from application state (the contract,
/// the execution report, verification) - no extra model call and no
/// model-invented "facts". Semantic and procedural memories are promoted
/// later by the consolidator from repeated episodes, or confirmed explicitly
/// by the user; they are not guessed per-turn.
class MemoryCandidateGenerator {
  const MemoryCandidateGenerator();

  List<MemoryCandidate> generate({
    required String agentTurnId,
    required CompletionContract contract,
    required AgentExecutionReport report,
    required VerificationResult verification,
    required List<String> touchedEntityIds,
    String? topicScope,
  }) {
    final candidates = <MemoryCandidate>[];
    final substantiveWork = report.actionsCompleted.isNotEmpty ||
        report.actionsFailed.isNotEmpty;

    // Episodic: a summarized record of what this interaction did. Importance
    // scales with how much the turn changed.
    if (substantiveWork) {
      final changes = report.tasksCreated.length +
          report.eventsCreated.length +
          report.eventsModified.length +
          report.filesAffected.length +
          report.rulesChanged.length;
      final headline = report.actionsCompleted.take(4).join('; ');
      candidates.add(MemoryCandidate(
        type: AgentMemoryType.episodic,
        content: 'Request: "${_clip(contract.originalRequest, 140)}" — '
            '${headline.isEmpty ? 'no actions completed' : headline}'
            '${report.actionsFailed.isNotEmpty ? '; failures: ${report.actionsFailed.take(2).join('; ')}' : ''}',
        reason: 'Summarized record of a completed interaction.',
        importance: (0.35 + changes * 0.08).clamp(0.35, 0.75),
        confidence: 0.95,
        entityIds: touchedEntityIds,
        sourceType: 'agent_turn',
        sourceId: agentTurnId,
        kind: MemoryKind.episodicEvent,
        // Derived in code from the execution report, not asserted by the
        // model - that distinction is what the write policy enforces.
        provenance: MemoryProvenance.deterministicInference,
        topicScope: topicScope,
      ));
    }

    // Working: unresolved problems the next turn should know about.
    if (report.actionsFailed.isNotEmpty) {
      candidates.add(MemoryCandidate(
        type: AgentMemoryType.working,
        content: 'Unresolved from the last request '
            '("${_clip(contract.originalRequest, 100)}"): '
            '${report.actionsFailed.take(3).join('; ')}',
        reason: 'Failed actions may need a retry or follow-up.',
        importance: 0.6,
        confidence: 0.95,
        entityIds: touchedEntityIds,
        sourceType: 'agent_turn',
        sourceId: agentTurnId,
        kind: MemoryKind.temporaryWorkingState,
        provenance: MemoryProvenance.deterministicInference,
        topicScope: topicScope,
        expiresAt: DateTime.now().add(const Duration(hours: 24)),
        validUntil: DateTime.now().add(const Duration(hours: 24)),
      ));
    }

    // Working: open uncertainty the user was told about (e.g. "a Monday
    // deadline without a date") - keep it alive so a follow-up resolves it.
    if (report.uncertainItems.isNotEmpty) {
      candidates.add(MemoryCandidate(
        type: AgentMemoryType.working,
        content:
            'Open questions: ${report.uncertainItems.take(3).join('; ')}',
        reason: 'Unresolved uncertainty disclosed to the user.',
        importance: 0.5,
        confidence: 0.9,
        entityIds: touchedEntityIds,
        sourceType: 'agent_turn',
        sourceId: agentTurnId,
        kind: MemoryKind.temporaryWorkingState,
        provenance: MemoryProvenance.deterministicInference,
        topicScope: topicScope,
        expiresAt: DateTime.now().add(const Duration(hours: 48)),
        validUntil: DateTime.now().add(const Duration(hours: 48)),
      ));
    }

    // Commitment: real email sent to someone - the user may be waiting on a
    // reply or owe follow-through. Recognized from the report's normalized
    // action summaries ("Sent email ...").
    for (final completed in report.actionsCompleted) {
      if (completed.startsWith('Sent email')) {
        candidates.add(MemoryCandidate(
          type: AgentMemoryType.commitment,
          content: completed,
          reason: 'External communication creates a pending thread.',
          importance: 0.65,
          confidence: 0.95,
          entityIds: touchedEntityIds,
          sourceType: 'agent_turn',
          sourceId: agentTurnId,
          kind: MemoryKind.userCommitment,
          // A tool actually sent it; the record is the evidence.
          provenance: MemoryProvenance.toolResult,
          topicScope: topicScope,
          expiresAt: DateTime.now().add(const Duration(days: 14)),
          validUntil: DateTime.now().add(const Duration(days: 14)),
        ));
      }
    }

    return candidates;
  }

  static String _clip(String text, int max) =>
      text.length > max ? '${text.substring(0, max)}...' : text;
}
