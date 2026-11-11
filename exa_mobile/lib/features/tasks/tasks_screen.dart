import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../data/models/task_item.dart';
import '../../shared/providers.dart';
import '../../shared/theme/exa_theme.dart';
import '../../shared/widgets/exa_empty_state.dart';

final tasksProvider = FutureProvider.autoDispose<List<TaskItem>>(
    (ref) => ref.watch(taskRepositoryProvider).list());

/// The segment shown under the digest header.
enum _TaskFilter {
  all('All Tasks'),
  overdue('Overdue'),
  important('Important'),
  completed('Completed');

  const _TaskFilter(this.label);

  final String label;
}

class TasksScreen extends ConsumerStatefulWidget {
  const TasksScreen({super.key});

  @override
  ConsumerState<TasksScreen> createState() => _TasksScreenState();
}

class _TasksScreenState extends ConsumerState<TasksScreen> {
  /// Ids of tasks dismissed in this frame. A swiped Dismissible must leave
  /// the tree synchronously - the FutureProvider keeps showing stale data
  /// during its invalidate-refresh, so we filter these out immediately and
  /// prune the id once the reloaded list no longer contains the task.
  final Set<String> _removing = {};

  _TaskFilter _filter = _TaskFilter.all;

  // These three read [clock] rather than [DateTime.now] so a test can pin
  // "now" - see [TaskItem.isOverdue].
  static String _greeting() {
    final hour = clock.now().hour;
    if (hour < 12) return 'Good morning';
    if (hour < 18) return 'Good afternoon';
    return 'Good evening';
  }

  static bool _isToday(DateTime? due) {
    if (due == null) return false;
    final now = clock.now();
    return due.year == now.year &&
        due.month == now.month &&
        due.day == now.day;
  }

  void _onTaskDismissed(String id) {
    setState(() => _removing.add(id));
  }

