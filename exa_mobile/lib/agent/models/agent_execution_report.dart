/// Normalized summary of everything the tool loop did this turn, so the
/// final synthesis model reads one report instead of dozens of raw payloads.
class AgentExecutionReport {
  const AgentExecutionReport({
    required this.originalRequest,
    required this.toolsCalled,
    required this.actionsCompleted,
    required this.actionsFailed,
    required this.tasksCreated,
    required this.eventsCreated,
    required this.eventsModified,
    required this.emailDigestItems,
    required this.filesAffected,
    required this.screensCreated,
    required this.rulesChanged,
    required this.warnings,
    required this.uncertainItems,
    required this.partialFailures,
    this.entitiesTouched = const [],
  });

  final String originalRequest;
  final List<String> toolsCalled;
  final List<String> actionsCompleted;
  final List<String> actionsFailed;
  final List<Map<String, dynamic>> tasksCreated;
  final List<Map<String, dynamic>> eventsCreated;
  final List<Map<String, dynamic>> eventsModified;
  final List<Map<String, dynamic>> emailDigestItems;
  final List<Map<String, dynamic>> filesAffected;
  final List<Map<String, dynamic>> screensCreated;
  final List<Map<String, dynamic>> rulesChanged;
  final List<String> warnings;
  final List<String> uncertainItems;
  final List<String> partialFailures;

  /// Entity graph ids this turn touched (created, modified, read).
  final List<String> entitiesTouched;

  bool get hasFailures =>
      actionsFailed.isNotEmpty || partialFailures.isNotEmpty;

  bool get hasWarnings => warnings.isNotEmpty || uncertainItems.isNotEmpty;

  Map<String, Object?> toJson() => {
        'original_request': originalRequest,
        'tools_called': toolsCalled,
        'actions_completed': actionsCompleted,
        'actions_failed': actionsFailed,
        'tasks_created': tasksCreated,
        'events_created': eventsCreated,
        'events_modified': eventsModified,
        'email_digest_items': emailDigestItems,
        'files_affected': filesAffected,
        'screens_created': screensCreated,
        'rules_changed': rulesChanged,
        'warnings': warnings,
        'uncertain_items': uncertainItems,
        'partial_failures': partialFailures,
        if (entitiesTouched.isNotEmpty) 'entities_touched': entitiesTouched,
      };
}
