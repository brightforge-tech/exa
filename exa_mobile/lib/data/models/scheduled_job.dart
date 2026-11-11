import 'dart:convert';

class ScheduledJob {
  static const types = [
    'daily_summary',
    'daily_review',
    'agent_task',
    'task_cleanup',
    'email_sync',
    'message_sync',
    'calendar_sync',
  ];
  static const statuses = ['Active', 'Paused', 'Canceled'];

  final String id;
  final String name;

  /// For `agent_task` jobs this is the instruction the agent runs; for the
  /// fixed job types it is just a note.
  final String? description;
  final String jobType;

  /// JSON rule, e.g. {"type": "daily", "time": "07:30"}.
  final Map<String, Object?> scheduleRule;
  final String status;
  final DateTime? lastRunAt;
  final DateTime? nextRunAt;
  final String createdBy;

  /// Per-job tool allow/block lists (see JobPermissions). Null = only the
  /// run mode limits what the job may do.
  final String? permissionsJson;

  /// `live` resolves behaviors at run time; `snapshot` pins them to
  /// [behaviorSnapshot] as of job creation/approval; `none` runs without
  /// behavior rules.
  final String behaviorMode;
  final String? behaviorSnapshot;
  final int? behaviorVersion;

  /// What to do when the app was asleep past one or more occurrences:
  /// `run_once_now` (default), `skip`, or `run_every_missed_occurrence`.
  final String missedRunPolicy;

  /// Keeps this job off the device's notification shade.
  ///
  /// Scoped to the job's own *content* - its result, and anything a
  /// behaviour rule produces while it runs. The result still lands in chat
  /// and in the job history, so nothing is lost, and a system-health notice
  /// ("this job stopped running") still goes out: muting a job must not turn
  /// its own outage into an invisible one.
  final bool muteNotifications;
  final int timeoutSeconds;
  final int maxAttempts;
  final DateTime createdAt;
  final DateTime updatedAt;

  static const behaviorModes = ['live', 'snapshot', 'none'];
  static const missedRunPolicies = [
    'run_once_now',
    'skip',
    'run_every_missed_occurrence',
  ];

  const ScheduledJob({
    required this.id,
    required this.name,
    this.description,
    required this.jobType,
    required this.scheduleRule,
    this.status = 'Active',
    this.lastRunAt,
    this.nextRunAt,
    this.createdBy = 'agent',
    this.permissionsJson,
    this.behaviorMode = 'live',
    this.behaviorSnapshot,
    this.behaviorVersion,
    this.missedRunPolicy = 'run_once_now',
    this.muteNotifications = false,
    this.timeoutSeconds = 1800,
    this.maxAttempts = 3,
    required this.createdAt,
    required this.updatedAt,
  });

  /// Shortest supported interval. Sub-15-minute cadence is driven by the
  /// exact-alarm chain (BriefAlarm re-arms after each run); the 15-minute
  /// WorkManager tick stays underneath as the catch-up net. In deep Doze
  /// Android throttles allow-while-idle alarms to roughly one per 9
  /// minutes, so very short intervals are exact while the device is awake
  /// and best-effort while it sleeps.
  static const minIntervalMinutes = 2;

  /// Run only when chat messages are waiting to be gone through.
  static const onlyIfNewMessages = 'new_messages';

  /// Run only when mail is waiting to be gone through.
  static const onlyIfNewEmail = 'new_email';

  /// Run when either is waiting.
  static const onlyIfNewInbound = 'new_inbound';

  static const runConditions = [
    onlyIfNewMessages,
    onlyIfNewEmail,
    onlyIfNewInbound,
  ];

