import 'package:uuid/uuid.dart';

import '../../agent/behaviors/output_validator.dart';
import '../database/app_database.dart';
import '../models/agent_behavior.dart';

class BehaviorRepository {
  BehaviorRepository(this._database);

  final AppDatabase _database;
  static const _uuid = Uuid();

  /// Monotonic version of the behaviour table, used as a cache key by
  /// [BehaviorCompiler] and recorded on job runs so a past result can be
  /// explained by the rules in force at the time.
  ///
  /// Derived from the rows themselves (count + newest update) rather than a
  /// counter, so it is correct across isolates without shared state: any
  /// insert, update or delete changes it.
  Future<int> currentVersion() async {
    try {
      final rows = await _database.db.rawQuery(
          'SELECT COUNT(*) AS n, MAX(updated_at) AS newest '
          'FROM agent_behaviors');
      if (rows.isEmpty) return 0;
      final count = (rows.first['n'] as int?) ?? 0;
      final newest = rows.first['newest'] as String? ?? '';
      return Object.hash(count, newest) & 0x7fffffff;
    } catch (_) {
      return 0;
    }
  }

  /// Active rules, expired ones removed.
  ///
  /// Expiry is applied on read rather than by a sweeper so a temporary rule
  /// stops applying the moment it lapses, even if nothing has run since.
  Future<List<AgentBehavior>> listActive({DateTime? now}) async {
    final at = (now ?? DateTime.now()).toIso8601String();
    final rows = await _database.db.query(
      'agent_behaviors',
      where: "status = 'Active' AND (expires_at IS NULL OR expires_at > ?)",
      whereArgs: [at],
      orderBy: 'priority ASC, created_at ASC',
    );
    return rows.map(AgentBehavior.fromRow).toList();
  }

  /// How long an inferred rule survives without being reinforced.
  ///
  /// A rule Exa worked out for itself is a hypothesis. If it keeps applying
  /// to real turns it earns its place; if it never comes up again, it was a
  /// one-off request that should not still be shaping answers next quarter.
  /// Rules the user stated explicitly never expire this way.
  static const inferredRuleLifetime = Duration(days: 60);

  /// Marks rules as having actually been applied, which feeds the staleness
  /// view (a rule that never gets used is a candidate for archiving).
  ///
  /// For inferred rules this is also reinforcement: being applied is the
  /// evidence that keeps them alive, and each application pushes their
  /// expiry out.
  Future<void> markUsed(Iterable<String> behaviorIds) async {
    final ids = behaviorIds.toSet();
    if (ids.isEmpty) return;
    final placeholders = List.filled(ids.length, '?').join(',');
    final now = DateTime.now();
    try {
      await _database.db.rawUpdate(
        'UPDATE agent_behaviors SET last_used_at = ? WHERE id IN '
        '($placeholders)',
        [now.toIso8601String(), ...ids],
      );
      await _database.db.rawUpdate(
        'UPDATE agent_behaviors SET '
        'evidence_count = evidence_count + 1, expires_at = ? '
        "WHERE source != 'explicit' AND approved_by_user = 0 "
        'AND id IN ($placeholders)',
        [
          now.add(inferredRuleLifetime).toIso8601String(),
          ...ids,
        ],
      );
    } catch (_) {
      // Usage stamps are diagnostics, never worth failing a turn over.
    }
  }

  /// The user reaffirming a rule: raises confidence and resets staleness.
  Future<void> confirm(String id) async {
    final now = DateTime.now();
    await _database.db.rawUpdate(
      'UPDATE agent_behaviors SET last_confirmed_at = ?, updated_at = ?, '
      'evidence_count = evidence_count + 1, '
      'confidence = MIN(1.0, confidence + 0.2) WHERE id = ?',
      [now.toIso8601String(), now.toIso8601String(), id],
    );
  }

  /// The user pushing back on a rule. Enough negative feedback and an
  /// inferred rule pauses itself rather than continuing to misfire.
  Future<void> recordNegativeFeedback(String id) async {
    final now = DateTime.now();
    await _database.db.rawUpdate(
      'UPDATE agent_behaviors SET negative_feedback_count = '
      'negative_feedback_count + 1, confidence = MAX(0.0, confidence - 0.3), '
      'updated_at = ? WHERE id = ?',
      [now.toIso8601String(), id],
    );
    final behavior = await getById(id);
    if (behavior != null &&
        behavior.source != 'explicit' &&
        behavior.negativeFeedbackCount >= 2) {
      await setStatus(id, 'Paused');
    }
  }

