import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../data/repositories/pending_calendar_repository.dart';
import '../../shared/providers.dart';
import '../../shared/theme/exa_theme.dart';
import '../../shared/widgets/exa_empty_state.dart';

final pendingApprovalsProvider =
    FutureProvider.autoDispose<List<PendingCalendarEvent>>(
        (ref) => ref.watch(pendingCalendarRepositoryProvider).recent());

final pendingApprovalCountProvider = FutureProvider.autoDispose<int>(
    (ref) => ref.watch(pendingCalendarRepositoryProvider).pendingCount());

/// High-risk actions Exa proposed that need the user's explicit yes before
/// they touch an external service — currently phone-calendar writes.
class PendingApprovalsScreen extends ConsumerWidget {
  const PendingApprovalsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final itemsAsync = ref.watch(pendingApprovalsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Pending approvals')),
      body: itemsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(child: Text('Error: $error')),
        data: (items) {
          if (items.isEmpty) {
            return const ExaEmptyState(
              icon: Icons.verified_user_outlined,
              title: 'Nothing waiting',
              message:
                  'When Exa wants to do something that touches an outside '
                  'service — like adding an event to your phone calendar — '
                  'it waits here for your approval.',
            );
          }
          return ListView(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
            children: [
              for (final item in items) _ApprovalCard(item: item),
            ],
          );
        },
      ),
    );
  }
}

class _ApprovalCard extends ConsumerWidget {
  const _ApprovalCard({required this.item});

  final PendingCalendarEvent item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final pending = item.status == 'Pending';
    final when = DateFormat('EEE, MMM d · HH:mm').format(item.startAt);

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.event_outlined,
                    size: 18, color: ExaColors.spark),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(item.title,
                      style: theme.textTheme.titleMedium),
                ),
                if (!pending)
                  _StatusChip(status: item.status),
              ],
            ),
            const SizedBox(height: 6),
            Text('Add to phone calendar · $when',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: ExaColors.textSecondary)),
            if (item.location?.isNotEmpty == true)
              Text(item.location!,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: ExaColors.textSecondary)),
            if (item.description?.isNotEmpty == true) ...[
              const SizedBox(height: 6),
              Text(item.description!,
                  maxLines: 3, overflow: TextOverflow.ellipsis),
            ],
            if (item.errorMessage != null) ...[
              const SizedBox(height: 6),
              Text(item.errorMessage!,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: ExaColors.error)),
            ],
            if (pending) ...[
              const SizedBox(height: 10),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => _reject(context, ref),
                    child: const Text('Reject'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    icon: const Icon(Icons.event_available, size: 18),
                    label: const Text('Add to calendar'),
                    onPressed: () => _approve(context, ref),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _approve(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    final repo = ref.read(pendingCalendarRepositoryProvider);
    try {
      final eventId =
          await ref.read(deviceCalendarServiceProvider).createEvent(
                title: item.title,
                startAt: item.startAt,
                endAt: item.endAt,
                location: item.location,
                description: item.description,
              );
      await repo.markApproved(item.id, externalEventId: eventId);
      await ref.read(auditRepositoryProvider).log(
        'user',
        'calendar_event_approved',
        detail: {'title': item.title},
      );
      messenger.showSnackBar(const SnackBar(
          content: Text('Added to your phone calendar.')));
    } catch (e) {
      await repo.markFailed(item.id, '$e');
      messenger.showSnackBar(
          SnackBar(content: Text('Could not add it: $e')));
    }
    ref
      ..invalidate(pendingApprovalsProvider)
      ..invalidate(pendingApprovalCountProvider);
  }

  Future<void> _reject(BuildContext context, WidgetRef ref) async {
    await ref.read(pendingCalendarRepositoryProvider).markRejected(item.id);
    await ref.read(auditRepositoryProvider).log(
      'user',
      'calendar_event_rejected',
      detail: {'title': item.title},
    );
    ref
      ..invalidate(pendingApprovalsProvider)
      ..invalidate(pendingApprovalCountProvider);
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.status});

  final String status;

  @override
  Widget build(BuildContext context) {
    final color = switch (status) {
      'Approved' => ExaColors.success,
      'Failed' => ExaColors.error,
      _ => ExaColors.textTertiary,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(status,
          style: Theme.of(context)
              .textTheme
              .labelSmall
              ?.copyWith(color: color)),
    );
  }
}
