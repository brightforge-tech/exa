import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../data/models/day_plan_entry.dart';
import '../../data/models/schedule_item.dart';
import '../../data/repositories/day_plan_repository.dart';
import '../../shared/providers.dart';
import '../../shared/theme/exa_theme.dart';
import '../../shared/widgets/exa_empty_state.dart';
import 'day_plan_controller.dart';

/// The daily planning board: what is waiting on top, the day itself below.
///
/// Drag a card from the strip onto a slot to plan it, drag a planned card to
/// another slot to move it. Every drag has a tap equivalent (tap to place at
/// the next free slot, the card menu to move or remove) - dragging is the
/// fast path, never the only one.
class DailyPlanBoardScreen extends ConsumerWidget {
  const DailyPlanBoardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Its own tab now, so it is kept alive in the nav's IndexedStack and
    // will not refetch on its own. A task completed on another tab has to
    // show here the moment the user comes back.
    ref.listen(tabVisitTickProvider(3), (_, _) {
      ref.invalidate(dayPlanBoardProvider);
    });
    final day = ref.watch(planDayProvider);
    final boardAsync = ref.watch(dayPlanBoardProvider);

    void step(int dir) => ref.read(planDayProvider.notifier).state =
        day.add(Duration(days: dir));

    return Scaffold(
      appBar: AppBar(
        title: Text(_dayTitle(day)),
        actions: [
          IconButton(
            icon: const Icon(Icons.chevron_left),
            tooltip: 'Previous day',
            onPressed: () => step(-1),
          ),
          IconButton(
            icon: const Icon(Icons.today),
            tooltip: 'Today',
            onPressed: () {
              final now = DateTime.now();
              ref.read(planDayProvider.notifier).state =
                  DateTime(now.year, now.month, now.day);
            },
          ),
          IconButton(
            icon: const Icon(Icons.chevron_right),
            tooltip: 'Next day',
            onPressed: () => step(1),
          ),
          PopupMenuButton<String>(
            onSelected: (value) async {
              switch (value) {
                case 'block':
                  await _addBlock(context, ref);
                case 'clear':
                  await _confirmClear(context, ref);
              }
            },
            itemBuilder: (context) => const [
              PopupMenuItem(value: 'block', child: Text('Add a time block')),
              PopupMenuItem(value: 'clear', child: Text('Clear this day')),
            ],
          ),
        ],
      ),
      body: boardAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(child: Text('Error: $error')),
        data: (board) => Column(
          children: [
            _BacklogStrip(board: board),
            const Divider(height: 1),
            _PlanSummary(board: board),
            Expanded(child: _Timeline(board: board)),
          ],
        ),
      ),
    );
  }

  static String _dayTitle(DateTime day) {
    final today = DateTime.now();
    final isToday = day.year == today.year &&
        day.month == today.month &&
        day.day == today.day;
    final label = DateFormat('EEE d MMM').format(day);
    return isToday ? 'Plan · Today' : 'Plan · $label';
  }

  Future<void> _addBlock(BuildContext context, WidgetRef ref) async {
    final controller = TextEditingController();
    final title = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Add a time block'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'Deep work, lunch, gym…',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (value) => Navigator.pop(dialogContext, value.trim()),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel')),
          FilledButton(
            onPressed: () =>
                Navigator.pop(dialogContext, controller.text.trim()),
            child: const Text('Add'),
          ),
        ],
      ),
    );
    if (title == null || title.isEmpty || !context.mounted) return;
    final start = await _pickSlot(context, ref);
    if (start == null) return;
    await ref
        .read(dayPlanControllerProvider)
        .addBlock(title: title, startMinute: start);
  }

  Future<void> _confirmClear(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Clear this day?'),
        content: const Text(
            'Removes every card from the board. The tasks and reminders '
            'themselves are untouched - only the plan for the day goes.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Clear')),
        ],
      ),
    );
    if (ok == true) await ref.read(dayPlanControllerProvider).clearDay();
  }
}

/// What is waiting to be planned. Cards are draggable onto the timeline; a
/// tap places one at the next free slot for people who would rather not drag.
class _BacklogStrip extends ConsumerWidget {
  const _BacklogStrip({required this.board});

  final DayPlanBoard board;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (board.backlog.isEmpty) {
      return const Padding(
        padding: EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Row(
          children: [
            Icon(Icons.check_circle_outline,
                size: 16, color: ExaColors.success),
            SizedBox(width: 8),
            Expanded(
              child: Text('Nothing left to plan - every open task and active '
                  'reminder is on the board.',
                  style: TextStyle(fontSize: 12, color: ExaColors.textSecondary)),
            ),
          ],
        ),
      );
    }
    return SizedBox(
      height: 108,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
            child: Text('To plan · ${board.backlog.length}',
                style: Theme.of(context).textTheme.labelMedium),
          ),
          Expanded(
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              itemCount: board.backlog.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, index) =>
                  _BacklogCard(item: board.backlog[index]),
            ),
          ),
        ],
      ),
    );
  }
}

