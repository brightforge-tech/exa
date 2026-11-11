import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../data/models/scheduled_job.dart';
import '../../data/repositories/diagnostics_repository.dart';
import '../../services/service_circuit_breaker.dart';
import '../../shared/providers.dart';
import '../../shared/theme/exa_theme.dart';

class _ReliabilityStatus {
  final bool exactAlarms;
  final bool batteryUnrestricted;
  final bool notifications;
  const _ReliabilityStatus({
    required this.exactAlarms,
    required this.batteryUnrestricted,
    required this.notifications,
  });
}

final _statusProvider =
    FutureProvider.autoDispose<_ReliabilityStatus>((ref) async {
  final notifications = ref.watch(notificationServiceProvider);
  return _ReliabilityStatus(
    exactAlarms: await notifications.canScheduleExact(),
    batteryUnrestricted:
        await Permission.ignoreBatteryOptimizations.isGranted,
    notifications: await Permission.notification.isGranted,
  );
});

/// Walks the user through the OS settings that decide whether reminders and
/// the daily brief actually fire when the app is in the background.
class ReliabilityScreen extends ConsumerWidget {
  const ReliabilityScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final statusAsync = ref.watch(_statusProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Background reliability')),
      body: statusAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(child: Text('Error: $error')),
        data: (status) => ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              'For reminders and your daily brief to arrive on time while '
              'Exa is closed, Android needs three things. Tap any that '
              'aren’t green.',
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: ExaColors.textSecondary),
            ),
            const SizedBox(height: 16),
            _ReliabilityTile(
              icon: Icons.alarm,
              title: 'Notifications',
              granted: status.notifications,
              body: 'Allow Exa to post reminders and brief notifications.',
              onFix: () async {
                await Permission.notification.request();
                ref.invalidate(_statusProvider);
              },
            ),
            _ReliabilityTile(
              icon: Icons.timer_outlined,
              title: 'Exact alarms',
              granted: status.exactAlarms,
              body: 'Lets reminders and the daily brief fire at the exact '
                  'time instead of a delayed batch.',
              onFix: () async {
                await ref
                    .read(notificationServiceProvider)
                    .requestExactAlarms();
                ref.invalidate(_statusProvider);
              },
            ),
            _ReliabilityTile(
              icon: Icons.battery_charging_full,
              title: 'Unrestricted battery',
              granted: status.batteryUnrestricted,
              body: 'The big one. Without this, aggressive phones '
                  '(Samsung, Xiaomi, OnePlus) freeze Exa in the '
                  'background and jobs silently never run.',
              onFix: () async {
                await Permission.ignoreBatteryOptimizations.request();
                ref.invalidate(_statusProvider);
              },
            ),
            const SizedBox(height: 12),
            const _ServiceHealth(),
            const SizedBox(height: 12),
            const _RecentProblems(),
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.info_outline,
                            size: 18, color: ExaColors.spark),
                        const SizedBox(width: 8),
                        Text('Samsung devices',
                            style:
                                Theme.of(context).textTheme.titleSmall),
                      ],
                    ),
                    const SizedBox(height: 8),
                    const Text(
                        'Even with the above granted, Samsung may add Exa '
                        'to a "Sleeping apps" list. Open Settings → '
                        'Battery → Background usage limits, and make '
                        'sure Exa is NOT in "Sleeping apps" or "Deep '
                        'sleeping apps".'),
                    const SizedBox(height: 10),
                    OutlinedButton.icon(
                      icon: const Icon(Icons.open_in_new, size: 18),
                      label: const Text('Open app settings'),
                      onPressed: () => openAppSettings(),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ReliabilityTile extends StatelessWidget {
  const _ReliabilityTile({
    required this.icon,
    required this.title,
    required this.granted,
    required this.body,
    required this.onFix,
  });

  final IconData icon;
  final String title;
  final bool granted;
  final String body;
  final Future<void> Function() onFix;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: ExaColors.textSecondary),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(title,
                            style:
                                Theme.of(context).textTheme.titleSmall),
                      ),
                      Icon(
                        granted
                            ? Icons.check_circle
                            : Icons.cancel_outlined,
                        size: 18,
                        color: granted
                            ? ExaColors.success
                            : ExaColors.warning,
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(body,
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: ExaColors.textSecondary)),
                  if (!granted) ...[
                    const SizedBox(height: 8),
                    FilledButton(
                      onPressed: onFix,
                      child: const Text('Fix'),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

final _diagnosticsProvider =
    FutureProvider.autoDispose<List<DiagnosticEvent>>((ref) =>
        ref.watch(diagnosticsRepositoryProvider).recent(limit: 30));

final _staleRunsProvider = FutureProvider.autoDispose<List<JobRun>>(
    (ref) => ref.watch(jobRepositoryProvider).staleRuns());

/// Background work fails quietly by design - a job must never crash the app
/// because the network is down. That makes the failures invisible, so every
/// swallowed problem is recorded and surfaced here.
class _RecentProblems extends ConsumerWidget {
  const _RecentProblems();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final events = ref.watch(_diagnosticsProvider).value ?? const [];
    final stale = ref.watch(_staleRunsProvider).value ?? const [];
    final problems = events
        .where((e) => e.severity != DiagnosticSeverity.info)
        .toList();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  problems.isEmpty && stale.isEmpty
                      ? Icons.check_circle_outline
                      : Icons.report_problem_outlined,
                  size: 18,
                  color: problems.isEmpty && stale.isEmpty
                      ? ExaColors.success
                      : ExaColors.warning,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('Recent background problems',
                      style: Theme.of(context).textTheme.titleSmall),
                ),
                if (events.isNotEmpty)
                  TextButton(
                    onPressed: () async {
                      await ref.read(diagnosticsRepositoryProvider).clear();
                      ref.invalidate(_diagnosticsProvider);
                    },
                    child: const Text('Clear'),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            if (problems.isEmpty && stale.isEmpty)
              Text(
                'Nothing has failed quietly. Denied actions, missing '
                'credentials, and jobs that could not run would appear '
                'here.',
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: ExaColors.textSecondary),
              ),
            if (stale.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  '${stale.length} job run(s) were interrupted and never '
                  'finished - the system stopped the background worker '
                  'mid-run. They are retried on the next wake-up.',
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: ExaColors.warning),
                ),
              ),
            for (final event in problems.take(10))
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${DateFormat('MMM d, HH:mm').format(event.createdAt)}'
                      ' · ${event.code}',
                      style: Theme.of(context)
                          .textTheme
                          .labelSmall
                          ?.copyWith(color: ExaColors.textTertiary),
                    ),
                    Text(event.message,
                        style: Theme.of(context).textTheme.bodySmall),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Services Exa has stopped calling, and why.
