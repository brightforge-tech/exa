import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../data/repositories/job_repository.dart';
import '../../data/repositories/provenance_repository.dart';
import '../../shared/providers.dart';
import '../../shared/theme/exa_theme.dart';
import '../../shared/widgets/exa_empty_state.dart';
import '../assistant/chat_controller.dart';

final jobHistoryProvider =
    FutureProvider.autoDispose<List<JobRunWithJob>>(
        (ref) => ref.watch(jobRepositoryProvider).listAllRuns());

/// Every past scheduled-job run across all jobs, newest first — read the
/// full brief or error, re-run a job, or pull a brief into chat to act on.
class JobHistoryScreen extends ConsumerWidget {
  const JobHistoryScreen({super.key});

  static const _briefTypes = {'daily_summary', 'daily_review'};

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final runsAsync = ref.watch(jobHistoryProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Job history'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => ref.invalidate(jobHistoryProvider),
          ),
        ],
      ),
      body: runsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(child: Text('Error: $error')),
        data: (runs) {
          if (runs.isEmpty) {
            return const ExaEmptyState(
              icon: Icons.history,
              title: 'No job runs yet',
              message:
                  'When a scheduled job runs — like your morning brief — '
                  'its result shows up here, success or failure.',
            );
          }
          return RefreshIndicator(
            color: ExaColors.accent,
            backgroundColor: ExaColors.surfaceHigh,
            onRefresh: () async => ref.invalidate(jobHistoryProvider),
            child: ListView.separated(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
              itemCount: runs.length,
              separatorBuilder: (_, _) => const SizedBox(height: 10),
              itemBuilder: (context, index) => _RunCard(
                entry: runs[index],
                isBrief: _briefTypes.contains(runs[index].jobType),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _RunCard extends ConsumerWidget {
  const _RunCard({required this.entry, required this.isBrief});

  final JobRunWithJob entry;
  final bool isBrief;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final run = entry.run;
    final failed = run.status == 'Failed';
    final body = run.errorMessage ?? run.resultSummary ?? '(no output)';

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  failed
                      ? Icons.error_outline
                      : run.status == 'Success'
                          ? Icons.check_circle_outline
                          : Icons.hourglass_top,
                  size: 18,
                  color: failed
                      ? ExaColors.error
                      : run.status == 'Success'
                          ? ExaColors.success
                          : ExaColors.textTertiary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(entry.jobName,
                      style: theme.textTheme.titleSmall),
                ),
                Text(
                  DateFormat('MMM d, HH:mm').format(run.startedAt),
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: ExaColors.textTertiary),
                ),
              ],
            ),
            const SizedBox(height: 10),
            SelectableText(
              body,
              style: theme.textTheme.bodyMedium?.copyWith(
                color:
                    failed ? ExaColors.error : ExaColors.textPrimary,
                height: 1.35,
              ),
            ),
            // What this run actually created, and a way to take it back.
            // A task that appeared overnight with no explanation is
            // indistinguishable from a bug; this is the explanation.
            _CreatedByRun(runId: run.id),
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (isBrief && run.resultSummary != null)
                  TextButton.icon(
                    icon: const Icon(Icons.forum_outlined, size: 18),
                    label: const Text('Address in chat'),
                    onPressed: () => _addressInChat(context, ref),
                  ),
                TextButton.icon(
                  icon: const Icon(Icons.replay, size: 18),
                  label: const Text('Run again'),
                  onPressed: () => _runAgain(context, ref),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _runAgain(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    final job = await ref.read(jobRepositoryProvider).getById(entry.run.jobId);
    if (job == null) {
      messenger.showSnackBar(const SnackBar(
          content: Text('That job no longer exists.')));
      return;
    }
    messenger.showSnackBar(const SnackBar(content: Text('Running...')));
    final outcome = await ref.read(jobRunnerProvider).runJob(job);
    ref.invalidate(jobHistoryProvider);
    messenger.showSnackBar(SnackBar(
        content: Text(outcome.success
            ? 'Done: ${outcome.summary}'
            : 'Failed: ${outcome.summary}')));
  }

  /// Drops this brief into the Exa chat (so even old runs are actionable)
  /// and jumps there.
  Future<void> _addressInChat(BuildContext context, WidgetRef ref) async {
    await ref.read(chatRepositoryProvider).append(
      'assistant',
      entry.run.resultSummary!,
      meta: {'source': 'scheduled_job', 'job_title': entry.jobName},
    );
    await ref.read(chatControllerProvider.notifier).refresh();
    if (context.mounted) context.go('/');
  }
}

/// Records created by one run, with an undo. Renders nothing when the run
/// created nothing, which is the common case for a read-only sync.
final _runCreationsProvider = FutureProvider.autoDispose
    .family<List<ProvenancedRecord>, String>((ref, runId) =>
        ref.watch(provenanceRepositoryProvider).byRun(runId));

class _CreatedByRun extends ConsumerWidget {
  const _CreatedByRun({required this.runId});

  final String runId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final records = ref.watch(_runCreationsProvider(runId)).valueOrNull;
    if (records == null || records.isEmpty) return const SizedBox.shrink();
    final live = [for (final r in records) if (!r.isUndone) r];
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Created by this run',
            style: theme.textTheme.labelMedium
                ?.copyWith(color: ExaColors.textTertiary),
          ),
          const SizedBox(height: 4),
          for (final record in records.take(6))
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Text(
                '• ${record.kind}: ${record.title}'
                '${record.isUndone ? ' (undone)' : ''}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: record.isUndone
                      ? ExaColors.textTertiary
                      : ExaColors.textSecondary,
                  decoration:
                      record.isUndone ? TextDecoration.lineThrough : null,
                ),
              ),
            ),
          if (records.length > 6)
            Text('…and ${records.length - 6} more',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: ExaColors.textTertiary)),
          if (live.isNotEmpty)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                icon: const Icon(Icons.undo, size: 18),
                label: Text('Undo ${live.length} item'
                    '${live.length == 1 ? '' : 's'}'),
                onPressed: () => _undo(context, ref, live.length),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _undo(BuildContext context, WidgetRef ref, int count) async {
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Undo this run?'),
        content: Text('This removes the $count record'
            '${count == 1 ? '' : 's'} this run created. The run itself '
            'stays in the history.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Undo')),
        ],
      ),
    );
    if (confirmed != true) return;
    final undone =
        await ref.read(provenanceRepositoryProvider).undoRun(runId);
    ref.invalidate(_runCreationsProvider(runId));
    messenger.showSnackBar(SnackBar(
        content: Text('Removed $undone record${undone == 1 ? '' : 's'}.')));
  }
}
