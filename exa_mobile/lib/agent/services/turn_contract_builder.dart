import '../models/agent_ids.dart';
import '../models/turn_contract.dart';
import '../orchestrator/domain_router.dart';
import '../skills/models/workflow_skill.dart';

/// Builds the turn's completion contract from its three sources: the router
/// result, the matched workflow skill, and (later, in the orchestrator) the
/// deterministic output profiles.
///
/// The contract is application state, not model state: once built it is
/// persisted, its actions tracked, and its outputs verified.
class TurnContractBuilder {
  const TurnContractBuilder();

  CompletionContract build({
    required String agentTurnId,
    required String originalRequest,
    required DomainRoutingResult? routing,
    WorkflowSkill? skill,
  }) {
    if (routing == null) {
      final fallback = fallbackContract(
        originalRequest: originalRequest,
        agentTurnId: agentTurnId,
      );
      // A matched skill still contributes even when routing failed.
      if (skill == null) return fallback;
      return CompletionContract(
        id: fallback.id,
        agentTurnId: agentTurnId,
        originalRequest: originalRequest,
        domains: null,
        actions: fallback.actions,
        requiredOutputs: {
          ...fallback.requiredOutputs,
          ...skill.requiredOutputs,
        },
        skillId: skill.id,
        skillVersion: skill.version,
        requiresConfirmation: skill.requiresConfirmation,
        requiresSynthesis: true,
        requiresVerification: true,
        createdAt: DateTime.now(),
      );
    }

    final outputs = <ResponseOutputType>{
      ...routing.responseOutputs,
      if (skill != null) ...skill.requiredOutputs,
    };
    final domains = routing.domains == null
        ? null
        : {
            ...routing.domains!,
            if (skill != null) ...skill.requiredDomains,
          };
    return CompletionContract(
      id: AgentId.contract(),
      agentTurnId: agentTurnId,
      originalRequest: originalRequest,
      domains: domains,
      actions: routing.actions,
      requiredOutputs: outputs,
      skillId: skill?.id,
      skillVersion: skill?.version,
      constraints: routing.constraints,
      assumptions: routing.assumptions,
      requiresConfirmation:
          routing.requiresConfirmation || (skill?.requiresConfirmation ?? false),
      requiresSynthesis: routing.requiresSynthesis || outputs.isNotEmpty,
      requiresVerification: routing.requiresVerification ||
          routing.actions.length > 1 ||
          (domains?.length ?? 2) > 1 ||
          skill != null,
      createdAt: DateTime.now(),
    );
  }
}
