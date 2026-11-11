import '../models/agent_execution_report.dart';
import '../models/tool_execution_record.dart';
import '../models/turn_contract.dart';
import 'tool_labels.dart';

/// A message written in code rather than by the model.
class RenderedResponse {
  const RenderedResponse({
    required this.message,
    required this.kind,
    this.includedOutputs = const {},
  });

  final String message;

  /// Which renderer produced it, for diagnostics: `task_created`,
  /// `reminder_created`, `email_digest`, `permission_denied`, ...
  final String kind;

  final Set<ResponseOutputType> includedOutputs;
}

/// Deterministic responses for the turns that do not need a model to write
/// them.
///
/// The separate synthesis call earns its latency on a rundown or an
/// analysis. It does not earn it on "reminder created, Friday at 4" — and
/// worse, a model asked to confirm a stored date is the one component in
/// the pipeline that can get that date wrong. Rendering these in code makes
/// them faster, cheaper, and incapable of contradicting the database.
///
/// Every renderer copies the `..._label` value the tool returned verbatim.
/// None of them computes a weekday.
class DeterministicRenderer {
  const DeterministicRenderer();

  /// Outputs a rendered message can satisfy. Anything asking for analysis,
  /// a recommendation, or a rundown is beyond what code can honestly write.
  static const renderableOutputs = {
    ResponseOutputType.confirmation,
    ResponseOutputType.changeDescription,
    ResponseOutputType.resultList,
    ResponseOutputType.failureReport,
  };

