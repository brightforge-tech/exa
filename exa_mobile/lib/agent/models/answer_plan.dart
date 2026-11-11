/// The meaning of an answer, separated from its presentation.
///
/// The synthesis call decides *what is true and worth saying*; a renderer
/// decides how long it is, whether it uses bullets, and what order things
/// come in. Splitting them means the user's output preferences ("two
/// bullets, no tables") are applied by code that cannot forget them, and a
/// model that writes six paragraphs cannot override them by writing well.
///
/// Optional throughout: a synthesis reply that carries only `message` is
/// still valid, and is what most turns produce.
class AnswerPlan {
  const AnswerPlan({
    this.directAnswer = '',
    this.completedActions = const [],
    this.importantFindings = const [],
    this.evidenceIds = const [],
    this.warnings = const [],
    this.unresolvedItems = const [],
    this.suggestedNextAction,
  });

  final String directAnswer;
  final List<String> completedActions;
  final List<String> importantFindings;

  /// Ids from the turn's evidence ledger backing the claims above. An id
  /// that is not in the ledger is a fabrication, and cheap to catch.
  final List<String> evidenceIds;

  final List<String> warnings;
  final List<String> unresolvedItems;
  final String? suggestedNextAction;

  bool get isEmpty =>
      directAnswer.trim().isEmpty &&
      completedActions.isEmpty &&
      importantFindings.isEmpty &&
      warnings.isEmpty &&
      unresolvedItems.isEmpty &&
      suggestedNextAction == null;

  Map<String, Object?> toJson() => {
        'direct_answer': directAnswer,
        if (completedActions.isNotEmpty) 'completed_actions': completedActions,
        if (importantFindings.isNotEmpty)
          'important_findings': importantFindings,
        if (evidenceIds.isNotEmpty) 'evidence_ids': evidenceIds,
        if (warnings.isNotEmpty) 'warnings': warnings,
        if (unresolvedItems.isNotEmpty) 'unresolved_items': unresolvedItems,
        if (suggestedNextAction != null)
          'suggested_next_action': suggestedNextAction,
      };

  static AnswerPlan? fromJson(Map<String, Object?> json) {
    List<String> strings(String key) =>
        ((json[key] as List?) ?? const []).whereType<String>().toList();

    final plan = AnswerPlan(
      directAnswer: json['direct_answer'] as String? ?? '',
      completedActions: strings('completed_actions'),
      importantFindings: strings('important_findings'),
      evidenceIds: strings('evidence_ids'),
      warnings: strings('warnings'),
      unresolvedItems: strings('unresolved_items'),
      suggestedNextAction: json['suggested_next_action'] as String?,
    );
    return plan.isEmpty ? null : plan;
  }

  /// Renders the plan as the message a user reads, applying the turn's
  /// length budget. Used when the model returned a plan but no usable
  /// message — a small model that filled in the structure and then
  /// truncated its prose still has a complete answer here.
  String render({int maxBullets = 6}) {
    final buffer = StringBuffer();
    if (directAnswer.trim().isNotEmpty) {
      buffer.writeln(directAnswer.trim());
    }
    void section(String heading, List<String> items) {
      if (items.isEmpty) return;
      if (buffer.isNotEmpty) buffer.writeln();
      buffer.writeln(heading);
      for (final item in items.take(maxBullets)) {
        buffer.writeln('- $item');
      }
    }

    section('Done:', completedActions);
    section('Worth knowing:', importantFindings);
    section('Warnings:', warnings);
    section('Still open:', unresolvedItems);
    if (suggestedNextAction != null &&
        suggestedNextAction!.trim().isNotEmpty) {
      if (buffer.isNotEmpty) buffer.writeln();
      buffer.writeln('Next: ${suggestedNextAction!.trim()}');
    }
    return buffer.toString().trim();
  }
}
