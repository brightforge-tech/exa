import 'package:clock/clock.dart';

import 'agent_datetime_label.dart';

class TaskItem {
  static const statuses = [
    'Pending',
    'In Progress',
    'Waiting',
    'Completed',
    'Canceled',
    'Overdue',
  ];
  static const priorities = ['Low', 'Normal', 'High', 'Urgent'];

  /// Supported task recurrence rules.
  static const recurrenceRules = ['daily', 'weekly', 'monthly'];

  final String id;
  final String title;
  final String? description;
  final String status;
  final String priority;
  final String? category;
  final DateTime? dueAt;
  final DateTime? completedAt;
  final String? recurrenceRule;
  final String source;
  final String createdBy;

  /// Ref ("calendarId:eventId") of this task's mirror on the phone calendar,
  /// or null when it has not been mirrored there.
  final String? deviceEventId;
  final DateTime createdAt;
  final DateTime updatedAt;

  const TaskItem({
    required this.id,
    required this.title,
    this.description,
    this.status = 'Pending',
    this.priority = 'Normal',
    this.category,
    this.dueAt,
    this.completedAt,
    this.recurrenceRule,
    this.source = 'user',
    this.createdBy = 'user',
    this.deviceEventId,
    required this.createdAt,
    required this.updatedAt,
  });

  bool get isOpen => status != 'Completed' && status != 'Canceled';

  /// Reads [clock] rather than [DateTime.now] so a test can pin "now" - a
  /// fixture task due at a fixed hour today is otherwise overdue for half the
  /// day and not the other half.
  bool get isOverdue =>
      isOpen && dueAt != null && dueAt!.isBefore(clock.now());

  TaskItem copyWith({
    String? title,
    String? description,
    String? status,
    String? priority,
    String? category,
    DateTime? dueAt,
    DateTime? completedAt,
    String? recurrenceRule,
    DateTime? updatedAt,
  }) {
    return TaskItem(
      id: id,
      title: title ?? this.title,
      description: description ?? this.description,
      status: status ?? this.status,
      priority: priority ?? this.priority,
      category: category ?? this.category,
      dueAt: dueAt ?? this.dueAt,
      completedAt: completedAt ?? this.completedAt,
      recurrenceRule: recurrenceRule ?? this.recurrenceRule,
      source: source,
      createdBy: createdBy,
      deviceEventId: deviceEventId,
      createdAt: createdAt,
      updatedAt: updatedAt ?? DateTime.now(),
    );
  }

  Map<String, Object?> toRow() => {
        'id': id,
        'title': title,
        'description': description,
        'status': status,
        'priority': priority,
        'category': category,
        'due_at': dueAt?.toIso8601String(),
        'completed_at': completedAt?.toIso8601String(),
        'recurrence_rule': recurrenceRule,
        'source': source,
        'created_by': createdBy,
        'device_event_id': deviceEventId,
        'created_at': createdAt.toIso8601String(),
        'updated_at': updatedAt.toIso8601String(),
      };

  factory TaskItem.fromRow(Map<String, Object?> row) => TaskItem(
        id: row['id'] as String,
        title: row['title'] as String,
        description: row['description'] as String?,
        status: row['status'] as String? ?? 'Pending',
        priority: row['priority'] as String? ?? 'Normal',
        category: row['category'] as String?,
        dueAt: _parseDate(row['due_at']),
        completedAt: _parseDate(row['completed_at']),
        recurrenceRule: row['recurrence_rule'] as String?,
        source: row['source'] as String? ?? 'user',
        createdBy: row['created_by'] as String? ?? 'user',
        deviceEventId: row['device_event_id'] as String?,
        createdAt: _parseDate(row['created_at']) ?? DateTime.now(),
        updatedAt: _parseDate(row['updated_at']) ?? DateTime.now(),
      );

  /// Compact form handed to the agent as a tool result.
  Map<String, Object?> toAgentJson() => {
        'id': id,
        'title': title,
        if (description != null) 'description': description,
        'status': status,
        'priority': priority,
        if (category != null) 'category': category,
        if (dueAt != null) 'due_at': dueAt!.toIso8601String(),
        // Quote this, don't re-derive the weekday - see [agentDateTimeLabel].
        if (dueAt != null) 'due_at_label': agentDateTimeLabel(dueAt!),
        // When it was finished, so "what did I get done today?" is a lookup.
        // Without it a completed task carries only its due date, and the
        // model cannot tell this morning's work from last month's.
        // Only while it is completed: a reopened task keeps its old time
        // in the column, and "open, completed Tuesday" reads as a mistake.
        if (completedAt != null && status == 'Completed') ...{
          'completed_at': completedAt!.toIso8601String(),
          'completed_at_label': agentDateTimeLabel(completedAt!),
        },
        if (recurrenceRule != null) 'recurrence_rule': recurrenceRule,
        if (deviceEventId != null) 'on_phone_calendar': true,
      };

  static DateTime? _parseDate(Object? value) =>
      value is String && value.isNotEmpty ? DateTime.tryParse(value) : null;
}
