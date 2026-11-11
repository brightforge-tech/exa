/// Why a record exists.
///
/// A task that appeared overnight with no explanation is indistinguishable,
/// from the user's side, from a bug. Every record the agent creates carries
/// the job, the run, the tool call and the source item behind it, so the UI
/// can say *"Created by 'Daily Email Digest' from email 'Project deadline
/// changed'"* — and offer to undo it.
class CreationProvenance {
  const CreationProvenance({
    required this.originType,
    this.originJobId,
    this.originRunId,
    this.originToolCallId,
    this.sourceRecordId,
    this.authorizationSource,
    this.reason,
  });

  /// A record the user made directly. Carries no origin chain.
  static const user = CreationProvenance(originType: 'user');

  /// `user`, `agent_turn`, `scheduled_job`, `behavior_trigger`.
  final String originType;

  /// The scheduled job, when one was running.
  final String? originJobId;

  /// The specific run/occurrence, so an undo can target exactly the records
  /// one run produced.
  final String? originRunId;

  /// The tool call that created it.
  final String? originToolCallId;

  /// The item this came from: the email digested, the task expanded.
  final String? sourceRecordId;

  /// What permitted it: `user_confirmation`, `job_permissions`,
  /// `write_scope`, `interactive`.
  final String? authorizationSource;

  /// Short human sentence for the UI.
  final String? reason;

  bool get isAgentCreated => originType != 'user';

  Map<String, Object?> toRow() => {
        'origin_type': originType,
        'origin_job_id': originJobId,
        'origin_run_id': originRunId,
        'origin_tool_call_id': originToolCallId,
        'source_record_id': sourceRecordId,
        'authorization_source': authorizationSource,
        'origin_reason': reason,
      };

  Map<String, Object?> toJson() => {
        'origin_type': originType,
        if (originJobId != null) 'origin_job_id': originJobId,
        if (originRunId != null) 'origin_run_id': originRunId,
        if (originToolCallId != null) 'origin_tool_call_id': originToolCallId,
        if (sourceRecordId != null) 'source_record_id': sourceRecordId,
        if (authorizationSource != null)
          'authorization_source': authorizationSource,
        if (reason != null) 'reason': reason,
      };

  static CreationProvenance fromRow(Map<String, Object?> row) =>
      CreationProvenance(
        originType: row['origin_type'] as String? ?? 'user',
        originJobId: row['origin_job_id'] as String?,
        originRunId: row['origin_run_id'] as String?,
        originToolCallId: row['origin_tool_call_id'] as String?,
        sourceRecordId: row['source_record_id'] as String?,
        authorizationSource: row['authorization_source'] as String?,
        reason: row['origin_reason'] as String?,
      );

  CreationProvenance copyWith({
    String? originToolCallId,
    String? sourceRecordId,
    String? authorizationSource,
    String? reason,
  }) =>
      CreationProvenance(
        originType: originType,
        originJobId: originJobId,
        originRunId: originRunId,
        originToolCallId: originToolCallId ?? this.originToolCallId,
        sourceRecordId: sourceRecordId ?? this.sourceRecordId,
        authorizationSource: authorizationSource ?? this.authorizationSource,
        reason: reason ?? this.reason,
      );

  /// The one-line explanation shown next to the record.
  String describe({String? jobName, String? sourceLabel}) {
    if (!isAgentCreated) return 'Created by you';
    final by = jobName != null
        ? 'Created by "$jobName"'
        : originType == 'behavior_trigger'
            ? 'Created by a rule you saved'
            : 'Created by Exa';
    if (sourceLabel != null && sourceLabel.isNotEmpty) {
      return '$by from "$sourceLabel"';
    }
    if (reason != null && reason!.isNotEmpty) return '$by — $reason';
    return by;
  }
}
