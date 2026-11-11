import 'dart:convert';

import 'package:sqflite/sqflite.dart' show ConflictAlgorithm;

import '../../data/database/app_database.dart';
import '../models/agent_execution_report.dart';
import '../models/agent_ids.dart';
import '../models/turn_contract.dart';
import '../security/content_trust.dart';

/// A topic compacted into its meaning.
///
/// The message window already preserves tool-use/tool-result pairing by
/// blanking old results rather than removing blocks — that is a correctness
/// mechanism and stays. This is the layer above it: once a topic outgrows
/// what can be replayed, what matters is not the transcript but the
/// decisions, constraints, commitments and open questions it produced.
///
/// Capsules **reference** persisted records; they never become the source of
/// truth. A generated summary that quietly outranks a verified fact is how
/// a long conversation starts confidently repeating something that was
/// corrected fifty messages ago.
class ConversationCapsule {
  const ConversationCapsule({
    required this.id,
    required this.conversationId,
    required this.topicId,
    required this.userGoal,
    this.confirmedDecisions = const [],
    this.currentConstraints = const [],
    this.completedActions = const [],
    this.unresolvedQuestions = const [],
    this.importantEntityIds = const [],
    this.evidenceRefs = const [],
    this.lastUserCorrection,
    this.turnCount = 0,
    this.isStale = false,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String conversationId;
  final String topicId;
  final String userGoal;
  final List<String> confirmedDecisions;
  final List<String> currentConstraints;
  final List<String> completedActions;
  final List<String> unresolvedQuestions;
  final List<String> importantEntityIds;

  /// Ids of records backing the above, so a claim can be re-checked against
  /// the database rather than trusted because a summary said it.
  final List<String> evidenceRefs;

  final String? lastUserCorrection;
  final int turnCount;

  /// True when a user correction landed after this was written. A stale
  /// capsule is never replayed - it is rebuilt.
  final bool isStale;

  final DateTime createdAt;
  final DateTime updatedAt;

  bool get isEmpty =>
      confirmedDecisions.isEmpty &&
      currentConstraints.isEmpty &&
      completedActions.isEmpty &&
      unresolvedQuestions.isEmpty;

  /// The prompt block. Labelled as a generated summary so it is never
  /// mistaken for a verified record.
  String render() {
    final payload = <String, Object?>{
      'topic_id': topicId,
      'user_goal': userGoal,
      if (confirmedDecisions.isNotEmpty)
        'confirmed_decisions': confirmedDecisions,
      if (currentConstraints.isNotEmpty)
        'current_constraints': currentConstraints,
      if (completedActions.isNotEmpty) 'completed_actions': completedActions,
      if (unresolvedQuestions.isNotEmpty)
        'unresolved_questions': unresolvedQuestions,
      if (importantEntityIds.isNotEmpty)
        'important_entity_ids': importantEntityIds,
      if (evidenceRefs.isNotEmpty) 'evidence_refs': evidenceRefs,
      if (lastUserCorrection != null)
        'last_user_correction': lastUserCorrection,
    };
    return 'Earlier in this topic (${ContentTrust.generatedSummary.wireName} '
        '- a summary of $turnCount turns, not a record. Where it disagrees '
        'with a tool result or a stored value, the stored value wins):\n'
        '${jsonEncode(payload)}';
  }

  Map<String, Object?> toRow() => {
        'id': id,
        'conversation_id': conversationId,
        'topic_id': topicId,
        'user_goal': userGoal,
        'confirmed_decisions_json': jsonEncode(confirmedDecisions),
        'current_constraints_json': jsonEncode(currentConstraints),
        'completed_actions_json': jsonEncode(completedActions),
        'unresolved_questions_json': jsonEncode(unresolvedQuestions),
        'important_entity_ids_json': jsonEncode(importantEntityIds),
        'evidence_refs_json': jsonEncode(evidenceRefs),
        'last_user_correction': lastUserCorrection,
        'turn_count': turnCount,
        'is_stale': isStale ? 1 : 0,
        'created_at': createdAt.toIso8601String(),
        'updated_at': updatedAt.toIso8601String(),
      };

  static ConversationCapsule fromRow(Map<String, Object?> row) {
    List<String> list(String key) {
      final raw = row[key];
      if (raw is! String || raw.isEmpty) return const [];
      try {
        return (jsonDecode(raw) as List).whereType<String>().toList();
      } catch (_) {
        return const [];
      }
    }

    return ConversationCapsule(
      id: row['id'] as String,
      conversationId: row['conversation_id'] as String,
      topicId: row['topic_id'] as String,
      userGoal: row['user_goal'] as String? ?? '',
      confirmedDecisions: list('confirmed_decisions_json'),
      currentConstraints: list('current_constraints_json'),
      completedActions: list('completed_actions_json'),
      unresolvedQuestions: list('unresolved_questions_json'),
      importantEntityIds: list('important_entity_ids_json'),
      evidenceRefs: list('evidence_refs_json'),
      lastUserCorrection: row['last_user_correction'] as String?,
      turnCount: (row['turn_count'] as int?) ?? 0,
      isStale: row['is_stale'] == 1,
      createdAt: DateTime.tryParse(row['created_at'] as String? ?? '') ??
          DateTime.now(),
      updatedAt: DateTime.tryParse(row['updated_at'] as String? ?? '') ??
          DateTime.now(),
    );
  }
}

/// Storage and deterministic maintenance of capsules.
///
/// Everything here is derived from the completion contract and the execution
/// report — application state, not a model's recollection. There is no
/// summarization call: a capsule that can be wrong in a new way is worse
/// than no capsule.
class ConversationCapsuleRepository {
  ConversationCapsuleRepository(this._database);

  final AppDatabase _database;

  /// Turns on one topic before its capsule is worth replaying. Below this
  /// the raw history is still short enough to carry itself.
  static const int minimumTurnsToReplay = 3;

  /// Caps so a long-running topic cannot grow an unbounded prompt block.
  static const int maxItemsPerSection = 8;

  Future<ConversationCapsule?> forTopic({
    required String conversationId,
    required String topicId,
  }) async {
    try {
      final rows = await _database.db.query(
        'conversation_capsules',
        where: 'conversation_id = ? AND topic_id = ?',
        whereArgs: [conversationId, topicId],
        limit: 1,
      );
      if (rows.isEmpty) return null;
      final capsule = ConversationCapsule.fromRow(rows.first);
      // A stale capsule contains a value the user has since corrected.
      // Replaying it is exactly the failure this whole layer exists to
      // prevent, so it is withheld until the next turn rebuilds it.
      if (capsule.isStale) return null;
      return capsule;
    } catch (_) {
      return null;
    }
  }

  /// Marks every capsule that could contain a corrected value as stale.
  /// Scoped to the topic when one is known; otherwise the whole
  /// conversation, because a correction with no topic could be about
  /// anything.
  Future<void> invalidate({
    required String conversationId,
    String? topicId,
  }) async {
    try {
      await _database.db.update(
        'conversation_capsules',
        {'is_stale': 1, 'updated_at': DateTime.now().toIso8601String()},
        where: topicId == null
            ? 'conversation_id = ?'
            : 'conversation_id = ? AND topic_id = ?',
        whereArgs: [conversationId, ?topicId],
      );
    } catch (_) {
      // Nothing to invalidate on a database that has not migrated yet.
    }
  }

  /// Folds one finished turn into the topic's capsule.
  ///
  /// Temporary detail is dropped on purpose: which tools ran, in what
  /// order, with what arguments. What survives is what the next turn would
  /// be wrong without — the goal, decisions, constraints, what was actually
  /// done, and what is still open.
  Future<ConversationCapsule?> recordTurn({
    required String conversationId,
    required String topicId,
    required CompletionContract contract,
    required AgentExecutionReport report,
    required List<String> entityIds,
    String? userCorrection,
  }) async {
    try {
      final existing = await _rawFor(conversationId, topicId);
      final now = DateTime.now();

      List<String> merge(List<String> before, Iterable<String> add) {
        final seen = <String>{...before};
        final merged = [...before];
        for (final item in add) {
          final trimmed = item.trim();
          if (trimmed.isEmpty || !seen.add(trimmed)) continue;
          merged.add(trimmed);
        }
        // Newest wins when the section is full: a topic's current
        // constraints matter more than its first ones.
        return merged.length <= maxItemsPerSection
            ? merged
            : merged.sublist(merged.length - maxItemsPerSection);
      }

      final capsule = ConversationCapsule(
        id: existing?.id ?? AgentId.contract(),
        conversationId: conversationId,
        topicId: topicId,
        // The first statement of a goal is usually the clearest; later
        // turns refine rather than replace it.
        userGoal: existing?.userGoal.isNotEmpty == true
            ? existing!.userGoal
            : contract.originalRequest,
        confirmedDecisions: merge(
          existing?.confirmedDecisions ?? const [],
          [
            for (final action in contract.actions)
              if (action.status == ContractItemStatus.completed)
                action.description,
          ],
        ),
        currentConstraints:
            merge(existing?.currentConstraints ?? const [], contract.constraints),
        completedActions:
            merge(existing?.completedActions ?? const [], report.actionsCompleted),
        unresolvedQuestions: merge(
          existing?.unresolvedQuestions ?? const [],
          [...report.uncertainItems, ...report.actionsFailed],
        ),
        importantEntityIds:
            merge(existing?.importantEntityIds ?? const [], entityIds),
        evidenceRefs: merge(existing?.evidenceRefs ?? const [], [
          for (final task in report.tasksCreated)
            if (task['id'] is String) task['id'] as String,
          for (final event in report.eventsCreated)
            if (event['id'] is String) event['id'] as String,
        ]),
        lastUserCorrection: userCorrection ?? existing?.lastUserCorrection,
        turnCount: (existing?.turnCount ?? 0) + 1,
        // Writing a fresh turn into it is what clears the stale flag: the
        // capsule now reflects the world after the correction.
        isStale: false,
        createdAt: existing?.createdAt ?? now,
        updatedAt: now,
      );

      await _database.db.insert(
        'conversation_capsules',
        capsule.toRow(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      return capsule;
    } catch (_) {
      return null;
    }
  }

  Future<ConversationCapsule?> _rawFor(
      String conversationId, String topicId) async {
    final rows = await _database.db.query(
      'conversation_capsules',
      where: 'conversation_id = ? AND topic_id = ?',
      whereArgs: [conversationId, topicId],
      limit: 1,
    );
    return rows.isEmpty ? null : ConversationCapsule.fromRow(rows.first);
  }
}
