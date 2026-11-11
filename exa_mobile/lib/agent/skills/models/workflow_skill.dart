import '../../models/tool_execution_record.dart';
import '../../models/turn_contract.dart';

/// What a step does when its tool call fails.
enum SkillStepFailurePolicy {
  /// Abort the whole skill; remaining steps do not run.
  stop,

  /// Record the failure, keep going; the report discloses it.
  continueAndReport,

  /// Retry up to maxRetries, then abort like [stop].
  retry,

  /// Cannot proceed without the user; abort and surface the question.
  requestUserInput,

  /// Ask the user before running this step (in addition to any tool-level
  /// confirmation gate, which always applies).
  requestConfirmation,

  /// Mark skipped and continue.
  skip;

  String get wireName => name;

  static SkillStepFailurePolicy fromWireName(String name) =>
      SkillStepFailurePolicy.values.firstWhere(
        (policy) => policy.name == name.trim(),
        orElse: () => SkillStepFailurePolicy.stop,
      );
}

/// How a matched skill participates in the turn.
enum SkillExecutionMode {
  /// The skill executor runs the steps itself; the open loop is skipped.
  deterministic,

  /// The skill contributes domains, outputs, and a step recipe to the
  /// prompt, but the model-driven loop performs the work (needed when steps
  /// require language understanding, e.g. extracting tasks from email
  /// bodies).
  guided;

  String get wireName => name;

  static SkillExecutionMode fromWireName(String name) =>
      SkillExecutionMode.values.firstWhere(
        (mode) => mode.name == name.trim(),
        orElse: () => SkillExecutionMode.guided,
      );
}

/// One ordered step of a workflow skill. Argument templates may reference
/// skill inputs (`{{input.x}}`), previous step results (`{{stepId.field}}`),
/// and - inside a forEach step - the current item (`{{item.field}}`).
class SkillStep {
  const SkillStep({
    required this.id,
    required this.name,
    required this.toolName,
    this.argumentTemplate = const {},
    this.dependsOn = const [],
    this.failurePolicy = SkillStepFailurePolicy.stop,
    this.condition,
    this.maxRetries = 0,
    this.requiresConfirmation = false,
    this.isOptional = false,
    this.forEachPath,
  });

  final String id;
  final String name;
  final String toolName;
  final Map<String, dynamic> argumentTemplate;
  final List<String> dependsOn;

  /// Simple expression over previous results, e.g.
  /// `read.emails.length > 0` or `sync.ok == true`. Absent = always run.
  final String? condition;
  final SkillStepFailurePolicy failurePolicy;
  final int maxRetries;
  final bool requiresConfirmation;
  final bool isOptional;

  /// Path to a list in a previous step's result (e.g. `read.emails`); the
  /// step then executes once per element with `{{item...}}` bound.
  final String? forEachPath;

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'tool_name': toolName,
        'argument_template': argumentTemplate,
        'depends_on': dependsOn,
        if (condition != null) 'condition': condition,
        'failure_policy': failurePolicy.wireName,
        'max_retries': maxRetries,
        'requires_confirmation': requiresConfirmation,
        'is_optional': isOptional,
        if (forEachPath != null) 'for_each': forEachPath,
      };
}

/// A reusable, versioned, testable procedure for a recurring assistant
/// activity. The model may choose and parameterize a skill; the definition
/// controls domains, steps, completion rules, and confirmation behavior.
class WorkflowSkill {
  const WorkflowSkill({
    required this.id,
    required this.name,
    required this.description,
    required this.version,
    required this.requiredDomains,
    required this.steps,
    required this.requiredOutputs,
    required this.createdAt,
    required this.updatedAt,
    this.triggerExamples = const [],
    this.inputSchema = const {},
    this.mode = SkillExecutionMode.guided,
    this.isEnabled = true,
    this.isSystemSkill = true,
    this.requiresConfirmation = false,
  });

  final String id;
  final String name;
  final String description;
  final int version;
  final Set<String> requiredDomains;
  final List<SkillStep> steps;
  final Set<ResponseOutputType> requiredOutputs;
  final List<String> triggerExamples;
  final Map<String, dynamic> inputSchema;
  final SkillExecutionMode mode;
  final bool isEnabled;
  final bool isSystemSkill;
  final bool requiresConfirmation;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// Prompt-facing recipe summary for guided execution.
  String describeSteps() => steps.isEmpty
      ? '(no fixed steps)'
      : steps
          .map((step) =>
              '${step.name} [${step.toolName}]'
              '${step.condition != null ? ' when ${step.condition}' : ''}')
          .join(' -> ');
}

/// A successful skill match: which skill, how confident, and the inputs the
/// matcher extracted for it.
class SkillMatch {
  const SkillMatch({
    required this.skill,
    required this.confidence,
    this.inputs = const {},
    this.matchSource = 'matcher',
  });

  final WorkflowSkill skill;
  final double confidence;
  final Map<String, dynamic> inputs;

  /// explicit_command | trigger | router | similarity | procedural_memory
  final String matchSource;
}

/// The outcome of one deterministic skill execution.
class SkillExecutionResult {
  const SkillExecutionResult({
    required this.executionId,
    required this.skillId,
    required this.skillName,
    required this.skillVersion,
    required this.status,
    required this.toolRecords,
    this.failureReason,
  });

  final String executionId;
  final String skillId;
  final String skillName;
  final int skillVersion;

  /// completed | partial | failed | cancelled
  final String status;
  final List<ToolExecutionRecord> toolRecords;
  final String? failureReason;

  bool get succeeded => status == 'completed' || status == 'partial';

  Map<String, Object?> toJson() => {
        'execution_id': executionId,
        'skill_id': skillId,
        'skill_name': skillName,
        'skill_version': skillVersion,
        'status': status,
        if (failureReason != null) 'failure_reason': failureReason,
        'tool_calls': toolRecords.length,
      };
}
