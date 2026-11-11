/// A complete, replayable record of one agent turn: what went in (request,
/// routing, contract, memories, entities), what happened (tool executions,
/// report), and what came out (response, verification). Stored as structured
/// JSON so future orchestration/prompt/model versions can be evaluated
/// against history without touching real user data.
class ReplayTrace {
  const ReplayTrace({
    required this.id,
    required this.agentTurnId,
    required this.createdAt,
    required this.userRequest,
    required this.routingResult,
    required this.contract,
    required this.memoriesProvided,
    required this.activeEntities,
    required this.toolExecutions,
    required this.executionReport,
    required this.finalResponse,
    required this.verificationResult,
    required this.modelConfiguration,
    this.skillExecution,
    this.userFeedback,
    this.containsSensitiveData = false,
  });

  final String id;
  final String agentTurnId;
  final DateTime createdAt;
  final String userRequest;
  final Map<String, dynamic> routingResult;
  final Map<String, dynamic> contract;
  final List<Map<String, dynamic>> memoriesProvided;
  final List<Map<String, dynamic>> activeEntities;
  final List<Map<String, dynamic>> toolExecutions;
  final Map<String, dynamic> executionReport;
  final Map<String, dynamic> finalResponse;
  final Map<String, dynamic> verificationResult;
  final Map<String, dynamic> modelConfiguration;
  final Map<String, dynamic>? skillExecution;
  final Map<String, dynamic>? userFeedback;
  final bool containsSensitiveData;

  ReplayTrace copyWith({
    String? userRequest,
    List<Map<String, dynamic>>? memoriesProvided,
    List<Map<String, dynamic>>? activeEntities,
    List<Map<String, dynamic>>? toolExecutions,
    Map<String, dynamic>? executionReport,
    Map<String, dynamic>? finalResponse,
    Map<String, dynamic>? userFeedback,
    bool? containsSensitiveData,
  }) =>
      ReplayTrace(
        id: id,
        agentTurnId: agentTurnId,
        createdAt: createdAt,
        userRequest: userRequest ?? this.userRequest,
        routingResult: routingResult,
        contract: contract,
        memoriesProvided: memoriesProvided ?? this.memoriesProvided,
        activeEntities: activeEntities ?? this.activeEntities,
        toolExecutions: toolExecutions ?? this.toolExecutions,
        executionReport: executionReport ?? this.executionReport,
        finalResponse: finalResponse ?? this.finalResponse,
        verificationResult: verificationResult,
        modelConfiguration: modelConfiguration,
        skillExecution: skillExecution,
        userFeedback: userFeedback ?? this.userFeedback,
        containsSensitiveData:
            containsSensitiveData ?? this.containsSensitiveData,
      );
}
