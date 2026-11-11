import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../agent/behaviors/schedule_defaults.dart';
import '../planning/day_plan_controller.dart';
import '../../data/models/reminder.dart';
import '../../data/models/schedule_item.dart';
import '../../shared/providers.dart';
import '../../shared/theme/exa_theme.dart';
import '../../shared/widgets/exa_empty_state.dart';
import '../reminders/reminders_screen.dart';

final selectedDayProvider = StateProvider<DateTime>((ref) {
  final now = DateTime.now();
  return DateTime(now.year, now.month, now.day);
});

/// How much of the calendar the Schedule screen shows at once.
enum ScheduleViewMode { day, week, month }

final scheduleViewModeProvider =
    StateProvider<ScheduleViewMode>((ref) => ScheduleViewMode.day);

/// The half-open [from, to) window for [mode] anchored on [day].
(DateTime, DateTime) scheduleWindow(ScheduleViewMode mode, DateTime day) {
  final start = DateTime(day.year, day.month, day.day);
  switch (mode) {
    case ScheduleViewMode.day:
      return (start, start.add(const Duration(days: 1)));
    case ScheduleViewMode.week:
      final monday = start.subtract(Duration(days: start.weekday - 1));
      return (monday, monday.add(const Duration(days: 7)));
    case ScheduleViewMode.month:
      return (DateTime(day.year, day.month, 1),
          DateTime(day.year, day.month + 1, 1));
  }
}

/// One row on the calendar: either a scheduled event or a reminder firing that
/// day. Reminders appear here (with their times) so the calendar is a single
/// view of everything happening, including recurring ones.
class CalendarEntry {
  CalendarEntry.event(ScheduleItem this.event)
      : reminder = null,
        time = event.startAt;
  CalendarEntry.reminder(Reminder this.reminder, this.time) : event = null;

  final ScheduleItem? event;
  final Reminder? reminder;
  final DateTime time;

  bool get isReminder => reminder != null;
}

final daScheduleProvider =
    FutureProvider.autoDispose<List<CalendarEntry>>((ref) async {
  final day = ref.watch(selectedDayProvider);
  final mode = ref.watch(scheduleViewModeProvider);
  final (from, to) = scheduleWindow(mode, day);

  final events =
      await ref.watch(scheduleRepositoryProvider).listBetween(from, to);
  final reminderHits =
      await ref.watch(reminderRepositoryProvider).occurrencesBetween(from, to);

  final entries = [
    for (final e in events) CalendarEntry.event(e),
    for (final hit in reminderHits)
      CalendarEntry.reminder(hit.key, hit.value),
  ]..sort((a, b) => a.time.compareTo(b.time));
  return entries;
});

class ScheduleScreen extends ConsumerWidget {
  const ScheduleScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Reload when this tab is reopened - it's kept alive in the nav
    // IndexedStack, so it won't refetch on revisit on its own.
    ref.listen(tabVisitTickProvider(2), (_, _) {
      ref.invalidate(daScheduleProvider);
    });
    final day = ref.watch(selectedDayProvider);
    final mode = ref.watch(scheduleViewModeProvider);
    final itemsAsync = ref.watch(daScheduleProvider);

