import 'dart:async';
import 'dart:convert';

import 'package:intl/intl.dart';

import '../../agent/behaviors/behavior_context.dart';
import '../../agent/behaviors/behavior_triggers.dart';
import '../../agent/behaviors/notification_policy.dart';
import '../../agent/behaviors/output_validator.dart';
import '../../agent/models/tool_execution_record.dart';
import '../../agent/orchestrator/agent_orchestrator.dart';
import '../../agent/services/response_gateway.dart';
import '../../agent/security/write_scope.dart';
import '../../agent/tools/tool_failure.dart';
import '../../agent/behaviors/trigger_firing_ledger.dart';
import '../service_circuit_breaker.dart';
import '../../data/database/app_database.dart';
import '../../data/models/agent_behavior.dart';
import '../../data/models/browser_context_item.dart';
import '../../data/models/email_item.dart';
import '../../data/models/scheduled_job.dart';
import '../../agent/security/capability_policy.dart';
import '../../data/repositories/behavior_repository.dart';
import '../../data/repositories/browser_context_repository.dart';
import '../../data/repositories/diagnostics_repository.dart';
import '../../data/repositories/chat_repository.dart';
import '../../data/repositories/email_repository.dart';
import '../../data/repositories/inbound_media_repository.dart';
import '../../data/repositories/inbound_message_repository.dart';
import '../../data/repositories/job_repository.dart';
import '../../data/repositories/mail_account_repository.dart';
import '../../data/repositories/reminder_repository.dart';
import '../../data/repositories/schedule_repository.dart';
import '../../data/repositories/settings_repository.dart';
import '../../data/repositories/task_repository.dart';
import '../ai_client/ai_client.dart';
import '../ai_client/claude_client.dart';
import '../ai_client/deepseek_client.dart';
import '../ai_client/local_endpoint_client.dart';
import '../ai_client/openai_compatible_client.dart';
import '../calendar/device_calendar_service.dart';
import '../mail/mail_service.dart';
import '../messaging/message_ingest_service.dart';
import '../notifications/notification_service.dart';
import '../transcription/audio_transcriber.dart';

/// Executes scheduled jobs. Runs both in the foreground ("Run now") and in
/// the WorkManager background isolate (periodic tick).
class JobRunner {
  JobRunner({
    required AppDatabase database,
    required this.notifications,
    ClaudeClient? claudeClient,
    AudioTranscriber? audioTranscriber,
    this.orchestratorFactory,
  })  : jobs = JobRepository(database),
        tasks = TaskRepository(database),
        schedule = ScheduleRepository(database),
        reminders = ReminderRepository(database),
        browserContext = BrowserContextRepository(database),
        emails = EmailRepository(database),
        chat = ChatRepository(database),
        settings = SettingsRepository(database),
        behaviors = BehaviorRepository(database),
        diagnostics = DiagnosticsRepository(database),
        claude = claudeClient ?? ClaudeClient(),
        circuits = ServiceCircuitBreaker(database),
        _db = database {
    mail = MailService(
        accounts: MailAccountRepository(database), emails: emails);
    // One media lifecycle owner, here as everywhere else: the drain stores
    // media rows through the message repository, the transcription pass reads
    // them through the same object, and the messages the digest scopes are
    // read with their media attached.
    chatMedia = InboundMediaRepository(database);
    chatMessages = InboundMessageRepository(database, media: chatMedia);
    // The job's own transcriber, reading the endpoint from settings at call
    // time like every other local client here. Injectable because the pass it
    // serves is tested against a recorded HTTP client, not a live server.
    transcriber = audioTranscriber ?? OpenAiAudioTranscriber(settings: settings);
    messageIngest = MessageIngestService(
      messages: chatMessages,
      media: chatMedia,
      settings: settings,
      audioTranscriber: transcriber,
    );
    deviceCalendar = DeviceCalendarService(schedule: schedule);
  }

  /// Supplies the agent orchestrator for jobs that run as full agent turns
  /// (currently daily_review). A factory - not an instance - because the
  /// tool registry depends on JobRunner, so the orchestrator can only be
  /// resolved lazily after the whole stack exists. Mutable so the
  /// background isolate can wire it after constructing the registry.
  /// Null = jobs use the legacy deterministic path.
  AgentOrchestrator Function()? orchestratorFactory;

  /// Re-entrancy guard: a daily_review started from INSIDE an agent turn
  /// (via the run_scheduled_job_now tool) must not start a nested agent
  /// turn - it takes the deterministic path instead.
  bool _agentTurnInProgress = false;

  final AppDatabase _db;
  final JobRepository jobs;
  final TaskRepository tasks;
  final ScheduleRepository schedule;
  final ReminderRepository reminders;
  final BrowserContextRepository browserContext;
  final EmailRepository emails;
  late final InboundMediaRepository chatMedia;
  late final InboundMessageRepository chatMessages;
  final ChatRepository chat;
  final SettingsRepository settings;
  final BehaviorRepository behaviors;
  final DiagnosticsRepository diagnostics;

  /// Per-service health. Complements the occurrence ledger rather than
  /// replacing it: the ledger stops one occurrence running twice, this
  /// stops a broken account being retried every two minutes forever.
  final ServiceCircuitBreaker circuits;
  final NotificationService notifications;
  final ClaudeClient claude;
  late final MailService mail;
  late final MessageIngestService messageIngest;

  /// The file-audio capability the chat-sync job runs after its drain. Held
  /// here so the wiring is visible from the job that uses it; the pass itself
  /// lives on [messageIngest], which is the only object that can pair a media
  /// row with the media directory it came from.
  late final AudioTranscriber transcriber;
  late final DeviceCalendarService deviceCalendar;

  /// How long one WorkManager invocation may spend running jobs.
  ///
  /// Android stops a JobScheduler-backed worker after about ten minutes,
  /// and a stopped worker takes the Dart isolate with it: no catch block
  /// runs, so the run stays `Running` until its lease expires and is never
  /// finished. The device's JobScheduler stats showed exactly that (seven
  /// "timeout" stops in one day, each a chat digest on a slow local model).
  /// Keeping the run inside the budget turns a silent kill into an ordinary
  /// timeout: recorded, retried on the next wake-up, dead-lettered if it
  /// keeps happening. The margin is for what the worker does after the
  /// jobs (push check, reminder re-registration, alarm re-arm).
  static const workerBudget = Duration(minutes: 8);

  /// How long one run of the foreground job service may spend.
  ///
  /// The service has no platform limit; this is Exa's own. Long enough for
  /// a slow model to finish several jobs in a row, short enough that a run
  /// which has gone wrong gives the phone back the same half hour.
  static const serviceBudget = Duration(minutes: 20);

  /// With less budget than this a job is left for the next wake-up rather
  /// than started and cut off.
  static const minRunSlice = Duration(seconds: 45);

  /// Runs everything that is due. Returns the number of jobs executed.
  ///
  /// A job whose occurrence is already claimed by another wake-up (or is
  /// already done) is skipped here rather than run twice, so the exact
  /// alarm and the WorkManager tick firing together is harmless.
  ///
  /// [budget] caps the whole call: each job gets what is left of it as its
  /// time limit, and a job that no longer fits is deferred to the next
  /// wake-up. A WorkManager worker passes [workerBudget]; a caller with no
  /// platform limit passes nothing.
  Future<int> runDueJobs({
    String triggerSource = 'worker',
    Duration? budget,
  }) async {
    final startedAt = DateTime.now();
    await _closeOutInterruptedRuns();
    final due = await jobs.listDue();
    var executed = 0;
    for (var i = 0; i < due.length; i++) {
      final job = due[i];
      Duration? timeLimit;
      if (budget != null) {
        timeLimit = budget - DateTime.now().difference(startedAt);
        if (timeLimit < minRunSlice) {
          final left = due.length - i;
          await diagnostics.record(
            code: 'JOB_DEFERRED_NO_TIME',
            message: "'${job.name}'"
                "${left > 1 ? ' and ${left - 1} more' : ''} left for the "
                'next wake-up: this background run has used the time '
                'Android gives a worker.',
            context: {'job_id': job.id, 'deferred': left},
          );
          break;
        }
      }
      final outcome = await runJob(job,
          triggerSource: triggerSource, timeLimit: timeLimit);
      if (!outcome.wasSkipped) executed++;
    }
    return executed;
  }

