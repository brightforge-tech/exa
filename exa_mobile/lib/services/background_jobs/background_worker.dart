import 'package:workmanager/workmanager.dart';

import '../../agent/behaviors/notification_policy.dart';
import '../../agent/orchestrator/agent_intelligence.dart';
import '../../agent/orchestrator/agent_orchestrator.dart';
import '../../agent/tools/tool_registry.dart';
import '../../data/database/app_database.dart';
import '../../data/repositories/behavior_repository.dart';
import '../../data/repositories/browser_context_repository.dart';
import '../../data/repositories/chat_repository.dart';
import '../../data/repositories/diagnostics_repository.dart';
import '../../data/repositories/dynamic_screen_repository.dart';
import '../../data/repositories/email_repository.dart';
import '../../data/repositories/idempotency_repository.dart';
import '../../data/repositories/job_repository.dart';
import '../../data/repositories/mail_account_repository.dart';
import '../../data/repositories/pending_calendar_repository.dart';
import '../../data/repositories/reminder_repository.dart';
import '../../data/repositories/schedule_repository.dart';
import '../../data/repositories/settings_repository.dart';
import '../../data/repositories/task_repository.dart';
import '../../data/repositories/tool_call_repository.dart';
import '../../device/device_bridge.dart';
import '../../device/device_owner_backend.dart';
import '../ai_client/claude_client.dart';
import '../ai_client/deepseek_client.dart';
import '../ai_client/local_endpoint_client.dart';
import '../browser/browser_bridge.dart';
import '../calendar/device_calendar_service.dart';
import '../mail/mail_service.dart';
import '../notifications/notification_service.dart';
import '../push_watchdog/push_watchdog.dart';
import '../transcription/audio_transcriber.dart';
import 'brief_alarm.dart';
import 'job_runner.dart';

const periodicTaskName = 'exa-job-tick';

/// One-off task enqueued by [BriefAlarm] when an exact alarm fires. The alarm
/// itself cannot hold a wakelock across its Dart callback, so the run happens
/// here, under the WorkManager job's wakelock - see brief_alarm.dart.
const alarmTaskName = 'exa-job-alarm';

/// Builds the full agent stack (tool registry + intelligence layer +
/// orchestrator) over an already-open database, and wires it into [runner]
/// so jobs that run as agent turns (daily_review) get the same pipeline as
/// chat turns. The registry needs the runner (for the scheduled-job tools),
/// and the orchestrator needs the registry - hence wiring after the fact.
///
/// No on-device client is passed: embedded models cannot run in the
/// background isolate, and JobRunner falls back to the deterministic
/// summary for that provider anyway.
AgentOrchestrator buildJobOrchestrator({
  required AppDatabase database,
  required NotificationService notifications,
  required JobRunner runner,
}) {
  final mailAccounts = MailAccountRepository(database);
  final emails = EmailRepository(database);
  final schedule = ScheduleRepository(database);
  final settings = SettingsRepository(database);
  final registry = ToolRegistry(
    tasks: TaskRepository(database),
    reminders: ReminderRepository(database),
    schedule: schedule,
    behaviors: BehaviorRepository(database),
    screens: DynamicScreenRepository(database),
    toolCalls: ToolCallRepository(database),
    notifications: notifications,
    database: database,
    jobs: JobRepository(database),
    jobRunner: runner,
    browserContext: BrowserContextRepository(database),
    emails: emails,
    browserBridge: BrowserBridge(),
    mailAccounts: mailAccounts,
    mail: MailService(accounts: mailAccounts, emails: emails),
    deviceCalendar: DeviceCalendarService(
        schedule: schedule, tasks: TaskRepository(database)),
    pendingCalendar: PendingCalendarRepository(database),
    idempotency: IdempotencyRepository(database),
  );
  return AgentOrchestrator(
    client: ClaudeClient(),
    deepSeekClient: DeepSeekClient(),
    localClient: LocalEndpointClient(baseUrl: ''),
    registry: registry,
    chat: ChatRepository(database),
    behaviors: BehaviorRepository(database),
    settings: settings,
    // A job turn that is handed a voice note hears it the same way a chat
    // turn does. The endpoint is read per call, so a job run that starts
    // before the user configures a server and one after behave differently -
    // and correctly - with no restart.
    audioTranscriber: OpenAiAudioTranscriber(settings: settings),
    intelligence:
        AgentIntelligence.standard(database: database, registry: registry),
  );
}