  @override
  Widget build(BuildContext context) {
    // Reload when this tab is reopened - it's kept alive in the nav
    // IndexedStack, so it won't refetch on revisit on its own.
    ref.listen(tabVisitTickProvider(1), (_, _) {
      ref.invalidate(tasksProvider);
    });
    final tasksAsync = ref.watch(tasksProvider);

    return Scaffold(
      floatingActionButton:
          _AddTaskButton(onPressed: () => _showTaskSheet(context, ref)),
      body: SafeArea(
        bottom: false,
        child: tasksAsync.when(
          loading: () => const Center(
              child: CircularProgressIndicator(color: ExaColors.accent)),
          error: (error, _) => Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text('Error: $error'),
            ),
          ),
          data: (tasks) {
            if (tasks.isEmpty) {
              return ExaEmptyState(
                icon: Icons.check_circle_outline,
                title: 'Nothing on your plate',
                message:
                    'Add a task with the + button, or just ask Exa — '
                    '"remind me to call the dentist tomorrow".',
                actionLabel: 'Add a task',
                onAction: () => _showTaskSheet(context, ref),
              );
            }
            // Drop any tasks mid-dismissal so the swiped Dismissible is gone
            // from the tree on this build; prune ids the reload has caught up
            // on (after the frame, to avoid setState during build).
            if (_removing.isNotEmpty) {
              final ids = tasks.map((t) => t.id).toSet();
              final settled =
                  _removing.where((id) => !ids.contains(id)).toList();
              if (settled.isNotEmpty) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted) setState(() => _removing.removeAll(settled));
                });
              }
            }
            final visible =
                tasks.where((t) => !_removing.contains(t.id)).toList();
            final open = visible.where((t) => t.isOpen).toList();
            final closed = visible.where((t) => !t.isOpen).toList();
            final overdue = open.where((t) => t.isOverdue).toList();
            final important = open
                .where((t) => t.priority == 'High' || t.priority == 'Urgent')
                .toList();
            final dueToday = open.where((t) => _isToday(t.dueAt)).toList();

            return RefreshIndicator(
              color: ExaColors.accent,
              backgroundColor: ExaColors.surfaceHigh,
              onRefresh: () async => ref.invalidate(tasksProvider),
              child: ListView(
                padding: const EdgeInsets.only(bottom: 108),
                children: [
                  _DigestHeader(
                    greeting: _greeting(),
                    openCount: open.length,
                    overdue: overdue.length,
                    dueToday: dueToday.length,
                  ),
                  _FilterBar(
                    selected: _filter,
                    onSelect: (filter) => setState(() => _filter = filter),
                  ),
                  ..._filteredSection(
                    open: open,
                    closed: closed,
                    overdue: overdue,
                    important: important,
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  /// The cards (and any section labels) for the active filter.
  List<Widget> _filteredSection({
    required List<TaskItem> open,
    required List<TaskItem> closed,
    required List<TaskItem> overdue,
    required List<TaskItem> important,
  }) {
    Widget card(TaskItem task) =>
        _TaskCard(task: task, ref: ref, onDismissed: _onTaskDismissed);

    switch (_filter) {
      case _TaskFilter.all:
        if (open.isEmpty && closed.isEmpty) {
          return const [
            _InlineEmpty(
              icon: Icons.check_circle_outline,
              title: 'Nothing on your plate',
              message: 'Add a task with the + button.',
            ),
          ];
        }
        return [
          for (final task in open) card(task),
          if (closed.isNotEmpty) ...[
            const _SectionLabel('Done'),
            for (final task in closed) card(task),
          ],
        ];
      case _TaskFilter.overdue:
        if (overdue.isEmpty) {
          return const [
            _InlineEmpty(
              icon: Icons.event_available_outlined,
              title: 'Nothing overdue',
              message: 'You are all caught up.',
            ),
          ];
        }
        return [for (final task in overdue) card(task)];
      case _TaskFilter.important:
        if (important.isEmpty) {
          return const [
            _InlineEmpty(
              icon: Icons.priority_high,
              title: 'Nothing marked important',
              message: 'High and urgent tasks land here.',
            ),
          ];
        }
        return [for (final task in important) card(task)];
      case _TaskFilter.completed:
        if (closed.isEmpty) {
          return const [
            _InlineEmpty(
              icon: Icons.done_all,
              title: 'Nothing completed yet',
              message: 'Tick a task off and it shows up here.',
            ),
          ];
        }
        return [for (final task in closed) card(task)];
    }
  }

  static Future<void> _showTaskSheet(BuildContext context, WidgetRef ref,
      [TaskItem? existing]) async {
    final titleController =
        TextEditingController(text: existing?.title ?? '');
    final descriptionController =
        TextEditingController(text: existing?.description ?? '');
    DateTime? dueAt = existing?.dueAt;
    String priority = existing?.priority ?? 'Normal';

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(sheetContext).viewInsets.bottom,
        ),
        child: StatefulBuilder(
          builder: (sheetContext, setSheetState) => Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(existing == null ? 'New task' : 'Edit task',
                    style: Theme.of(sheetContext).textTheme.titleLarge),
                const SizedBox(height: 12),
                TextField(
                  controller: titleController,
                  decoration: const InputDecoration(
                      labelText: 'Title', border: OutlineInputBorder()),
                  autofocus: existing == null,
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: descriptionController,
                  decoration: const InputDecoration(
                      labelText: 'Description',
                      border: OutlineInputBorder()),
                  maxLines: 2,
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        initialValue: priority,
                        decoration: const InputDecoration(
                            labelText: 'Priority',
                            border: OutlineInputBorder()),
                        items: [
                          for (final p in TaskItem.priorities)
                            DropdownMenuItem(value: p, child: Text(p)),
                        ],
                        onChanged: (value) =>
                            priority = value ?? 'Normal',
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.event),
                        label: Text(dueAt == null
                            ? 'Due date'
                            : DateFormat('MMM d, HH:mm').format(dueAt!)),
                        onPressed: () async {
                          final date = await showDatePicker(
                            context: sheetContext,
                            initialDate: dueAt ?? DateTime.now(),
                            firstDate: DateTime(2020),
                            lastDate: DateTime(2100),
                          );
                          if (date == null || !sheetContext.mounted) return;
                          final time = await showTimePicker(
                            context: sheetContext,
                            initialTime: TimeOfDay.fromDateTime(
                                dueAt ?? DateTime.now()),
                          );
                          setSheetState(() {
                            dueAt = DateTime(
                              date.year,
                              date.month,
                              date.day,
                              time?.hour ?? 9,
                              time?.minute ?? 0,
                            );
                          });
                        },
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: () async {
                    final title = titleController.text.trim();
                    if (title.isEmpty) return;
                    final repo = ref.read(taskRepositoryProvider);
                    final calendarSync =
                        ref.read(calendarSyncServiceProvider);
                    if (existing == null) {
                      final task = await repo.create(
                        title: title,
                        description:
                            descriptionController.text.trim().isEmpty
                                ? null
                                : descriptionController.text.trim(),
                        priority: priority,
                        dueAt: dueAt,
                      );
                      // Mirror to the phone calendar when that's enabled.
                      await calendarSync.syncTaskIfEnabled(task);
                    } else {
                      final updated = await repo.update(
                        existing.id,
                        title: title,
                        description: descriptionController.text.trim(),
                        priority: priority,
                        dueAt: dueAt,
                      );
                      if (updated != null) {
                        await calendarSync.syncTaskIfEnabled(updated);
                      }
                    }
                    ref.invalidate(tasksProvider);
                    if (sheetContext.mounted) {
                      Navigator.of(sheetContext).pop();
                    }
                  },
                  child: Text(existing == null ? 'Add task' : 'Save'),
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The daily anchor at the top of Tasks: a Sora greeting and three
/// live counts (open, overdue, today).
class _DigestHeader extends StatelessWidget {
  const _DigestHeader({
    required this.greeting,
    required this.openCount,
    required this.overdue,
    required this.dueToday,
  });

  final String greeting;
  final int openCount;
  final int overdue;
  final int dueToday;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 14, 16, 18),
      padding: const EdgeInsets.fromLTRB(22, 24, 22, 24),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            ExaColors.accentGlowStart.withValues(alpha: 0.12),
            ExaColors.surfaceHigh,
          ],
        ),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: ExaColors.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            greeting,
            style: theme.textTheme.headlineMedium?.copyWith(
              color: ExaColors.spark,
              fontSize: 30,
              height: 1.1,
            ),
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              _Stat(value: openCount, label: 'Open'),
              const _StatDivider(),
              _Stat(
                value: overdue,
                label: 'Overdue',
                color: overdue > 0 ? ExaColors.error : null,
              ),
              const _StatDivider(),
              _Stat(value: dueToday, label: 'Today'),
            ],
          ),
          const SizedBox(height: 16),
          // Deciding *when* to do the open work is the other half of a task
          // list, so the way into the board sits with the counts rather than
          // hidden in a menu.
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => context.go('/plan'),
              icon: const Icon(Icons.view_day_outlined, size: 18),
              label: const Text('Plan my day'),
              style: TextButton.styleFrom(
                foregroundColor: ExaColors.spark,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                visualDensity: VisualDensity.compact,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.value, required this.label, this.color});

  final int value;
  final String label;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '$value',
            style: theme.textTheme.bodyLarge?.copyWith(
              color: color ?? ExaColors.textPrimary,
              fontSize: 30,
              fontWeight: FontWeight.w700,
              height: 1.1,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            label.toUpperCase(),
            style: theme.textTheme.labelSmall?.copyWith(
              color: ExaColors.textTertiary,
              fontSize: 10.5,
              fontWeight: FontWeight.w600,
              letterSpacing: 1.4,
            ),
          ),
        ],
      ),
    );
  }
}

