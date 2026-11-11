import 'dart:convert';

import 'package:uuid/uuid.dart';

import '../../agent/security/capability_policy.dart';
import '../../services/background_jobs/brief_alarm.dart';
import '../database/app_database.dart';
import '../models/scheduled_job.dart';

/// A job run paired with the parent job's name/type for history views.
class JobRunWithJob {
  final JobRun run;
  final String jobName;
  final String jobType;
  const JobRunWithJob(
      {required this.run, required this.jobName, required this.jobType});
}

class JobRepository {
  JobRepository(this._database);

  final AppDatabase _database;
  static const _uuid = Uuid();

  Future<ScheduledJob> create({
    required String name,
    required String jobType,
    required Map<String, Object?> scheduleRule,
    String? description,
    String createdBy = 'agent',
    JobPermissions permissions = JobPermissions.none,
    String behaviorMode = 'live',
    String? behaviorSnapshot,
    int? behaviorVersion,
    String missedRunPolicy = 'run_once_now',
    bool muteNotifications = false,
    int timeoutSeconds = 1800,
    int maxAttempts = 3,
  }) async {
    final now = DateTime.now();
    final job = ScheduledJob(
      id: _uuid.v4(),
      name: name,
      description: description,
      jobType: jobType,
      scheduleRule: scheduleRule,
      nextRunAt: ScheduledJob.computeNextRun(scheduleRule),
      createdBy: createdBy,
      permissionsJson: permissions.encode(),
      behaviorMode: behaviorMode,
      behaviorSnapshot: behaviorSnapshot,
      behaviorVersion: behaviorVersion,
      missedRunPolicy: missedRunPolicy,
      muteNotifications: muteNotifications,
      timeoutSeconds: timeoutSeconds,
      maxAttempts: maxAttempts,
      createdAt: now,
      updatedAt: now,
    );
    await _database.db.insert('scheduled_jobs', job.toRow());
    await BriefAlarm.rearm(_database);
    return job;
  }