  /// What has to be waiting for this job to be worth running, or null when
  /// it runs every time it is due.
  ///
  /// A digest that runs every ten minutes finds nothing most of the time,
  /// and finding nothing used to cost a whole agent turn: over eight hours
  /// on the device, 34 of 41 chat digests created and marked nothing, each
  /// after a minute of model time - several minutes on a slow local model,
  /// which is how two of them ran out of background time. Whether anything
  /// is waiting is a row count; the app checks it and only then wakes the
  /// model. Kept in the schedule rule beside the active window, because it
  /// answers the same question: is this occurrence worth running at all.
  String? get onlyIf {
    final value = scheduleRule['only_if'];
    return value is String && runConditions.contains(value) ? value : null;
  }

  bool get waitsForMessages =>
      onlyIf == onlyIfNewMessages || onlyIf == onlyIfNewInbound;

  bool get waitsForEmail =>
      onlyIf == onlyIfNewEmail || onlyIf == onlyIfNewInbound;

  /// [onlyIf] in words, for the Jobs screen. Null when there is none.
  static String? describeOnlyIf(String? condition) => switch (condition) {
        onlyIfNewMessages => 'Only runs when new chat messages are waiting',
        onlyIfNewEmail => 'Only runs when new mail is waiting',
        onlyIfNewInbound =>
          'Only runs when new chat messages or mail are waiting',
        _ => null,
      };

  /// Next run time. Rules:
  ///   {"type": "daily", "time": "HH:mm"}
  ///   {"type": "weekly", "weekday": 1-7 (Mon-Sun), "time": "HH:mm"}
  ///   {"type": "interval", "minutes": N (>= 2)}
  static DateTime computeNextRun(Map<String, Object?> rule,
      {DateTime? from}) {
    final now = from ?? DateTime.now();

    if (rule['type'] == 'interval') {
      final minutes = ((rule['minutes'] as int?) ?? 30)
          .clamp(minIntervalMinutes, 24 * 60);
      final next = now.add(Duration(minutes: minutes));
      // Optional active window: an interval job that should only run during
      // the day carries active_from / active_to as "HH:mm". A run that would
      // fall outside the window is pushed to the next window opening, so no
      // agent turn (and no notification) happens overnight.
      return _snapToWindow(next, rule['active_from'], rule['active_to']);
    }

    final time = (rule['time'] as String?) ?? '07:30';
    final parts = time.split(':');
    final hour = int.tryParse(parts[0]) ?? 7;
    final minute = parts.length > 1 ? int.tryParse(parts[1]) ?? 30 : 30;
    var next = DateTime(now.year, now.month, now.day, hour, minute);

    if (rule['type'] == 'weekly') {
      final weekday =
          ((rule['weekday'] as int?) ?? DateTime.monday).clamp(1, 7);
      while (next.weekday != weekday || !next.isAfter(now)) {
        next = next.add(const Duration(days: 1));
      }
      return next;
    }

    if (!next.isAfter(now)) {
      next = next.add(const Duration(days: 1));
    }
    return next;
  }

  /// Minutes-since-midnight for an "HH:mm" string, or null.
  static int? _minutesOfDay(Object? hm) {
    if (hm is! String || hm.isEmpty) return null;
    final parts = hm.split(':');
    final h = int.tryParse(parts[0]);
    if (h == null) return null;
    final m = parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0;
    return (h.clamp(0, 23)) * 60 + m.clamp(0, 59);
  }

  /// Pushes [candidate] into the daily [from]..[to] window when both are
  /// given. A same-day window (07:00-19:00) is the common case; an overnight
  /// window (22:00-06:00) is honoured too. Returns [candidate] unchanged when
  /// no window is set or it already lands inside one.
  static DateTime _snapToWindow(DateTime candidate, Object? from, Object? to) {
    final fromMin = _minutesOfDay(from);
    final toMin = _minutesOfDay(to);
    if (fromMin == null || toMin == null || fromMin == toMin) return candidate;
    final mins = candidate.hour * 60 + candidate.minute;
    DateTime atToday(int minutes) => DateTime(candidate.year, candidate.month,
        candidate.day, minutes ~/ 60, minutes % 60);
    if (fromMin < toMin) {
      // Same-day window.
      if (mins < fromMin) return atToday(fromMin);
      if (mins >= toMin) return atToday(fromMin).add(const Duration(days: 1));
      return candidate;
    }
    // Overnight window (from > to): allowed when at/after `from` or before
    // `to`; otherwise wait for today's opening.
    if (mins >= fromMin || mins < toMin) return candidate;
    return atToday(fromMin);
  }