class _StatDivider extends StatelessWidget {
  const _StatDivider();

  @override
  Widget build(BuildContext context) => Container(
        width: 1,
        height: 44,
        margin: const EdgeInsets.symmetric(horizontal: 14),
        color: ExaColors.outline,
      );
}

/// Horizontally scrolling pill filters under the digest.
class _FilterBar extends StatelessWidget {
  const _FilterBar({required this.selected, required this.onSelect});

  final _TaskFilter selected;
  final ValueChanged<_TaskFilter> onSelect;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 44,
      margin: const EdgeInsets.only(bottom: 18),
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: _TaskFilter.values.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final filter = _TaskFilter.values[index];
          final isSelected = filter == selected;
          return _FilterPill(
            label: filter.label,
            selected: isSelected,
            onTap: () => onSelect(filter),
          );
        },
      ),
    );
  }
}

class _FilterPill extends StatelessWidget {
  const _FilterPill({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    const radius = BorderRadius.all(Radius.circular(22));
    return Material(
      color: selected ? ExaColors.spark : ExaColors.surfaceHigh,
      borderRadius: radius,
      child: InkWell(
        onTap: onTap,
        borderRadius: radius,
        child: Container(
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 15),
          decoration: BoxDecoration(
            borderRadius: radius,
            border: Border.all(
                color: selected ? Colors.transparent : ExaColors.outline),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: selected
                  ? const Color(0xFF0F1316)
                  : ExaColors.textSecondary,
              fontSize: 13,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(22, 18, 20, 8),
        child: Text(
          text.toUpperCase(),
          style: const TextStyle(
            color: ExaColors.textTertiary,
            fontSize: 11,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.4,
          ),
        ),
      );
}

/// A compact empty state shown in place of the cards when a filter has
/// nothing to show (the header and filters stay put).
class _InlineEmpty extends StatelessWidget {
  const _InlineEmpty({
    required this.icon,
    required this.title,
    required this.message,
  });

  final IconData icon;
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 56, 32, 32),
      child: Column(
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              color: ExaColors.accent.withValues(alpha: 0.10),
              shape: BoxShape.circle,
              border:
                  Border.all(color: ExaColors.accent.withValues(alpha: 0.26)),
            ),
            child: Icon(icon, size: 26, color: ExaColors.spark),
          ),
          const SizedBox(height: 16),
          Text(title,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          Text(
            message,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: ExaColors.textSecondary),
          ),
        ],
      ),
    );
  }
}