  Future<List<AgentBehavior>> listAll() async {
    final rows = await _database.db
        .query('agent_behaviors', orderBy: 'priority ASC, created_at ASC');
    return rows.map(AgentBehavior.fromRow).toList();
  }

  Future<AgentBehavior?> getById(String id) async {
    final rows = await _database.db
        .query('agent_behaviors', where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : AgentBehavior.fromRow(rows.first);
  }

  /// Creates and activates a behavior. Used for Low Risk rules that the
  /// agent may save automatically (the change is still shown to the user).
  Future<AgentBehavior> createActive({
    required String title,
    required String behaviorType,
    required String ruleText,
    String? description,
    String riskLevel = 'Low Risk',
    String createdBy = 'agent',
    bool approvedByUser = false,
    Map<String, Object?> params = const {},
    String? enforcementMode,
    String source = 'explicit',
    double? confidence,
    String? scopeIntent,
    String? conflictGroup,
    DateTime? expiresAt,
  }) async {
    final now = DateTime.now();
    final behavior = AgentBehavior(
      id: _uuid.v4(),
      behaviorKey: _keyFromTitle(title),
      title: title,
      description: description,
      behaviorType: behaviorType,
      ruleText: ruleText,
      status: 'Active',
      riskLevel: riskLevel,
      createdBy: createdBy,
      approvedByUser: approvedByUser,
      params: params,
      // A rule the app implements itself (quiet hours, event defaults) is
      // marked so it can be kept out of prompts; anything with measurable
      // output constraints is validated in code after the model answers.
      enforcementMode: enforcementMode ??
          defaultEnforcementMode(behaviorType, params),
      source: source,
      confidence: confidence ?? (source == 'explicit' ? 1.0 : 0.5),
      scopeIntent: scopeIntent,
      conflictGroup: conflictGroup ?? defaultConflictGroup(behaviorType),
      lastConfirmedAt: source == 'explicit' ? now : null,
      // An inferred rule starts on a clock. It is active immediately - a
      // low-risk preference is not worth interrupting the user for - but it
      // has to keep being applied to stay alive, so a single unusual
      // request cannot become a standing rule by default.
      expiresAt: expiresAt ??
          (source == 'explicit' || approvedByUser
              ? null
              : now.add(inferredRuleLifetime)),
      createdAt: now,
      updatedAt: now,
    );
    await _database.db.insert('agent_behaviors', behavior.toRow());
    await _writeVersion(behavior.id, 1, ruleText, 'Initial rule', createdBy);
    return behavior;
  }

  Future<AgentBehavior?> updateRuleText(
    String id,
    String ruleText, {
    String? changeReason,
    String changedBy = 'agent',
  }) async {
    final existing = await getById(id);
    if (existing == null) return null;
    final versions = await listVersions(id);
    final nextVersion = versions.length + 1;
    await _database.db.update(
      'agent_behaviors',
      {
        'rule_text': ruleText,
        'updated_at': DateTime.now().toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [id],
    );
    await _writeVersion(id, nextVersion, ruleText, changeReason, changedBy);
    return getById(id);
  }

  Future<void> setStatus(String id, String status) async {
    await _database.db.update(
      'agent_behaviors',
      {'status': status, 'updated_at': DateTime.now().toIso8601String()},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<bool> delete(String id) async {
    await _database.db.delete('agent_behavior_versions',
        where: 'behavior_id = ?', whereArgs: [id]);
    final count = await _database.db
        .delete('agent_behaviors', where: 'id = ?', whereArgs: [id]);
    return count > 0;
  }

  Future<List<Map<String, Object?>>> listVersions(String behaviorId) {
    return _database.db.query(
      'agent_behavior_versions',
      where: 'behavior_id = ?',
      whereArgs: [behaviorId],
      orderBy: 'version_number ASC',
    );
  }

  /// Restores the rule text of an earlier version (as a new version, so the
  /// history stays append-only).
  Future<AgentBehavior?> rollbackToVersion(
      String behaviorId, int versionNumber) async {
    final versions = await listVersions(behaviorId);
    final target = versions
        .where((v) => v['version_number'] == versionNumber)
        .toList();
    if (target.isEmpty) return null;
    return updateRuleText(
      behaviorId,
      target.first['rule_text'] as String,
      changeReason: 'Rollback to version $versionNumber',
      changedBy: 'user',
    );
  }

  // ---- Change requests (Medium/High risk proposals awaiting the user) ----

  Future<BehaviorChangeRequest> createChangeRequest({
    required String proposedTitle,
    required String proposedRuleText,
    required String behaviorType,
    required String riskLevel,
    String? reason,
    String? behaviorId,
    Map<String, Object?> params = const {},
  }) async {
    final request = BehaviorChangeRequest(
      id: _uuid.v4(),
      behaviorId: behaviorId,
      proposedTitle: proposedTitle,
      proposedRuleText: proposedRuleText,
      behaviorType: behaviorType,
      reason: reason,
      riskLevel: riskLevel,
      params: params,
      createdAt: DateTime.now(),
    );
    await _database.db.insert('behavior_change_requests', request.toRow());
    return request;
  }

  Future<List<BehaviorChangeRequest>> listPendingRequests() async {
    final rows = await _database.db.query(
      'behavior_change_requests',
      where: "status = 'Pending'",
      orderBy: 'created_at ASC',
    );
    return rows.map(BehaviorChangeRequest.fromRow).toList();
  }

  /// User approves a pending proposal: activates it as a behavior.
  Future<AgentBehavior?> approveChangeRequest(String requestId) async {
    final rows = await _database.db.query('behavior_change_requests',
        where: 'id = ?', whereArgs: [requestId], limit: 1);
    if (rows.isEmpty) return null;
    final request = BehaviorChangeRequest.fromRow(rows.first);
    final behavior = await createActive(
      title: request.proposedTitle,
      behaviorType: request.behaviorType,
      ruleText: request.proposedRuleText,
      description: request.reason,
      riskLevel: request.riskLevel,
      approvedByUser: true,
      params: request.params,
    );
    await _database.db.update(
      'behavior_change_requests',
      {
        'status': 'Approved',
        'user_decision': 'approved',
        'behavior_id': behavior.id,
        'decided_at': DateTime.now().toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [requestId],
    );
    return behavior;
  }

  Future<void> rejectChangeRequest(String requestId) async {
    await _database.db.update(
      'behavior_change_requests',
      {
        'status': 'Rejected',
        'user_decision': 'rejected',
        'decided_at': DateTime.now().toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [requestId],
    );
  }

  Future<void> addEvaluation(
    String behaviorId,
    String note, {
    int? successScore,
    String? failureReason,
  }) async {
    await _database.db.insert('behavior_evaluations', {
      'id': _uuid.v4(),
      'behavior_id': behaviorId,
      'evaluation_note': note,
      'success_score': successScore,
      'failure_reason': failureReason,
      'created_at': DateTime.now().toIso8601String(),
    });
  }

  Future<void> _writeVersion(
    String behaviorId,
    int versionNumber,
    String ruleText,
    String? changeReason,
    String changedBy,
  ) async {
    await _database.db.insert('agent_behavior_versions', {
      'id': _uuid.v4(),
      'behavior_id': behaviorId,
      'version_number': versionNumber,
      'rule_text': ruleText,
      'change_reason': changeReason,
      'changed_by': changedBy,
      'created_at': DateTime.now().toIso8601String(),
    });
  }

  /// Rules the app can implement itself are marked `code_enforced` so they
  /// never spend prompt tokens; rules carrying measurable output limits are
  /// `output_validated` so they are checked after the model answers.
  static String defaultEnforcementMode(
      String behaviorType, Map<String, Object?> params) {
    if (behaviorType == 'safety_rule') return 'mandatory';
    if (params.isNotEmpty) {
      // A rule the app fires itself is guaranteed by code, so it does not
      // also need to spend tokens in every prompt.
      if (params['trigger'] is Map) return 'code_enforced';
      const codeEnforcedTypes = {'notification_rule', 'schedule_rule'};
      if (codeEnforcedTypes.contains(behaviorType)) return 'code_enforced';
      if (params.keys.any(OutputConstraint.kinds.contains)) {
        return 'output_validated';
      }
    }
    return 'advisory';
  }

  /// Default bucket of contradictions a rule type belongs to, so two rules
  /// answering the same question can be resolved instead of both applying.
  static String? defaultConflictGroup(String behaviorType) =>
      switch (behaviorType) {
        'summary_rule' => 'response_shape',
        'notification_rule' => 'notification_timing',
        'schedule_rule' => 'event_defaults',
        'task_prioritization_rule' => 'task_ordering',
        _ => null,
      };

  static String _keyFromTitle(String title) {
    final slug = title
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    final suffix = DateTime.now().millisecondsSinceEpoch.toRadixString(36);
    return '${slug}_$suffix';
  }
}
