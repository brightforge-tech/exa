import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../agent/security/capability_policy.dart';
import '../../agent/services/tool_labels.dart';
import '../../data/models/scheduled_job.dart';
import '../../shared/providers.dart';
import '../../shared/theme/exa_theme.dart';

final jobsProvider = FutureProvider.autoDispose<List<ScheduledJob>>(
    (ref) => ref.watch(jobRepositoryProvider).listAll());

/// Whether Android currently lets Exa fire exact alarms ("Alarms &
/// reminders" permission - denied by default on Android 14+).
final exactAlarmsAllowedProvider = FutureProvider.autoDispose<bool>(
    (ref) => ref.watch(notificationServiceProvider).canScheduleExact());

class JobsScreen extends ConsumerWidget {
  const JobsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final jobsAsync = ref.watch(jobsProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Scheduled jobs'),
        actions: [
          IconButton(
            icon: const Icon(Icons.history),
            tooltip: 'Job history',
            onPressed: () => context.go('/settings/job-history'),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _showJobSheet(context, ref),
        child: const Icon(Icons.add_task),
      ),
      body: jobsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(child: Text('Error: $error')),
        data: (jobs) {
          if (jobs.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'No background jobs yet.\n\nAdd a daily summary here, or '
                  'ask Exa: "Every morning at 7:30, send me a summary of '
                  'my day."',
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }
          // On-time job runs depend on the exact-alarm chain; without the
          // "Alarms & reminders" grant, everything degrades to the
          // roughly-15-minute background tick (fatal for short-interval
          // jobs). Surface that instead of letting it fail invisibly.
          final hasActiveJob = jobs.any((job) => job.status == 'Active');
          final exactAllowed =
              ref.watch(exactAlarmsAllowedProvider).valueOrNull ?? true;
          return ListView(
            padding: const EdgeInsets.only(bottom: 80),
            children: [
              if (hasActiveJob && !exactAllowed) const _ExactAlarmBanner(),
              for (final job in jobs) _JobTile(job: job),
            ],
          );
        },
      ),
    );
  }

  /// "HH:mm" from a stored schedule rule, or null when absent/malformed.
  static TimeOfDay? _parseTime(String? value) {
    if (value == null) return null;
    final parts = value.split(':');
    final hour = int.tryParse(parts.first);
    final minute = parts.length > 1 ? int.tryParse(parts[1]) : 0;
    if (hour == null || minute == null) return null;
    if (hour < 0 || hour > 23 || minute < 0 || minute > 59) return null;
    return TimeOfDay(hour: hour, minute: minute);
  }

  /// Creates a job, or edits [existing] in place.
  static Future<void> _showJobSheet(BuildContext context, WidgetRef ref,
      {ScheduledJob? existing}) async {
    final isEdit = existing != null;
    final rule = existing?.scheduleRule ?? const {};
    final nameController =
        TextEditingController(text: existing?.name ?? '');
    final instructionsController =
        TextEditingController(text: existing?.description ?? '');
    // Free text rather than a fixed 30/60 dropdown: jobs exist at 2-minute
    // cadence, and offering only preset intervals would silently rewrite
    // one the moment its owner opened this sheet.
    final intervalController = TextEditingController(
        text: '${(rule['minutes'] as int?) ?? 30}');
    String jobType = existing?.jobType ?? 'daily_summary';
    String frequency = switch (rule['type']) {
      'weekly' => 'weekly',
      'interval' => 'interval',
      _ => 'daily',
    };
    int weekday = (rule['weekday'] as int?) ?? DateTime.monday;
    TimeOfDay time = _parseTime(rule['time'] as String?) ??
        const TimeOfDay(hour: 7, minute: 30);
    String behaviorMode = existing?.behaviorMode ?? 'live';
    String missedRunPolicy = existing?.missedRunPolicy ?? 'run_once_now';
    bool muteNotifications = existing?.muteNotifications ?? false;
    String? onlyIf = existing?.onlyIf;
    const weekdayNames = [
      'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday',
      'Saturday', 'Sunday',
    ];

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
                Text(isEdit ? 'Edit scheduled job' : 'New scheduled job',
                    style: Theme.of(sheetContext).textTheme.titleLarge),
                const SizedBox(height: 12),
                TextField(
                  controller: nameController,
                  decoration: const InputDecoration(
                      labelText: 'Name', border: OutlineInputBorder()),
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  initialValue: jobType,
                  decoration: const InputDecoration(
                      labelText: 'Job type', border: OutlineInputBorder()),
                  items: const [
                    DropdownMenuItem(
                        value: 'daily_summary',
                        child: Text('Daily summary notification')),
                    DropdownMenuItem(
                        value: 'daily_review',
                        child: Text('Daily review (AI-written)')),
                    DropdownMenuItem(
                        value: 'agent_task',
                        child: Text('Custom task (Exa runs it)')),
                    DropdownMenuItem(
                        value: 'task_cleanup',
                        child: Text('Flag overdue tasks')),
                    DropdownMenuItem(
                        value: 'email_sync',
                        child: Text('Fetch new mail (IMAP)')),
                    DropdownMenuItem(
                        value: 'message_sync',
                        child: Text('Take in chat messages')),
                    DropdownMenuItem(
                        value: 'calendar_sync',
                        child: Text('Import device calendar')),
                  ],
                  onChanged: (value) =>
                      setSheetState(() => jobType = value ?? jobType),
                ),
                if (jobType == 'agent_task') ...[
                  const SizedBox(height: 8),
                  TextField(
                    controller: instructionsController,
                    maxLines: 3,
                    decoration: const InputDecoration(
                      labelText: 'Instructions',
                      hintText: 'What should Exa do on each run?',
                      helperText: 'Runs as a full agent turn with your saved '
                          'behaviours. Nobody is there to approve anything, '
                          'so confirmation-gated actions are skipped.',
                      helperMaxLines: 3,
                      border: OutlineInputBorder(),
                    ),
                  ),
                ],
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        initialValue: frequency,
                        decoration: const InputDecoration(
                            labelText: 'Repeats',
                            border: OutlineInputBorder()),
                        items: const [
                          DropdownMenuItem(
                              value: 'daily', child: Text('Daily')),
                          DropdownMenuItem(
                              value: 'weekly', child: Text('Weekly')),
                          DropdownMenuItem(
                              value: 'interval',
                              child: Text('Every N minutes')),
                        ],
                        onChanged: (value) => setSheetState(
                            () => frequency = value ?? frequency),
                      ),
                    ),
                    if (frequency == 'interval') ...[
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: intervalController,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: 'Minutes',
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                    ],
                    if (frequency == 'weekly') ...[
                      const SizedBox(width: 8),
                      Expanded(
                        child: DropdownButtonFormField<int>(
                          initialValue: weekday,
                          decoration: const InputDecoration(
                              labelText: 'On',
                              border: OutlineInputBorder()),
                          items: [
                            for (var i = 0; i < 7; i++)
                              DropdownMenuItem(
                                  value: i + 1,
                                  child: Text(weekdayNames[i])),
                          ],
                          onChanged: (value) => setSheetState(
                              () => weekday = value ?? weekday),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 8),
                if (frequency != 'interval')
                  OutlinedButton.icon(
                    icon: const Icon(Icons.schedule),
                    label: Text('Runs at ${time.format(sheetContext)}'),
                    onPressed: () async {
                      final picked = await showTimePicker(
                          context: sheetContext, initialTime: time);
                      if (picked != null) {
                        setSheetState(() => time = picked);
                      }
                    },
                  ),
                if (jobType == 'agent_task') ...[
                  const SizedBox(height: 8),
                  DropdownButtonFormField<String>(
                    initialValue: onlyIf ?? '',
                    isExpanded: true,
                    decoration: const InputDecoration(
                        labelText: 'Runs',
                        border: OutlineInputBorder()),
                    items: const [
                      DropdownMenuItem(
                          value: '', child: Text('Every time it is due')),
                      DropdownMenuItem(
                          value: ScheduledJob.onlyIfNewMessages,
                          child: Text('Only when new chat messages wait')),
                      DropdownMenuItem(
                          value: ScheduledJob.onlyIfNewEmail,
                          child: Text('Only when new mail waits')),
                      DropdownMenuItem(
                          value: ScheduledJob.onlyIfNewInbound,
                          child: Text('Only when either waits')),
                    ],
                    onChanged: (value) => setSheetState(() =>
                        onlyIf = (value == null || value.isEmpty)
                            ? null
                            : value),
                  ),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<String>(
                    initialValue: behaviorMode,
                    decoration: const InputDecoration(
                        labelText: 'Behaviours',
                        border: OutlineInputBorder()),
                    items: const [
                      DropdownMenuItem(
                          value: 'live',
                          child: Text('Use my current rules')),
                      DropdownMenuItem(
                          value: 'snapshot',
                          child: Text('Lock to the rules saved now')),
                      DropdownMenuItem(
                          value: 'none', child: Text('Ignore my rules')),
                    ],
                    onChanged: (value) => setSheetState(
                        () => behaviorMode = value ?? behaviorMode),
                  ),
                ],
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  initialValue: missedRunPolicy,
                  decoration: const InputDecoration(
                      labelText: 'If the phone was asleep',
                      border: OutlineInputBorder()),
                  items: const [
                    DropdownMenuItem(
                        value: 'run_once_now',
                        child: Text('Catch up with one run')),
                    DropdownMenuItem(
                        value: 'skip', child: Text('Skip missed runs')),
                    DropdownMenuItem(
                        value: 'run_every_missed_occurrence',
                        child: Text('Run every missed occurrence')),
                  ],
                  onChanged: (value) => setSheetState(
                      () => missedRunPolicy = value ?? missedRunPolicy),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  secondary: Icon(muteNotifications
                      ? Icons.notifications_off_outlined
                      : Icons.notifications_active_outlined),
                  title: const Text('Mute notifications'),
                  subtitle: Text(muteNotifications
                      ? 'This job never buzzes the phone. Its results still '
                          'go to chat and Job history, and you are still '
                          'told if it stops running.'
                      : 'Results are pushed to your phone as they happen.'),
                  value: muteNotifications,
                  onChanged: (value) =>
                      setSheetState(() => muteNotifications = value),
                ),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: () async {
                    final messenger = ScaffoldMessenger.of(context);
                    final instructions =
                        instructionsController.text.trim();
                    // A custom task with no instructions could only ever
                    // fail at run time, so refuse it here.
                    if (jobType == 'agent_task' && instructions.isEmpty) {
                      messenger.showSnackBar(const SnackBar(
                          content: Text('Tell Exa what to do on each '
                              'run first.')));
                      return;
                    }
                    final minutes =
                        int.tryParse(intervalController.text.trim());
                    if (frequency == 'interval' &&
                        (minutes == null ||
                            minutes < ScheduledJob.minIntervalMinutes)) {
                      messenger.showSnackBar(SnackBar(
                          content: Text('Intervals must be at least '
                              '${ScheduledJob.minIntervalMinutes} minutes - '
                              'the scheduler cannot run more often.')));
                      return;
                    }
                    final name = nameController.text.trim().isEmpty
                        ? (jobType == 'agent_task'
                            ? 'Custom task'
                            : 'Daily summary')
                        : nameController.text.trim();
                    final timeText =
                        '${time.hour.toString().padLeft(2, '0')}:'
                        '${time.minute.toString().padLeft(2, '0')}';
                    final scheduleRule = <String, Object?>{
                      ...switch (frequency) {
                        'weekly' => {
                            'type': 'weekly',
                            'weekday': weekday,
                            'time': timeText,
                          },
                        'interval' => {
                            'type': 'interval',
                            'minutes': minutes ?? 30,
                            // This sheet has no field for the active
                            // window. Rebuilding the rule without it turned
                            // a daytime-only job into an all-night one the
                            // first time its owner changed anything else.
                            if (rule['active_from'] != null &&
                                rule['active_to'] != null) ...{
                              'active_from': rule['active_from'],
                              'active_to': rule['active_to'],
                            },
                          },
                        _ => {'type': 'daily', 'time': timeText},
                      },
                      if (jobType == 'agent_task' && onlyIf != null)
                        'only_if': onlyIf,
                    };
                    final repository = ref.read(jobRepositoryProvider);
                    if (isEdit) {
                      await repository.update(
                        existing.id,
                        name: name,
                        jobType: jobType,
                        // Empty clears it, as on the other edit sheets.
                        description: instructions,
                        scheduleRule: scheduleRule,
                        behaviorMode: behaviorMode,
                        missedRunPolicy: missedRunPolicy,
                        muteNotifications: muteNotifications,
                      );
                    } else {
                      await repository.create(
                        name: name,
                        jobType: jobType,
                        description:
                            instructions.isEmpty ? null : instructions,
                        scheduleRule: scheduleRule,
                        behaviorMode: behaviorMode,
                        missedRunPolicy: missedRunPolicy,
                        muteNotifications: muteNotifications,
                        createdBy: 'user',
                      );
                    }
                    ref.invalidate(jobsProvider);
                    if (sheetContext.mounted) {
                      Navigator.of(sheetContext).pop();
                    }
                  },
                  child: Text(isEdit ? 'Save job' : 'Create job'),
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

/// Shown when active jobs exist but Android's "Alarms & reminders"
/// permission is off: the exact-alarm chain then degrades to the
/// ~15-minute background tick — late for timed jobs, fatal for
/// short-interval ones.
class _ExactAlarmBanner extends ConsumerWidget {
  const _ExactAlarmBanner();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      color: scheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.timer_off_outlined,
                    color: scheme.onErrorContainer, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('Fast schedules need exact alarms',
                      style: Theme.of(context)
                          .textTheme
                          .titleSmall
                          ?.copyWith(color: scheme.onErrorContainer)),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
                'Android\'s "Alarms & reminders" permission is off, so '
                'jobs only run on the roughly-15-minute background check '
                'instead of at their exact times. Schedules faster than '
                '15 minutes cannot keep up without it.',
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: scheme.onErrorContainer)),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () async {
                  await ref
                      .read(notificationServiceProvider)
                      .requestExactAlarms();
                  ref.invalidate(exactAlarmsAllowedProvider);
                },
                child: const Text('Allow exact alarms'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _JobTile extends ConsumerWidget {
  const _JobTile({required this.job});

  final ScheduledJob job;

  static Widget _policyLine(
      BuildContext context, IconData icon, String text) {
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 14, color: ExaColors.textTertiary),
          const SizedBox(width: 6),
          Expanded(
            child: Text(text,
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: ExaColors.textSecondary)),
          ),
        ],
      ),
    );
  }

  /// Scheduled runs are unattended, so they can never send, delete, or
  /// change Exa's own rules - that is enforced in the tool executor, not
  /// just asked of the model. A job can be narrowed further than that, and
  /// widened in exactly one way: an outbound grant the user made when they
  /// scheduled it ("text Mum every Friday"), which is spelled out here so it
  /// is never a surprise.
  String _permissionsLine() {
    final permissions = JobPermissions.decode(job.permissionsJson);
    if (permissions.isEmpty) {
      return 'Runs unattended: may read and create, never send, delete, or '
          'change its own rules';
    }
    final parts = <String>[];
    if (permissions.outboundGrants.isNotEmpty) {
      parts.add('may ${(permissions.outboundGrants.toList()..sort())
          .map(ToolLabels.describe).join(', ')} without asking');
    }
    if (permissions.allowedTools.isNotEmpty) {
      // Reads never count against the list, and a listed tool admits other
      // edits of the same kind (see CapabilityGate), so name the kinds of
      // record the job may change - the tools would describe a narrower
      // job than the one that runs.
      final kinds = <String>[];
      final other = <String>[];
      for (final tool in permissions.allowedTools.toList()..sort()) {
        if (CapabilityGate.capabilityOf(tool) == ToolCapability.read) {
          continue;
        }
        final kind = CapabilityGate.writeKindOf(tool, const {});
        if (kind == null) {
          other.add(ToolLabels.describe(tool));
        } else if (!kinds.contains(_kindLabel(kind))) {
          kinds.add(_kindLabel(kind));
        }
      }
      final scope = [...kinds, ...other];
      parts.add(scope.isEmpty
          ? 'may look things up but change nothing'
          : 'may look things up; otherwise only works on '
              '${scope.join(', ')}');
    }
    if (permissions.blockedTools.isNotEmpty) {
      parts.add('never ${(permissions.blockedTools.toList()..sort())
          .map(ToolLabels.describe).join(', ')}');
    }
    final line = parts.join('; ');
    return '${line[0].toUpperCase()}${line.substring(1)}';
  }

  /// Plain words for a write-effect family on the permissions line.
  static String _kindLabel(String kind) => switch (kind) {
        'task' => 'tasks',
        'reminder' => 'reminders',
        'calendar' => 'the schedule',
        'message' => 'chat messages',
        'email' => 'email',
        'day_plan' => 'the day plan',
        'file' => 'files',
        'screen' => 'screens',
        'collection' || 'record' => 'records',
        'behavior' => 'its own rules',
        'job' => 'scheduled jobs',
        _ => kind.replaceAll('_', ' '),
      };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isActive = job.status == 'Active';
    final format = DateFormat('MMM d, HH:mm');

    return ExpansionTile(
      leading: Icon(
        switch (job.jobType) {
          'daily_summary' => Icons.wb_sunny_outlined,
          'daily_review' => Icons.auto_awesome,
          'agent_task' => Icons.smart_toy_outlined,
          _ => Icons.cleaning_services_outlined,
        },
        color: isActive ? Theme.of(context).colorScheme.primary : Colors.grey,
      ),
      title: Text(job.name),
      subtitle: Text([
        job.status,
        switch (job.scheduleRule['type']) {
          'weekly' => 'weekly at ${job.scheduleRule['time'] ?? '?'}',
          'interval' =>
            'every ${job.scheduleRule['minutes'] ?? '?'} min',
          _ => 'daily at ${job.scheduleRule['time'] ?? '?'}',
        },
        if (job.nextRunAt != null && isActive)
          'next ${format.format(job.nextRunAt!)}',
      ].join(' - ')),
      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      expandedCrossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (job.jobType == 'agent_task' &&
            (job.description?.isNotEmpty ?? false))
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text('"${job.description}"',
                style: Theme.of(context).textTheme.bodyMedium),
          ),
        // What this job may do and which rules it runs under - the two
        // things that decide what it can change while nobody is watching.
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (ScheduledJob.describeOnlyIf(job.onlyIf) != null)
                _policyLine(
                  context,
                  Icons.mark_chat_unread_outlined,
                  ScheduledJob.describeOnlyIf(job.onlyIf)!,
                ),
              _policyLine(
                context,
                Icons.tune,
                switch (job.behaviorMode) {
                  'snapshot' => 'Behaviours: locked to the rules saved when '
                      'this job was created',
                  'none' => 'Behaviours: not applied',
                  _ => 'Behaviours: uses your current rules',
                },
              ),
              _policyLine(context, Icons.shield_outlined, _permissionsLine()),
              if (job.muteNotifications)
                _policyLine(
                  context,
                  Icons.notifications_off_outlined,
                  'Muted: results go to chat and Job history only. A '
                      'notice still arrives if this job stops running.',
                ),
              if (job.missedRunPolicy != 'run_once_now')
                _policyLine(
                  context,
                  Icons.update,
                  job.missedRunPolicy == 'skip'
                      ? 'Missed runs are skipped'
                      : 'Every missed run is caught up',
                ),
            ],
          ),
        ),
        Row(
          children: [
            TextButton.icon(
              icon: const Icon(Icons.edit_outlined, size: 18),
              label: const Text('Edit'),
              onPressed: () =>
                  JobsScreen._showJobSheet(context, ref, existing: job),
            ),
            TextButton.icon(
              icon: Icon(isActive ? Icons.pause : Icons.play_arrow,
                  size: 18),
              label: Text(isActive ? 'Pause' : 'Resume'),
              onPressed: () async {
                await ref
                    .read(jobRepositoryProvider)
                    .setStatus(job.id, isActive ? 'Paused' : 'Active');
                ref.invalidate(jobsProvider);
              },
            ),
            TextButton.icon(
              icon: const Icon(Icons.play_circle_outline, size: 18),
              label: const Text('Run now'),
              onPressed: () async {
                final messenger = ScaffoldMessenger.of(context);
                final outcome =
                    await ref.read(jobRunnerProvider).runJob(job);
                ref.invalidate(jobsProvider);
                messenger.showSnackBar(SnackBar(
                  content: Text(outcome.success
                      ? 'Job ran: ${outcome.summary}'
                      : 'Job failed: ${outcome.summary}'),
                ));
              },
            ),
            TextButton.icon(
              icon: const Icon(Icons.delete_outline, size: 18),
              label: const Text('Delete'),
              onPressed: () async {
                await ref.read(jobRepositoryProvider).delete(job.id);
                ref.invalidate(jobsProvider);
              },
            ),
          ],
        ),
        FutureBuilder(
          future: ref.read(jobRepositoryProvider).listRuns(job.id),
          builder: (context, snapshot) {
            final runs = snapshot.data ?? const [];
            if (runs.isEmpty) {
              return const Padding(
                padding: EdgeInsets.symmetric(vertical: 4),
                child: Text('No runs yet.'),
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Recent runs:'),
                for (final run in runs.take(5))
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          run.status == 'Success'
                              ? Icons.check_circle
                              : run.status == 'Failed'
                                  ? Icons.error
                                  : Icons.hourglass_top,
                          size: 14,
                          color: run.status == 'Success'
                              ? Colors.green
                              : run.status == 'Failed'
                                  ? Colors.red
                                  : Colors.grey,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            '${format.format(run.startedAt)} - '
                            '${run.resultSummary ?? run.errorMessage ?? run.status}',
                            style: Theme.of(context).textTheme.bodySmall,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }
}