class _BacklogCard extends ConsumerWidget {
  const _BacklogCard({required this.item});

  final BacklogItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final card = _card(context);
    return LongPressDraggable<_PlanDrag>(
      data: _PlanDrag.backlog(item),
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: Opacity(
        opacity: 0.9,
        child: Material(
          color: Colors.transparent,
          child: SizedBox(width: 200, child: _card(context, dragging: true)),
        ),
      ),
      childWhenDragging: Opacity(opacity: 0.3, child: card),
      child: GestureDetector(
        onTap: () async {
          final messenger = ScaffoldMessenger.of(context);
          final entry = await ref
              .read(dayPlanControllerProvider)
              .planAtNextFreeSlot(item);
          messenger.showSnackBar(SnackBar(
            content: Text(entry == null
                ? 'No free slot left today - move something first.'
                // Say the alarm moved. Rescheduling someone's reminder is
                // not something to do without telling them.
                : item.isReminder
                    ? 'Planned for ${entry.startLabel} - reminder now fires '
                        'then'
                    : 'Planned for ${entry.startLabel}'),
          ));
        },
        child: card,
      ),
    );
  }

  Widget _card(BuildContext context, {bool dragging = false}) {
    final due = item.firesAt ?? item.dueAt;
    return Container(
      width: 190,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: dragging ? ExaColors.surfaceHighest : ExaColors.surfaceHigh,
        borderRadius: BorderRadius.circular(ExaRadii.chip),
        border: Border.all(
            color: dragging ? ExaColors.accent : ExaColors.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(
                  item.isReminder
                      ? Icons.notifications_outlined
                      : Icons.check_box_outline_blank,
                  size: 14,
                  color: ExaColors.textSecondary),
              const SizedBox(width: 6),
              Expanded(
                child: Text(item.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13)),
              ),
            ],
          ),
          const Spacer(),
          Text(
            _footer(item),
            style: TextStyle(
              fontSize: 11,
              color: _dueColor(due, item.isReminder),
            ),
          ),
        ],
      ),
    );
  }

  /// What the card says under its title.
  ///
  /// A reminder set for another day says so with its date, because dropping
  /// it on this board moves it here - the user should see what they are
  /// moving before they move it.
  static String _footer(BacklogItem item) {
    final reminder = item.reminder;
    if (reminder != null) {
      final firesAt = item.firesAt;
      if (firesAt != null) return 'Fires ${DateFormat('HH:mm').format(firesAt)}';
      return 'Set for ${DateFormat('E d MMM, HH:mm').format(reminder.remindAt)}';
    }
    final due = item.dueAt;
    return due == null
        ? 'No deadline'
        : 'Due ${DateFormat('d MMM').format(due)}';
  }

  static Color _dueColor(DateTime? due, bool isReminder) {
    if (due == null) return ExaColors.textTertiary;
    if (isReminder) return ExaColors.textSecondary;
    return due.isBefore(DateTime.now())
        ? ExaColors.error
        : ExaColors.textSecondary;
  }
}

class _PlanSummary extends StatelessWidget {
  const _PlanSummary({required this.board});

  final DayPlanBoard board;

  @override
  Widget build(BuildContext context) {
    if (board.planned.isEmpty) return const SizedBox.shrink();
    final hours = (board.plannedMinutes / 60).toStringAsFixed(
        board.plannedMinutes % 60 == 0 ? 0 : 1);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Row(
        children: [
          Text('${board.planned.length} planned · ${hours}h',
              style: const TextStyle(
                  fontSize: 12, color: ExaColors.textSecondary)),
          const Spacer(),
          if (board.doneCount > 0)
            Text('${board.doneCount} done',
                style:
                    const TextStyle(fontSize: 12, color: ExaColors.success)),
        ],
      ),
    );
  }
}

/// The day, one 30-minute slot per row. Slots are the drop targets, which is
/// what keeps a drag landing where the user aimed on a phone-sized screen.
class _Timeline extends ConsumerWidget {
  const _Timeline({required this.board});