  Map<String, Object?> toRow() => {
        'id': id,
        'name': name,
        'description': description,
        'job_type': jobType,
        'schedule_rule': jsonEncode(scheduleRule),
        'status': status,
        'last_run_at': lastRunAt?.toIso8601String(),
        'next_run_at': nextRunAt?.toIso8601String(),
        'created_by': createdBy,
        'permissions_json': permissionsJson,
        'behavior_mode': behaviorMode,
        'behavior_snapshot': behaviorSnapshot,
        'behavior_version': behaviorVersion,
        'missed_run_policy': missedRunPolicy,
        'mute_notifications': muteNotifications ? 1 : 0,
        'timeout_seconds': timeoutSeconds,
        'max_attempts': maxAttempts,
        'created_at': createdAt.toIso8601String(),
        'updated_at': updatedAt.toIso8601String(),
      };

  factory ScheduledJob.fromRow(Map<String, Object?> row) {
    Map<String, Object?> rule = const {'type': 'daily', 'time': '07:30'};
    try {
      rule = (jsonDecode(row['schedule_rule'] as String? ?? '{}') as Map)
          .cast<String, Object?>();
    } catch (_) {}
    return ScheduledJob(
      id: row['id'] as String,
      name: row['name'] as String,
      description: row['description'] as String?,
      jobType: row['job_type'] as String,
      scheduleRule: rule,
      status: row['status'] as String? ?? 'Active',
      lastRunAt: _parse(row['last_run_at']),
      nextRunAt: _parse(row['next_run_at']),
      createdBy: row['created_by'] as String? ?? 'agent',
      permissionsJson: row['permissions_json'] as String?,
      behaviorMode: row['behavior_mode'] as String? ?? 'live',
      behaviorSnapshot: row['behavior_snapshot'] as String?,
      behaviorVersion: row['behavior_version'] as int?,
      missedRunPolicy: row['missed_run_policy'] as String? ?? 'run_once_now',
      muteNotifications: ((row['mute_notifications'] as int?) ?? 0) != 0,
      timeoutSeconds: (row['timeout_seconds'] as int?) ?? 1800,
      maxAttempts: (row['max_attempts'] as int?) ?? 3,
      createdAt: _parse(row['created_at']) ?? DateTime.now(),
      updatedAt: _parse(row['updated_at']) ?? DateTime.now(),
    );
  }

  /// The occurrence a run at [now] belongs to, used as the idempotency key.
  ///
  /// Interval jobs bucket by their own period so a retry a few seconds later
  /// lands on the same occurrence; clock-based jobs use their due time. Two
  /// wake-ups for the same occurrence therefore produce the same key and the
  /// second one loses the race in [JobRepository.claimRun].
  DateTime occurrenceFor(DateTime now) {
    final due = nextRunAt;
    if (scheduleRule['type'] == 'interval') {
      final minutes = ((scheduleRule['minutes'] as int?) ?? 30)
          .clamp(minIntervalMinutes, 24 * 60);
      final anchor = due ?? now;
      // Snap to the interval grid anchored on the scheduled time, so a run
      // that fires late still maps onto the occurrence it is servicing.
      if (!now.isAfter(anchor)) return anchor;
      final elapsed = now.difference(anchor).inMinutes;
      final periods = elapsed ~/ minutes;
      return anchor.add(Duration(minutes: periods * minutes));
    }
    // Clock jobs: the due time itself identifies the occurrence. A run
    // with no due time recorded falls back to the current minute.
    return due ?? DateTime(now.year, now.month, now.day, now.hour, now.minute);
  }