  /// A run killed with its isolate can only be resumed while its occurrence
  /// is still current; the rest are closed out here so the reliability
  /// screen reports them once, as history, instead of counting them forever.
  Future<void> _closeOutInterruptedRuns() async {
    final closed = await jobs.sweepInterruptedRuns();
    for (final entry in closed) {
      final name = entry.job?.name ?? 'a deleted job';
      await diagnostics.warn(
        code: 'JOB_RUN_INTERRUPTED',
        message: "${entry.count} run(s) of '$name' were stopped by the "
            'system before they finished and have been closed out. They '
            'are retried; a run that needs more time than it is allowed is '
            'cut off and recorded rather than killed.',
        context: {
          if (entry.job != null) 'job_id': entry.job!.id,
          'count': entry.count,
        },
      );
    }
  }

  /// Runs a single job, recording the attempt in the execution ledger.
  ///
  /// The occurrence is claimed first ([JobRepository.claimRun]); losing that
  /// race means another isolate is already on it, which is reported as a
  /// skip rather than a failure. Failures back off and retry up to the
  /// job's `max_attempts` before the occurrence is dead-lettered.
  Future<JobRunOutcome> runJob(
    ScheduledJob job, {
    String triggerSource = 'manual',
    Duration? timeLimit,
  }) async {
    // The job's own timeout, unless the caller has less time than that: a
    // worker's remaining budget is a hard ceiling (see [workerBudget]).
    final ownTimeout = Duration(seconds: job.timeoutSeconds);
    final cutShort = timeLimit != null && timeLimit < ownTimeout;
    final timeout = cutShort ? timeLimit : ownTimeout;
    final run = await jobs.claimRun(
      job,
      triggerSource: triggerSource,
      // Stamped on the run so a past result can be read against the rules
      // that were in force when it happened.
      behaviorVersion: await behaviors.currentVersion(),
      // A killed run stays untouchable for its lease; that must not outlive
      // the time this run can actually take.
      leaseFor: timeout,
    );
    if (run == null) {
      await diagnostics.record(
        code: 'JOB_RUN_SKIPPED_DUPLICATE',
        message: "Skipped '${job.name}': this occurrence is already "
            'claimed or finished.',
        context: {'job_id': job.id, 'trigger': triggerSource},
      );
      return const JobRunOutcome(
        success: true,
        summary: 'Already running or already done for this occurrence.',
        wasSkipped: true,
      );
    }

    // Records created during this run are stamped with it, so the Job
    // history can show what a run produced and offer to undo exactly that.
    _activeRunId = run.id;
    _activeRunMuted = job.muteNotifications;
    // When this run loses its right to keep going. Jobs that spend part of
    // the run on an external call (voice-note transcription) read it to size
    // that call's own slice, so a slow endpoint costs a deferred voice note
    // rather than a job Android kills.
    _activeRunDeadline = DateTime.now().add(timeout);
    try {
      await onJobStarting?.call(job);
    } catch (_) {
      // A status line must never cost the run.
    }
    try {
      final work = switch (job.jobType) {
        'daily_summary' => _runDailySummary(useAi: false),
        'daily_review' => _runDailyReview(),
        'agent_task' => _runAgentTask(job),
        'task_cleanup' => _runTaskCleanup(job),
        'email_sync' => _runEmailSync(job),
        'message_sync' => _runMessageSync(job),
        'calendar_sync' => _runCalendarSync(job),
        _ => Future<String>.error(UnsupportedError(
            "Job type '${job.jobType}' is not supported yet")),
      };
      // A hung network call must not hold the lease forever, and a run
      // that would outlive the worker's budget is cut off here - where it
      // is recorded and retried - rather than killed with the isolate.
      final summary = await work.timeout(timeout);
      await jobs.completeRun(run.id, summary: summary);
      await jobs.markRan(job);
      return JobRunOutcome(success: true, summary: summary);
    } catch (e) {
      final timedOut = e is TimeoutException;
      final code = timedOut ? 'JOB_TIMEOUT' : 'JOB_FAILED';
      final reason = !timedOut
          ? '$e'
          : cutShort
              ? 'Ran out of background time: this run had '
                  '${_minutesAndSeconds(timeout)} left of what a background '
                  'run is allowed, and needed more. It is retried on the '
                  'next wake-up.'
              : 'Took longer than its ${timeout.inMinutes}-minute limit.';
      final retryAt = await jobs.failRun(
        run.id,
        attempt: run.attempt,
        maxAttempts: job.maxAttempts,
        errorCode: code,
        errorMessage: reason,
      );
      await diagnostics.warn(
        code: code,
        message: "Job '${job.name}' failed on attempt ${run.attempt} of "
            '${job.maxAttempts}: $reason',
        context: {
          'job_id': job.id,
          'job_type': job.jobType,
          'attempt': run.attempt,
          'will_retry': retryAt != null,
        },
        error: e,
      );
      if (retryAt != null) {
        // Come back for this same occurrence after the backoff; the claim
        // then takes over the existing RetryWait row as attempt N+1.
        await jobs.scheduleRetry(job, retryAt);
      } else {
        // Out of attempts: give up on this occurrence and move to the next
        // one so a permanently broken job doesn't stall its own schedule.
        await jobs.markRan(job);
        // The user asked for this to happen and it is not happening. That
        // is a health problem, not content, so neither quiet hours nor the
        // job's own mute switch hide it.
        await _notify(
          id: _healthNotificationId(job.id),
          title: "'${job.name}' isn't running",
          body: 'It failed ${job.maxAttempts} times and has been paused '
              'until its next scheduled run. Open Job history for details.',
          route: '/settings/jobs',
          channel: NotificationPolicy.channelSystemHealth,
        );
      }
      return JobRunOutcome(success: false, summary: reason);
    } finally {
      _activeRunId = null;
      _activeRunMuted = false;
      _activeRunDeadline = null;
    }
  }

  static String _minutesAndSeconds(Duration d) => d.inMinutes >= 2
      ? '${d.inMinutes} minutes'
      : '${d.inSeconds} seconds';

  /// Told each job as it starts, for a host that shows what it is doing.
  Future<void> Function(ScheduledJob job)? onJobStarting;

  /// The occurrence currently executing, threaded into agent turns so
  /// everything they create can name the run that made it.
  String? _activeRunId;

  /// Wall-clock end of the run whose context this is, derived from its caller
  /// timeout. Null when no limit was imposed.
  DateTime? _activeRunDeadline;

  /// Whether the job currently executing has its notifications muted. A
  /// field rather than a parameter threaded through every path, for the same
  /// reason as [_activeRunId]: jobs run one after another, and this has to
  /// cover work the run causes indirectly - a behaviour trigger's digest
  /// fired by a muted sync is that sync's noise too.
  bool _activeRunMuted = false;

  /// Every device notification a job run produces goes through here, so the
  /// mute rule lives in one place.
  ///
  /// Muting is about content: the run's result still reaches chat and the
  /// job history. System-health notices pass regardless - a muted job that
  /// has stopped working must not fail silently.
  Future<void> _notify({
    required int id,
    required String title,
    required String body,
    String? route,
    String channel = NotificationPolicy.channelContent,
  }) async {
    if (_activeRunMuted && channel != NotificationPolicy.channelSystemHealth) {
      return;
    }
    await notifications.showNow(
      id: id,
      title: title,
      body: body,
      route: route,
      channel: channel,
    );
  }

  /// True while a behaviour trigger's own action is running. Work it
  /// produces must not fire the trigger that produced it.
  var _inTriggerAction = false;

  /// Durable per-behaviour firing counters and per-event deduplication.
  late final TriggerFiringLedger triggerFirings = TriggerFiringLedger(_db);