  final DayPlanBoard board;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final slots = _slots();
    if (board.planned.isEmpty && board.events.isEmpty) {
      return Column(
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: ExaEmptyState(
              icon: Icons.view_day_outlined,
              title: 'Nothing planned yet',
              message: 'Drag a card from the strip above onto a time, or tap '
                  'one to drop it in the next free slot.',
            ),
          ),
          Expanded(child: _slotList(slots)),
        ],
      );
    }
    return _slotList(slots);
  }

  Widget _slotList(List<int> slots) => ListView.builder(
        padding: const EdgeInsets.only(bottom: 32),
        itemCount: slots.length,
        itemBuilder: (context, index) {
          final minute = slots[index];
          return _SlotRow(
            minute: minute,
            items: [
              for (final item in board.planned)
                if (item.entry.startMinute >= minute &&
                    item.entry.startMinute < minute + DayPlanEntry.slotMinutes)
                  item,
            ],
            events: [
              for (final event in board.events)
                if (_eventMinute(event) >= minute &&
                    _eventMinute(event) < minute + DayPlanEntry.slotMinutes)
                  event,
            ],
          );
        },
      );

  /// The board's fixed window, widened to include anything planned outside it
  /// (a 5am start, a midnight block) so no card is ever off-screen.
  List<int> _slots() {
    var start = DayPlanRepository.boardStartMinute;
    var end = DayPlanRepository.boardEndMinute;
    for (final item in board.planned) {
      if (item.entry.startMinute < start) {
        start = item.entry.startMinute - item.entry.startMinute % DayPlanEntry.slotMinutes;
      }
      if (item.entry.endMinute > end) end = item.entry.endMinute;
    }
    for (final event in board.events) {
      final minute = _eventMinute(event);
      if (minute < start) {
        start = minute - minute % DayPlanEntry.slotMinutes;
      }
      if (minute + DayPlanEntry.slotMinutes > end) {
        end = minute + DayPlanEntry.slotMinutes;
      }
    }
    return [
      for (var m = start; m < end; m += DayPlanEntry.slotMinutes) m,
    ];
  }

  static int _eventMinute(ScheduleItem event) =>
      event.startAt.hour * 60 + event.startAt.minute;
}

class _SlotRow extends ConsumerWidget {
  const _SlotRow({
    required this.minute,
    required this.items,
    required this.events,
  });

  final int minute;
  final List<DayPlanItem> items;
  final List<ScheduleItem> events;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final onTheHour = minute % 60 == 0;
    return DragTarget<_PlanDrag>(
      onAcceptWithDetails: (details) =>
          _accept(ref, details.data, minute),
      builder: (context, candidate, _) {
        final hovering = candidate.isNotEmpty;
        return Container(
          constraints: const BoxConstraints(minHeight: 44),
          decoration: BoxDecoration(
            color: hovering ? ExaColors.accentContainer : null,
            border: Border(
              top: BorderSide(
                color: onTheHour ? ExaColors.outline : ExaColors.surfaceHigh,
              ),
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 56,
                child: Padding(
                  padding: const EdgeInsets.only(top: 10, left: 12),
                  child: Text(
                    onTheHour ? DayPlanEntry.formatMinuteOfDay(minute) : '',
                    style: const TextStyle(
                        fontSize: 11, color: ExaColors.textTertiary),
                  ),
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(0, 4, 12, 4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final event in events) _EventBand(event: event),
                      for (final item in items) _PlannedCard(item: item),
                      if (items.isEmpty && events.isEmpty)
                        SizedBox(height: hovering ? 36 : 24),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  static Future<void> _accept(WidgetRef ref, _PlanDrag drag, int minute) async {
    final controller = ref.read(dayPlanControllerProvider);
    final backlog = drag.backlogItem;
    if (backlog != null) {
      await controller.planBacklogItem(backlog, startMinute: minute);
      return;
    }
    await controller.moveEntry(drag.entryId!, startMinute: minute);
  }
}

/// A calendar event: drawn so the user can plan around it, never moved from
/// here. Rescheduling a commitment belongs on the Schedule screen.
class _EventBand extends StatelessWidget {
  const _EventBand({required this.event});

  final ScheduleItem event;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: ExaColors.surfaceLow,
        borderRadius: BorderRadius.circular(10),
        border: const Border(
            left: BorderSide(color: ExaColors.textTertiary, width: 3)),
      ),
      child: Row(
        children: [
          const Icon(Icons.event_busy_outlined,
              size: 14, color: ExaColors.textTertiary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '${DateFormat('HH:mm').format(event.startAt)} · ${event.title}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  fontSize: 12, color: ExaColors.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}

class _PlannedCard extends ConsumerWidget {
  const _PlannedCard({required this.item});

  final DayPlanItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final card = _card(context, ref);
    return LongPressDraggable<_PlanDrag>(
      data: _PlanDrag.entry(item.entry.id),
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: Opacity(
        opacity: 0.9,
        child: Material(
          color: Colors.transparent,
          child: SizedBox(width: 240, child: _card(context, ref, flat: true)),
        ),
      ),
      childWhenDragging: Opacity(opacity: 0.3, child: card),
      child: card,
    );
  }

  Widget _card(BuildContext context, WidgetRef ref, {bool flat = false}) {
    final done = item.done;
    final entry = item.entry;
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.fromLTRB(6, 2, 2, 2),
      decoration: BoxDecoration(
        color: done ? ExaColors.surfaceLow : ExaColors.surfaceHigh,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
            color: flat ? ExaColors.accent : ExaColors.outline),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 34,
            height: 34,
            child: Checkbox(
              value: done,
              visualDensity: VisualDensity.compact,
              onChanged: (value) => ref
                  .read(dayPlanControllerProvider)
                  .setDone(item, value ?? false),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  item.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    decoration: done || item.skipped
                        ? TextDecoration.lineThrough
                        : null,
                    color: done ? ExaColors.textTertiary : null,
                  ),
                ),
                Text(
                  '${entry.startLabel}–${entry.endLabel}'
                  '${_sourceSuffix()}',
                  style: const TextStyle(
                      fontSize: 11, color: ExaColors.textTertiary),
                ),
              ],
            ),
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert, size: 18),
            onSelected: (value) => _onMenu(context, ref, value),
            itemBuilder: (context) => [
              const PopupMenuItem(value: 'time', child: Text('Change time')),
              const PopupMenuItem(
                  value: 'duration', child: Text('Change duration')),
              PopupMenuItem(
                value: 'skip',
                child: Text(item.skipped ? 'Un-skip' : 'Skip today'),
              ),
              const PopupMenuItem(
                  value: 'remove', child: Text('Take off the board')),
            ],
          ),
        ],
      ),
    );
  }