  Map<String, Object?> toAgentJson() => {
        'id': id,
        'name': name,
        if (description != null && description!.isNotEmpty)
          'instructions': description,
        if (permissionsJson != null) 'permissions': permissionsJson,
        if (behaviorMode != 'live') 'behavior_mode': behaviorMode,
        if (muteNotifications) 'mute_notifications': true,
        'job_type': jobType,
        'schedule_rule': scheduleRule,
        'status': status,
        if (lastRunAt != null) 'last_run_at': lastRunAt!.toIso8601String(),
        if (nextRunAt != null) 'next_run_at': nextRunAt!.toIso8601String(),
      };

  static DateTime? _parse(Object? value) =>
      value is String && value.isNotEmpty ? DateTime.tryParse(value) : null;
}

class JobRun {
  /// Terminal states a run can end in. `RetryWait` is transient: the run is
  /// scheduled to be attempted again. `DeadLetter` means every attempt was
  /// used up and the occurrence is abandoned (it never fires again, and it
  /// stays visible in history so the failure isn't silent).
  static const statusRunning = 'Running';
  static const statusSuccess = 'Success';
  static const statusFailed = 'Failed';
  static const statusRetryWait = 'RetryWait';
  static const statusDeadLetter = 'DeadLetter';
  static const statusTimedOut = 'TimedOut';
  static const statusCancelled = 'Cancelled';

  final String id;
  final String jobId;
  final DateTime startedAt;
  final DateTime? finishedAt;
  final String status;
  final String? resultSummary;
  final String? errorMessage;

  /// The scheduled occurrence this run services. Two wake-ups for the same
  /// occurrence share this value, which is what the unique index keys on.
  final DateTime? scheduledFor;
  final int attempt;

  /// While this is in the future and the status is Running, another isolate
  /// must leave the run alone.
  final DateTime? leaseUntil;

  /// What woke the run: `alarm`, `worker`, `manual`.
  final String? triggerSource;
  final String? errorCode;
  final String? modelId;
  final int? tokensIn;
  final int? tokensOut;
  final int? behaviorVersion;

  const JobRun({
    required this.id,
    required this.jobId,
    required this.startedAt,
    this.finishedAt,
    required this.status,
    this.resultSummary,
    this.errorMessage,
    this.scheduledFor,
    this.attempt = 1,
    this.leaseUntil,
    this.triggerSource,
    this.errorCode,
    this.modelId,
    this.tokensIn,
    this.tokensOut,
    this.behaviorVersion,
  });

  bool get isTerminal =>
      status == statusSuccess ||
      status == statusDeadLetter ||
      status == statusCancelled;

  factory JobRun.fromRow(Map<String, Object?> row) => JobRun(
        id: row['id'] as String,
        jobId: row['job_id'] as String,
        startedAt:
            DateTime.tryParse(row['started_at'] as String? ?? '') ??
                DateTime.now(),
        finishedAt: row['finished_at'] is String
            ? DateTime.tryParse(row['finished_at'] as String)
            : null,
        status: row['status'] as String? ?? statusRunning,
        resultSummary: row['result_summary'] as String?,
        errorMessage: row['error_message'] as String?,
        scheduledFor: row['scheduled_for'] is String
            ? DateTime.tryParse(row['scheduled_for'] as String)
            : null,
        attempt: (row['attempt'] as int?) ?? 1,
        leaseUntil: row['lease_until'] is String
            ? DateTime.tryParse(row['lease_until'] as String)
            : null,
        triggerSource: row['trigger_source'] as String?,
        errorCode: row['error_code'] as String?,
        modelId: row['model_id'] as String?,
        tokensIn: row['tokens_in'] as int?,
        tokensOut: row['tokens_out'] as int?,
        behaviorVersion: row['behavior_version'] as int?,
      );
}
