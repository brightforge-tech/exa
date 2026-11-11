import '../models/agent_execution_report.dart';
import '../models/tool_execution_record.dart';
import 'tool_labels.dart';

/// Converts the turn's tool execution records into one normalized report
/// for the synthesis model.
///
/// Mapping is keyed on the tool name (deterministic, matches the registry's
/// actual result shapes) with a secondary pass over the doc-standard result
/// keys (`task`, `event`, `digest_items`, `uncertainties`) so tools that
/// adopt the structured format are picked up without builder changes.
class ExecutionReportBuilder {
  const ExecutionReportBuilder();

  AgentExecutionReport build({
    required String originalRequest,
    required List<ToolExecutionRecord> records,
    List<String> entitiesTouched = const [],
  }) {
    final tasksCreated = <Map<String, dynamic>>[];
    final eventsCreated = <Map<String, dynamic>>[];
    final eventsModified = <Map<String, dynamic>>[];
    final emailDigestItems = <Map<String, dynamic>>[];
    final filesAffected = <Map<String, dynamic>>[];
    final screensCreated = <Map<String, dynamic>>[];
    final rulesChanged = <Map<String, dynamic>>[];
    final actionsCompleted = <String>[];
    final actionsFailed = <String>[];
    final warnings = <String>[];
    final uncertainItems = <String>[];
    final partialFailures = <String>[];

    for (final record in records) {
      // Scope expansion changes the control environment; it never completes
      // part of the user's request, so it stays out of the report.
      if (record.isControlPlane) continue;

      switch (record.status) {
        // These strings are read back to the user by the synthesizer, so
        // the fallbacks speak in tool *labels*, never tool names: "Checked
        // chats", not "sync_messages completed".
        case ToolExecutionStatus.success:
          final summary = record.summary ?? ToolLabels.pill(record.toolName);
          actionsCompleted.add(summary);
        case ToolExecutionStatus.denied:
          actionsFailed.add(
              'Could not ${ToolLabels.describe(record.toolName)}: the user '
              'declined this action');
        case ToolExecutionStatus.partial:
          partialFailures.add(record.errorMessage ??
              'Could only partly ${ToolLabels.describe(record.toolName)}');
        case ToolExecutionStatus.failure:
        case ToolExecutionStatus.cancelled:
          actionsFailed.add(record.errorMessage ??
              'Could not ${ToolLabels.describe(record.toolName)}');
      }

      warnings.addAll(record.warnings);

      final result = record.rawResult;
      if (result is! Map) continue;
      final map = result.cast<String, dynamic>();
      final succeeded = record.status == ToolExecutionStatus.success;

      // An unattended create that found the record already there, or was
      // held because it may be, made nothing: it must not be counted,
      // listed or announced as created.
      if (succeeded &&
          map['already_exists'] != true &&
          map['possible_duplicate'] != true) {
        switch (record.toolName) {
          case 'create_task':
            tasksCreated.add(map);
          case 'create_schedule_event':
            eventsCreated.add(map);
          case 'add_to_phone_calendar':
            eventsCreated.add({
              ...record.arguments,
              'queued_for_approval': true,
              if (map['pending_id'] != null)
                'pending_id': map['pending_id'],
            });
          case 'update_schedule_event':
            eventsModified.add(map);
          case 'read_email_context':
            final emails = map['emails'];
            if (emails is List) {
              emailDigestItems
                  .addAll(emails.whereType<Map>().map(_asDigestItem));
            } else if (map['subject'] != null) {
              emailDigestItems.add(_asDigestItem(map));
            }
          case 'store_file':
          case 'write_file':
          case 'delete_file':
            filesAffected.add({
              'operation':
                  record.toolName == 'delete_file' ? 'deleted' : 'stored',
              ...map,
            });
          case 'create_dynamic_screen':
            screensCreated.add(map);
          case 'propose_behavior_change':
          case 'update_behavior':
          case 'rollback_behavior_version':
            rulesChanged.add({
              ...map,
              if (record.arguments['title'] != null)
                'title': record.arguments['title'],
              if (record.arguments['risk_level'] != null)
                'risk_level': record.arguments['risk_level'],
            });
        }
      }

      // Doc-standard structured keys, for tools that adopt them.
      final task = map['task'];
      if (task is Map) tasksCreated.add(task.cast<String, dynamic>());
      final event = map['event'];
      if (event is Map) eventsCreated.add(event.cast<String, dynamic>());
      final digestItems = map['digest_items'];
      if (digestItems is List) {
        emailDigestItems.addAll(digestItems
            .whereType<Map>()
            .map((item) => item.cast<String, dynamic>()));
      }
      final uncertainties = map['uncertainties'];
      if (uncertainties is List) {
        uncertainItems.addAll(uncertainties.whereType<String>());
      }
      final resultWarnings = map['warnings'];
      if (resultWarnings is List) {
        warnings.addAll(resultWarnings.whereType<String>());
      }
    }

    return AgentExecutionReport(
      originalRequest: originalRequest,
      toolsCalled: [
        for (final record in records)
          if (!record.isControlPlane) record.toolName,
      ],
      actionsCompleted: actionsCompleted,
      actionsFailed: actionsFailed,
      tasksCreated: tasksCreated,
      eventsCreated: eventsCreated,
      eventsModified: eventsModified,
      emailDigestItems: emailDigestItems,
      filesAffected: filesAffected,
      screensCreated: screensCreated,
      rulesChanged: rulesChanged,
      warnings: warnings,
      uncertainItems: uncertainItems,
      partialFailures: partialFailures,
      entitiesTouched: entitiesTouched,
    );
  }