///
/// A paused mail account is the failure users misread as "Exa is broken":
/// nothing arrives, nothing is reported, and there is no obvious place to
/// look. This is that place.
final _circuitsProvider =
    FutureProvider.autoDispose<List<CircuitStatus>>((ref) =>
        ServiceCircuitBreaker(ref.watch(appDatabaseProvider)).unhealthy());

class _ServiceHealth extends ConsumerWidget {
  const _ServiceHealth();

  static String _describe(CircuitStatus circuit) {
    final buffer = StringBuffer('${circuit.service} is paused after '
        '${circuit.consecutiveFailures} failures');
    if (circuit.failureKind != null) {
      buffer.write(' (${circuit.failureKind})');
    }
    if (circuit.retryAfter != null) {
      buffer.write('. Retrying after '
          '${DateFormat('MMM d, HH:mm').format(circuit.retryAfter!)}');
    }
    buffer.write('.');
    return buffer.toString();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final circuits = ref.watch(_circuitsProvider).valueOrNull ?? const [];
    final health = ref.watch(appDatabaseProvider).health;
    final theme = Theme.of(context);

    // Nothing to say when everything is working, which is the normal case.
    if (circuits.isEmpty && (health?.isHealthy ?? true)) {
      return const SizedBox.shrink();
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.health_and_safety_outlined,
                    size: 18, color: ExaColors.spark),
                const SizedBox(width: 8),
                Text('Service health', style: theme.textTheme.titleSmall),
              ],
            ),
            const SizedBox(height: 8),
            if (health != null && !health.isHealthy)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  'The local database reported "${health.detail}" at '
                  'startup. Your data is still readable; consider a backup.',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: ExaColors.error),
                ),
              ),
            for (final circuit in circuits)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  _describe(circuit),
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: ExaColors.textSecondary),
                ),
              ),
            const SizedBox(height: 6),
            Text(
              'Exa retries on its own once the service works again.',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: ExaColors.textTertiary),
            ),
          ],
        ),
      ),
    );
  }
}