  /// The fixed request the daily review runs as an agent turn. Phrased to
  /// trigger the daily_review skill (and ONLY that skill): it says "daily
  /// review", which is that skill's trigger, and deliberately avoids the
  /// digest_emails and prepare_daily_briefing trigger phrases, so neither
  /// the email-only recipe (which never looks at the day) nor the
  /// deterministic briefing (which would skip email digestion) can hijack
  /// the turn.
  static const dailyReviewPrompt =
      'Daily review: go through my new email and pull out tasks, meetings '
      "and deadlines into the right places, then look at today's schedule, "
      'my open tasks and upcoming reminders, and give me a short rundown '
      'with anything that needs attention.';

  /// The AI daily review, routed through the full agent pipeline.
  ///
  /// Falls back to the legacy deterministic summary when the agent turn
  /// can't run or produces nothing.
  Future<String> _runDailyReview() async {
    // Captured before the turn so the same close-out the deterministic path
    // has always done also applies when the agent runs the review.
    final batch =
        (await emails.undigested()).map((email) => email.id).toList();
    final summary = await _runAgentTurn(dailyReviewPrompt,
        title: 'Your daily review', notificationId: 90002);
    if (summary == null) return _runDailySummary(useAi: true);
    await _closeOutDigestedBatch(batch, source: 'Your daily review');
    return summary;
  }

  /// A user-defined recurring instruction ("every Friday, list what slipped
  /// this week"), run as a full agent turn. Unlike daily_review there is no
  /// deterministic equivalent to fall back to, so an unavailable provider is
  /// a job failure with a readable reason on the Job history screen.
  Future<String> _runAgentTask(ScheduledJob job) async {
    final instructions = job.description?.trim() ?? '';
    if (instructions.isEmpty) {
      throw StateError(
          'This job has no instructions. Open it and describe what Exa '
          'should do when it runs.');
    }
    final nothingNew = await _nothingWaitingFor(job);
    if (nothingNew != null) return nothingNew;
    if (_readsChats(job)) {
      // Voice notes are only words once transcribed, and the chat-sync job
      // that normally does it may not have run since they arrived. A short
      // pass here means the model reads what was said, not a size and format.
      try {
        await _transcribeVoiceNotes(
          job,
          mediaStored: 0,
          ceiling: agentTaskTranscriptionCeiling,
        );
      } catch (_) {
        // Untranscribed notes still reach the model as their honest note.
      }
    }
    final summary = await _runAgentTurn(instructions, title: job.name,
        job: job);
    if (summary == null) {
      throw StateError(
          'No AI provider is available for background runs. Add an API key '
          'or a local endpoint in Settings > AI provider.');
    }
    return summary;
  }

  /// Whether an agent task works on captured chat messages: it waits for
  /// them, its allow-list names a chat-reading tool, or its instructions
  /// talk about chats. Used to transcribe voice notes before the model reads.
  static bool _readsChats(ScheduledJob job) {
    if (job.waitsForMessages) return true;
    final allowed = job.permissionsJson ?? '';
    if (allowed.contains('read_message_context') ||
        allowed.contains('read_chat') ||
        allowed.contains('sync_messages')) {
      return true;
    }
    return RegExp(r'\b(chats?|messages?|whatsapp|voice notes?)\b',
            caseSensitive: false)
        .hasMatch(job.description ?? '');
  }

  /// The result of a run that had nothing to work on, or null when the job
  /// should run (see [ScheduledJob.onlyIf]).
  ///
  /// Takes in what has arrived first - the same intake the model's own sync
  /// call would do - so "nothing waiting" is decided on current data. A
  /// failed intake does not wake the model either: its sync would fail the
  /// same way, and whatever is already stored is still counted.
  ///
  /// Quiet by construction: no chat card and no notification, only the line
  /// in Job history. Behaviour triggers are not fired from here; this is the
  /// job's own look before it starts, not a sync job.

  Future<String?> _nothingWaitingFor(ScheduledJob job) async {
    if (job.onlyIf == null) return null;
    var waiting = 0;
    final checked = <String>[];
    if (job.waitsForMessages) {
      try {
        await messageIngest.syncAllDetailed();
      } catch (_) {
        // Counted from what is stored.
      }
      waiting += await chatMessages.countUndigested();
      checked.add('chats');
    }
    if (job.waitsForEmail) {
      try {
        if (await circuits.allows(ServiceNames.mail)) {
          await mail.syncAllDetailed();
        }
      } catch (_) {
        // Counted from what is stored.
      }
      waiting += await emails.countUndigested();
      checked.add('mail');
    }
    if (waiting > 0) return null;
    await diagnostics.record(
      code: 'JOB_NOTHING_WAITING',
      message: "'${job.name}' found nothing new in ${checked.join(' or ')}, "
          'so the model was not woken for it.',
      context: {'job_id': job.id, 'only_if': job.onlyIf},
    );
    return 'Nothing new in your ${checked.join(' or ')}, so there was '
        'nothing to go through.';
  }

  /// Runs [prompt] through the full agent pipeline: domain routing, skill
  /// matching, completion contract, idempotent tool execution, verification,
  /// entity graph, memory, and a replay trace - identical guarantees to a
  /// chat turn, and the user's behavior rules apply the same way (the turn
  /// is flagged unattended, so the agent knows it cannot ask anything).
  ///
  /// No user bubble is written; the result lands in chat tagged as a
  /// scheduled job. Returns null when no agent turn could run (no
  /// orchestrator wired, no capable provider - on-device models cannot run
  /// in the background isolate - or the turn failed outright), leaving the
  /// caller to decide between a fallback and a failure.
  Future<String?> _runAgentTurn(
    String prompt, {
    required String title,
    int notificationId = 90003,
    ScheduledJob? job,
  }) async {
    final orchestrate = orchestratorFactory;
    if (orchestrate == null) {
      await diagnostics.warn(
        code: 'JOB_NO_ORCHESTRATOR',
        message: 'No agent stack is wired into this runner, so '
            "'$title' could not run as an agent turn.",
      );
      return null;
    }
    if (_agentTurnInProgress) return null;
    if (!await _agentTurnAvailable()) {
      await diagnostics.warn(
        code: 'JOB_NO_PROVIDER',
        message: "No usable AI provider for '$title' in the background "
            '(on-device models cannot run in a background isolate).',
        context: {'title': title},
      );
      return null;
    }
    _agentTurnInProgress = true;
    try {
      final result = await orchestrate().run(
        prompt,
        persistUserMessage: false,
        unattended: true,
        // A run that found nothing new (every 5 minutes, say) is not worth
        // a chat card; the job history still records what it found.
        suppressQuietChatMessage: true,
        behaviorSurface: BehaviorSurface.scheduledJob,
        jobPermissions: JobPermissions.decode(job?.permissionsJson),
        jobId: job?.id,
        jobRunId: _activeRunId,
        // A job may declare exactly which effects it exists to produce.
        // One that says nothing keeps the unattended default, which
        // already excludes anything recurring - widened only by the
        // effects of the outbound tools the user granted it, if any.
        writeScope: WriteScope.forJob(job?.permissionsJson),
        behaviorSnapshot: _snapshotFor(job),
        skipBehaviors: job?.behaviorMode == 'none',
        assistantMeta: {'source': 'scheduled_job', 'job_title': title},
      );
      final summary = result.assistantText.trim();
      // A null report means the turn failed before doing any work (missing
      // key, provider error) - report that as "no turn ran".
      if (summary.isEmpty || result.report == null) return null;
      // The model wrote a result without calling a single tool, twice. That
      // is not a run with nothing to report - it is a run that did not
      // happen, and recording its text as the outcome is how "created three
      // tasks" ended up in the job history with no task behind it. A job of
      // the user's own is failed (and so retried, and eventually flagged as
      // not running); the built-in callers take their fallback.
      if (result.didNothing) {
        if (job != null) throw const _IdleAgentRun();
        return null;
      }
      await _closeOutServedItems(result, source: title);
      if (result.wasQuiet) {
        // Nothing new, nothing done, nothing failed: the orchestrator kept
        // it out of chat, and a buzz for it would be noise too. The run and
        // its summary still land in the job history.
        await diagnostics.record(
          code: 'JOB_QUIET_RUN',
          message: "'$title' found nothing new, so no chat card or "
              'notification was posted.',
          context: {'title': title, if (job != null) 'job_id': job.id},
        );
        return summary;
      }
      await _notify(
        id: notificationId,
        title: title,
        body: _clipForNotification(summary),
        route: '/',
      );
      return summary;
    } on _IdleAgentRun {
      rethrow;
    } catch (e) {
      await diagnostics.warn(
        code: 'JOB_AGENT_TURN_FAILED',
        message: "The agent turn for '$title' failed: $e",
        context: {'title': title, if (job != null) 'job_id': job.id},
        error: e,
      );
      return null;
    } finally {
      _agentTurnInProgress = false;
    }
  }

