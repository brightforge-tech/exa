import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../data/models/reminder.dart';
import '../../shared/providers.dart';
import '../../shared/theme/exa_theme.dart';
import '../../shared/widgets/exa_empty_state.dart';

final remindersProvider = FutureProvider.autoDispose<List<Reminder>>(
    (ref) => ref.watch(reminderRepositoryProvider).listAll());

class RemindersScreen extends ConsumerWidget {
  const RemindersScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Reload when this tab is reopened - it's kept alive in the nav
    // IndexedStack, so it won't refetch on revisit on its own.
    // Index 4 since the Plan board took 3 - see _destinations in router.dart.
    ref.listen(tabVisitTickProvider(4), (_, _) {
      ref.invalidate(remindersProvider);
    });
    final remindersAsync = ref.watch(remindersProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Reminders')),
      floatingActionButton: FloatingActionButton(
        onPressed: () => showReminderSheet(context, ref),
        child: const Icon(Icons.add_alarm),
      ),
      body: remindersAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(child: Text('Error: $error')),
        data: (reminders) {
          if (reminders.isEmpty) {
            return ExaEmptyState(
              icon: Icons.notifications_active_outlined,
              title: 'No reminders yet',
              message:
                  'Tell Exa "remind me tomorrow at 8 AM to call John", '
                  'or add one with the button.',
              actionLabel: 'Add a reminder',
              onAction: () => showReminderSheet(context, ref),
            );
          }
          final active =
              reminders.where((r) => r.status == 'Active').toList();
          final inactive =
              reminders.where((r) => r.status != 'Active').toList();
          return RefreshIndicator(
            color: ExaColors.accent,
            backgroundColor: ExaColors.surfaceHigh,
            onRefresh: () async => ref.invalidate(remindersProvider),
            child: ListView(
              padding: const EdgeInsets.only(bottom: 96),
              children: [
                for (final reminder in active)
                  _ReminderTile(reminder: reminder, ref: ref),
                if (inactive.isNotEmpty) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 18, 16, 6),
                    child: Text('Past',
                        style: Theme.of(context)
                            .textTheme
                            .titleSmall
                            ?.copyWith(color: ExaColors.textTertiary)),
                  ),
                  for (final reminder in inactive)
                    _ReminderTile(reminder: reminder, ref: ref),
                ],
              ],
            ),
          );
        },
      ),
    );
  }

  static Future<void> showReminderSheet(
      BuildContext context, WidgetRef ref, {Reminder? existing}) async {
    final isEdit = existing != null;
    final titleController =
        TextEditingController(text: existing?.title ?? '');
    DateTime remindAt =
        existing?.remindAt ?? DateTime.now().add(const Duration(hours: 1));
    String? recurrence = existing?.recurrenceRule;

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => Padding(
        padding: EdgeInsets.only(
            bottom: MediaQuery.of(sheetContext).viewInsets.bottom),
        child: StatefulBuilder(
          builder: (sheetContext, setSheetState) => Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(isEdit ? 'Edit reminder' : 'New reminder',
                    style: Theme.of(sheetContext).textTheme.titleLarge),
                const SizedBox(height: 12),
                TextField(
                  controller: titleController,
                  decoration: const InputDecoration(
                      labelText: 'Remind me to...',
                      border: OutlineInputBorder()),
                  autofocus: true,
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  icon: const Icon(Icons.schedule),
                  label: Text(
                      DateFormat('EEE, MMM d - HH:mm').format(remindAt)),
                  onPressed: () async {
                    final date = await showDatePicker(
                      context: sheetContext,
                      initialDate: remindAt,
                      firstDate: DateTime.now()
                          .subtract(const Duration(days: 1)),
                      lastDate: DateTime(2100),
                    );
                    if (date == null || !sheetContext.mounted) return;
                    final time = await showTimePicker(
                      context: sheetContext,
                      initialTime: TimeOfDay.fromDateTime(remindAt),
                    );
                    setSheetState(() {
                      remindAt = DateTime(
                        date.year, date.month, date.day,
                        time?.hour ?? remindAt.hour,
                        time?.minute ?? remindAt.minute,
                      );
                    });
                  },
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<String?>(
                  initialValue: recurrence,
                  decoration: const InputDecoration(
                      labelText: 'Repeat', border: OutlineInputBorder()),
                  items: const [
                    DropdownMenuItem(value: null, child: Text('Once')),
                    DropdownMenuItem(value: 'daily', child: Text('Daily')),
                    DropdownMenuItem(
                        value: 'weekly', child: Text('Weekly')),
                    DropdownMenuItem(
                        value: 'monthly', child: Text('Monthly')),
                  ],
                  onChanged: (value) => recurrence = value,
                ),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: () async {
                    final title = titleController.text.trim();
                    if (title.isEmpty) return;
                    final reminders = ref.read(reminderRepositoryProvider);
                    final notifications =
                        ref.read(notificationServiceProvider);
                    if (isEdit) {
                      final updated = await reminders.update(
                        existing.id,
                        title: title,
                        remindAt: remindAt,
                        recurrenceRule: recurrence,
                        clearRecurrence: existing.recurrenceRule != null &&
                            recurrence == null,
                      );
                      if (updated != null) {
                        // Reschedule from scratch: time or recurrence may have
                        // changed.
                        await notifications.cancelReminder(updated);
                        if (updated.status == 'Active') {
                          await notifications.scheduleReminder(updated);
                        }
                      }
                    } else {
                      final reminder = await reminders.create(
                        title: title,
                        remindAt: remindAt,
                        recurrenceRule: recurrence,
                        createdBy: 'user',
                      );
                      await notifications.scheduleReminder(reminder);
                    }
                    ref.invalidate(remindersProvider);
                    if (sheetContext.mounted) {
                      Navigator.of(sheetContext).pop();
                    }
                  },
                  child: Text(isEdit ? 'Save reminder' : 'Add reminder'),
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

class _ReminderTile extends StatelessWidget {
  const _ReminderTile({required this.reminder, required this.ref});

  final Reminder reminder;
  final WidgetRef ref;

  @override
  Widget build(BuildContext context) {
    final isActive = reminder.status == 'Active';
    final timeText =
        DateFormat('EEE, MMM d - HH:mm').format(reminder.remindAt);

    return ListTile(
      // Tap an active reminder to edit its time, title, or recurrence.
      onTap: isActive
          ? () => RemindersScreen.showReminderSheet(context, ref,
              existing: reminder)
          : null,
      leading: Icon(
        isActive ? Icons.alarm_on : Icons.alarm_off,
        color: isActive ? Theme.of(context).colorScheme.primary : null,
      ),
      title: Text(reminder.title),
      subtitle: Text([
        timeText,
        if (reminder.recurrenceRule != null)
          'repeats ${reminder.recurrenceRule}',
        if (!isActive) reminder.status.toLowerCase(),
      ].join(' - ')),
      trailing: isActive
          ? IconButton(
              tooltip: 'Cancel reminder',
              icon: const Icon(Icons.close),
              onPressed: () async {
                final repo = ref.read(reminderRepositoryProvider);
                final canceled = await repo.cancel(reminder.id);
                if (canceled != null) {
                  await ref
                      .read(notificationServiceProvider)
                      .cancelReminder(canceled);
                }
                ref.invalidate(remindersProvider);
              },
            )
          : null,
    );
  }
}
