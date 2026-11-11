import 'agent_datetime_label.dart';

class Reminder {
  static const statuses = ['Active', 'Completed', 'Canceled'];

  /// Supported recurrence rules for the MVP scheduler.
  static const recurrenceRules = ['daily', 'weekly', 'monthly'];

  final String id;
  final String? taskId;
  final String title;
  final String? description;
  final DateTime remindAt;
  final String? recurrenceRule;
  final String status;
  final int? notificationId;
  final String createdBy;
  final DateTime createdAt;
  final DateTime updatedAt;

  const Reminder({
    required this.id,
    this.taskId,
    required this.title,
    this.description,
    required this.remindAt,
    this.recurrenceRule,
    this.status = 'Active',
    this.notificationId,
    this.createdBy = 'agent',
    required this.createdAt,
    required this.updatedAt,
  });

  Reminder copyWith({
    String? title,
    String? description,
    DateTime? remindAt,
    String? recurrenceRule,
    String? status,
    int? notificationId,
    DateTime? updatedAt,
  }) {
    return Reminder(
      id: id,
      taskId: taskId,
      title: title ?? this.title,
      description: description ?? this.description,
      remindAt: remindAt ?? this.remindAt,
      recurrenceRule: recurrenceRule ?? this.recurrenceRule,
      status: status ?? this.status,
      notificationId: notificationId ?? this.notificationId,
      createdBy: createdBy,
      createdAt: createdAt,
      updatedAt: updatedAt ?? DateTime.now(),
    );
  }

  Map<String, Object?> toRow() => {
        'id': id,
        'task_id': taskId,
        'title': title,
        'description': description,
        'remind_at': remindAt.toIso8601String(),
        'recurrence_rule': recurrenceRule,
        'status': status,
        'notification_id': notificationId,
        'created_by': createdBy,
        'created_at': createdAt.toIso8601String(),
        'updated_at': updatedAt.toIso8601String(),
      };

  factory Reminder.fromRow(Map<String, Object?> row) => Reminder(
        id: row['id'] as String,
        taskId: row['task_id'] as String?,
        title: row['title'] as String,
        description: row['description'] as String?,
        remindAt: DateTime.tryParse(row['remind_at'] as String? ?? '') ??
            DateTime.now(),
        recurrenceRule: row['recurrence_rule'] as String?,
        status: row['status'] as String? ?? 'Active',
        notificationId: row['notification_id'] as int?,
        createdBy: row['created_by'] as String? ?? 'agent',
        createdAt:
            DateTime.tryParse(row['created_at'] as String? ?? '') ??
                DateTime.now(),
        updatedAt:
            DateTime.tryParse(row['updated_at'] as String? ?? '') ??
                DateTime.now(),
      );

  Map<String, Object?> toAgentJson() => {
        'id': id,
        'title': title,
        if (description != null) 'description': description,
        'remind_at': remindAt.toIso8601String(),
        // Quote this, don't re-derive the weekday - see [agentDateTimeLabel].
        'remind_at_label': agentDateTimeLabel(remindAt),
        if (recurrenceRule != null) 'recurrence_rule': recurrenceRule,
        'status': status,
      };

  /// The local datetime this reminder fires on [day], or null if it does not
  /// occur that day. Honors daily/weekly recurrence; a one-time reminder only
  /// occurs on its own calendar date. Used to place reminders on the calendar
  /// alongside scheduled events.
  DateTime? occurrenceOn(DateTime day) {
    final at = DateTime(
        day.year, day.month, day.day, remindAt.hour, remindAt.minute);
    // Recurrence never fires before the reminder's own start date.
    final startDay =
        DateTime(remindAt.year, remindAt.month, remindAt.day);
    final thisDay = DateTime(day.year, day.month, day.day);
    switch (recurrenceRule) {
      case 'daily':
        return thisDay.isBefore(startDay) ? null : at;
      case 'weekly':
        if (day.weekday != remindAt.weekday) return null;
        return thisDay.isBefore(startDay) ? null : at;
      case 'monthly':
        if (thisDay.isBefore(startDay)) return null;
        // Fire on the same day-of-month, clamped to the last day for shorter
        // months (e.g. the 31st becomes Feb 28).
        final lastDom = DateTime(day.year, day.month + 1, 0).day;
        final targetDom =
            remindAt.day <= lastDom ? remindAt.day : lastDom;
        return day.day == targetDom ? at : null;
      default:
        // One-time reminder: only on its exact date.
        return thisDay == startDay ? at : null;
    }
  }
}
