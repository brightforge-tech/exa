import 'agent_datetime_label.dart';
import 'reminder.dart';
import 'task_item.dart';

/// One card on the daily planning board: a block of time the user set aside
/// for something.
///
/// Distinct from a due date (a deadline) and from a calendar event (a
/// commitment to be somewhere). A task due Friday can be planned for Tuesday
/// morning, and moving it on the board changes when they mean to do it -
/// never when it is due.
class DayPlanEntry {
  static const sourceTask = 'task';
  static const sourceReminder = 'reminder';

  /// A block with nothing behind it - "deep work", "lunch", "gym". Its title
  /// and status live entirely on this row.
  static const sourceNote = 'note';

  static const sourceTypes = [sourceTask, sourceReminder, sourceNote];

  static const statusPlanned = 'planned';
  static const statusDone = 'done';
  static const statusSkipped = 'skipped';
  static const statuses = [statusPlanned, statusDone, statusSkipped];

  /// What a block is worth when nobody says otherwise.
  static const defaultDurationMinutes = 30;

  /// The board's grid. Everything snaps to this, which is what makes drag
  /// targets big enough to hit on a phone.
  static const slotMinutes = 30;

  final String id;

  /// Local calendar date, `yyyy-MM-dd`. Stored as a date rather than a
  /// timestamp so "what is planned for Tuesday" is an index hit and never a
  /// timezone argument.
  final String planDate;

  final String sourceType;

  /// The task or reminder this block is for; null for [sourceNote].
  final String? sourceId;

  /// Snapshot of the title at planning time. The live task is still the
  /// source of truth - this is what keeps the board renderable in one query
  /// and gives ad-hoc blocks a name.
  final String title;

  /// Minutes from local midnight, 0..1439.
  final int startMinute;
  final int durationMinutes;

  /// Only authoritative for [sourceNote] blocks; for task- and
  /// reminder-backed ones the item's own status wins. See [DayPlanItem.done].
  final String status;

  final String? notes;
  final String createdBy;
  final DateTime createdAt;
  final DateTime updatedAt;

  const DayPlanEntry({
    required this.id,
    required this.planDate,
    required this.sourceType,
    this.sourceId,
    required this.title,
    required this.startMinute,
    this.durationMinutes = defaultDurationMinutes,
    this.status = statusPlanned,
    this.notes,
    this.createdBy = 'user',
    required this.createdAt,
    required this.updatedAt,
  });

  int get endMinute => startMinute + durationMinutes;

  bool get isNote => sourceType == sourceNote;

  /// `HH:mm`, the label used on the board and in tool results.
  String get startLabel => formatMinuteOfDay(startMinute);
  String get endLabel => formatMinuteOfDay(endMinute);

  /// The wall-clock start, for anything that needs a real DateTime (sorting
  /// against calendar events, agent date labels).
  DateTime get startAt {
    final day = parseDateKey(planDate);
    return DateTime(day.year, day.month, day.day)
        .add(Duration(minutes: startMinute));
  }

  DayPlanEntry copyWith({
    String? title,
    int? startMinute,
    int? durationMinutes,
    String? status,
    String? notes,
    DateTime? updatedAt,
  }) =>
      DayPlanEntry(
        id: id,
        planDate: planDate,
        sourceType: sourceType,
        sourceId: sourceId,
        title: title ?? this.title,
        startMinute: startMinute ?? this.startMinute,
        durationMinutes: durationMinutes ?? this.durationMinutes,
        status: status ?? this.status,
        notes: notes ?? this.notes,
        createdBy: createdBy,
        createdAt: createdAt,
        updatedAt: updatedAt ?? DateTime.now(),
      );

  Map<String, Object?> toRow() => {
        'id': id,
        'plan_date': planDate,
        'source_type': sourceType,
        'source_id': sourceId,
        'title': title,
        'start_minute': startMinute,
        'duration_minutes': durationMinutes,
        'status': status,
        'notes': notes,
        'created_by': createdBy,
        'created_at': createdAt.toIso8601String(),
        'updated_at': updatedAt.toIso8601String(),
      };

