import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../data/models/email_item.dart';
import '../../data/models/reminder.dart';
import '../../data/models/schedule_item.dart';
import '../../data/models/task_item.dart';
import '../../shared/providers.dart';
import '../../shared/theme/exa_theme.dart';

/// Everything happening "today", aggregated for the home panel. Mirrors the
/// data the daily-summary job already gathers (job_runner `_runDailySummary`).
class TodayDashboard {
  const TodayDashboard({
    required this.overdue,
    required this.dueToday,
    required this.events,
    required this.reminders,
    required this.undigestedEmails,
  });

  final List<TaskItem> overdue;
  final List<TaskItem> dueToday;
  final List<ScheduleItem> events;

  /// Reminder occurrences that fire today, as (reminder, fire-time) pairs.
  final List<MapEntry<Reminder, DateTime>> reminders;
  final List<EmailItem> undigestedEmails;

  bool get isEmpty =>
      overdue.isEmpty &&
      dueToday.isEmpty &&
      events.isEmpty &&
      reminders.isEmpty &&
      undigestedEmails.isEmpty;

  int get scheduleCount => events.length + reminders.length;
}

/// Aggregates today's schedule, reminders, tasks, and new emails. autoDispose
/// so it releases when the Exa tab is offstage; invalidated on tab revisit /
/// app resume / after a quick action.
final todayDashboardProvider =
    FutureProvider.autoDispose<TodayDashboard>((ref) async {
  final now = DateTime.now();
  final startOfDay = DateTime(now.year, now.month, now.day);
  final startOfTomorrow = startOfDay.add(const Duration(days: 1));

  final tasks = ref.watch(taskRepositoryProvider);
  final overdue = await tasks.listOverdue();
  final dueToday =
      (await tasks.list(openOnly: true, dueBefore: startOfTomorrow))
          .where((t) => !overdue.any((o) => o.id == t.id))
          .toList();
  final events = await ref.watch(scheduleRepositoryProvider).listForDay(now);
  final reminders = await ref
      .watch(reminderRepositoryProvider)
      .occurrencesBetween(startOfDay, startOfTomorrow);
  final undigested = await ref.watch(emailRepositoryProvider).undigested();

  return TodayDashboard(
    overdue: overdue,
    dueToday: dueToday,
    events: events,
    reminders: reminders,
    undigestedEmails: undigested,
  );
});

/// One row in the panel's schedule section: an event or a reminder occurrence.
class _ScheduleRow {
  _ScheduleRow.event(ScheduleItem e)
      : time = e.startAt,
        title = e.title,
        reminderId = null;
  _ScheduleRow.reminder(Reminder r, this.time)
      : title = r.title,
        reminderId = r.id;

  final DateTime time;
  final String title;
  final String? reminderId;

  bool get isReminder => reminderId != null;
}

/// Collapsible "Today" panel shown above the chat on the Exa home. Hidden
/// entirely when nothing is happening today; its collapsed state persists.
class TodayPanel extends ConsumerStatefulWidget {
  const TodayPanel({
    super.key,
    required this.onOpenRoute,
    required this.onDigestEmails,
  });

  /// Opens an app route (e.g. /schedule, /tasks) when a section is tapped.
  final void Function(String route) onOpenRoute;

  /// Kicks off an email-digest turn in the chat.
  final VoidCallback onDigestEmails;

  @override
  ConsumerState<TodayPanel> createState() => _TodayPanelState();
}

class _TodayPanelState extends ConsumerState<TodayPanel> {
  static const _collapsedKey = 'today_panel_collapsed';
  bool _collapsed = false;
  bool _loadedPref = false;

  @override
  void initState() {
    super.initState();
    _loadCollapsed();
  }

