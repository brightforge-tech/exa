import 'agent_ids.dart';

/// User-facing outputs a request can demand of the final response, distinct
/// from the tool actions it demands. Completing tool actions does not
/// automatically satisfy these.
enum ResponseOutputType {
  confirmation,
  summary,
  rundown,
  recommendation,
  taskList,
  meetingList,
  deadlineList,
  warningList,
  changeDescription,
  resultList,
  failureReport,
  attentionItems,
  generatedContent,
  priorityPlan,
  nextSteps,

  /// One specific, useful follow-up question ending the response - used by
  /// proactive flows (screen-snippet analysis) where the assistant must
  /// offer the most valuable next action rather than dead-end.
  followUpQuestion;

  /// Wire name used in router / synthesizer JSON (snake_case).
  String get wireName => switch (this) {
        confirmation => 'confirmation',
        summary => 'summary',
        rundown => 'rundown',
        recommendation => 'recommendation',
        taskList => 'task_list',
        meetingList => 'meeting_list',
        deadlineList => 'deadline_list',
        warningList => 'warning_list',
        changeDescription => 'change_description',
        resultList => 'result_list',
        failureReport => 'failure_report',
        attentionItems => 'attention_items',
        generatedContent => 'generated_content',
        priorityPlan => 'priority_plan',
        nextSteps => 'next_steps',
        followUpQuestion => 'follow_up_question',
      };

  /// Parses a wire name; unknown values return null (they are rejected, not
  /// guessed at).
  static ResponseOutputType? fromWireName(String name) {
    final normalized = name.trim().toLowerCase();
    for (final type in ResponseOutputType.values) {
      if (type.wireName == normalized) return type;
    }
    return null;
  }

  /// All wire names, for prompts that enumerate the allowed values.
  static List<String> get allWireNames =>
      ResponseOutputType.values.map((t) => t.wireName).toList();

  /// What the reader actually needs from this output, in plain words.
  ///
  /// The synthesis and repair prompts used to list outputs by wire name
  /// alone, and a model handed "rundown, task_list, meeting_list" writes
  /// "Rundown: … Task list: … Meeting list: …" - the names become headings,
  /// and an empty list becomes a labeled empty section. Giving each name its
  /// meaning lets the prompt say "cover this in prose" and mean it.
  String get readerNeed => switch (this) {
        confirmation => 'a plain statement of what was done (or not done)',
        summary => 'a short summary of what you found',
        rundown => 'a short rundown of what came in and what matters',
        recommendation => 'what you recommend, and why in a few words',
        taskList => 'tasks created or that need doing',
        meetingList => 'meetings found or added',
        deadlineList => 'deadlines found',
        warningList => 'anything to watch out for',
        changeDescription => 'what changed',
        resultList => 'the results, itemized',
        failureReport =>
          'what could not be done and what that means for the reader',
        attentionItems => 'anything that needs the reader\'s attention',
        generatedContent => 'the content the reader asked you to write',
        priorityPlan => 'a prioritized plan',
        nextSteps => 'suggested next steps',
        followUpQuestion =>
          'one specific follow-up question, as the last line',
      };
}

/// Lifecycle of a single contract action (or any contract item).
enum ContractItemStatus {
  pending,
  completed,
  failed,
  skipped,
  cancelled,
  awaitingConfirmation;

  String get wireName => name;

  static ContractItemStatus fromWireName(String name) =>
      ContractItemStatus.values.firstWhere(
        (status) => status.name == name.trim(),
        orElse: () => ContractItemStatus.pending,
      );
}

/// One action the request demands be completed through tools. Descriptions
/// are labels for planning/verification, never executable instructions.
class ContractAction {
  const ContractAction({
    required this.id,
    required this.description,
    this.status = ContractItemStatus.pending,
    this.required = true,
    this.expectedToolNames = const [],
    this.entityIds = const [],
    this.failureReason,
  });

  final String id;
  final String description;
  final ContractItemStatus status;
  final bool required;

  /// Tools whose successful execution satisfies this action, when the
  /// router (or skill) could predict them. Empty = resolved by matching.
  final List<String> expectedToolNames;
  final List<String> entityIds;
  final String? failureReason;

  /// A required action is resolved once it reached a terminal state -
  /// including failure, which must then be disclosed to the user.
  bool get isResolved => status != ContractItemStatus.pending &&
      status != ContractItemStatus.awaitingConfirmation;

  ContractAction copyWith({
    ContractItemStatus? status,
    String? failureReason,
    List<String>? entityIds,
  }) =>
      ContractAction(
        id: id,
        description: description,
        status: status ?? this.status,
        required: required,
        expectedToolNames: expectedToolNames,
        entityIds: entityIds ?? this.entityIds,
        failureReason: failureReason ?? this.failureReason,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'description': description,
        'status': status.wireName,
        'required': required,
        if (expectedToolNames.isNotEmpty)
          'expected_tool_names': expectedToolNames,
        if (entityIds.isNotEmpty) 'entity_ids': entityIds,
        if (failureReason != null) 'failure_reason': failureReason,
      };

  factory ContractAction.fromJson(Map<String, Object?> json) =>
      ContractAction(
        id: json['id'] as String? ?? AgentId.contractAction(),
        description: json['description'] as String? ?? '',
        status: ContractItemStatus.fromWireName(
            json['status'] as String? ?? 'pending'),
        required: json['required'] != false,
        expectedToolNames: ((json['expected_tool_names'] as List?) ?? const [])
            .whereType<String>()
            .toList(),
        entityIds: ((json['entity_ids'] as List?) ?? const [])
            .whereType<String>()
            .toList(),
        failureReason: json['failure_reason'] as String?,
      );
}