  Future<ScheduledJob?> getById(String id) async {
    final rows = await _database.db.query('scheduled_jobs',
        where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : ScheduledJob.fromRow(rows.first);
  }

  Future<List<ScheduledJob>> listAll() async {
    final rows = await _database.db
        .query('scheduled_jobs', orderBy: 'created_at ASC');
    return rows.map(ScheduledJob.fromRow).toList();
  }

  /// Active jobs whose next_run_at is due.
  Future<List<ScheduledJob>> listDue({DateTime? now}) async {
    final cutoff = (now ?? DateTime.now()).toIso8601String();
    final rows = await _database.db.query(
      'scheduled_jobs',
      where: "status = 'Active' AND next_run_at IS NOT NULL "
          'AND next_run_at <= ?',
      whereArgs: [cutoff],
    );
    return rows.map(ScheduledJob.fromRow).toList();
  }

  /// Edits a job in place. Only the fields passed are changed.
  ///
  /// Changing [scheduleRule] recomputes `next_run_at` from now rather than
  /// leaving the old one: a job moved from 07:30 to 18:00 must not fire once
  /// more at the old time first. The exact alarm is re-armed for the same
  /// reason - it holds a wake-up for whatever the previous schedule said.
  Future<ScheduledJob?> update(
    String id, {
    String? name,
    String? description,
    String? jobType,
    Map<String, Object?>? scheduleRule,
    String? behaviorMode,
    String? missedRunPolicy,
    bool? muteNotifications,
    JobPermissions? permissions,
    int? timeoutSeconds,
    int? maxAttempts,
  }) async {
    final existing = await getById(id);
    if (existing == null) return null;
    final now = DateTime.now();
    final rule = scheduleRule ?? existing.scheduleRule;

    await _database.db.update(
      'scheduled_jobs',
      {
        'name': ?name,
        'description': ?description,
        'job_type': ?jobType,
        if (scheduleRule != null) ...{
          'schedule_rule': jsonEncode(rule),
          'next_run_at':
              ScheduledJob.computeNextRun(rule, from: now).toIso8601String(),
        },
        'behavior_mode': ?behaviorMode,
        'missed_run_policy': ?missedRunPolicy,
        if (muteNotifications != null)
          'mute_notifications': muteNotifications ? 1 : 0,
        if (permissions != null) 'permissions_json': permissions.encode(),
        'timeout_seconds': ?timeoutSeconds,
        'max_attempts': ?maxAttempts,
        'updated_at': now.toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [id],
    );
    await BriefAlarm.rearm(_database);
    return getById(id);
  }

  Future<void> setStatus(String id, String status) async {
    await _database.db.update(
      'scheduled_jobs',
      {'status': status, 'updated_at': DateTime.now().toIso8601String()},
      where: 'id = ?',
      whereArgs: [id],
    );
    await BriefAlarm.rearm(_database);
  }

  /// Advances the job past the occurrence it just ran.
  ///
  /// `run_every_missed_occurrence` steps one occurrence at a time from the
  /// old due time, so a phone that slept through five hourly runs works
  /// through them on subsequent ticks. Every other policy - including the
  /// default - computes the next occurrence from *now*, which collapses a
  /// backlog into a single catch-up run rather than replaying ten stale
  /// briefings at once.
  Future<void> markRan(ScheduledJob job, {DateTime? ranAt}) async {
    final now = ranAt ?? DateTime.now();
    final DateTime next;
    if (job.missedRunPolicy == 'run_every_missed_occurrence' &&
        job.nextRunAt != null) {
      final stepped =
          ScheduledJob.computeNextRun(job.scheduleRule, from: job.nextRunAt!);
      // Never schedule into the past-but-already-handled window; if the
      // stepped occurrence is still behind, the next tick handles it.
      next = stepped;
    } else {
      next = ScheduledJob.computeNextRun(job.scheduleRule, from: now);
    }
    await _database.db.update(
      'scheduled_jobs',
      {
        'last_run_at': now.toIso8601String(),
        'next_run_at': next.toIso8601String(),
        'updated_at': now.toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [job.id],
    );
  }

  Future<bool> delete(String id) async {
    await _database.db
        .delete('job_runs', where: 'job_id = ?', whereArgs: [id]);
    final count = await _database.db
        .delete('scheduled_jobs', where: 'id = ?', whereArgs: [id]);
    await BriefAlarm.rearm(_database);
    return count > 0;
  }

  // ----------------------------------------------------------- job runs --

  Future<String> startRun(String jobId) async {
    final id = _uuid.v4();
    await _database.db.insert('job_runs', {
      'id': id,
      'job_id': jobId,
      'started_at': DateTime.now().toIso8601String(),
      'status': JobRun.statusRunning,
    });
    return id;
  }

  /// Claims the occurrence [job] is due for, or returns null when it is
  /// already taken or already done.
  ///
  /// This is the lock that makes duplicate execution impossible. Android
  /// gives us several ways to run the same occurrence twice - the exact
  /// alarm and the 15-minute WorkManager tick can both fire, a killed
  /// isolate leaves a run half-finished, and WorkManager retries after a
  /// crash - so the ledger, not the scheduler, decides what actually runs:
  ///
  ///  * the unique index on (job_id, scheduled_for) means a second claim for
  ///    the same occurrence hits a constraint violation rather than starting
  ///    a second run;
  ///  * a run whose lease is still valid is left alone (another isolate has
  ///    it right now);
  ///  * a run whose lease has expired is taken over as the next attempt,
  ///    which is how a killed isolate's work gets picked up;
  ///  * a terminal run is never re-run.
  ///
  /// [leaseFor] is how long the claim stays untouchable: the job's own timeout
  /// unless the caller can give the run less time than that (a background
  /// worker's remaining budget), in which case the lease must not outlive
  /// the run either.
  Future<JobRun?> claimRun(
    ScheduledJob job, {
    DateTime? now,
    String triggerSource = 'worker',
    int? behaviorVersion,
    Duration? leaseFor,
  }) async {
    final at = now ?? DateTime.now();
    final leaseUntil = at.add(leaseFor ?? Duration(seconds: job.timeoutSeconds));

    // A scheduled wake-up that finds an attempt waiting to be retried must
    // continue THAT occurrence, not open a new one. Retrying moves the job's
    // next_run_at to the backoff time, so computing the occurrence from it
    // would mint a fresh key every attempt: the ledger would fill with
    // attempt-1 rows, and max_attempts and dead-lettering could never fire.
    if (triggerSource != 'manual') {
      final resumed = await _resumeRetry(job, at, leaseUntil, triggerSource);
      if (resumed.handled) return resumed.run;
    }

    // "Run now" is an explicit request, not a scheduled occurrence: it gets
    // its own key so pressing it twice runs twice, while the scheduler's
    // occurrences stay protected from duplicate firing.
    final occurrence =
        triggerSource == 'manual' ? at : job.occurrenceFor(at);
    final row = {
      'id': _uuid.v4(),
      'job_id': job.id,
      'scheduled_for': occurrence.toIso8601String(),
      'started_at': at.toIso8601String(),
      'status': JobRun.statusRunning,
      'attempt': 1,
      'lease_until': leaseUntil.toIso8601String(),
      'trigger_source': triggerSource,
      'behavior_version': behaviorVersion,
    };

    try {
      await _database.db.insert('job_runs', row);
      return JobRun.fromRow(row);
    } catch (_) {
      // Constraint violation: this occurrence already has a run.
    }

    final existingRows = await _database.db.query('job_runs',
        where: 'job_id = ? AND scheduled_for = ?',
        whereArgs: [job.id, occurrence.toIso8601String()],
        limit: 1);
    if (existingRows.isEmpty) return null;
    final existing = JobRun.fromRow(existingRows.first);

    if (existing.isTerminal || existing.status == JobRun.statusSuccess) {
      return null; // already completed - do not run it again
    }
    final lease = existing.leaseUntil;
    if (existing.status == JobRun.statusRunning &&
        lease != null &&
        lease.isAfter(at)) {
      return null; // someone else is running it right now
    }
    if (existing.attempt >= job.maxAttempts) {
      await _database.db.update(
        'job_runs',
        {
          'status': JobRun.statusDeadLetter,
          'finished_at': at.toIso8601String(),
          'error_code': 'MAX_ATTEMPTS_EXCEEDED',
          'lease_until': null,
        },
        where: 'id = ?',
        whereArgs: [existing.id],
      );
      return null;
    }

    // Take over: expired lease (killed isolate) or a scheduled retry.
    final attempt = existing.attempt + 1;
    await _database.db.update(
      'job_runs',
      {
        'status': JobRun.statusRunning,
        'attempt': attempt,
        'started_at': at.toIso8601String(),
        'finished_at': null,
        'lease_until': leaseUntil.toIso8601String(),
        'trigger_source': triggerSource,
      },
      where: 'id = ?',
      whereArgs: [existing.id],
    );
    return JobRun.fromRow({
      ...existingRows.first,
      'status': JobRun.statusRunning,
      'attempt': attempt,
      'started_at': at.toIso8601String(),
      'lease_until': leaseUntil.toIso8601String(),
    });
  }

  /// Continues an occurrence that is waiting to be retried.
  ///
  /// `handled` true means the caller must not open a new occurrence: either
  /// this attempt is now running, or the occurrence just used up its last
  /// attempt and was dead-lettered (run null).
  Future<({bool handled, JobRun? run})> _resumeRetry(
    ScheduledJob job,
    DateTime at,
    DateTime leaseUntil,
    String triggerSource,
  ) async {
    final rows = await _database.db.query(
      'job_runs',
      where: 'job_id = ? AND status = ?',
      whereArgs: [job.id, JobRun.statusRetryWait],
      orderBy: 'started_at DESC',
      limit: 1,
    );
    if (rows.isEmpty) return (handled: false, run: null);
    final pending = JobRun.fromRow(rows.first);

    if (pending.attempt >= job.maxAttempts) {
      await _database.db.update(
        'job_runs',
        {
          'status': JobRun.statusDeadLetter,
          'finished_at': at.toIso8601String(),
          'error_code': 'MAX_ATTEMPTS_EXCEEDED',
          'lease_until': null,
        },
        where: 'id = ?',
        whereArgs: [pending.id],
      );
      // Move past the abandoned occurrence so the job's own schedule
      // resumes instead of retrying a hopeless attempt forever.
      await markRan(job, ranAt: at);
      return (handled: true, run: null);
    }

    final attempt = pending.attempt + 1;
    await _database.db.update(
      'job_runs',
      {
        'status': JobRun.statusRunning,
        'attempt': attempt,
        'started_at': at.toIso8601String(),
        'finished_at': null,
        'lease_until': leaseUntil.toIso8601String(),
        'trigger_source': triggerSource,
      },
      where: 'id = ?',
      whereArgs: [pending.id],
    );
    return (
      handled: true,
      run: JobRun.fromRow({
        ...rows.first,
        'status': JobRun.statusRunning,
        'attempt': attempt,
        'started_at': at.toIso8601String(),
        'lease_until': leaseUntil.toIso8601String(),
      }),
    );
  }

  Future<void> completeRun(
    String runId, {
    required String summary,
    String? modelId,
    int? tokensIn,
    int? tokensOut,
  }) async {
    await _database.db.update(
      'job_runs',
      {
        'finished_at': DateTime.now().toIso8601String(),
        'status': JobRun.statusSuccess,
        'result_summary': summary,
        'error_message': null,
        'error_code': null,
        'lease_until': null,
        'model_id': modelId,
        'tokens_in': tokensIn,
        'tokens_out': tokensOut,
      },
      where: 'id = ?',
      whereArgs: [runId],
    );
  }

  /// Records a failed attempt. Returns the retry time when another attempt
  /// is allowed, or null when the occurrence is dead-lettered.
  ///
  /// Backoff is exponential from one minute (1, 2, 4 ...), which on a
  /// scheduler with a 15-minute floor means "next tick" in practice while
  /// still spacing out repeated failures for interval jobs.
  Future<DateTime?> failRun(
    String runId, {
    required int attempt,
    required int maxAttempts,
    required String errorCode,
    required String errorMessage,
    DateTime? now,
  }) async {
    final at = now ?? DateTime.now();
    final canRetry = attempt < maxAttempts;
    final retryAt = canRetry
        ? at.add(Duration(minutes: 1 << (attempt - 1).clamp(0, 6)))
        : null;
    await _database.db.update(
      'job_runs',
      {
        'finished_at': at.toIso8601String(),
        'status':
            canRetry ? JobRun.statusRetryWait : JobRun.statusDeadLetter,
        'error_code': canRetry ? errorCode : 'MAX_ATTEMPTS_EXCEEDED',
        'error_message': errorMessage,
        'lease_until': null,
      },
      where: 'id = ?',
      whereArgs: [runId],
    );
    return retryAt;
  }

  /// Runs left Running by a process that died, whose lease has expired.
  /// Reported by the reliability screen so a crash-loop is visible.
  /// For each job with a run in flight, when that run's lease ends.
  ///
  /// A leased occurrence cannot be claimed by anyone else until then, so
  /// waking up for it sooner achieves nothing (see `BriefAlarm.nextWake`).
  Future<Map<String, DateTime>> liveLeases({DateTime? now}) async {
    final at = (now ?? DateTime.now()).toIso8601String();
    final rows = await _database.db.query(
      'job_runs',
      columns: ['job_id', 'lease_until'],
      where: 'status = ? AND lease_until IS NOT NULL AND lease_until >= ?',
      whereArgs: [JobRun.statusRunning, at],
    );
    final leases = <String, DateTime>{};
    for (final row in rows) {
      final until = DateTime.tryParse('${row['lease_until']}');
      final jobId = row['job_id'] as String?;
      if (until == null || jobId == null) continue;
      final held = leases[jobId];
      if (held == null || until.isAfter(held)) leases[jobId] = until;
    }
    return leases;
  }

  Future<List<JobRun>> staleRuns({DateTime? now}) async {
    final at = (now ?? DateTime.now()).toIso8601String();
    final rows = await _database.db.query(
      'job_runs',
      where: 'status = ? AND lease_until IS NOT NULL AND lease_until < ?',
      whereArgs: [JobRun.statusRunning, at],
      orderBy: 'started_at DESC',
    );
    return rows.map(JobRun.fromRow).toList();
  }

  /// Closes out interrupted runs that will never be resumed.
  ///
  /// A run left Running past its lease was killed with its isolate (Android
  /// stops a background worker after about ten minutes). [claimRun] takes
  /// such a run over on the next wake-up - but only while its occurrence is
  /// still the current one. An interval job has moved on by then, and the
  /// old row would otherwise stay Running forever, counted as "interrupted"
  /// on every visit to the reliability screen. Rows for a past occurrence
  /// (or a Run-now, which nothing resumes) are marked Failed with
  /// `error_code` INTERRUPTED. Returns how many were closed per job; a job
  /// that no longer exists is reported under a null job.
  Future<List<({ScheduledJob? job, int count})>> sweepInterruptedRuns(
      {DateTime? now}) async {
    final at = now ?? DateTime.now();
    final stale = await staleRuns(now: at);
    if (stale.isEmpty) return const [];
    final byJob = <String, List<JobRun>>{};
    for (final run in stale) {
      byJob.putIfAbsent(run.jobId, () => []).add(run);
    }
    final closed = <({ScheduledJob? job, int count})>[];
    for (final entry in byJob.entries) {
      final job = await getById(entry.key);
      final current = job?.occurrenceFor(at);
      final abandoned = [
        for (final run in entry.value)
          if (current == null ||
              run.triggerSource == 'manual' ||
              run.scheduledFor == null ||
              run.scheduledFor!.isBefore(current))
            run.id,
      ];
      if (abandoned.isEmpty) continue;
      // Chunked: SQLite caps the parameters in one statement.
      for (var i = 0; i < abandoned.length; i += 200) {
        final ids = abandoned.sublist(
            i, i + 200 > abandoned.length ? abandoned.length : i + 200);
        await _database.db.update(
          'job_runs',
          {
            'status': JobRun.statusFailed,
            'finished_at': at.toIso8601String(),
            'error_code': 'INTERRUPTED',
            'error_message': 'Stopped before it finished: the system ended '
                'the background worker mid-run.',
            'lease_until': null,
          },
          where: 'id IN (${List.filled(ids.length, '?').join(', ')})',
          whereArgs: ids,
        );
      }
      closed.add((job: job, count: abandoned.length));
    }
    return closed;
  }

  Future<void> finishRun(
    String runId, {
    required bool success,
    String? resultSummary,
    String? errorMessage,
  }) async {
    await _database.db.update(
      'job_runs',
      {
        'finished_at': DateTime.now().toIso8601String(),
        'status': success ? JobRun.statusSuccess : JobRun.statusFailed,
        'result_summary': resultSummary,
        'error_message': errorMessage,
        'lease_until': null,
      },
      where: 'id = ?',
      whereArgs: [runId],
    );
  }

  /// Advances a job to its next occurrence after a failed attempt, so the
  /// retry lands at [retryAt] instead of the normal cadence.
  Future<void> scheduleRetry(ScheduledJob job, DateTime retryAt) async {
    await _database.db.update(
      'scheduled_jobs',
      {
        'next_run_at': retryAt.toIso8601String(),
        'updated_at': DateTime.now().toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [job.id],
    );
  }

  Future<List<JobRun>> listRuns(String jobId, {int limit = 20}) async {
    final rows = await _database.db.query(
      'job_runs',
      where: 'job_id = ?',
      whereArgs: [jobId],
      orderBy: 'started_at DESC',
      limit: limit,
    );
    return rows.map(JobRun.fromRow).toList();
  }

  /// All runs across every job, newest first, each paired with its job's
  /// name and type (for the Job history screen).
  Future<List<JobRunWithJob>> listAllRuns({int limit = 100}) async {
    final rows = await _database.db.rawQuery('''
      SELECT r.*, j.name AS job_name, j.job_type AS job_type
      FROM job_runs r
      LEFT JOIN scheduled_jobs j ON j.id = r.job_id
      ORDER BY r.started_at DESC
      LIMIT ?
    ''', [limit]);
    return rows
        .map((row) => JobRunWithJob(
              run: JobRun.fromRow(row),
              jobName: row['job_name'] as String? ?? 'Deleted job',
              jobType: row['job_type'] as String? ?? 'unknown',
            ))
        .toList();
  }
}