  Future<void> _loadCollapsed() async {
    try {
      final raw =
          await ref.read(settingsRepositoryProvider).getValue(_collapsedKey);
      if (mounted) {
        setState(() {
          _collapsed = raw == 'true';
          _loadedPref = true;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loadedPref = true);
    }
  }

  void _toggle() {
    setState(() => _collapsed = !_collapsed);
    // Persist best-effort; the panel still works if it doesn't stick.
    ref
        .read(settingsRepositoryProvider)
        .setValue(_collapsedKey, _collapsed ? 'true' : 'false')
        .ignore();
  }

  Future<void> _completeTask(String id) async {
    await ref.read(taskRepositoryProvider).complete(id);
    ref.invalidate(todayDashboardProvider);
  }

  Future<void> _cancelReminder(String id) async {
    final canceled = await ref.read(reminderRepositoryProvider).cancel(id);
    if (canceled != null) {
      await ref.read(notificationServiceProvider).cancelReminder(canceled);
    }
    ref.invalidate(todayDashboardProvider);
  }

  Future<void> _markEmailRead(String id) async {
    await ref.read(emailRepositoryProvider).markDigested(id);
    ref.invalidate(todayDashboardProvider);
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(todayDashboardProvider);
    final data = async.value;
    // Render nothing until the pref is known and there's something to show, so
    // the panel never flashes in/out or pushes the empty-chat hero down.
    if (!_loadedPref || data == null || data.isEmpty) {
      return const SizedBox.shrink();
    }

    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 10, 12, 2),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            ExaColors.accentGlowStart.withValues(alpha: 0.14),
            ExaColors.surfaceHigh,
          ],
        ),
        borderRadius: BorderRadius.circular(ExaRadii.card),
        border: Border.all(color: ExaColors.outline),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(ExaRadii.card),
            onTap: _toggle,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
              child: Row(
                children: [
                  const Icon(Icons.wb_sunny_outlined,
                      size: 18, color: ExaColors.spark),
                  const SizedBox(width: 8),
                  Text('Today', style: theme.textTheme.titleMedium),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      _summary(data),
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: ExaColors.textSecondary),
                    ),
                  ),
                  Icon(_collapsed ? Icons.expand_more : Icons.expand_less,
                      color: ExaColors.textSecondary),
                ],
              ),
            ),
          ),
          if (!_collapsed)
            ConstrainedBox(
              constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(context).size.height * 0.42),
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: _sections(theme, data),
                ),
              ),
            ),
        ],
      ),
    );
  }

  static String _summary(TodayDashboard d) {
    final parts = <String>[];
    if (d.scheduleCount > 0) {
      parts.add('${d.scheduleCount} on schedule');
    }
    final due = d.overdue.length + d.dueToday.length;
    if (due > 0) parts.add('$due to do');
    if (d.undigestedEmails.isNotEmpty) {
      parts.add('${d.undigestedEmails.length} new email'
          '${d.undigestedEmails.length == 1 ? '' : 's'}');
    }
    return parts.join(' · ');
  }

  List<Widget> _sections(ThemeData theme, TodayDashboard d) {
    final rows = <_ScheduleRow>[
      for (final e in d.events) _ScheduleRow.event(e),
      for (final hit in d.reminders) _ScheduleRow.reminder(hit.key, hit.value),
    ]..sort((a, b) => a.time.compareTo(b.time));

    return [
      if (rows.isNotEmpty)
        _SectionLabel('Schedule', onTap: () => widget.onOpenRoute('/schedule')),
      for (final row in rows)
        _PanelRow(
          leadingTime: DateFormat('HH:mm').format(row.time),
          icon: row.isReminder ? Icons.alarm : Icons.event_outlined,
          title: row.title,
          trailing: row.isReminder
              ? _RowIconButton(
                  icon: Icons.close,
                  tooltip: 'Cancel reminder',
                  onTap: () => _cancelReminder(row.reminderId!),
                )
              : null,
          onTap: () => widget.onOpenRoute('/schedule'),
        ),
      if (d.overdue.isNotEmpty)
        _SectionLabel('Overdue',
            color: ExaColors.error, onTap: () => widget.onOpenRoute('/tasks')),
      for (final task in d.overdue) _taskRow(task, overdue: true),
      if (d.dueToday.isNotEmpty)
        _SectionLabel('Due today', onTap: () => widget.onOpenRoute('/tasks')),
      for (final task in d.dueToday) _taskRow(task, overdue: false),
      if (d.undigestedEmails.isNotEmpty) ...[
        _SectionLabel('New emails',
            trailing: TextButton(
              onPressed: widget.onDigestEmails,
              style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 8)),
              child: const Text('Digest'),
            ),
            onTap: () => widget.onOpenRoute('/settings/emails')),
        for (final email in d.undigestedEmails.take(5))
          _PanelRow(
            icon: Icons.mail_outline,
            title: email.subject,
            subtitle: email.sender,
            trailing: _RowIconButton(
              icon: Icons.mark_email_read_outlined,
              tooltip: 'Mark read',
              onTap: () => _markEmailRead(email.id),
            ),
            onTap: () => widget.onOpenRoute('/settings/emails'),
          ),
      ],
    ];
  }

  Widget _taskRow(TaskItem task, {required bool overdue}) => _PanelRow(
        icon: Icons.radio_button_unchecked,
        title: task.title,
        subtitle: task.dueAt == null
            ? null
            : DateFormat('MMM d, HH:mm').format(task.dueAt!),
        subtitleColor: overdue ? ExaColors.error : null,
        trailing: _RowIconButton(
          icon: Icons.check_circle_outline,
          tooltip: 'Complete',
          onTap: () => _completeTask(task.id),
        ),
        onTap: () => widget.onOpenRoute('/tasks'),
      );
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.label, {this.color, this.trailing, this.onTap});

  final String label;
  final Color? color;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(2, 10, 0, 4),
        child: Row(
          children: [
            Text(label.toUpperCase(),
                style: theme.textTheme.labelSmall?.copyWith(
                    color: color ?? ExaColors.textTertiary,
                    letterSpacing: 0.6)),
            const Spacer(),
            ?trailing,
          ],
        ),
      ),
    );
  }
}

class _PanelRow extends StatelessWidget {
  const _PanelRow({
    this.leadingTime,
    required this.icon,
    required this.title,
    this.subtitle,
    this.subtitleColor,
    this.trailing,
    this.onTap,
  });

  final String? leadingTime;
  final IconData icon;
  final String title;
  final String? subtitle;
  final Color? subtitleColor;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(ExaRadii.field),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
        child: Row(
          children: [
            if (leadingTime != null) ...[
              SizedBox(
                width: 42,
                child: Text(leadingTime!,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: ExaColors.textSecondary)),
              ),
            ] else ...[
              Icon(icon, size: 16, color: ExaColors.textSecondary),
              const SizedBox(width: 10),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium),
                  if (subtitle != null && subtitle!.isNotEmpty)
                    Text(subtitle!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                            color:
                                subtitleColor ?? ExaColors.textSecondary)),
                ],
              ),
            ),
            ?trailing,
          ],
        ),
      ),
    );
  }
}

class _RowIconButton extends StatelessWidget {
  const _RowIconButton(
      {required this.icon, required this.tooltip, required this.onTap});

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      icon: Icon(icon, size: 20),
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints(),
      padding: const EdgeInsets.all(6),
      color: ExaColors.textSecondary,
      onPressed: onTap,
    );
  }
}