    void step(int dir) {
      final next = switch (mode) {
        ScheduleViewMode.day => day.add(Duration(days: dir)),
        ScheduleViewMode.week => day.add(Duration(days: 7 * dir)),
        ScheduleViewMode.month =>
          DateTime(day.year, day.month + dir, day.day),
      };
      ref.read(selectedDayProvider.notifier).state = next;
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(_titleFor(mode, day)),
        actions: [
          IconButton(
            icon: const Icon(Icons.view_day_outlined),
            tooltip: 'Plan this day',
            onPressed: () {
              // Hand the board the day being looked at, so "plan this day"
              // means the one on screen.
              ref.read(planDayProvider.notifier).state =
                  DateTime(day.year, day.month, day.day);
              // go, not push: Plan is a nav branch now, so this switches
              // to its tab instead of stacking a second copy on this one.
              context.go('/plan');
            },
          ),
          IconButton(
            icon: const Icon(Icons.download_outlined),
            tooltip: 'Import device calendar',
            onPressed: () async {
              final messenger = ScaffoldMessenger.of(context);
              messenger.showSnackBar(const SnackBar(
                  content: Text('Importing device calendar...')));
              final result =
                  await ref.read(deviceCalendarServiceProvider).import();
              ref.invalidate(daScheduleProvider);
              messenger.showSnackBar(
                  SnackBar(content: Text(result.summary)));
            },
          ),
          IconButton(
            icon: const Icon(Icons.chevron_left),
            onPressed: () => step(-1),
          ),
          IconButton(
            icon: const Icon(Icons.today),
            tooltip: 'Today',
            onPressed: () {
              final now = DateTime.now();
              ref.read(selectedDayProvider.notifier).state =
                  DateTime(now.year, now.month, now.day);
            },
          ),
          IconButton(
            icon: const Icon(Icons.chevron_right),
            onPressed: () => step(1),
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(48),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: SizedBox(
              width: double.infinity,
              child: SegmentedButton<ScheduleViewMode>(
                showSelectedIcon: false,
                style: ButtonStyle(
                  visualDensity: VisualDensity.compact,
                  textStyle: WidgetStatePropertyAll(
                      Theme.of(context).textTheme.labelLarge),
                ),
                segments: const [
                  ButtonSegment(
                      value: ScheduleViewMode.day, label: Text('Day')),
                  ButtonSegment(
                      value: ScheduleViewMode.week, label: Text('Week')),
                  ButtonSegment(
                      value: ScheduleViewMode.month, label: Text('Month')),
                ],
                selected: {mode},
                onSelectionChanged: (selection) => ref
                    .read(scheduleViewModeProvider.notifier)
                    .state = selection.first,
              ),
            ),
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _showEventSheet(context, ref, day),
        child: const Icon(Icons.add),
      ),
      body: itemsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(child: Text('Error: $error')),
        data: (entries) {
          if (entries.isEmpty) {
            return ExaEmptyState(
              icon: Icons.event_available_outlined,
              title: 'Nothing scheduled',
              message: 'No events or reminders ${_rangeNoun(mode)}. Add one '
                  'with the + button, or pull down to import your device '
                  'calendar.',
              actionLabel: 'Add an event',
              onAction: () => _showEventSheet(context, ref, day),
            );
          }
          // Day view is flat; week/month insert a header whenever the day
          // changes (rows hold either a DateTime header or a CalendarEntry).
          final rows = <Object>[];
          if (mode == ScheduleViewMode.day) {
            rows.addAll(entries);
          } else {
            DateTime? lastDay;
            for (final entry in entries) {
              final d = DateTime(
                  entry.time.year, entry.time.month, entry.time.day);
              if (lastDay == null || d != lastDay) {
                rows.add(d);
                lastDay = d;
              }
              rows.add(entry);
            }
          }
          return RefreshIndicator(
            color: ExaColors.accent,
            backgroundColor: ExaColors.surfaceHigh,
            onRefresh: () async {
              await ref.read(deviceCalendarServiceProvider).import();
              ref.invalidate(daScheduleProvider);
            },
            child: ListView.builder(
              padding: const EdgeInsets.only(bottom: 96),
              itemCount: rows.length,
              itemBuilder: (context, index) {
                final row = rows[index];
                if (row is DateTime) return _dayHeader(context, row);
                final entry = row as CalendarEntry;
                return entry.isReminder
                    ? _reminderTile(context, ref, entry.reminder!, entry.time)
                    : _eventTile(context, ref, entry.event!);
              },
            ),
          );
        },
      ),
    );
  }

  static bool _isSameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  static String _titleFor(ScheduleViewMode mode, DateTime day) {
    switch (mode) {
      case ScheduleViewMode.day:
        return _isSameDay(day, DateTime.now())
            ? 'Today'
            : DateFormat('EEE, MMM d').format(day);
      case ScheduleViewMode.week:
        final monday = day.subtract(Duration(days: day.weekday - 1));
        return 'Week of ${DateFormat('MMM d').format(monday)}';
      case ScheduleViewMode.month:
        return DateFormat('MMMM yyyy').format(day);
    }
  }

  static String _rangeNoun(ScheduleViewMode mode) => switch (mode) {
        ScheduleViewMode.day => 'on this day',
        ScheduleViewMode.week => 'this week',
        ScheduleViewMode.month => 'this month',
      };

  /// A day separator shown in week/month views.
  static Widget _dayHeader(BuildContext context, DateTime day) {
    final isToday = _isSameDay(day, DateTime.now());
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 2),
      child: Text(
        isToday
            ? 'Today · ${DateFormat('MMM d').format(day)}'
            : DateFormat('EEE, MMM d').format(day),
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
            color: isToday ? ExaColors.accent : ExaColors.textSecondary),
      ),
    );
  }

  /// A scheduled event row. Tap to edit it; the delete action also cancels
  /// its start-time notification.
  static Widget _eventTile(
      BuildContext context, WidgetRef ref, ScheduleItem item) {
    final start = DateFormat('HH:mm').format(item.startAt);
    final end =
        item.endAt == null ? null : DateFormat('HH:mm').format(item.endAt!);
    final details = [
      if (item.location?.isNotEmpty == true) item.location!,
      if (item.description?.isNotEmpty == true) item.description!,
    ].join(' - ');
    return ListTile(
      onTap: () =>
          _showEventSheet(context, ref, item.startAt, existing: item),
      leading: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(start, style: Theme.of(context).textTheme.titleMedium),
          if (end != null)
            Text(end, style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
      title: Text(item.title),
      subtitle: details.isEmpty ? null : Text(details),
      trailing: IconButton(
        icon: const Icon(Icons.delete_outline),
        onPressed: () async {
          final confirmed = await showDialog<bool>(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('Delete event?'),
                  content: Text(item.title),
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
              false;
          if (!confirmed) return;
          await ref.read(scheduleRepositoryProvider).delete(item.id);
          await ref
              .read(notificationServiceProvider)
              .cancelEventNotification(item.id);
          // If the event was mirrored to the phone calendar, remove it
          // there too.
          await ref.read(calendarSyncServiceProvider).removeEventMirror(item);
          ref.invalidate(daScheduleProvider);
        },
      ),
    );
  }

  /// A reminder firing this day. Tapping opens the same editor the
  /// Reminders screen uses - a row you can see on the calendar but not
  /// touch is the one dead end on this screen.
  ///
  /// Recurring reminders show one row per occurrence, and editing changes
  /// the whole series (there is no per-occurrence override), which the
  /// subtitle says so the effect is not a surprise.
  static Widget _reminderTile(BuildContext context, WidgetRef ref,
      Reminder reminder, DateTime time) {
    final theme = Theme.of(context);
    final repeats = reminder.recurrenceRule != null;
    return ListTile(
      onTap: () async {
        await RemindersScreen.showReminderSheet(context, ref,
            existing: reminder);
        // The sheet refreshes the Reminders screen; the calendar reads a
        // different provider and would otherwise keep showing the old time.
        ref.invalidate(daScheduleProvider);
      },
      leading: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(DateFormat('HH:mm').format(time),
              style: theme.textTheme.titleMedium),
          Icon(Icons.alarm, size: 16, color: theme.colorScheme.primary),
        ],
      ),
      title: Text(reminder.title),
      subtitle: Text(repeats
          ? 'Reminder · repeats ${reminder.recurrenceRule} · tap edits '
              'every occurrence'
          : 'Reminder'),
    );
  }

  /// Durations offered when creating an event; an existing event's own
  /// length is added to the list when it isn't one of these.
  static const _durationPresets = [30, 60, 120, 480];

  /// Lead times offered in the "Notify me" dropdown.
  static const _leadPresets = [0, 5, 10, 15, 30, 60];

  static String _minutesLabel(int minutes) {
    final hours = minutes ~/ 60;
    final rest = minutes % 60;
    if (hours == 0) return '$minutes min';
    if (rest == 0) return hours == 1 ? '1 hour' : '$hours hours';
    return '${hours}h ${rest}m';
  }

  static String _durationLabel(int minutes) =>
      minutes == 480 ? 'All day' : _minutesLabel(minutes);

  static String _leadLabel(int minutes) =>
      minutes == 0 ? 'At start time' : '${_minutesLabel(minutes)} before';

  /// The event editor: creates a new event on [day], or edits [existing] in
  /// place (tapping a row on the calendar).
  static Future<void> _showEventSheet(
      BuildContext context, WidgetRef ref, DateTime day,
      {ScheduleItem? existing}) async {
    final isEdit = existing != null;
    // Imported events belong to the phone calendar - they can be edited
    // here, but the next import rewrites them from the device copy, and
    // mirroring one back would duplicate it.
    final isDeviceEvent = isEdit && existing.source == 'device';
    final titleController =
        TextEditingController(text: existing?.title ?? '');
    final locationController =
        TextEditingController(text: existing?.location ?? '');
    final descriptionController =
        TextEditingController(text: existing?.description ?? '');
    DateTime startAt = existing?.startAt ??
        DateTime(day.year, day.month, day.day, TimeOfDay.now().hour + 1);
    // A schedule_rule behavior ("my meetings are 30 minutes, warn me 15
    // minutes ahead") seeds a new event; an existing one keeps its own.
    final defaults = isEdit
        ? ScheduleDefaults.none
        : await ScheduleDefaults.load(ref.read(behaviorRepositoryProvider));
    // null = "no end time", only reachable for an existing event that has
    // none (or a zero-length imported one).
    final existingMinutes =
        existing?.endAt?.difference(existing.startAt).inMinutes;
    int? durationMinutes = isEdit
        ? (existingMinutes != null && existingMinutes > 0
            ? existingMinutes
            : null)
        : (defaults.durationMinutes ?? 60);
    int leadMinutes =
        existing?.leadTimeMinutes ?? defaults.leadMinutes ?? 0;
    final calendarSync = ref.read(calendarSyncServiceProvider);
    // Pre-checked when the event is already mirrored, or - for a new event -
    // when the user has "add events to phone calendar" on in Settings; still
    // overridable per event.
    bool addToPhone = isEdit
        ? existing.deviceEventId != null
        : await calendarSync.eventSyncEnabled();
    if (!context.mounted) return;

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => Padding(
        padding: EdgeInsets.only(
            bottom: MediaQuery.of(sheetContext).viewInsets.bottom),
        child: StatefulBuilder(
          builder: (sheetContext, setSheetState) {
            final durationChoices = <int>{
              ..._durationPresets,
              if (durationMinutes != null) durationMinutes!,
            }.toList()
              ..sort();
            final leadChoices = <int>{..._leadPresets, leadMinutes}.toList()
              ..sort();
            return Padding(
              padding: const EdgeInsets.all(16),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(isEdit ? 'Edit event' : 'New event',
                        style: Theme.of(sheetContext).textTheme.titleLarge),
                    const SizedBox(height: 12),
                    TextField(
                      controller: titleController,
                      decoration: const InputDecoration(
                          labelText: 'Title', border: OutlineInputBorder()),
                      autofocus: !isEdit,
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: locationController,
                      decoration: const InputDecoration(
                          labelText: 'Location',
                          border: OutlineInputBorder()),
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
                          child: OutlinedButton.icon(
                            icon: const Icon(Icons.schedule),
                            label: Text(DateFormat('MMM d, HH:mm')
                                .format(startAt)),
                            onPressed: () async {
                              final date = await showDatePicker(
                                context: sheetContext,
                                initialDate: startAt,
                                firstDate: DateTime(2020),
                                lastDate: DateTime(2100),
                              );
                              if (date == null || !sheetContext.mounted) {
                                return;
                              }
                              final time = await showTimePicker(
                                context: sheetContext,
                                initialTime:
                                    TimeOfDay.fromDateTime(startAt),
                              );
                              setSheetState(() {
                                startAt = DateTime(
                                  date.year, date.month, date.day,
                                  time?.hour ?? startAt.hour,
                                  time?.minute ?? startAt.minute,
                                );
                              });
                            },
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: DropdownButtonFormField<int?>(
                            initialValue: durationMinutes,
                            decoration: const InputDecoration(
                                labelText: 'Duration',
                                border: OutlineInputBorder()),
                            items: [
                              if (durationMinutes == null)
                                const DropdownMenuItem(
                                    value: null,
                                    child: Text('No end time')),
                              for (final minutes in durationChoices)
                                DropdownMenuItem(
                                    value: minutes,
                                    child: Text(_durationLabel(minutes))),
                            ],
                            onChanged: (value) => durationMinutes = value,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    DropdownButtonFormField<int>(
                      initialValue: leadMinutes,
                      decoration: const InputDecoration(
                          labelText: 'Notify me',
                          border: OutlineInputBorder()),
                      items: [
                        for (final minutes in leadChoices)
                          DropdownMenuItem(
                              value: minutes,
                              child: Text(_leadLabel(minutes))),
                      ],
                      onChanged: (value) => leadMinutes = value ?? 0,
                    ),
                    if (isDeviceEvent)
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Text(
                          'Imported from your phone calendar. Changes stay '
                          'in Exa and are replaced the next time you import.',
                          style: Theme.of(sheetContext)
                              .textTheme
                              .bodySmall
                              ?.copyWith(color: ExaColors.textSecondary),
                        ),
                      )
                    else
                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        title: Text(isEdit
                            ? 'Keep on phone calendar'
                            : 'Also add to phone calendar'),
                        subtitle: const Text('Syncs and notifies via your '
                            'calendar app'),
                        value: addToPhone,
                        onChanged: (value) =>
                            setSheetState(() => addToPhone = value ?? false),
                      ),
                    const SizedBox(height: 8),
                    FilledButton(
                      onPressed: () async {
                        final title = titleController.text.trim();
                        if (title.isEmpty) return;
                        final messenger = ScaffoldMessenger.of(context);
                        final location = locationController.text.trim();
                        final description =
                            descriptionController.text.trim();
                        DateTime? endAt;
                        if (durationMinutes != null) {
                          endAt = startAt
                              .add(Duration(minutes: durationMinutes!));
                        } else if (isEdit && existing.endAt != null) {
                          // Zero-length imported event: keep its end pinned
                          // to the (possibly moved) start.
                          endAt = startAt.add(
                              existing.endAt!.difference(existing.startAt));
                        }
                        final repository =
                            ref.read(scheduleRepositoryProvider);
                        final item = isEdit
                            ? await repository.update(
                                existing.id,
                                title: title,
                                // Empty clears the field, as on Tasks.
                                location: location,
                                description: description,
                                startAt: startAt,
                                endAt: endAt,
                                leadTimeMinutes: leadMinutes,
                              )
                            : await repository.create(
                                title: title,
                                startAt: startAt,
                                endAt: endAt,
                                location:
                                    location.isEmpty ? null : location,
                                description:
                                    description.isEmpty ? null : description,
                                leadTimeMinutes: leadMinutes,
                              );
                        ref.invalidate(daScheduleProvider);
                        if (sheetContext.mounted) {
                          Navigator.of(sheetContext).pop();
                        }
                        if (item == null) {
                          messenger.showSnackBar(const SnackBar(
                              content:
                                  Text('That event no longer exists.')));
                          return;
                        }
                        // The user is doing this themselves, so write
                        // directly (the OS permission prompt is the only
                        // gate). Going through the sync service records the
                        // mirror's id, so later edits/deletes and imports
                        // track it.
                        var onPhoneCalendar = false;
                        if (addToPhone && !isDeviceEvent) {
                          try {
                            await calendarSync.pushEvent(item);
                            onPhoneCalendar = true;
                            messenger.showSnackBar(SnackBar(
                                content: Text(isEdit
                                    ? 'Updated on your phone calendar.'
                                    : 'Added to your phone calendar.')));
                          } catch (e) {
                            messenger.showSnackBar(SnackBar(
                                content: Text(
                                    'Phone calendar add failed: $e')));
                          }
                        } else if (item.deviceEventId != null) {
                          // Unchecked on an already-mirrored event: drop the
                          // phone-calendar copy.
                          await calendarSync.removeEventMirror(item);
                        }
                        // Time, title and lead may have changed, so
                        // re-register from scratch. Unless it's also on the
                        // phone calendar (which has its own alert), Exa
                        // fires the start-time notification.
                        final notifications =
                            ref.read(notificationServiceProvider);
                        await notifications.cancelEventNotification(item.id);
                        if (!onPhoneCalendar) {
                          await notifications
                              .scheduleEventNotification(item);
                        }
                        ref.invalidate(daScheduleProvider);
                      },
                      child: Text(isEdit ? 'Save' : 'Add event'),
                    ),
                    const SizedBox(height: 8),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