  /// The rules a `snapshot` job was created with, or null for a `live` job
  /// (which resolves the user's current rules at run time). A corrupt
  /// snapshot degrades to live rather than running with no rules at all.
  List<AgentBehavior>? _snapshotFor(ScheduledJob? job) {
    if (job == null || job.behaviorMode != 'snapshot') return null;
    final raw = job.behaviorSnapshot;
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return null;
      return [
        for (final row in decoded.whereType<Map>())
          AgentBehavior.fromRow(row.cast<String, Object?>()),
      ];
    } catch (_) {
      return null;
    }
  }

  /// Whether the orchestrator can run a model turn in this context: a hosted
  /// API (Anthropic, DeepSeek) with a key, or a local endpoint. On-device
  /// models need plugin channels the WorkManager isolate does not have.
  Future<bool> _agentTurnAvailable() async {
    final provider = await settings.getAiProvider();
    if (provider == SettingsRepository.providerLocal) return true;
    if (SettingsRepository.isHostedProvider(provider)) {
      final key = await settings.getApiKeyForProvider(provider);
      return key != null && key.isNotEmpty;
    }
    return false;
  }

  /// Deterministic jobs (cleanup, the syncs) never call a model, so behavior
  /// rules can only shape what the user is TOLD about them.
  ///
  /// Three gates, all necessary. The user must have asked to hear about
  /// these jobs at all (a summary or notification rule); something must
  /// have actually happened ([changed] or [failed]) - a job that polls every
  /// two minutes and finds nothing has nothing to say; and the message must
  /// differ from the last one this job posted, because "0 fetched" repeated
  /// every two minutes is noise that buries the run that mattered.
  Future<String> _reportDeterministic(
    ScheduledJob job,
    String summary, {
    bool changed = false,
    bool failed = false,
  }) async {
    if (!changed && !failed) return summary;

    final rules = await BehaviorContext.load(
      behaviors: behaviors,
      surface: BehaviorSurface.scheduledJob,
      unattended: true,
      onlyTypes: const {'summary_rule', 'notification_rule'},
    );
    // Check the trigger types explicitly: safety rules are never filtered
    // out, so a non-empty context alone would not mean the user asked to
    // hear about these jobs.
    final wantsReport = rules.ofType('summary_rule').isNotEmpty ||
        rules.ofType('notification_rule').isNotEmpty;
    if (!wantsReport) return summary;

    // A change is always news, even when it reads the same as last time
    // ("flagged 1 task" twice running is two different tasks). A standing
    // failure is not: a broken account reporting the same error every two
    // minutes is the noise this gate exists for.
    if (!changed && failed && await _alreadyReported(job, summary)) {
      return summary;
    }

    final report = await _writeJobReport(job, summary, rules) ?? summary;
    await _notify(
      id: _reportNotificationId(job.id),
      title: job.name,
      body: _clipForNotification(report),
      route: '/',
    );
    await chat.append('assistant', report,
        meta: {'source': 'scheduled_job', 'job_title': job.name});
    return report;
  }

  /// Whether this job's previous run said the same thing. Compared against
  /// the stored run summary rather than an in-memory flag, so it still holds
  /// across the app restarts and separate background isolates that run these
  /// jobs.
  Future<bool> _alreadyReported(ScheduledJob job, String summary) async {
    try {
      final recent = await jobs.listRuns(job.id, limit: 3);
      return recent.any((run) =>
          run.status == JobRun.statusSuccess &&
          run.resultSummary != null &&
          run.resultSummary!.startsWith(summary));
    } catch (_) {
      return false;
    }
  }

  /// Marks any of [batch] the turn read but left unmarked.
  ///
  /// Marking is the model's job via `mark_email_digested`, and a capable one
  /// does it. A smaller model reliably reads and analyses the batch and then
  /// drops the final bookkeeping call - which is worse than it sounds: the
  /// same messages stay "new", the next run picks up the identical batch,
  /// and the backlog never moves while every run spends a model turn. The
  /// app read them, so the app closes them out.
  ///
  /// Deliberately scoped to the batch this run was given, never the whole
  /// backlog, so nothing the turn did not see is ever marked.
  Future<void> _closeOutDigestedBatch(
    List<String> batch, {
    required String source,
  }) async {
    if (batch.isEmpty) return;
    final missed = <String>[];
    for (final id in batch) {
      final email = await emails.getById(id);
      if (email != null && !email.digested) {
        await emails.markDigested(id);
        missed.add(id);
      }
    }
    if (missed.isEmpty) return;
    await diagnostics.warn(
      code: 'DIGEST_NOT_MARKED_BY_MODEL',
      message: '${missed.length} of ${batch.length} email(s) were read but '
          'never marked digested by the model, so "$source" marked them. '
          'Without this the same messages would be re-analysed every run.',
      context: {'source': source, 'marked': missed.length},
    );
  }

  /// Runs whatever the user's behavior rules armed for [event].
  ///
  /// Returns a short note for the job summary, or null when nothing was
  /// armed or nothing was due. Never throws: a trigger failing must not turn
  /// a successful sync into a failed run.
  Future<String?> _fireTriggers(String event, {String? eventId}) async {
    try {
      final armed =
          BehaviorTrigger.forEvent(await behaviors.listActive(), event);
      if (armed.isEmpty) return null;

      for (final trigger in armed) {
        final lastFiredRaw = await settings.getValue(trigger.lastFiredKey);
        final lastFired =
            lastFiredRaw == null ? null : DateTime.tryParse(lastFiredRaw);
        if (!trigger.isDue(lastFired)) continue;

        // Interval pacing bounds how *often* a rule fires; these bound how
        // much it does in total, and survive process restarts - background
        // isolates share no memory to count in.
        final refusal = await triggerFirings.claim(
          trigger: trigger,
          eventId: eventId ?? '$event:${_activeRunId ?? DateTime.now()}',
          jobRunId: _activeRunId,
          // Work a trigger created must never raise the event that fires
          // the same trigger; nothing else in the system breaks that cycle.
          triggeredByTriggerWork: _inTriggerAction,
        );
        if (refusal != null) {
          await diagnostics.record(
            code: 'BEHAVIOR_TRIGGER_SUPPRESSED',
            message: TriggerFiringLedger.describe(refusal, trigger),
            context: {
              'behavior_id': trigger.behaviorId,
              'event': event,
              'reason': refusal.name,
            },
          );
          continue;
        }

        _inTriggerAction = true;
        final ({String note, bool moreWork})? outcome;
        try {
          outcome = await _runTriggerAction(trigger);
        } finally {
          _inTriggerAction = false;
        }
        if (outcome == null) continue;
        // Finishing a backlog is a continuation, not a new firing: pace it
        // faster than the idle interval so 57 emails drain over a few runs
        // instead of one batch per half hour, while an empty queue still
        // waits the full interval before anything happens again.
        final fired = outcome.moreWork
            ? DateTime.now().subtract(
                Duration(minutes: trigger.continuationCreditMinutes))
            : DateTime.now();
        await settings.setValue(
            trigger.lastFiredKey, fired.toIso8601String());
        return outcome.note;
      }
      return null;
    } catch (e) {
      await diagnostics.warn(
        code: 'BEHAVIOR_TRIGGER_FAILED',
        message: 'A behavior trigger for "$event" could not run: $e',
        error: e,
      );
      return null;
    }
  }

  Future<({String note, bool moreWork})?> _runTriggerAction(
      BehaviorTrigger trigger) async {
    switch (trigger.action) {
      case BehaviorTrigger.actionDigest:
        // The same action means different work depending on what raised it.
        // Splitting on the event rather than adding a second action keeps
        // "digest it when it arrives" one concept the user can state once.
        if (trigger.event == BehaviorTrigger.eventNewMessage) {
          return _digestMessages(trigger);
        }
        // Counts mail downloaded on earlier runs too, not just what arrived
        // just now - otherwise a backlog that built up while the rule was
        // inactive would never be picked up.
        final backlog = await emails.countUndigested();
        if (backlog == 0) return null;
        final take = backlog > trigger.maxItems ? trigger.maxItems : backlog;
        // The exact batch handed over, so the run can be held to it.
        final batch = (await emails.undigested(limit: take))
            .map((email) => email.id)
            .toList();
        final summary = await _runAgentTurn(
          'Digest my email: read up to $take undigested messages with '
          'read_email_context (undigested_only true, limit $take), pull out '
          'tasks, meetings, and deadlines into the right tools, mark every '
          'one you processed as digested in a single mark_email_digested '
          'call, and give me a short rundown. There are $backlog waiting in '
          'total; do NOT try to read them all at once - the rest are '
          'handled on the next run.',
          title: 'Email digest',
          notificationId: 90004,
        );
        if (summary == null) {
          await diagnostics.warn(
            code: 'BEHAVIOR_TRIGGER_NO_TURN',
            message: 'Rule "${trigger.behaviorTitle}" wanted to digest '
                '$backlog email(s), but no agent turn could run '
                '(no usable AI provider in the background, or the model '
                'called no tool and the run was discarded).',
            context: {'behavior_id': trigger.behaviorId},
          );
          return null;
        }
        await _closeOutDigestedBatch(batch, source: trigger.behaviorTitle);
        final left = await emails.countUndigested();
        return (
          note: left > 0
              ? 'Digested a batch on behalf of "${trigger.behaviorTitle}"; '
                  '$left still waiting'
              : 'Digested email on behalf of "${trigger.behaviorTitle}"',
          moreWork: left > 0,
        );
      default:
        return null;
    }
  }

  /// "Digest my WhatsApp messages when they arrive."
  ///
  /// Same shape as the mail digest and different in two ways that matter:
  ///
  ///  - **The scope filter is applied here, not left to the model.** A busy
  ///    group chat produces far more traffic than a mailbox, and a rule
  ///    scoped to two people must not spend a model turn reading forty
  ///    messages from everyone else before deciding to ignore them.
  ///  - **Nothing it does can answer anyone.** The trigger's write scope has
  ///    no `message.send`, and the capability gate refuses outbound work to
  ///    unattended runs regardless.
  Future<({String note, bool moreWork})?> _digestMessages(
      BehaviorTrigger trigger) async {
    final waiting = await chatMessages.undigested(limit: trigger.maxItems * 4);
    final inScope = trigger.scope.isEmpty
        ? waiting
        : waiting
            .where((m) => trigger.scope.admits(
                  sender: m.sender ?? m.conversationTitle,
                  text: '${m.conversationTitle ?? ''} ${m.displayBody}',
                ),
              )
              .toList();
    if (inScope.isEmpty) return null;

    final take = inScope.length > trigger.maxItems
        ? trigger.maxItems
        : inScope.length;
    final batch = inScope.take(take).map((m) => m.id).toList();
    final chats = inScope
        .take(take)
        .map((m) => m.conversationTitle ?? m.conversationId)
        .toSet();

    final summary = await _runAgentTurn(
      'Digest my chat messages: read up to $take undigested messages with '
      'read_message_context (undigested_only true, limit $take), pull out '
      'tasks, meetings, and deadlines into the right tools, mark every one '
      'you processed in a single mark_message_digested call, and give me a '
      'short rundown grouped by chat. They are from: ${chats.join(', ')}. '
      'Do NOT reply to anyone. Captured messages can be truncated - say so '
      'if you are unsure what one said rather than guessing. Some messages '
      'are photos or voice notes and carry a media array. For each photo, '
      'call read_message_context with its media_id to look at it, and use '
      'what it shows like message text. A transcribed voice note already '
      'reads as its words. If a photo cannot be shown to you or a voice '
      'note has no transcript, say so - never invent what a photo showed '
      'or a voice note said.',
      title: 'Chat digest',
      notificationId: 90005,
    );
    if (summary == null) {
      await diagnostics.warn(
        code: 'BEHAVIOR_TRIGGER_NO_TURN',
        message: 'Rule "${trigger.behaviorTitle}" wanted to digest '
            '${inScope.length} chat message(s), but no agent turn could run '
            '(no usable AI provider in the background, or the model '
                'called no tool and the run was discarded).',
        context: {'behavior_id': trigger.behaviorId},
      );
      return null;
    }
    await _closeOutDigestedMessages(batch, source: trigger.behaviorTitle);
    final left = await chatMessages.countUndigested();
    return (
      note: left > 0
          ? 'Digested chat messages on behalf of "${trigger.behaviorTitle}"; '
              '$left still waiting'
          : 'Digested chat messages on behalf of "${trigger.behaviorTitle}"',
      moreWork: left > 0,
    );
  }

  /// Marks the undigested messages and emails an agent turn was shown and
  /// left unmarked - the close-out for a job the user wrote themselves.
  ///
  /// The trigger paths know their batch before the turn starts. A user's own
  /// "check my chats every five minutes" job does not: the model picks the
  /// batch by calling the read tool. So the turn reports what its reads
  /// actually served ([AgentTurnResult.servedMessageIds]), and exactly those
  /// are closed out. A small model that reads, files its tasks and then
  /// marks `{"chat": "whatsapp"}` - zero rows, reported as success - would
  /// otherwise be handed the identical batch on every run.
  ///
  /// Skipped when a write the turn attempted did not go through: those
  /// messages still have something owed, and leaving them unmarked is what
  /// gets it retried. The duplicate guard on unattended creates is what
  /// makes that retry safe for the writes that did succeed.
  Future<void> _closeOutServedItems(
    AgentTurnResult result, {
    required String source,
  }) async {
    if (result.servedMessageIds.isEmpty && result.servedEmailIds.isEmpty) {
      return;
    }
    final writeFailed = result.executionRecords.any((record) =>
        !record.isControlPlane &&
        record.status != ToolExecutionStatus.success &&
        _owesWork(record.toolName, record.arguments));
    if (writeFailed) {
      await diagnostics.record(
        code: 'DIGEST_CLOSE_OUT_SKIPPED',
        message: '"$source" read new items but one of its changes did not '
            'go through, so they were left unmarked for the next run.',
        context: {'source': source},
      );
      return;
    }
    await _closeOutDigestedMessages(result.servedMessageIds, source: source);
    await _closeOutDigestedBatch(result.servedEmailIds, source: source);
  }

  /// Whether a failed call to [tool] leaves the item it came from unhandled.
  /// Bookkeeping (marking, syncing) does not: that is the very thing the
  /// close-out is standing in for.
  static bool _owesWork(String tool, Map<String, Object?> arguments) {
    final effect = WriteScope.effectOf(tool, arguments);
    return effect != null &&
        effect != WriteEffect.messageMarkDigested &&
        effect != WriteEffect.emailMarkDigested &&
        effect != WriteEffect.messageSync &&
        effect != WriteEffect.emailSync &&
        effect != WriteEffect.calendarSync;
  }

  /// The chat equivalent of [_closeOutDigestedBatch], and needed for the same
  /// reason: a model that reads a batch and forgets the bookkeeping call
  /// leaves the identical messages "new", so the next run re-reads them and
  /// the backlog never moves while every run spends a turn.
  Future<void> _closeOutDigestedMessages(
    List<String> batch, {
    required String source,
  }) async {
    if (batch.isEmpty) return;
    final missed = <String>[];
    for (final id in batch) {
      final message = await chatMessages.getById(id);
      if (message != null && !message.digested) {
        await chatMessages.markDigested(id);
        missed.add(id);
      }
    }
    if (missed.isEmpty) return;
    await diagnostics.warn(
      code: 'DIGEST_NOT_MARKED_BY_MODEL',
      message: '${missed.length} of ${batch.length} chat message(s) were read '
          'but never marked digested by the model, so "$source" marked them.',
      context: {'source': source, 'marked': missed.length, 'kind': 'chat'},
    );
  }

  /// Stable notification id for a deterministic job's report, banded away
  /// from the fixed briefing ids (90001-90003). Two jobs can share a slot
  /// (their reports replace each other), which is the intended trade for
  /// never colliding with the briefings.
  static int _reportNotificationId(String jobId) =>
      90100 + (_hash(jobId) % 100);

  /// Health notices sit in their own band so a job's failure notice never
  /// replaces its result notice.
  static int _healthNotificationId(String jobId) =>
      90300 + (_hash(jobId) % 100);

  static int _hash(String value) {
    var hash = 0;
    for (final unit in value.codeUnits) {
      hash = (hash * 31 + unit) & 0x7fffffff;
    }
    return hash;
  }

  /// Rewrites a job's one-line result the way the user's rules ask for.
  /// Null on any failure - the caller then delivers the plain result.
  ///
  /// This is a model paraphrasing a deterministic string, and it used to be
  /// guarded only by the prompt below saying "never invent detail". A paraphrase
  /// that moves a date is exactly the failure `DateConsistency` exists for, and
  /// here it is worse than in chat: nobody is watching a background job, and the
  /// notification is often the only thing the user ever reads about the run. So
  /// the rewrite is now checked against the summary it came from, and a rewrite
  /// that added a date the summary does not contain is discarded in favour of
  /// the deterministic text.
  Future<String?> _writeJobReport(
      ScheduledJob job, String summary, BehaviorContext rules) async {
    final ai = await _selectJobAi();
    if (ai == null) return null;
    try {
      final response = await ai.client.createMessage(
        apiKey: ai.apiKey,
        model: ai.model,
        system: 'You write one very short status update from a personal '
            'assistant\'s background job, for a phone notification. Plain '
            'text only, no markdown, under 300 characters. State only what '
            'the job result says - never invent detail.\n\n'
            '${rules.render()}',
        messages: [
          {
            'role': 'user',
            'content': 'Job: ${job.name} (${job.jobType})\n'
                'Result: $summary\n\nWrite the update.',
          },
        ],
        maxTokens: 512 + OpenAiCompatibleClient.headroomOf(ai.client),
      );
      final text = response.text.trim();
      if (text.isEmpty) return null;

      final outcome = const ResponseGateway().apply(
        text,
        constraints: [
          for (final behavior in rules.behaviors)
            ...OutputConstraint.fromBehavior(behavior),
        ],
        evidence: '$summary\n${job.name}\n${job.jobType}',
        maxChars: ResponseGateway.notificationBodyChars,
      );
      if (outcome.unsupportedDates.isNotEmpty) {
        await diagnostics.warn(
          code: 'JOB_REPORT_DATE_FABRICATED',
          message: 'The rewritten report for "${job.name}" stated '
              '${outcome.unsupportedDates.join(', ')}, which its own result '
              'does not contain. The deterministic result was sent instead.',
          context: {
            'job_id': job.id,
            'dates': outcome.unsupportedDates,
          },
        );
        return null;
      }
      return outcome.text;
    } catch (_) {
      return null;
    } finally {
      ai.disposable?.dispose();
    }
  }

  /// Provider selection for the job-level model calls (the briefing and the
  /// deterministic-job reports). Null when nothing can run here: on-device
  /// models need plugin channels the WorkManager isolate does not have, and
  /// reading settings can itself fail in a bare isolate - these calls are
  /// all best-effort, so a lookup failure must read as "no provider" rather
  /// than failing the job. The caller must dispose [_JobAi.disposable].
  Future<_JobAi?> _selectJobAi() async {
    try {
      final provider = await settings.getAiProvider();
      if (provider == SettingsRepository.providerLocal) {
        final local = LocalEndpointClient(
          baseUrl: await settings.getLocalBaseUrl(),
          apiKey: await settings.getLocalApiKey(),
        );
        return _JobAi(
          client: local,
          model: await settings.getLocalModel(),
          disposable: local,
        );
      }
      if (SettingsRepository.isHostedProvider(provider)) {
        final apiKey = await settings.getApiKeyForProvider(provider);
        if (apiKey == null || apiKey.isEmpty) {
          await diagnostics.warn(
            code: 'JOB_MISSING_CREDENTIALS',
            message: 'Background work needs an API key, but none is stored. '
                'Add one in Settings > AI provider.',
          );
          return null;
        }
        if (provider == SettingsRepository.providerDeepSeek) {
          // Built per job rather than shared: this can run in the WorkManager
          // isolate, which has no Riverpod container to hold one.
          final deepSeek = DeepSeekClient(
              baseUrl: await settings.getDeepSeekBaseUrl(), apiKey: apiKey);
          return _JobAi(
            client: deepSeek,
            model: await settings.getDeepSeekModel(),
            apiKey: apiKey,
            disposable: deepSeek,
          );
        }
        return _JobAi(
            client: claude, model: await settings.getModel(), apiKey: apiKey);
      }
      // On-device: expected in a background isolate, not a fault.
      await diagnostics.record(
        code: 'JOB_PROVIDER_UNAVAILABLE',
        message: 'The on-device provider cannot run in a background '
            'isolate; using the deterministic path instead.',
        context: {'provider': provider},
      );
      return null;
    } catch (e) {
      // Distinguished from "no provider configured": this is a lookup that
      // broke (secure storage unavailable, database closed), which the user
      // can act on - so it is recorded rather than silently swallowed.
      await diagnostics.warn(
        code: 'JOB_MODEL_SELECTION_FAILED',
        message: 'Could not work out which AI provider to use for '
            'background work: $e',
        error: e,
      );
      return null;
    }
  }

  /// Notification bodies go through the same gateway as everything else, so
  /// the clip rule lives in one place rather than being re-guessed per surface.
  static String _clipForNotification(String text) => const ResponseGateway()
      .apply(text, maxChars: ResponseGateway.notificationBodyChars)
      .text;

  /// Daily summary: overdue tasks, today's items, upcoming reminders, and -
  /// for the AI-enriched daily review - recently shared browser pages.
  Future<String> _runDailySummary({required bool useAi}) async {
    if (useAi) {
      // Pull fresh mail before reviewing, so the briefing sees it.
      try {
        await mail.syncAll();
      } catch (_) {}
    }
    final now = DateTime.now();
    final overdue = await tasks.listOverdue();
    final dueToday = (await tasks.list(
            openOnly: true,
            dueBefore: DateTime(now.year, now.month, now.day + 1)))
        .where((t) => !overdue.any((o) => o.id == t.id))
        .toList();
    final events = await schedule.listForDay(now);
    final upcomingReminders = (await reminders.listByStatus('Active'))
        .where((r) =>
            r.remindAt.isAfter(now) &&
            r.remindAt.isBefore(now.add(const Duration(hours: 24))))
        .toList();
    final sharedPages = useAi
        ? await browserContext
            .sharedSince(now.subtract(const Duration(hours: 24)))
        : const <BrowserContextItem>[];
    final newEmails = await emails.undigested();

    final lines = <String>[];
    if (events.isNotEmpty) {
      lines.add('Today: ${events.map((e) => '${DateFormat('HH:mm').format(
            e.startAt,
          )} ${e.title}').join(', ')}');
    }
    if (overdue.isNotEmpty) {
      lines.add(
          'Overdue: ${overdue.take(5).map((t) => t.title).join(', ')}'
          '${overdue.length > 5 ? ' (+${overdue.length - 5} more)' : ''}');
    }
    if (dueToday.isNotEmpty) {
      lines.add('Due today: '
          '${dueToday.take(5).map((t) => t.title).join(', ')}');
    }
    if (upcomingReminders.isNotEmpty) {
      lines.add('Reminders in the next 24h: '
          '${upcomingReminders.map((r) => r.title).join(', ')}');
    }
    if (newEmails.isNotEmpty) {
      lines.add('Undigested emails: '
          '${newEmails.take(5).map((e) => e.subject).join(', ')}'
          '${newEmails.length > 5 ? ' (+${newEmails.length - 5} more)' : ''}');
    }
    var summary = lines.isEmpty
        ? 'Nothing scheduled, nothing overdue. Clear day.'
        : lines.join('\n');

    if (useAi) {
      final aiSummary =
          await _tryAiSummary(summary, sharedPages, newEmails);
      if (aiSummary != null) summary = aiSummary;
    }

    final title = useAi ? 'Your daily review' : 'Your daily summary';
    await _notify(
      id: useAi ? 90002 : 90001,
      title: title,
      // A briefing can run long, and an unclipped body is truncated by the OS
      // mid-word instead. The chat copy below keeps the whole thing.
      body: _clipForNotification(summary),
      route: '/',
    );
    // Also drop it into the chat so the user can read and act on it there
    // ("snooze the first one", "mark these done").
    await chat.append('assistant', summary, meta: {
      'source': 'scheduled_job',
      'job_title': title,
    });
    // The AI review reads each new email into the briefing - that's the app
    // processing them, so mark them digested and don't re-surface them in the
    // next review. (The plain summary only lists subjects, so it leaves them.)
    if (useAi) {
      for (final email in newEmails) {
        await emails.markDigested(email.id);
      }
    }
    return summary;
  }

  /// Best-effort AI pass over the deterministic summary plus shared pages.
  /// Any failure falls back to the deterministic text - the job never
  /// breaks because the network or key is unavailable.
  Future<String?> _tryAiSummary(
    String factsSummary,
    List<BrowserContextItem> sharedPages,
    List<EmailItem> newEmails,
  ) async {
    // Match the user's selected provider. On-device models can't run in the
    // WorkManager background isolate, so those briefings fall through to the
    // deterministic summary (return null).
    final ai = await _selectJobAi();
    if (ai == null) return null;
    try {
      // This is the fallback path for the daily review, so it has to carry
      // the same rules the orchestrated turn would have applied.
      final rules = await BehaviorContext.load(
        behaviors: behaviors,
        surface: BehaviorSurface.scheduledJob,
        unattended: true,
        onlyTypes: BehaviorContext.styleTypes,
      );

      final pagesBlock = sharedPages.isEmpty
          ? 'None.'
          : sharedPages
              .map((p) => '- ${p.pageTitle ?? p.pageUrl}: '
                  '${p.contentSummary ?? ''}')
              .join('\n');
      final emailsBlock = newEmails.isEmpty
          ? 'None.'
          : newEmails
              .take(8)
              .map((e) => '- ${e.subject}'
                  '${e.sender != null ? ' (from ${e.sender})' : ''}: '
                  '${e.summary ?? ''}')
              .join('\n');

      final behaviorBlock = rules.render();
      final response = await ai.client.createMessage(
        apiKey: ai.apiKey,
        model: ai.model,
        system: 'You write very short morning briefings for a personal '
            'assistant notification. Plain text only, no markdown, under '
            '500 characters. Lead with what matters most. Mention '
            'meetings before tasks unless something is urgent. Call out '
            'any email that clearly needs a reply or contains a deadline.'
            '${behaviorBlock.isEmpty ? '' : '\n\n$behaviorBlock'}',
        messages: [
          {
            'role': 'user',
            'content': 'Today\'s facts:\n$factsSummary\n\n'
                'New emails the user added for me to digest:\n'
                '$emailsBlock\n\n'
                'Pages the user shared with me in the last 24h:\n'
                '$pagesBlock\n\nWrite the briefing.',
          },
        ],
        maxTokens: 1024 + OpenAiCompatibleClient.headroomOf(ai.client),
      );
      final text = response.text.trim();
      if (text.isEmpty) return null;

      // The highest-stakes model-written text in the app: nobody is watching,
      // and for most users this briefing is the only thing they read about the
      // day. Everything it may legitimately state is in the three blocks above,
      // so a date outside them was invented - and the fallback is a correct, if
      // plainer, deterministic summary. That is a better trade than a confident
      // briefing with the wrong day in it.
      final outcome = const ResponseGateway().apply(
        text,
        constraints: [
          for (final behavior in rules.behaviors)
            ...OutputConstraint.fromBehavior(behavior),
        ],
        evidence: '$factsSummary\n$emailsBlock\n$pagesBlock',
      );
      if (outcome.unsupportedDates.isNotEmpty) {
        await diagnostics.warn(
          code: 'BRIEFING_DATE_FABRICATED',
          message: 'The daily briefing stated '
              '${outcome.unsupportedDates.join(', ')}, which none of its own '
              'inputs contain. The deterministic summary was sent instead.',
          context: {'dates': outcome.unsupportedDates},
        );
        return null;
      }
      return outcome.text;
    } catch (_) {
      return null;
    } finally {
      ai.disposable?.dispose();
    }
  }

  /// Flags open tasks whose due date passed as Overdue.
  Future<String> _runTaskCleanup(ScheduledJob job) async {
    final overdue = await tasks.listOverdue();
    var flagged = 0;
    for (final task in overdue) {
      if (task.status != 'Overdue') {
        await tasks.update(task.id, status: 'Overdue');
        flagged++;
      }
    }
    final summary = 'Flagged $flagged task(s) as overdue.';
    await _reportDeterministic(job, summary, changed: flagged > 0);
    return summary;
  }

  /// Fetches mail, then hands over to any behavior armed for new mail.
  ///
  /// A sync that could not reach a single account fails the run: it used to
  /// return the error as text, which recorded a green "Success" in the job
  /// history and meant the retry and dead-letter logic never engaged for the
  /// one failure mode that actually needs them.
  Future<String> _runEmailSync(ScheduledJob job) async {
    // A mail account whose password changed fails identically every two
    // minutes. The ledger dutifully retries and dead-letters each
    // occurrence separately, which from the provider's side is a login
    // attempt every two minutes and from the user's side is a notification
    // storm about one problem. The breaker notices, stops, and probes.
    final breaker = circuits;
    if (!await breaker.allows(ServiceNames.mail)) {
      final status = await breaker.statusOf(ServiceNames.mail);
      return 'Mail sync is paused until ${status.retryAfter} after '
          '${status.consecutiveFailures} failures '
          '(${status.failureKind ?? 'unknown'}). It resumes on its own once '
          'the account works again.';
    }

    final result = await mail.syncAllDetailed();
    if (result.failedCompletely) {
      final status = await breaker.recordFailure(
        ServiceNames.mail,
        kind: ToolRecoveryPolicy.classify(error: result.errors.join('; ')),
      );
      if (status.state == CircuitState.open &&
          await breaker.shouldNotify(ServiceNames.mail)) {
        // Told once, and as a health problem: an account that stopped
        // working is not content, so quiet hours must not hide it.
        await _notify(
          id: 90010,
          title: 'Mail sync has stopped',
          body: 'Your mail account failed '
              '${status.consecutiveFailures} times in a row. Open '
              'Settings > Mail accounts to fix it.',
          route: '/settings/mail-accounts',
          channel: NotificationPolicy.channelSystemHealth,
        );
      }
      throw StateError(result.errors.join('; '));
    }
    await breaker.recordSuccess(ServiceNames.mail);
    await _reportDeterministic(
      job,
      result.summary,
      changed: result.hasChanges,
      failed: result.hasErrors,
    );
    // "Digest my email when it arrives" is a rule the app has to act on;
    // it cannot act on itself, because this job never runs a model turn.
    final triggered = await _fireTriggers(BehaviorTrigger.eventNewMail);
    return triggered == null ? result.summary : '${result.summary}. $triggered';
  }

  /// Drains captured chat messages, transcribes the voice notes that drain
  /// stored, then hands over to any behavior armed for new messages.
  ///
  /// Unlike [_runEmailSync] there is nothing in the drain itself that can fail
  /// the way a mail login can: the source is a local file written by the
  /// notification listener, and an unreadable one is retried on the next tick.
  /// So the drain keeps no breaker — a breaker with no failure mode to break
  /// on is a notification the user gets for nothing.
  ///
  /// The transcription pass that runs after it has every reason for one: it is
  /// a model call to the user's local AI server, made once per voice note,
  /// from a job that wakes every couple of minutes. So it is gated on
  /// [ServiceNames.transcription] and given a slice of the job's remaining
  /// time, never the whole of it.
  Future<String> _runMessageSync(ScheduledJob job) async {
    final result = await messageIngest.syncAllDetailed();
    final transcription =
        await _transcribeVoiceNotes(job, mediaStored: result.mediaStored);
    final summary = transcription.line == null
        ? result.summary
        : '${result.summary} ${transcription.line}';
    await _reportDeterministic(
      job,
      summary,
      changed: result.hasChanges || transcription.transcribed > 0,
      failed: result.hasErrors || transcription.failed,
    );
    final triggered = await _fireTriggers(BehaviorTrigger.eventNewMessage);
    return triggered == null ? summary : '$summary. $triggered';
  }

  /// Runs the voice-note transcription pass and says what it did, in one
  /// sentence the job report can carry.
  ///
  /// Three states the user has to be able to tell apart, because each is a
  /// different action for them: paused (the endpoint failed three passes in a
  /// row and is being probed on its own), unavailable (there is no transcription
  /// endpoint to talk to at all), or working (here is what moved and what did
  /// not). Only the first is a failure of the run.
  ///
  /// The breaker is told only about passes that actually spoke to the
  /// endpoint. "Nothing was waiting" and "no media directory" are not endpoint
  /// faults, and a pass that only skipped rows proves nothing about the
  /// server — recording either as a success would keep a broken endpoint's
  /// breaker closed forever, and recording it as a failure would pause
  /// transcription on a phone that has nothing to transcribe.
  Future<({String? line, bool failed, int transcribed})> _transcribeVoiceNotes(
    ScheduledJob job, {
    required int mediaStored,
    Duration ceiling = transcriptionCeiling,
  }) async {
    final breaker = circuits;
    if (!await breaker.allows(ServiceNames.transcription)) {
      final status = await breaker.statusOf(ServiceNames.transcription);
      return (
        line: 'Voice-note transcription is paused until '
            '${status.retryAfter} after ${status.consecutiveFailures} '
            'failures (${status.failureKind ?? 'unreachable'}). It probes the '
            'local AI server on its own and resumes once that answers.',
        failed: true,
        transcribed: 0,
      );
    }

    final pass = await messageIngest.transcribePending(
      timeBudget: _transcriptionTimeBudget(ceiling),
    );

    if (pass.blockedWith != null) {
      // Say it only when this run captured audio that is therefore going
      // nowhere. The same line every two minutes on a phone whose user never
      // set a local AI server is noise, and one line per run that stored
      // audio is exactly the news.
      if (mediaStored == 0) {
        return (line: null, failed: false, transcribed: 0);
      }
      await diagnostics.record(
        code: 'TRANSCRIPTION_UNAVAILABLE',
        message: "'${job.name}' stored voice notes, but voice-note "
            'transcription is unavailable, so no audio was turned into text.',
        context: {
          'job_id': job.id,
          'job_type': job.jobType,
          'media_stored': mediaStored,
        },
      );
      return (line: pass.summary, failed: false, transcribed: 0);
    }

    if (pass.attempted > 0) {
      if (pass.hasErrors) {
        await breaker.recordFailure(ServiceNames.transcription);
        // Counts and a job name only. The provider's own error body, a
        // signed URL and the transcript itself are all outside content this
        // log must not carry into a report the model reads.
        await diagnostics.warn(
          code: 'TRANSCRIPTION_FAILED',
          message: "Voice-note transcription in '${job.name}' failed on "
              '${pass.failed} of ${pass.attempted} attempt(s): the local AI '
              'server did not answer. Those voice notes stay undigested with '
              'their size-and-format note and are tried again, up to three '
              'attempts each.',
          context: {
            'job_id': job.id,
            'job_type': job.jobType,
            'attempted': pass.attempted,
            'failed': pass.failed,
            'transcribed': pass.transcribed,
          },
        );
      } else {
        await breaker.recordSuccess(ServiceNames.transcription);
      }
    }

    // A pass that asked something, or refused to ask because a name was not a
    // sidecar it may open, is worth a line. The steady state — nothing waiting
    // — is not, and the drain's own summary already said whether anything came.
    if (pass.attempted == 0 && pass.skipped == 0) {
      return (line: null, failed: false, transcribed: pass.transcribed);
    }
    return (
      line: pass.summary,
      failed: pass.hasErrors,
      transcribed: pass.transcribed,
    );
  }

  /// Ceiling on one transcription pass inside a chat-sync run.
  ///
  /// A whisper run on a phone grinds, and a backlog of voice notes must not be
  /// able to eat a job that also has mail, calendar and the user's own digest
  /// rules waiting behind it. Anything not transcribed inside the slice is
  /// still pending next run — which is what the durable attempt state is for.
  static const transcriptionCeiling = Duration(minutes: 3);

  /// Ceiling on the pass an agent task runs before its model turn. Shorter
  /// than [transcriptionCeiling]: the turn itself needs most of the run's
  /// budget on a slow local model, and notes left over go next run.
  static const agentTaskTranscriptionCeiling = Duration(seconds: 90);

  /// The slice of the current job's remaining time to give the pass: half of
  /// what is left, under [transcriptionCeiling]. Null when the caller imposed
  /// no limit (a foreground "Run now"), in which case the pass is bounded by
  /// its own item cap and the transcriber's per-call timeout instead.
  Duration? _transcriptionTimeBudget([
    Duration ceiling = transcriptionCeiling,
  ]) {
    final deadline = _activeRunDeadline;
    if (deadline == null) return null;
    final left = deadline.difference(DateTime.now());
    if (left <= Duration.zero) return Duration.zero;
    final half = Duration(microseconds: left.inMicroseconds ~/ 2);
    return half > ceiling ? ceiling : half;
  }

  Future<String> _runCalendarSync(ScheduledJob job) async {
    final result = await deviceCalendar.import();
    if (result.error != null) throw StateError(result.error!);
    await _reportDeterministic(
      job,
      result.summary,
      changed: result.imported > 0 || result.updated > 0,
    );
    return result.summary;
  }
}

class JobRunOutcome {
  final bool success;
  final String summary;

  /// True when nothing ran because the occurrence was already claimed or
  /// finished - not a failure, and not work either.
  final bool wasSkipped;

  const JobRunOutcome({
    required this.success,
    required this.summary,
    this.wasSkipped = false,
  });
}

/// A provider ready for a job-level model call. [disposable] is the client
/// this selection created and the caller must dispose (null when reusing a
/// shared one).
class _JobAi {
  const _JobAi({
    required this.client,
    required this.model,
    this.apiKey,
    this.disposable,
  });

  final AiClient client;
  final String model;
  final String? apiKey;
  final AiClient? disposable;
}

/// An agent turn for one of the user's own jobs that ended without calling
/// a tool (see [AgentTurnResult.didNothing]). Its message is what the Job
/// history shows for the failed attempt.
class _IdleAgentRun implements Exception {
  const _IdleAgentRun();

  @override
  String toString() =>
      'The AI answered without checking anything, so this run did no work. '
      'It will be tried again.';
}