/// One task, as a standalone card: a rounded checkbox, the title with an
/// optional status badge, the due line, and a description preview.
/// Tap edits, the checkbox completes, a swipe left deletes.
class _TaskCard extends StatelessWidget {
  const _TaskCard(
      {required this.task, required this.ref, required this.onDismissed});

  final TaskItem task;
  final WidgetRef ref;

  /// Called synchronously the instant the swipe completes so the parent can
  /// drop this card from the tree before any async delete resolves.
  final void Function(String id) onDismissed;

  bool get _isImportant =>
      task.priority == 'High' || task.priority == 'Urgent';

  /// Due after today - shown as an "upcoming" badge.
  bool get _isUpcoming {
    final due = task.dueAt;
    if (due == null || !task.isOpen) return false;
    final now = clock.now();
    final endOfToday = DateTime(now.year, now.month, now.day, 23, 59, 59);
    return due.isAfter(endOfToday);
  }

  Future<void> _toggleComplete(bool checked) async {
    final repo = ref.read(taskRepositoryProvider);
    final updated = await repo.update(task.id,
        status: checked ? 'Completed' : 'Pending');
    if (updated != null) {
      // Completing removes the phone-calendar mirror; re-opening restores
      // it. A completed recurring task spawns its next occurrence, which
      // the pending sweep mirrors.
      final calendarSync = ref.read(calendarSyncServiceProvider);
      await calendarSync.syncTaskIfEnabled(updated);
      if (updated.status == 'Completed' && updated.recurrenceRule != null) {
        await calendarSync.syncPending();
      }
    }
    ref.invalidate(tasksProvider);
  }

