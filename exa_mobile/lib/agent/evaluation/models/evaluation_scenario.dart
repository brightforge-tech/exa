import '../../models/turn_contract.dart';

/// A reusable evaluation case: a request, the mock state it runs against,
/// and the expectations a correct turn must satisfy. Built by hand, or
/// generated from a replay trace when the user corrects Exa.
class EvaluationScenario {
  const EvaluationScenario({
    required this.id,
    required this.name,
    required this.userRequest,
    required this.mockState,
    required this.expectedDomains,
    required this.requiredTools,
    required this.forbiddenTools,
    required this.requiredOutputs,
    required this.maximumToolCalls,
    required this.createdAt,
    this.expectedSkill,
    this.expectedEntities = const [],
    this.expectedMemoryIds = const [],
    this.tags = const [],
    this.sourceTraceId,
  });

  final String id;
  final String name;
  final String userRequest;

  /// Queued mock tool responses keyed by tool name (each call consumes one).
  final Map<String, dynamic> mockState;
  final Set<String> expectedDomains;
  final Set<String> requiredTools;
  final Set<String> forbiddenTools;
  final Set<ResponseOutputType> requiredOutputs;
  final String? expectedSkill;
  final List<String> expectedEntities;
  final List<String> expectedMemoryIds;
  final int maximumToolCalls;
  final List<String> tags;

  /// The replay trace this scenario was generated from, when applicable.
  final String? sourceTraceId;

  final DateTime createdAt;

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'user_request': userRequest,
        'mock_state': mockState,
        'expected_domains': expectedDomains.toList(),
        'required_tools': requiredTools.toList(),
        'forbidden_tools': forbiddenTools.toList(),
        'required_outputs': requiredOutputs.map((o) => o.wireName).toList(),
        if (expectedSkill != null) 'expected_skill': expectedSkill,
        'expected_entities': expectedEntities,
        'expected_memory_ids': expectedMemoryIds,
        'maximum_tool_calls': maximumToolCalls,
        'tags': tags,
        if (sourceTraceId != null) 'source_trace_id': sourceTraceId,
      };
}