/// What the user asked Exa to do, return, and confirm this turn.
///
/// Built from the router's structured result, the matched workflow skill,
/// and deterministic output profiles (or a conservative fallback when
/// routing fails). It prevents the agent from assuming the request is
/// complete merely because tools were called successfully: tool calls
/// complete actions; final synthesis completes the request; verification
/// confirms both.
class CompletionContract {
  const CompletionContract({
    required this.id,
    required this.agentTurnId,
    required this.originalRequest,
    required this.domains,
    required this.actions,
    required this.requiredOutputs,
    required this.requiresConfirmation,
    required this.requiresSynthesis,
    required this.requiresVerification,
    required this.createdAt,
    this.skillId,
    this.skillVersion,
    this.constraints = const [],
    this.assumptions = const [],
  });

  final String id;
  final String agentTurnId;
  final String originalRequest;

  /// Tool domains routed for this turn. Null means all tools are exposed
  /// (routing failed or the request was too broad to scope).
  final Set<String>? domains;

  /// The actions the turn must complete through tools, with live status.
  final List<ContractAction> actions;

  /// User-facing outputs that must appear in the final response.
  final Set<ResponseOutputType> requiredOutputs;

  /// Workflow skill this contract executes through, when one matched.
  final String? skillId;
  final int? skillVersion;

  /// Constraints the turn must respect (e.g. "Do not create duplicate
  /// tasks"). Verified where deterministically checkable, otherwise
  /// passed to the model as instructions.
  final List<String> constraints;
  final List<String> assumptions;

  /// True when the request contains a potentially consequential action.
  /// Informational: actual confirmation gating stays deterministic per-tool.
  final bool requiresConfirmation;

  /// True when a separate final response-generation call is required.
  final bool requiresSynthesis;

  /// True when the turn must pass the deterministic verifier before its
  /// response is returned.
  final bool requiresVerification;

  final DateTime createdAt;

  bool get hasRequiredOutputs => requiredOutputs.isNotEmpty;

  /// Descriptive action labels, for prompts and diagnostics.
  List<String> get actionDescriptions =>
      [for (final action in actions) action.description];

  CompletionContract copyWith({
    List<ContractAction>? actions,
    Set<ResponseOutputType>? requiredOutputs,
    bool? requiresVerification,
  }) =>
      CompletionContract(
        id: id,
        agentTurnId: agentTurnId,
        originalRequest: originalRequest,
        domains: domains,
        actions: actions ?? this.actions,
        requiredOutputs: requiredOutputs ?? this.requiredOutputs,
        skillId: skillId,
        skillVersion: skillVersion,
        constraints: constraints,
        assumptions: assumptions,
        requiresConfirmation: requiresConfirmation,
        requiresSynthesis: requiresSynthesis,
        requiresVerification:
            requiresVerification ?? this.requiresVerification,
        createdAt: createdAt,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'agent_turn_id': agentTurnId,
        'original_request': originalRequest,
        'domains': domains?.toList(),
        'actions': [for (final action in actions) action.toJson()],
        'required_outputs': requiredOutputs.map((o) => o.wireName).toList(),
        if (skillId != null) 'skill_id': skillId,
        if (skillVersion != null) 'skill_version': skillVersion,
        if (constraints.isNotEmpty) 'constraints': constraints,
        if (assumptions.isNotEmpty) 'assumptions': assumptions,
        'requires_confirmation': requiresConfirmation,
        'requires_synthesis': requiresSynthesis,
        'requires_verification': requiresVerification,
        'created_at': createdAt.toIso8601String(),
      };

  factory CompletionContract.fromJson(Map<String, Object?> json) =>
      CompletionContract(
        id: json['id'] as String? ?? AgentId.contract(),
        agentTurnId: json['agent_turn_id'] as String? ?? '',
        originalRequest: json['original_request'] as String? ?? '',
        domains: json['domains'] is List
            ? ((json['domains'] as List).whereType<String>().toSet())
            : null,
        actions: ((json['actions'] as List?) ?? const [])
            .whereType<Map>()
            .map((raw) => ContractAction.fromJson(raw.cast<String, Object?>()))
            .toList(),
        requiredOutputs: {
          for (final name in ((json['required_outputs'] as List?) ?? const [])
              .whereType<String>())
            if (ResponseOutputType.fromWireName(name) != null)
              ResponseOutputType.fromWireName(name)!,
        },
        skillId: json['skill_id'] as String?,
        skillVersion: json['skill_version'] as int?,
        constraints: ((json['constraints'] as List?) ?? const [])
            .whereType<String>()
            .toList(),
        assumptions: ((json['assumptions'] as List?) ?? const [])
            .whereType<String>()
            .toList(),
        requiresConfirmation: json['requires_confirmation'] == true,
        requiresSynthesis: json['requires_synthesis'] == true,
        requiresVerification: json['requires_verification'] == true,
        createdAt:
            DateTime.tryParse(json['created_at'] as String? ?? '') ??
                DateTime.now(),
      );
}

/// Conservative contract used when routing fails: expose all tools, plan no
/// specific actions, but never skip final synthesis - a useful confirmation
/// beats silently ending after tool execution. Verification stays on so a
/// blind turn is still checked against its own execution report.
CompletionContract fallbackContract({
  required String originalRequest,
  Set<String>? domains,
  String? agentTurnId,
}) {
  return CompletionContract(
    id: AgentId.contract(),
    agentTurnId: agentTurnId ?? AgentId.turn(),
    originalRequest: originalRequest,
    domains: domains,
    actions: const [],
    requiredOutputs: const {
      ResponseOutputType.confirmation,
    },
    requiresConfirmation: false,
    requiresSynthesis: true,
    requiresVerification: true,
    createdAt: DateTime.now(),
  );
}