  factory DayPlanEntry.fromRow(Map<String, Object?> row) => DayPlanEntry(
        id: row['id'] as String,
        planDate: row['plan_date'] as String,
        sourceType: row['source_type'] as String? ?? sourceNote,
        sourceId: row['source_id'] as String?,
        title: row['title'] as String? ?? '',
        startMinute: (row['start_minute'] as int?) ?? 0,
        durationMinutes:
            (row['duration_minutes'] as int?) ?? defaultDurationMinutes,
        status: row['status'] as String? ?? statusPlanned,
        notes: row['notes'] as String?,
        createdBy: row['created_by'] as String? ?? 'user',
        createdAt: DateTime.tryParse(row['created_at'] as String? ?? '') ??
            DateTime.now(),
        updatedAt: DateTime.tryParse(row['updated_at'] as String? ?? '') ??
            DateTime.now(),
      );

  /// `yyyy-MM-dd` for a local day, the key every query uses.
  static String dateKey(DateTime day) =>
      '${day.year.toString().padLeft(4, '0')}-'
      '${day.month.toString().padLeft(2, '0')}-'
      '${day.day.toString().padLeft(2, '0')}';

  /// Midnight local on the day [key] names; today when it is unparseable.
  static DateTime parseDateKey(String key) {
    final parsed = DateTime.tryParse(key);
    if (parsed == null) {
      final now = DateTime.now();
      return DateTime(now.year, now.month, now.day);
    }
    return DateTime(parsed.year, parsed.month, parsed.day);
  }

  /// `HH:mm` for minutes-from-midnight, wrapping past midnight defensively.
  static String formatMinuteOfDay(int minute) {
    final clamped = minute.clamp(0, 24 * 60);
    final hour = (clamped ~/ 60) % 24;
    final minutes = clamped % 60;
    return '${hour.toString().padLeft(2, '0')}:'
        '${minutes.toString().padLeft(2, '0')}';
  }

  /// Parses `HH:mm` (or `H:mm`) into minutes from midnight; null when it is
  /// not a time. Tolerates a full ISO datetime by taking its clock time,
  /// because that is what a model tends to send.
  static int? parseTimeOfDay(String? value) {
    final text = value?.trim();
    if (text == null || text.isEmpty) return null;
    final match = RegExp(r'(\d{1,2}):(\d{2})').firstMatch(text);
    if (match == null) return null;
    final hour = int.tryParse(match.group(1)!);
    final minute = int.tryParse(match.group(2)!);
    if (hour == null || minute == null) return null;
    if (hour > 23 || minute > 59) return null;
    return hour * 60 + minute;
  }
}

/// A board card with its live source resolved: the entry plus whatever task
/// or reminder it points at.
///
/// Status is *derived* here rather than copied onto the entry. Completing a
/// task anywhere - the Tasks screen, a tool, a background job - has to show
/// up on the board immediately, and the only way to guarantee that is to
/// never store a second copy of the answer.
class DayPlanItem {
  const DayPlanItem({
    required this.entry,
    this.task,
    this.reminder,
  });

  final DayPlanEntry entry;
  final TaskItem? task;
  final Reminder? reminder;

  String get title => task?.title ?? reminder?.title ?? entry.title;

  bool get done => switch (entry.sourceType) {
        DayPlanEntry.sourceTask => task != null && !task!.isOpen,
        DayPlanEntry.sourceReminder => reminder?.status != 'Active',
        _ => entry.status == DayPlanEntry.statusDone,
      };

  bool get skipped => entry.status == DayPlanEntry.statusSkipped;

  /// The deadline behind this block, when there is one. Shown on the card so
  /// "planned Tuesday, due Friday" is visible while rearranging.
  DateTime? get dueAt => task?.dueAt;

  /// When the reminder behind this block actually fires - the notification
  /// keeps its own time, which planning does not move.
  DateTime? get remindAt => reminder?.remindAt;

  Map<String, Object?> toAgentJson() => {
        'entry_id': entry.id,
        'title': title,
        'start_time': entry.startLabel,
        'end_time': entry.endLabel,
        'duration_minutes': entry.durationMinutes,
        'source': entry.sourceType,
        if (entry.sourceId != null) 'source_id': entry.sourceId,
        'done': done,
        if (skipped) 'skipped': true,
        if (entry.notes != null) 'notes': entry.notes,
        if (dueAt != null) 'due_at': dueAt!.toIso8601String(),
        // Quote this, don't re-derive the weekday - see [agentDateTimeLabel].
        if (dueAt != null) 'due_at_label': agentDateTimeLabel(dueAt!),
        if (remindAt != null) 'reminder_fires_at': remindAt!.toIso8601String(),
      };
}
