import 'dart:convert';

class AgentBehavior {
  static const types = [
    'preference_rule',
    'workflow_rule',
    'summary_rule',
    'schedule_rule',
    'notification_rule',
    'screen_generation_rule',
    'email_review_rule',
    'calendar_review_rule',
    'task_prioritization_rule',
    'safety_rule',
    'integration_rule',
  ];
  static const statuses = [
    'Draft',
    'Active',
    'Paused',
    'Rejected',
    'Archived',
    'Superseded',
  ];
  static const riskLevels = ['Low Risk', 'Medium Risk', 'High Risk'];

  /// How a rule is applied.
  ///
  /// `advisory` is prompt text the model should follow. `outputValidated`
  /// is additionally checked in code after the model answers.
  /// `codeEnforced` is implemented by the app (quiet hours, event defaults)
  /// and therefore does NOT need to be spent on prompt tokens.
  /// `mandatory` is a safety rule that always applies and always renders.
  static const enforcementModes = [
    'advisory',
    'output_validated',
    'code_enforced',
    'mandatory',
  ];

  /// Where a rule came from, which decides how much it is trusted in a
  /// conflict and whether it may expire.
  static const sources = ['explicit', 'inferred', 'imported', 'system'];

  final String id;
  final String behaviorKey;
  final String title;
  final String? description;
  final String behaviorType;
  final String ruleText;
  final int priority;
  final String status;
  final String riskLevel;
  final bool requiresConfirmation;
  final String createdBy;
  final bool approvedByUser;

  /// Machine-readable parameters for the rules that code enforces rather
  /// than only reads: `notification_rule` takes
  /// `{"quiet_hours": {"from": "22:00", "to": "07:00"}}`, `schedule_rule`
  /// takes `{"default_lead_minutes": 15, "default_duration_minutes": 30}`.
  /// Empty for the rules that are purely prompt text.
  final Map<String, Object?> params;

  /// Schema generation of [params], so a future format change can migrate
  /// or ignore old parameter shapes instead of misreading them.
  final int paramsSchemaVersion;

  /// One of [enforcementModes].
  final String enforcementMode;

  /// One of [sources].
  final String source;

  /// 0-1. Inferred rules start low and rise as they are confirmed.
  final double confidence;

  /// Free-text scope this rule was meant for ("status updates", "work
  /// email"). Used as a specificity signal in conflict resolution.
  final String? scopeIntent;

  /// Rules that answer the same question (`response_length`,
  /// `notification_timing`). At most one rule per group survives
  /// resolution, so contradictions can't both reach the model.
  final String? conflictGroup;

  final int version;
  final int evidenceCount;
  final int negativeFeedbackCount;
  final DateTime? lastUsedAt;
  final DateTime? lastConfirmedAt;

  /// After this, the rule stops applying (temporary project preferences).
  final DateTime? expiresAt;
  final DateTime createdAt;
  final DateTime updatedAt;

  const AgentBehavior({
    required this.id,
    required this.behaviorKey,
    required this.title,
    this.description,
    required this.behaviorType,
    required this.ruleText,
    this.priority = 100,
    this.status = 'Draft',
    this.riskLevel = 'Low Risk',
    this.requiresConfirmation = false,
    this.createdBy = 'agent',
    this.approvedByUser = false,
    this.params = const {},
    this.paramsSchemaVersion = 1,
    this.enforcementMode = 'advisory',
    this.source = 'inferred',
    this.confidence = 0.5,
    this.scopeIntent,
    this.conflictGroup,
    this.version = 1,
    this.evidenceCount = 1,
    this.negativeFeedbackCount = 0,
    this.lastUsedAt,
    this.lastConfirmedAt,
    this.expiresAt,
    required this.createdAt,
    required this.updatedAt,
  });

  bool get isExpired =>
      expiresAt != null && expiresAt!.isBefore(DateTime.now());

  /// A rule the app implements itself; putting it in a prompt would spend
  /// tokens restating something already guaranteed.
  bool get isCodeEnforced => enforcementMode == 'code_enforced';

  bool get isMandatory =>
      enforcementMode == 'mandatory' || behaviorType == 'safety_rule';

  /// Safety rules the app ships, which a user-created rule may never
  /// weaken. Distinguished from a user's own safety preference.
  bool get isSystemSafety => behaviorType == 'safety_rule' &&
      (source == 'system' || createdBy == 'system');

  /// How narrowly the rule is scoped, highest wins in a conflict: an
  /// explicitly scoped rule beats a typed one, which beats a global.
  int get scopeSpecificity {
    if (scopeIntent != null && scopeIntent!.trim().isNotEmpty) return 3;
    if (params.isNotEmpty) return 2;
    const globals = {'preference_rule', 'workflow_rule'};
    return globals.contains(behaviorType) ? 0 : 1;
  }

  /// Freshness signal for conflict resolution: a rule the user recently
  /// confirmed outranks one inferred long ago.
  DateTime get effectiveConfirmedAt =>
      lastConfirmedAt ?? (source == 'explicit' ? createdAt : updatedAt);