  /// Returns a finished message, or null when this turn needs the model.
  ///
  /// Null is the safe answer and the common one: rendering a turn that
  /// deserved a real answer produces a curt non-sequitur, while sending a
  /// renderable turn to the model merely costs a call.
  RenderedResponse? render({
    required CompletionContract contract,
    required AgentExecutionReport report,
    required List<ToolExecutionRecord> records,
  }) {
    final actionable = [
      for (final record in records)
        if (!record.isControlPlane) record,
    ];
    if (actionable.isEmpty) return null;

    // Anything the contract wants that code cannot write honestly ends the
    // attempt here.
    if (contract.requiredOutputs
        .any((output) => !renderableOutputs.contains(output))) {
      return null;
    }

    // A denial is the clearest case: the user needs to know what was
    // refused and why, and the reason is already written.
    final denied = [
      for (final record in actionable)
        if (record.status == ToolExecutionStatus.denied) record,
    ];
    if (denied.isNotEmpty && denied.length == actionable.length) {
      return RenderedResponse(
        kind: 'permission_denied',
        includedOutputs: const {
          ResponseOutputType.confirmation,
          ResponseOutputType.failureReport,
        },
        message: denied.length == 1
            ? "I couldn't do that. ${denied.first.errorMessage ?? 'It is not '
                'permitted here.'}"
            : "I couldn't do those:\n"
                '${denied.map((r) => '- ${ToolLabels.describe(r.toolName)}: '
                    '${r.errorMessage ?? 'not permitted here'}').join('\n')}',
      );
    }

    // Mixed outcomes, partial work, or anything that failed: the user needs
    // the nuance a template cannot carry.
    if (report.hasFailures || report.hasWarnings) return null;

    final successes = [
      for (final record in actionable)
        if (record.status == ToolExecutionStatus.success) record,
    ];
    if (successes.length != actionable.length) return null;

    // One clean action is the sweet spot. Several unrelated ones read
    // better when a writer joins them up.
    if (successes.length == 1) {
      final single = _renderSingle(successes.first);
      if (single != null) return single;
    }

    if (successes.length > 1 && _allSameTool(successes)) {
      final batch = _renderBatch(successes);
      if (batch != null) return batch;
    }

    return null;
  }

  static bool _allSameTool(List<ToolExecutionRecord> records) =>
      records.every((record) => record.toolName == records.first.toolName);

  RenderedResponse? _renderSingle(ToolExecutionRecord record) {
    final data = record.rawResult is Map
        ? (record.rawResult as Map).cast<String, Object?>()
        : const <String, Object?>{};
    String? field(String key) {
      final value = data[key] ?? record.arguments[key];
      return value is String && value.trim().isNotEmpty ? value.trim() : null;
    }

    // The label is copied, never recomputed: it is the same string the
    // Reminders and Schedule screens show, which is what stops the
    // confirmation and the screen contradicting each other.
    final title = field('title') ?? field('name');

    switch (record.toolName) {
      case 'create_task':
        if (title == null) return null;
        final due = field('due_at_label');
        return RenderedResponse(
          kind: 'task_created',
          includedOutputs: const {ResponseOutputType.confirmation},
          message: due == null
              ? 'Task created: $title'
              : 'Task created: $title\nDue: $due',
        );
      case 'create_reminder':
        if (title == null) return null;
        final at = field('remind_at_label');
        return RenderedResponse(
          kind: 'reminder_created',
          includedOutputs: const {ResponseOutputType.confirmation},
          message: at == null
              ? "Reminder set: $title"
              : "Reminder set: $title\nWhen: $at",
        );
      case 'complete_task':
        if (title == null) return null;
        return RenderedResponse(
          kind: 'task_completed',
          includedOutputs: const {ResponseOutputType.confirmation},
          message: 'Marked done: $title',
        );
      case 'create_schedule_event':
        if (title == null) return null;
        final start = field('start_at_label');
        final location = field('location');
        return RenderedResponse(
          kind: 'event_created',
          includedOutputs: const {ResponseOutputType.confirmation},
          message: [
            'Event added: $title',
            if (start != null) 'When: $start',
            if (location != null) 'Where: $location',
          ].join('\n'),
        );
      case 'create_scheduled_job':
        if (title == null) return null;
        final next = field('next_run_at_label');
        return RenderedResponse(
          kind: 'job_created',
          includedOutputs: const {
            ResponseOutputType.confirmation,
            ResponseOutputType.changeDescription,
          },
          message: next == null
              ? 'Scheduled: $title'
              : 'Scheduled: $title\nFirst run: $next',
        );
      case 'sync_emails':
        final fetched = data['fetched'] ?? data['new_emails'] ?? data['count'];
        if (fetched is! num) return null;
        return RenderedResponse(
          kind: 'email_sync',
          includedOutputs: const {ResponseOutputType.confirmation},
          message: fetched == 0
              ? 'Mail checked — nothing new.'
              : 'Mail checked — $fetched new '
                  'message${fetched == 1 ? '' : 's'}.',
        );
      case 'sync_messages':
        final added = data['new_messages'];
        if (added is! num) return null;
        return RenderedResponse(
          kind: 'message_sync',
          includedOutputs: const {ResponseOutputType.confirmation},
          message: added == 0
              ? 'Chats checked — nothing new.'
              : 'Chats checked — $added new '
                  'message${added == 1 ? '' : 's'}.',
        );
      case 'sync_device_calendar':
        final imported = data['imported'] ?? data['count'];
        if (imported is! num) return null;
        return RenderedResponse(
          kind: 'calendar_sync',
          includedOutputs: const {ResponseOutputType.confirmation},
          message: imported == 0
              ? 'Calendar synced — nothing new to import.'
              : 'Calendar synced — $imported '
                  'event${imported == 1 ? '' : 's'} imported.',
        );
      default:
        return null;
    }
  }

  /// Several of the same clean action: "3 tasks created", itemized.
  RenderedResponse? _renderBatch(List<ToolExecutionRecord> records) {
    const batchable = {
      'create_task': ('Tasks created', 'title'),
      'create_reminder': ('Reminders set', 'title'),
      'complete_task': ('Tasks completed', 'title'),
    };
    final spec = batchable[records.first.toolName];
    if (spec == null) return null;
    if (records.length > 8) return null;

    final titles = <String>[];
    for (final record in records) {
      final data = record.rawResult is Map
          ? (record.rawResult as Map).cast<String, Object?>()
          : const <String, Object?>{};
      final title = (data[spec.$2] ?? record.arguments[spec.$2]);
      if (title is! String || title.trim().isEmpty) return null;
      titles.add(title.trim());
    }
    return RenderedResponse(
      kind: '${records.first.toolName}_batch',
      includedOutputs: const {
        ResponseOutputType.confirmation,
        ResponseOutputType.resultList,
      },
      message: '${spec.$1} (${titles.length}):\n'
          '${titles.map((t) => '- $t').join('\n')}',
    );
  }
}
