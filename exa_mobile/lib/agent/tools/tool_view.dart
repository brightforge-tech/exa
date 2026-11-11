import '../services/execution_report_builder.dart';

/// The model-facing projection of a tool result.
///
/// Repositories and external APIs return more than the model needs, and the
/// tool loop re-sends every result on every iteration, so each surplus field
/// is paid for many times over. The raw payload stays where it belongs —
/// in SQLite and on the execution record, where verification and replay
/// read it — while the model gets three levels:
///
///   * `summary` — one sentence stating what happened,
///   * `facts`   — the items, projected to the fields that matter,
///   * `page`    — how much was shown of how much there is,
///   * `raw_record_refs` — ids, so it can ask for a specific one.
///
/// The projection is per-tool and allowlisted. A tool with no projection
/// passes through untouched: guessing which field a tool needs is how a
/// digest quietly loses the email body it was digesting.
class ToolView {
  const ToolView();

  /// Fields kept for each list-returning tool. Ordered roughly by how
  /// often the model needs them, which is also the order they read in.
  static const Map<String, List<String>> projections = {
    'list_tasks': [
      'id', 'title', 'status', 'priority', 'due_at', 'due_at_label',
      'category', 'completed_at', 'completed_at_label',
    ],
    'list_reminders': [
      'id', 'title', 'remind_at', 'remind_at_label', 'status',
      'recurrence_rule',
    ],
    'list_schedule': [
      'id', 'type', 'title', 'start_at', 'start_at_label', 'end_at',
      'end_at_label', 'location',
    ],
    'list_scheduled_jobs': [
      'id', 'name', 'job_type', 'status', 'next_run_at', 'next_run_at_label',
    ],
    'list_files': ['id', 'name', 'kind', 'size_bytes', 'created_at'],
    'list_mail_accounts': [
      'id', 'display_name', 'email_address', 'sync_enabled', 'last_error',
    ],
    'list_browser_tabs': ['index', 'title', 'url'],
    'list_agent_behaviors': [
      'id', 'title', 'behavior_type', 'status', 'rule_text', 'priority',
    ],
    // Deliberately absent: read_email_context, read_file,
    // read_browser_context, search. Their payload IS the answer - the body
    // text, the page text, the match context - so projecting them would
    // remove the only thing the caller asked for.
  };

  /// The list a projection applies to when a payload carries more than one.
  ///
  /// `list_schedule` returns `events` and the day's `reminders`. Picking the
  /// first known key found `reminders`, applied the event fields to it, and
  /// so dropped every reminder's time - the model was told what would fire
  /// but not when.
  static const _primaryListKey = {'list_schedule': 'events'};

  /// Keys under which tools return their list of items.
  static const _listKeys = [
    'tasks', 'reminders', 'items', 'events', 'emails', 'files', 'jobs',
    'behaviors', 'tabs', 'accounts', 'results', 'screens', 'matches',
  ];

  /// Projects [payload] for the model. Returns it unchanged when the tool
  /// has no projection or the payload is not a list-bearing map.
  Object? project({
    required String toolName,
    required Object? payload,
    required Map<String, Object?> arguments,
  }) {
    if (payload is! Map) return payload;
    final map = payload.cast<String, Object?>();

    final preferred = _primaryListKey[toolName];
    final listKey = preferred != null && map[preferred] is List
        ? preferred
        : _listKeys.firstWhere(
            (key) => map[key] is List,
            orElse: () => '',
          );
    if (listKey.isEmpty) return payload;

    final items = (map[listKey] as List).whereType<Map>().toList();
    if (items.isEmpty) return payload;

    final fields = projections[toolName];
    final facts = fields == null
        ? items.map((item) => item.cast<String, Object?>()).toList()
        : [
            for (final item in items)
              {
                for (final field in fields)
                  if (item[field] != null) field: item[field],
              },
          ];

    final refs = [
      for (final item in items)
        if (item['id'] is String) item['id'] as String,
    ];

    return {
      'status': 'success',
      'summary': ExecutionReportBuilder.summarize(
            toolName: toolName,
            arguments: arguments,
            rawResult: payload,
          ) ??
          '${items.length} ${listKey.replaceAll('_', ' ')}',
      listKey: facts,
      'page': {
        'showing': facts.length,
        'total': map['total'] ?? map['count'] ?? items.length,
        if (map['remaining'] != null) 'remaining': map['remaining'],
        if (map['next_step'] != null) 'next_step': map['next_step'],
      },
      if (refs.isNotEmpty) 'raw_record_refs': refs,
      // Anything the tool returned alongside its list - counts, notes,
      // warnings - is kept: it is small and often the point.
      for (final entry in map.entries)
        if (entry.key != listKey &&
            entry.key != 'total' &&
            entry.key != 'count' &&
            entry.key != 'remaining' &&
            entry.key != 'next_step')
          entry.key: entry.value,
    };
  }
}