  @override
  Widget build(BuildContext context) {
    final done = task.status == 'Completed';
    final overdue = task.isOverdue;
    final dueText = task.dueAt == null
        ? null
        : DateFormat('EEE, MMM d • HH:mm').format(task.dueAt!);
    final description = task.description?.trim();

    return Dismissible(
      key: ValueKey(task.id),
      direction: DismissDirection.endToStart,
      background: Container(
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        decoration: BoxDecoration(
          color: ExaColors.error.withValues(alpha: 0.18),
          borderRadius: BorderRadius.circular(ExaRadii.card),
          border: Border.all(color: ExaColors.error.withValues(alpha: 0.4)),
        ),
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 22),
        child: const Icon(Icons.delete_outline, color: ExaColors.error),
      ),
      confirmDismiss: (_) async =>
          await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('Delete task?'),
              content: Text(task.title),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('Cancel')),
                FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('Delete')),
              ],
            ),
          ) ??
          false,
      onDismissed: (_) {
        // Remove from the tree first (synchronous), then persist (and drop
        // the phone-calendar mirror, if the task had one).
        onDismissed(task.id);
        ref.read(taskRepositoryProvider).delete(task.id).then((_) async {
          await ref.read(calendarSyncServiceProvider).removeTaskMirror(task);
          ref.invalidate(tasksProvider);
        });
      },
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        child: Material(
          color: ExaColors.surfaceHigh,
          borderRadius: BorderRadius.circular(ExaRadii.card),
          child: InkWell(
            borderRadius: BorderRadius.circular(ExaRadii.card),
            // Tap edits, matching Reminders and Schedule. The checkbox still
            // owns completion and a swipe still deletes, so the card tap has
            // no other job.
            onTap: () => _TasksScreenState._showTaskSheet(context, ref, task),
            child: Opacity(
              opacity: done ? 0.62 : 1,
              child: Container(
                padding: const EdgeInsets.fromLTRB(16, 18, 16, 18),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(ExaRadii.card),
                  border: Border.all(color: ExaColors.outline),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _TaskCheckbox(
                      checked: done,
                      overdue: overdue,
                      onChanged: _toggleComplete,
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: Text(
                                  // Wrap rather than truncate: the full title
                                  // is the point of the card, so let it grow.
                                  task.title,
                                  softWrap: true,
                                  style: TextStyle(
                                    color: done
                                        ? ExaColors.textSecondary
                                        : ExaColors.textPrimary,
                                    fontSize: 16.5,
                                    fontWeight: FontWeight.w600,
                                    height: 1.25,
                                    decoration: done
                                        ? TextDecoration.lineThrough
                                        : null,
                                    decorationColor: ExaColors.textTertiary,
                                  ),
                                ),
                              ),
                              if (_isImportant) ...[
                                const SizedBox(width: 10),
                                const _ImportantBadge(),
                              ] else if (_isUpcoming) ...[
                                const SizedBox(width: 10),
                                const _UpcomingBadge(),
                              ],
                            ],
                          ),
                          if (dueText != null) ...[
                            const SizedBox(height: 7),
                            Text(
                              overdue ? 'Overdue • $dueText' : dueText,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: overdue
                                    ? ExaColors.error
                                    : ExaColors.textSecondary,
                                fontSize: 12.5,
                                fontWeight:
                                    overdue ? FontWeight.w600 : FontWeight.w500,
                              ),
                            ),
                          ],
                          if (description != null &&
                              description.isNotEmpty) ...[
                            const SizedBox(height: 10),
                            Text(
                              description,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: ExaColors.textSecondary,
                                fontSize: 13.5,
                                height: 1.3,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Rounded-square completion box. Coral ring while the task is overdue,
/// filled with the accent once it's done.
class _TaskCheckbox extends StatelessWidget {
  const _TaskCheckbox({
    required this.checked,
    required this.overdue,
    required this.onChanged,
  });

  final bool checked;
  final bool overdue;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final borderColor = checked
        ? ExaColors.accent
        : overdue
            ? ExaColors.error
            : ExaColors.textTertiary;

    return Semantics(
      checked: checked,
      label: 'Mark complete',
      child: InkResponse(
        onTap: () => onChanged(!checked),
        radius: 24,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          width: 26,
          height: 26,
          decoration: BoxDecoration(
            color: checked ? ExaColors.accent : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: borderColor, width: 2),
          ),
          child: checked
              ? const Icon(Icons.check, size: 17, color: Colors.white)
              : null,
        ),
      ),
    );
  }
}

/// High / Urgent priority marker.
class _ImportantBadge extends StatelessWidget {
  const _ImportantBadge();

  @override
  Widget build(BuildContext context) => Tooltip(
        message: 'High priority',
        child: Container(
          width: 22,
          height: 22,
          decoration: const BoxDecoration(
            color: ExaColors.error,
            shape: BoxShape.circle,
          ),
          child: const Icon(Icons.priority_high, size: 15, color: Colors.white),
        ),
      );
}

/// Due after today.
class _UpcomingBadge extends StatelessWidget {
  const _UpcomingBadge();

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
        decoration: BoxDecoration(
          color: ExaColors.accentContainer,
          borderRadius: BorderRadius.circular(7),
        ),
        child: const Text(
          'UPCOMING',
          style: TextStyle(
            color: ExaColors.onAccentContainer,
            fontSize: 9.5,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.8,
          ),
        ),
      );
}

/// The squircle add button, glowing in the accent gradient.
class _AddTaskButton extends StatelessWidget {
  const _AddTaskButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(20);
    return Container(
      width: 58,
      height: 58,
      decoration: BoxDecoration(
        gradient: ExaColors.accentGradient,
        borderRadius: radius,
        boxShadow: [
          BoxShadow(
            color: ExaColors.accent.withValues(alpha: 0.42),
            blurRadius: 18,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: radius,
        child: InkWell(
          onTap: onPressed,
          borderRadius: radius,
          child: const Center(
            child: Icon(Icons.add, color: Colors.white, size: 28),
          ),
        ),
      ),
    );
  }
}
