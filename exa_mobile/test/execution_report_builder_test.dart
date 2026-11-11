import 'package:exa_mobile/agent/models/tool_execution_record.dart';
import 'package:exa_mobile/agent/services/execution_report_builder.dart';
import 'package:flutter_test/flutter_test.dart';

ToolExecutionRecord record({
  required String toolName,
  String domain = 'tasks',
  ToolExecutionStatus status = ToolExecutionStatus.success,
  Map<String, Object?> arguments = const {},
  Object? rawResult,
  String? summary,
  String? errorMessage,
  bool isControlPlane = false,
  List<String> warnings = const [],
}) =>
    ToolExecutionRecord(
      toolCallId: 'toolu_${toolName.hashCode}',
      toolName: toolName,
      domain: domain,
      arguments: arguments,
      status: status,
      startedAt: DateTime(2026, 7, 24, 9),
      completedAt: DateTime(2026, 7, 24, 9, 0, 1),
      isControlPlane: isControlPlane,
      rawResult: rawResult,
      summary: summary,
      errorMessage: errorMessage,
      warnings: warnings,
    );

void main() {
  const builder = ExecutionReportBuilder();

  test('created tasks are included', () {
    final report = builder.build(
      originalRequest: 'add tasks',
      records: [
        record(
          toolName: 'create_task',
          rawResult: {'id': 'task_1', 'title': 'Send revised invoice'},
          summary: 'Created task: Send revised invoice',
        ),
      ],
    );
    expect(report.tasksCreated, hasLength(1));
    expect(report.tasksCreated.first['title'], 'Send revised invoice');
    expect(report.actionsCompleted, ['Created task: Send revised invoice']);
  });

  test('calendar events are included, updates land in modified', () {
    final report = builder.build(
      originalRequest: 'schedule the meetings',
      records: [
        record(
          toolName: 'create_schedule_event',
          domain: 'calendar',
          rawResult: {'id': 'event_1', 'title': 'Client meeting'},
        ),
        record(
          toolName: 'update_schedule_event',
          domain: 'calendar',
          rawResult: {'id': 'event_2', 'title': 'Standup'},
        ),
      ],
    );
    expect(report.eventsCreated.single['title'], 'Client meeting');
    expect(report.eventsModified.single['title'], 'Standup');
  });

  test('email digest items are preserved', () {
    final report = builder.build(
      originalRequest: 'digest my emails',
      records: [
        record(
          toolName: 'read_email_context',
          domain: 'email',
          rawResult: {
            'count': 2,
            'emails': [
              {
                'id': 'email_1',
                'from': 'Tanner',
                'subject': 'CoinRoutes transfers',
                'summary': 'Asked about transfer records.',
              },
              {
                'id': 'email_2',
                'from': 'Amy',
                'subject': 'Business Central reports',
              },
            ],
          },
        ),
      ],
    );
    expect(report.emailDigestItems, hasLength(2));
    expect(report.emailDigestItems.first['sender'], 'Tanner');
    expect(report.emailDigestItems.first['summary'],
        'Asked about transfer records.');
    expect(report.emailDigestItems.last['subject'],
        'Business Central reports');
  });

  test('failures and denials are included', () {
    final report = builder.build(
      originalRequest: 'do things',
      records: [
        record(
          toolName: 'create_task',
          status: ToolExecutionStatus.failure,
          errorMessage: 'Task title missing',
        ),
        record(
          toolName: 'delete_email',
          domain: 'email',
          status: ToolExecutionStatus.denied,
        ),
      ],
    );
    expect(report.actionsFailed, hasLength(2));
    expect(report.actionsFailed.first, 'Task title missing');
    expect(report.actionsFailed.last, contains('declined'));
    expect(report.hasFailures, isTrue);
  });

  test('warnings and uncertainties are included', () {
    final report = builder.build(
      originalRequest: 'digest',
      records: [
        record(
          toolName: 'read_email_context',
          domain: 'email',
          warnings: ['One email referenced Monday without a date.'],
          rawResult: {
            'uncertainties': ['Deadline for the invoice is unclear'],
          },
        ),
      ],
    );
    expect(report.warnings, ['One email referenced Monday without a date.']);
    expect(report.uncertainItems, ['Deadline for the invoice is unclear']);
    expect(report.hasWarnings, isTrue);
  });

  test('expand_tools is excluded from completed user actions', () {
    final report = builder.build(
      originalRequest: 'review emails and add meetings',
      records: [
        record(
          toolName: 'expand_tools',
          domain: 'control',
          isControlPlane: true,
          rawResult: {
            'added_domains': ['calendar'],
          },
          summary: 'Expanded tools',
        ),
        record(
          toolName: 'create_schedule_event',
          domain: 'calendar',
          rawResult: {'id': 'event_1', 'title': 'Client meeting'},
          summary: 'Created event: Client meeting',
        ),
      ],
    );
    expect(report.toolsCalled, ['create_schedule_event']);
    expect(report.actionsCompleted, ['Created event: Client meeting']);
  });

  test('doc-standard structured keys are picked up', () {
    final report = builder.build(
      originalRequest: 'structured tool',
      records: [
        record(
          toolName: 'some_future_tool',
          rawResult: {
            'success': true,
            'task': {'id': 'task_9', 'title': 'From structured result'},
            'warnings': ['heads up'],
          },
        ),
      ],
    );
    expect(report.tasksCreated.single['title'], 'From structured result');
    expect(report.warnings, ['heads up']);
  });

  group('summarize', () {
    test('verb + entity for create_task', () {
      expect(
        ExecutionReportBuilder.summarize(
          toolName: 'create_task',
          arguments: {'title': 'Send invoice'},
          rawResult: {'id': 't1', 'title': 'Send invoice'},
        ),
        'Created task: Send invoice',
      );
    });

    test('email read summary uses the count', () {
      expect(
        ExecutionReportBuilder.summarize(
          toolName: 'read_email_context',
          arguments: {},
          rawResult: {'count': 3, 'emails': []},
        ),
        'Read 3 email(s)',
      );
    });

    test('unknown verbs return null instead of guessing', () {
      expect(
        ExecutionReportBuilder.summarize(
          toolName: 'frobnicate_widget',
          arguments: {},
          rawResult: null,
        ),
        isNull,
      );
    });

    test('chat housekeeping reads as what happened, not which tool ran', () {
      // These strings are handed to the synthesizer as "actions completed"
      // and used to come back to the user as "sync_messages completed".
      expect(
        ExecutionReportBuilder.summarize(
          toolName: 'sync_messages',
          arguments: {},
          rawResult: {'result': 'ok', 'new_messages': 0},
        ),
        'Checked chats: nothing new',
      );
      expect(
        ExecutionReportBuilder.summarize(
          toolName: 'sync_messages',
          arguments: {},
          rawResult: {'result': 'ok', 'new_messages': 3},
        ),
        'Checked chats: 3 new messages',
      );
      expect(
        ExecutionReportBuilder.summarize(
          toolName: 'read_message_context',
          arguments: {'undigested_only': true},
          rawResult: {'count': 2, 'messages': []},
        ),
        'Read 2 new chat messages',
      );
      expect(
        ExecutionReportBuilder.summarize(
          toolName: 'mark_message_digested',
          arguments: {'ids': ['m1']},
          rawResult: {'digested': ['m1'], 'count': 1},
        ),
        'Marked 1 chat message as handled',
      );
      expect(
        ExecutionReportBuilder.summarize(
          toolName: 'mark_email_digested',
          arguments: {'ids': ['e1', 'e2']},
          rawResult: {'digested': ['e1', 'e2'], 'count': 2},
        ),
        'Marked 2 emails as handled',
      );
    });
  });

  test('a record with no summary falls back to a label, not a tool name', () {
    final report = const ExecutionReportBuilder().build(
      originalRequest: 'digest my chats',
      records: [
        ToolExecutionRecord(
          toolCallId: 'tc_1',
          toolName: 'sync_messages',
          domain: 'messaging',
          arguments: const {},
          status: ToolExecutionStatus.success,
          startedAt: DateTime(2026, 1, 1),
          completedAt: DateTime(2026, 1, 1),
        ),
        ToolExecutionRecord(
          toolCallId: 'tc_2',
          toolName: 'mark_message_digested',
          domain: 'messaging',
          arguments: const {},
          status: ToolExecutionStatus.failure,
          startedAt: DateTime(2026, 1, 1),
          completedAt: DateTime(2026, 1, 1),
        ),
      ],
    );
    expect(report.actionsCompleted, ['Checked chats']);
    expect(report.actionsFailed,
        ['Could not mark chat messages as handled']);
    for (final line in [...report.actionsCompleted, ...report.actionsFailed]) {
      expect(line, isNot(contains('_')));
    }
  });
}