  /// Keeps the fields a rundown needs from an email result row.
  static Map<String, dynamic> _asDigestItem(Map raw) {
    final map = raw.cast<String, dynamic>();
    return {
      if (map['id'] != null) 'email_id': map['id'],
      if (map['from'] != null) 'sender': map['from'],
      if (map['sender'] != null) 'sender': map['sender'],
      if (map['subject'] != null) 'subject': map['subject'],
      if (map['received_at'] != null) 'received_at': map['received_at'],
      if (map['summary'] != null) 'summary': map['summary'],
      if (map['digested'] != null) 'digested': map['digested'],
      if (map['requires_reply'] != null)
        'requires_reply': map['requires_reply'],
    };
  }

  /// A short human-readable summary of one tool call, derived from the tool
  /// name's verb and the entity named in the result or arguments.
  /// "create_task" + {title: Send invoice} -> "Created task: Send invoice".
  static String? summarize({
    required String toolName,
    required Map<String, Object?> arguments,
    Object? rawResult,
  }) {
    final map = rawResult is Map ? rawResult.cast<String, Object?>() : null;

    if (map?['already_exists'] == true) {
      final title = map?['title'] ?? arguments['title'];
      return title is String
          ? 'Already on the list, not added again: $title'
          : 'Already on the list, not added again';
    }

    if (map?['possible_duplicate'] == true) {
      final similar = map?['similar_open_tasks'];
      final first = similar is List && similar.isNotEmpty ? similar.first : null;
      final existing = first is Map ? first['title'] : null;
      final title = map?['title'] ?? arguments['title'];
      return existing is String
          ? 'Held back, not added: "$title" may be the open task '
              '"$existing" again'
          : 'Held back, not added: "$title" may already be on the list';
    }

    // Tool-specific summaries where the generic verb+entity form reads badly.
    switch (toolName) {
      case 'sync_emails':
        final result = map?['result'];
        return result is String ? 'Synced mail: $result' : 'Synced mail';
      case 'sync_messages':
        final added = map?['new_messages'];
        if (added is int) {
          return added == 0
              ? 'Checked chats: nothing new'
              : 'Checked chats: $added new message${added == 1 ? '' : 's'}';
        }
        final result = map?['result'];
        return result is String ? 'Checked chats: $result' : 'Checked chats';
      case 'read_message_context':
        final count = map?['count'];
        final fresh = arguments['undigested_only'] == true ? 'new ' : '';
        return count is int
            ? 'Read $count ${fresh}chat message${count == 1 ? '' : 's'}'
            : 'Read ${fresh}chat messages';
      case 'mark_message_digested':
        final count = map?['count'];
        return count is int
            ? 'Marked $count chat message${count == 1 ? '' : 's'} as handled'
            : 'Marked chat messages as handled';
      case 'mark_email_digested':
        final count = map?['count'];
        return count is int
            ? 'Marked $count email${count == 1 ? '' : 's'} as handled'
            : 'Marked emails as handled';
      case 'read_email_context':
        final count = map?['count'];
        if (count is int) return 'Read $count email(s)';
        final subject = map?['subject'];
        return subject is String
            ? 'Read email: $subject'
            : 'Read email context';
      case 'search':
        final count = map?['count'];
        final query = map?['query'] ?? arguments['query'];
        return 'Searched for "$query"'
            '${count is int ? ' ($count results)' : ''}';
      case 'open_screen':
        return 'Opened the ${arguments['screen_key']} screen';
      case 'add_to_phone_calendar':
        return 'Queued "${arguments['title']}" for phone-calendar approval';
      case 'sync_device_calendar':
        final imported = map?['imported'];
        return imported is int
            ? 'Imported $imported event(s) from the phone calendar'
            : 'Synced the phone calendar';
      case 'send_email':
        return 'Sent email "${arguments['subject']}" to ${arguments['to']}';
    }

    const verbs = {
      'create': 'Created',
      'update': 'Updated',
      'complete': 'Completed',
      'delete': 'Deleted',
      'cancel': 'Canceled',
      'list': 'Listed',
      'read': 'Read',
      'mark': 'Marked',
      'store': 'Stored',
      'save': 'Saved',
      'pause': 'Paused',
      'resume': 'Resumed',
      'run': 'Ran',
      'propose': 'Proposed',
      'rollback': 'Rolled back',
      'activate': 'Activated',
      'evaluate': 'Evaluated',
      'summarize': 'Summarized',
      'sync': 'Synced',
      'send': 'Sent',
      'open': 'Opened',
      'add': 'Added',
      'move': 'Moved',
      'plan': 'Planned',
      'unplan': 'Unplanned',
      'reply': 'Replied',
      'define': 'Defined',
      'mute': 'Muted',
      'search': 'Searched',
      'write': 'Wrote',
    };
    final parts = toolName.split('_');
    final verb = verbs[parts.first];
    if (verb == null) return null;
    final noun = parts.length > 1 ? parts.sublist(1).join(' ') : '';
    final entity =
        map?['title'] ?? map?['name'] ?? map?['subject'] ?? arguments['title'];
    final label = [verb, if (noun.isNotEmpty) noun].join(' ');
    return entity is String ? '$label: $entity' : label;
  }
}