  String _sourceSuffix() {
    final due = item.dueAt;
    if (item.entry.sourceType == DayPlanEntry.sourceReminder) {
      return ' · reminder';
    }
    if (due == null) return '';
    return ' · due ${DateFormat('d MMM').format(due)}';
  }

  Future<void> _onMenu(
      BuildContext context, WidgetRef ref, String value) async {
    final controller = ref.read(dayPlanControllerProvider);
    switch (value) {
      case 'time':
        final minute = await _pickSlot(context, ref,
            initial: item.entry.startMinute);
        if (minute != null) {
          await controller.moveEntry(item.entry.id, startMinute: minute);
        }
      case 'duration':
        if (!context.mounted) return;
        final minutes = await _pickDuration(context, item.entry.durationMinutes);
        if (minutes != null) {
          await controller.moveEntry(item.entry.id, durationMinutes: minutes);
        }
      case 'skip':
        await controller.setSkipped(item, !item.skipped);
      case 'remove':
        await controller.unplan(item.entry.id);
    }
  }
}

/// A drag carries either something from the backlog (plan it) or an existing
/// entry (move it). One payload type keeps every slot a single DragTarget.
class _PlanDrag {
  const _PlanDrag.backlog(BacklogItem this.backlogItem) : entryId = null;
  const _PlanDrag.entry(String this.entryId) : backlogItem = null;

  final BacklogItem? backlogItem;
  final String? entryId;
}

Future<int?> _pickSlot(BuildContext context, WidgetRef ref,
    {int? initial}) async {
  final now = initial ?? DayPlanRepository.boardStartMinute;
  final picked = await showTimePicker(
    context: context,
    initialTime: TimeOfDay(hour: now ~/ 60, minute: now % 60),
    helpText: 'Plan at',
  );
  if (picked == null) return null;
  // Snap to the board's grid so the card lands in a slot the user can later
  // drag it out of.
  final raw = picked.hour * 60 + picked.minute;
  return (raw ~/ DayPlanEntry.slotMinutes) * DayPlanEntry.slotMinutes;
}

Future<int?> _pickDuration(BuildContext context, int current) =>
    showDialog<int>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: const Text('How long?'),
        children: [
          for (final minutes in const [15, 30, 45, 60, 90, 120, 180])
            RadioListTile<int>(
              value: minutes,
              // ignore: deprecated_member_use
              groupValue: current,
              title: Text(minutes < 60
                  ? '$minutes min'
                  : '${(minutes / 60).toStringAsFixed(minutes % 60 == 0 ? 0 : 1)} h'),
              // ignore: deprecated_member_use
              onChanged: (value) => Navigator.pop(dialogContext, value),
            ),
        ],
      ),
    );
