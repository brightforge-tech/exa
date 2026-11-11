import 'package:exa_mobile/agent/models/turn_contract.dart';

/// Builds a [CompletionContract] for tests without repeating the id/turn
/// boilerplate. Action labels become required [ContractAction]s.
CompletionContract testContract({
  String originalRequest = 'request',
  Set<String>? domains = const {'core'},
  List<String> actionLabels = const [],
  List<ContractAction>? actions,
  Set<ResponseOutputType> requiredOutputs = const {},
  List<String> constraints = const [],
  bool requiresConfirmation = false,
  bool requiresSynthesis = false,
  bool requiresVerification = false,
}) =>
    CompletionContract(
      id: 'contract_test',
      agentTurnId: 'turn_test',
      originalRequest: originalRequest,
      domains: domains,
      actions: actions ??
          [
            for (var i = 0; i < actionLabels.length; i++)
              ContractAction(id: 'act_$i', description: actionLabels[i]),
          ],
      requiredOutputs: requiredOutputs,
      constraints: constraints,
      requiresConfirmation: requiresConfirmation,
      requiresSynthesis: requiresSynthesis,
      requiresVerification: requiresVerification,
      createdAt: DateTime(2026, 1, 1),
    );
