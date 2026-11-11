import 'package:exa_mobile/data/models/scheduled_job.dart';
import 'package:exa_mobile/services/background_jobs/brief_alarm.dart';
import 'package:flutter_test/flutter_test.dart';

/// The exact-alarm entry point must not do job work itself: the alarm
/// plugin releases its wakelock as soon as the callback returns its first
/// await, and a run left in the alarm isolate freezes with the screen off.
/// So the alarm hands the run to WorkManager, and only runs inline when that
/// handover is refused.
void main() {
  test('an alarm hands the run to WorkManager and does not run it inline',
      () async {
    var enqueued = 0;
    var inline = 0;
    final outcome = await BriefAlarm.onFired(
      enqueue: () async => enqueued++,
      runInline: () async => inline++,
    );
    expect(outcome, AlarmOutcome.enqueued);
    expect(enqueued, 1);
    expect(inline, 0);
  });

  test('a refused handover still runs the occurrence, inline', () async {
    var inline = 0;
    final outcome = await BriefAlarm.onFired(
      enqueue: () async => throw StateError('You have not properly '
          'initialized the Flutter WorkManager Package.'),
      runInline: () async => inline++,
    );
    expect(outcome, AlarmOutcome.ranInline);
    expect(inline, 1);
  });

  test('the job service is asked first, and then nothing else runs',
      () async {
    var enqueued = 0;
    var inline = 0;
    final outcome = await BriefAlarm.onFired(
      startService: () async {},
      enqueue: () async => enqueued++,
      runInline: () async => inline++,
    );
    expect(outcome, AlarmOutcome.serviceStarted);
    expect(enqueued + inline, 0);
  });

  test('a refused service start falls back to the worker', () async {
    var enqueued = 0;
    final outcome = await BriefAlarm.onFired(
      startService: () async => throw StateError(
          'startForegroundService() not allowed due to mAllowStartForeground '
          'false'),
      enqueue: () async => enqueued++,
      runInline: () async {},
    );
    expect(outcome, AlarmOutcome.enqueued);
    expect(enqueued, 1);
  });

  test('with no plugin and no worker the occurrence still runs', () async {
    var inline = 0;
    final outcome = await BriefAlarm.onFired(
      startService: () async => throw StateError('device plugin unavailable'),
      enqueue: () async => throw StateError('no WorkManager'),
      runInline: () async => inline++,
    );
    expect(outcome, AlarmOutcome.ranInline);
    expect(inline, 1);
  });

  test('nothing escapes the alarm entry point', () async {
    final outcome = await BriefAlarm.onFired(
      enqueue: () async => throw StateError('no WorkManager'),
      runInline: () async => throw StateError('no database'),
    );
    expect(outcome, AlarmOutcome.ranInline);
  });
  group('when to wake next', () {
    final now = DateTime(2026, 9, 27, 22, 0);
    ScheduledJob job(String id, DateTime? next, {String status = 'Active'}) =>
        ScheduledJob(
          id: id,
          name: id,
          jobType: 'agent_task',
          scheduleRule: const {'type': 'interval', 'minutes': 10},
          status: status,
          nextRunAt: next,
          createdAt: now,
          updatedAt: now,
        );

    test('the earliest job that is still ahead', () {
      expect(
          BriefAlarm.nextWake(
            jobs: [
              job('a', now.add(const Duration(minutes: 9))),
              job('b', now.add(const Duration(minutes: 2))),
              job('paused', now.add(const Duration(minutes: 1)),
                  status: 'Paused'),
            ],
            leases: const {},
            now: now,
          ),
          now.add(const Duration(minutes: 2)));
    });

    test('an overdue job is tried again shortly', () {
      expect(
          BriefAlarm.nextWake(
            jobs: [job('a', now.subtract(const Duration(minutes: 1)))],
            leases: const {},
            now: now,
          ),
          now.add(BriefAlarm.overdueRetry));
    });

    test('an overdue job whose run is still held waits for the hold to end',
        () {
      // A run killed mid-way keeps its occurrence for the rest of its
      // lease. Thirty-second alarms until then claimed nothing forty times.
      final held = now.add(const Duration(minutes: 17));
      expect(
          BriefAlarm.nextWake(
            jobs: [job('a', now.subtract(const Duration(minutes: 1)))],
            leases: {'a': held},
            now: now,
          ),
          held.add(BriefAlarm.leaseGrace));
    });

    test('one held job does not make another one late', () {
      expect(
          BriefAlarm.nextWake(
            jobs: [
              job('held', now.subtract(const Duration(minutes: 1))),
              job('due', now.subtract(const Duration(seconds: 5))),
            ],
            leases: {'held': now.add(const Duration(minutes: 17))},
            now: now,
          ),
          now.add(BriefAlarm.overdueRetry));
    });

    test('a hold that has already ended is not waited for', () {
      expect(
          BriefAlarm.nextWake(
            jobs: [job('a', now.subtract(const Duration(minutes: 30)))],
            leases: {'a': now.subtract(const Duration(minutes: 1))},
            now: now,
          ),
          now.add(BriefAlarm.overdueRetry));
    });

    test('nothing scheduled, nothing to wake for', () {
      expect(
          BriefAlarm.nextWake(
              jobs: [job('a', null)], leases: const {}, now: now),
          isNull);
    });
  });
}
