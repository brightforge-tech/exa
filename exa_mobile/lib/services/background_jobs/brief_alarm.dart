import 'package:android_alarm_manager_plus/android_alarm_manager_plus.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:workmanager/workmanager.dart';

import '../../agent/behaviors/notification_policy.dart';
import '../../agent/orchestrator/agent_orchestrator.dart';
import '../../data/database/app_database.dart';
import '../../data/repositories/behavior_repository.dart';
import '../../data/models/scheduled_job.dart';
import '../../data/repositories/job_repository.dart';
import '../../device/device_bridge.dart';
import '../notifications/notification_service.dart';
import 'background_worker.dart'
    show alarmTaskName, backgroundJobDispatcher, buildJobOrchestrator;
import 'job_runner.dart';

const _briefAlarmId = 7301;

/// Top-level entry point invoked by Android's AlarmManager at a job's exact
/// run time.
///
/// It does no job work itself. android_alarm_manager_plus invokes this
/// callback without awaiting it, so the native service's wakelock is gone
/// about 100 ms in - while the run (database, mail, model calls, digests)
/// is still going. With the screen off the CPU then suspends within a second
/// or two and the run sits frozen until something else wakes the phone; on
/// the S8+ that was 57 minutes (alarm 14:40:28, CPU asleep 14:40:28.9, next
/// wake 15:37:51). So the alarm only *hands the run to WorkManager*, whose
/// job holds a wakelock for the whole run, and falls back to running here
/// only when that handover is refused.
///
/// This is a precision layer on top of the 15-minute WorkManager tick: if
/// the exact alarm is ever suppressed (force-stop, OEM deep-sleep),
/// WorkManager still runs the job late, so behaviour is never worse than
/// before - only more on-time.
@pragma('vm:entry-point')
Future<void> briefAlarmCallback() => BriefAlarm.onFired(
    startService: _startJobService,
    enqueue: _enqueueRun,
    runInline: _runInline);

/// Asks the foreground job service to run what is due. It has no ten-minute
/// limit, which is the whole reason it comes first; see `ExaJobService`.
///
/// Throws when the start was refused or the plugin is not there, so the
/// caller moves on to the worker.
Future<void> _startJobService() async {
  final reply =
      await const DeviceBridge().callMap('jobs.startService');
  if (reply == null) throw StateError('device plugin unavailable');
  if (reply['ok'] != true) throw StateError('${reply['error']}');
}

/// Hands the run to WorkManager as a one-off task. [backgroundJobDispatcher]
/// runs it under the job's wakelock, stamps the ledger with `alarm` as the
/// trigger source, and re-arms the next alarm at the end.
Future<void> _enqueueRun() async {
  // The plugin reads the dispatcher handle it saved at app start when it
  // attaches to this isolate's engine, so this is normally redundant. Kept
  // because a missing handle is a refused enqueue rather than a crash, and
  // the fallback would then run every alarm unprotected.
  try {
    await Workmanager().initialize(backgroundJobDispatcher);
  } catch (_) {
    // Let registerOneOffTask decide; it fails loudly if the handle is missing.
  }
  await Workmanager().registerOneOffTask(
    alarmTaskName,
    alarmTaskName,
    // A run already in flight keeps going and this one queues behind it, so
    // an alarm that fires mid-run is never dropped on the floor.
    existingWorkPolicy: ExistingWorkPolicy.append,
    constraints: Constraints(networkType: NetworkType.notRequired),
  );
}

/// The pre-handover behaviour: run due jobs right here, in the alarm
/// isolate, with no wakelock. Only reached when WorkManager refuses the
/// enqueue (not initialised, plugin missing), where a late run still beats a
/// dropped occurrence.
Future<void> _runInline() async {
  final database = AppDatabase();
  try {
    await database.open();
    final notifications = NotificationService();
    notifications.policyLoader =
        () => NotificationPolicy.load(BehaviorRepository(database));
    await notifications.init(requestPermissions: false);
    final runner =
        JobRunner(database: database, notifications: notifications);
    // Agent-turn jobs (daily_review) run through the full intelligence
    // pipeline here too; built lazily only if a due job needs it.
    AgentOrchestrator? orchestrator;
    runner.orchestratorFactory = () => orchestrator ??= buildJobOrchestrator(
        database: database, notifications: notifications, runner: runner);
    await runner.runDueJobs(triggerSource: 'alarm');
    await BriefAlarm.rearm(database);
  } catch (_) {
    // Best effort; the WorkManager periodic tick remains the safety net.
  }
  // Deliberately NO database.close() - the sqflite connection is shared
  // across the process (see background_worker.dart).
}