  Map<String, Object?> toRow() => {
        'id': id,
        'behavior_key': behaviorKey,
        'title': title,
        'description': description,
        'behavior_type': behaviorType,
        'rule_text': ruleText,
        'priority': priority,
        'status': status,
        'risk_level': riskLevel,
        'requires_confirmation': requiresConfirmation ? 1 : 0,
        'created_by': createdBy,
        'approved_by_user': approvedByUser ? 1 : 0,
        'params': params.isEmpty ? null : jsonEncode(params),
        'params_schema_version': paramsSchemaVersion,
        'enforcement_mode': enforcementMode,
        'source': source,
        'confidence': confidence,
        'scope_intent': scopeIntent,
        'conflict_group': conflictGroup,
        'version': version,
        'evidence_count': evidenceCount,
        'negative_feedback_count': negativeFeedbackCount,
        'last_used_at': lastUsedAt?.toIso8601String(),
        'last_confirmed_at': lastConfirmedAt?.toIso8601String(),
        'expires_at': expiresAt?.toIso8601String(),
        'created_at': createdAt.toIso8601String(),
        'updated_at': updatedAt.toIso8601String(),
      };

  factory AgentBehavior.fromRow(Map<String, Object?> row) => AgentBehavior(
        id: row['id'] as String,
        behaviorKey: row['behavior_key'] as String,
        title: row['title'] as String,
        description: row['description'] as String?,
        behaviorType: row['behavior_type'] as String,
        ruleText: row['rule_text'] as String,
        priority: row['priority'] as int? ?? 100,
        status: row['status'] as String? ?? 'Draft',
        riskLevel: row['risk_level'] as String? ?? 'Low Risk',
        requiresConfirmation: (row['requires_confirmation'] as int? ?? 0) == 1,
        createdBy: row['created_by'] as String? ?? 'agent',
        approvedByUser: (row['approved_by_user'] as int? ?? 0) == 1,
        params: parseParams(row['params']),
        paramsSchemaVersion: (row['params_schema_version'] as int?) ?? 1,
        enforcementMode: row['enforcement_mode'] as String? ?? 'advisory',
        source: row['source'] as String? ?? 'inferred',
        confidence: (row['confidence'] as num?)?.toDouble() ?? 0.5,
        scopeIntent: row['scope_intent'] as String?,
        conflictGroup: row['conflict_group'] as String?,
        version: (row['version'] as int?) ?? 1,
        evidenceCount: (row['evidence_count'] as int?) ?? 1,
        negativeFeedbackCount:
            (row['negative_feedback_count'] as int?) ?? 0,
        lastUsedAt: _parseDate(row['last_used_at']),
        lastConfirmedAt: _parseDate(row['last_confirmed_at']),
        expiresAt: _parseDate(row['expires_at']),
        createdAt:
            DateTime.tryParse(row['created_at'] as String? ?? '') ??
                DateTime.now(),
        updatedAt:
            DateTime.tryParse(row['updated_at'] as String? ?? '') ??
                DateTime.now(),
      );

  static DateTime? _parseDate(Object? value) =>
      value is String && value.isNotEmpty ? DateTime.tryParse(value) : null;

  /// Tolerant params decode: a rule with corrupt parameters still loads and
  /// applies as prompt text rather than breaking every turn that reads it.
  static Map<String, Object?> parseParams(Object? value) {
    if (value is Map) return value.cast<String, Object?>();
    if (value is! String || value.isEmpty) return const {};
    try {
      final decoded = jsonDecode(value);
      return decoded is Map ? decoded.cast<String, Object?>() : const {};
    } catch (_) {
      return const {};
    }
  }
}

class BehaviorChangeRequest {
  final String id;
  final String? behaviorId;
  final String proposedTitle;
  final String proposedRuleText;
  final String behaviorType;
  final String? reason;
  final String riskLevel;
  final String status;
  final String? userDecision;

  /// Carried through approval so an approved rule keeps the parameters the
  /// deterministic consumers need. See [AgentBehavior.params].
  final Map<String, Object?> params;
  final DateTime createdAt;
  final DateTime? decidedAt;

  const BehaviorChangeRequest({
    required this.id,
    this.behaviorId,
    required this.proposedTitle,
    required this.proposedRuleText,
    this.behaviorType = 'preference_rule',
    this.reason,
    required this.riskLevel,
    this.status = 'Pending',
    this.userDecision,
    this.params = const {},
    required this.createdAt,
    this.decidedAt,
  });

  Map<String, Object?> toRow() => {
        'id': id,
        'behavior_id': behaviorId,
        'proposed_title': proposedTitle,
        'proposed_rule_text': proposedRuleText,
        'behavior_type': behaviorType,
        'reason': reason,
        'risk_level': riskLevel,
        'status': status,
        'user_decision': userDecision,
        'params': params.isEmpty ? null : jsonEncode(params),
        'created_at': createdAt.toIso8601String(),
        'decided_at': decidedAt?.toIso8601String(),
      };

  factory BehaviorChangeRequest.fromRow(Map<String, Object?> row) =>
      BehaviorChangeRequest(
        id: row['id'] as String,
        behaviorId: row['behavior_id'] as String?,
        proposedTitle: row['proposed_title'] as String,
        proposedRuleText: row['proposed_rule_text'] as String,
        behaviorType:
            row['behavior_type'] as String? ?? 'preference_rule',
        reason: row['reason'] as String?,
        riskLevel: row['risk_level'] as String,
        status: row['status'] as String? ?? 'Pending',
        userDecision: row['user_decision'] as String?,
        params: AgentBehavior.parseParams(row['params']),
        createdAt:
            DateTime.tryParse(row['created_at'] as String? ?? '') ??
                DateTime.now(),
        decidedAt: row['decided_at'] is String
            ? DateTime.tryParse(row['decided_at'] as String)
            : null,
      );
}