/// Entry point for the WorkManager background isolate. Runs for the periodic
/// tick (Android wakes the app roughly every 15 minutes) and for the one-off
/// task an exact alarm enqueues; either way, whatever scheduled jobs are due
/// run here, and JobScheduler holds a wakelock for the whole run.
@pragma('vm:entry-point')
void backgroundJobDispatcher() {
  Workmanager().executeTask((taskName, inputData) async {
    try {
      // The ledger records what woke the run; an alarm-enqueued task is
      // still an alarm run even though WorkManager executes it.
      // Budgeted: JobScheduler stops this worker after about ten minutes,
      // and a stopped worker kills the isolate mid-run (see workerBudget).
      await runBackgroundPass(
        triggerSource: taskName == alarmTaskName ? 'alarm' : 'worker',
        budget: JobRunner.workerBudget,
      );
      return true;
    } catch (_) {
      // Returning false lets WorkManager apply its retry/backoff policy.
      return false;
    }
  });
}

/// Everything one background wake-up does: run what is due, then the
/// housekeeping that keeps the next wake-up possible.
///
/// Shared by the WorkManager worker and the foreground job service, which
/// differ only in how long they may take. [budget] covers every pass
/// together. More than one pass is for a host that can afford it: a job that
/// came due while the first pass was running is then run before the host
/// stops, instead of waiting on the next alarm ([shouldRunAgain] says an
/// alarm fired meanwhile; a due job is found either way).
Future<void> runBackgroundPass({
  required String triggerSource,
  required Duration budget,
  int passes = 1,
  bool Function()? shouldRunAgain,
  Future<void> Function(String text)? onStatus,
}) async {
  final startedAt = DateTime.now();
  final database = AppDatabase();
  await database.open();
  final notifications = NotificationService();
  notifications.policyLoader =
      () => NotificationPolicy.load(BehaviorRepository(database));
  await notifications.init(requestPermissions: false);
  final runner = JobRunner(database: database, notifications: notifications);
  // Agent-turn jobs (daily_review) run through the same intelligence
  // pipeline as chat turns. Lazy: the stack is only built if a due job
  // actually asks for the orchestrator.
  AgentOrchestrator? orchestrator;
  runner.orchestratorFactory = () => orchestrator ??= buildJobOrchestrator(
      database: database, notifications: notifications, runner: runner);
  runner.onJobStarting = onStatus == null
      ? null
      : (job) => onStatus('Running ${job.name}');

  for (var pass = 0; pass < passes; pass++) {
    final left = budget - DateTime.now().difference(startedAt);
    if (left < JobRunner.minRunSlice) break;
    final executed =
        await runner.runDueJobs(triggerSource: triggerSource, budget: left);
    final again = shouldRunAgain?.call() ?? false;
    if (executed == 0 && !again) break;
    if ((await JobRepository(database).listDue()).isEmpty) break;
  }

  // Keep the phone's push connection alive. The device plugin is
  // registered in this isolate's engine too, which is what makes a check
  // from the background possible at all. Never fails the tick: the
  // watchdog swallows and records its own errors.
  await PushWatchdog(
    push: DeviceOwnerBackend(const DeviceBridge()).push,
    settings: SettingsRepository(database),
    diagnostics: DiagnosticsRepository(database),
    notifications: notifications,
  ).check();
  // Re-register active reminders so recurrences the OS can't auto-repeat
  // (monthly) roll forward to their next occurrence. Idempotent: stable
  // notification ids mean daily/weekly just re-register unchanged.
  final active = await ReminderRepository(database).listByStatus('Active');
  await notifications.rescheduleAll(active);
  // Keep the exact-time alarm armed for the next upcoming job.
  await BriefAlarm.rearm(database);
  // Deliberately NO database.close() here: sqflite shares one native
  // connection per database file across the whole process, so closing it
  // in this background isolate would also close it for the running app
  // (every screen then fails with "database_closed"). Leaving it open is
  // the correct sqflite multi-isolate pattern.
}

/// Registers the periodic background tick (call once at app start).
///
/// `update`, not `keep`: with `keep` a tick registered once at 15 minutes
/// stays at 15 minutes forever, whatever this code later says (the plugin
/// documents that trap). `update` rewrites the request in place and
/// preserves the next run time, so it is safe on every launch.
Future<void> registerBackgroundJobs() async {
  await Workmanager().initialize(backgroundJobDispatcher);
  await Workmanager().registerPeriodicTask(
    periodicTaskName,
    periodicTaskName,
    frequency: const Duration(minutes: 15),
    existingWorkPolicy: ExistingPeriodicWorkPolicy.update,
    constraints: Constraints(networkType: NetworkType.notRequired),
  );
}