/// How an alarm firing was handled.
enum AlarmOutcome {
  /// Handed to the foreground job service, which may take as long as the
  /// jobs need.
  serviceStarted,

  /// Handed to WorkManager; the run happens under its wakelock.
  enqueued,

  /// WorkManager refused the handover, so the run happened in the alarm
  /// isolate as it did before this layer existed.
  ranInline,
}

class BriefAlarm {
  /// What the alarm entry point does, with the two effects injectable so
  /// the choice between them is pinned by a test that needs no plugins.
  ///
  /// Never throws: an exception out of an alarm callback is an alarm the
  /// plugin may stop delivering.
  static Future<AlarmOutcome> onFired({
    Future<void> Function()? startService,
    required Future<void> Function() enqueue,
    required Future<void> Function() runInline,
  }) async {
    if (startService != null) {
      try {
        await startService();
        return AlarmOutcome.serviceStarted;
      } catch (_) {
        // Refused, or not there: the worker is still a run, only a
        // shorter one.
      }
    }
    try {
      await enqueue();
      return AlarmOutcome.enqueued;
    } catch (_) {
      // Fall through: a refused handover must not cost the occurrence.
    }
    try {
      await runInline();
    } catch (_) {
      // Best effort, as above.
    }
    return AlarmOutcome.ranInline;
  }

  /// Schedules one exact alarm at the earliest upcoming active job time.
  /// Safe no-op if alarms are unavailable.
  /// When the next alarm should fire, or null when nothing is scheduled.
  ///
  /// A job that is overdue is normally tried again in [overdueRetry]. One
  /// whose current occurrence is leased - running now, or killed mid-run
  /// and not yet released - cannot be claimed before the lease ends, and
  /// used to be tried every thirty seconds all the same: an alarm and a
  /// wake-up twice a minute for as long as the lease had to run, which is
  /// up to twenty minutes now that a run may take that long. It is woken
  /// for when the lease ends instead.
  static DateTime? nextWake({
    required Iterable<ScheduledJob> jobs,
    required Map<String, DateTime> leases,
    required DateTime now,
  }) {
    DateTime? earliest;
    for (final job in jobs) {
      final next = job.nextRunAt;
      if (job.status != 'Active' || next == null) continue;
      final lease = leases[job.id];
      final wake = next.isAfter(now)
          ? next
          : lease != null && lease.isAfter(now)
              ? lease.add(leaseGrace)
              : now.add(overdueRetry);
      if (earliest == null || wake.isBefore(earliest)) earliest = wake;
    }
    return earliest;
  }

  static const overdueRetry = Duration(seconds: 30);
  static const leaseGrace = Duration(seconds: 5);

  static Future<void> rearm(AppDatabase database) async {
    try {
      final repository = JobRepository(database);
      final jobs = await repository.listAll();
      var leases = const <String, DateTime>{};
      try {
        leases = await repository.liveLeases();
      } catch (_) {
        // Without them every overdue job is simply retried soon, as before.
      }
      final when =
          nextWake(jobs: jobs, leases: leases, now: DateTime.now());

      if (when == null) {
        await AndroidAlarmManager.cancel(_briefAlarmId);
        return;
      }

      // Exact only when the user has granted "Alarms & reminders"
      // (SCHEDULE_EXACT_ALARM, denied by default on Android 14+). The
      // alarm plugin silently schedules NOTHING for an exact request
      // without the grant, which would kill this chain entirely - an
      // inexact alarm (fires within a few minutes) keeps it alive.
      var exact = false;
      try {
        exact = await FlutterLocalNotificationsPlugin()
                .resolvePlatformSpecificImplementation<
                    AndroidFlutterLocalNotificationsPlugin>()
                ?.canScheduleExactNotifications() ??
            false;
      } catch (_) {
        // Cannot determine (e.g. plugin unavailable): inexact is the safe
        // choice - it always schedules.
      }

      await AndroidAlarmManager.oneShotAt(
        when,
        _briefAlarmId,
        briefAlarmCallback,
        exact: exact,
        wakeup: true,
        allowWhileIdle: true,
        rescheduleOnReboot: true,
      );
    } catch (_) {
      // android_alarm_manager_plus unavailable -> WorkManager covers it.
    }
  }
}
