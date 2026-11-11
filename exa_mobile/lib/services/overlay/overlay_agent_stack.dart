import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../agent/orchestrator/agent_intelligence.dart';
import '../../agent/orchestrator/agent_orchestrator.dart';
import '../../agent/tools/tool_registry.dart';
import '../../data/database/app_database.dart';
import '../../data/repositories/attachment_repository.dart';
import '../../data/repositories/behavior_repository.dart';
import '../../data/repositories/browser_context_repository.dart';
import '../../data/repositories/chat_repository.dart';
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
import '../ai_client/claude_client.dart';
import '../ai_client/deepseek_client.dart';
import '../ai_client/local_endpoint_client.dart';
import '../background_jobs/job_runner.dart';
import '../browser/browser_bridge.dart';
import '../calendar/calendar_sync_service.dart';
import '../calendar/device_calendar_service.dart';
import '../mail/mail_service.dart';
import '../notifications/notification_service.dart';
import '../transcription/audio_transcriber.dart';

/// Providers for the overlay FlutterEngine (`overlayMain`). This engine has
/// its own Riverpod scope; DO NOT import `shared/providers.dart` here - that
/// graph drags in flutter_gemma (which cannot run in a secondary engine) and
/// main-app UI state. The three base providers below are overridden with the
/// real instances in `overlayMain`.
final overlayDatabaseProvider =
    Provider<AppDatabase>((ref) => throw UnimplementedError());
final overlayNotificationsProvider =
    Provider<NotificationService>((ref) => throw UnimplementedError());
final overlayOrchestratorProvider =
    Provider<AgentOrchestrator>((ref) => throw UnimplementedError());

final overlayChatRepositoryProvider =
    Provider((ref) => ChatRepository(ref.watch(overlayDatabaseProvider)));
final overlayTaskRepositoryProvider =
    Provider((ref) => TaskRepository(ref.watch(overlayDatabaseProvider)));
final overlayReminderRepositoryProvider =
    Provider((ref) => ReminderRepository(ref.watch(overlayDatabaseProvider)));
final overlayToolCallRepositoryProvider =
    Provider((ref) => ToolCallRepository(ref.watch(overlayDatabaseProvider)));
final overlayAttachmentRepositoryProvider = Provider(
    (ref) => AttachmentRepository(ref.watch(overlayDatabaseProvider)));
final overlaySettingsRepositoryProvider =
    Provider((ref) => SettingsRepository(ref.watch(overlayDatabaseProvider)));
final overlayScheduleRepositoryProvider =
    Provider((ref) => ScheduleRepository(ref.watch(overlayDatabaseProvider)));

final overlayCalendarSyncProvider = Provider((ref) {
  final schedule = ref.watch(overlayScheduleRepositoryProvider);
  final tasks = ref.watch(overlayTaskRepositoryProvider);
  return CalendarSyncService(
    deviceCalendar: DeviceCalendarService(schedule: schedule, tasks: tasks),
    schedule: schedule,
    tasks: tasks,
    settings: ref.watch(overlaySettingsRepositoryProvider),
  );
});

/// Builds the full agent stack for the overlay engine - the same pipeline as
/// chat turns in the main app, including the intelligence layer (domain
/// routing, completion contracts, entity graph, memory, verification,
/// idempotency). Mirrors `buildJobOrchestrator` in
/// `services/background_jobs/background_worker.dart` with two deltas:
///  - the intelligence layer is always attached (overlay turns must follow
///    the exact same rules as in-app turns), and
///  - `calendarSync` + permission gating are wired like the main app's
///    `toolRegistryProvider`, since overlay turns are user-interactive.
///
/// No on-device client: flutter_gemma cannot run in a secondary engine, so
/// vision turns force the remote client (see `AgentOrchestrator.run`'s
/// `requireVision`).
AgentOrchestrator buildOverlayOrchestrator({
  required AppDatabase database,
  required NotificationService notifications,
}) {
  final mailAccounts = MailAccountRepository(database);
  final emails = EmailRepository(database);
  final schedule = ScheduleRepository(database);
  final tasks = TaskRepository(database);
  final settings = SettingsRepository(database);
  final deviceCalendar =
      DeviceCalendarService(schedule: schedule, tasks: tasks);
  final runner = JobRunner(database: database, notifications: notifications);
  final registry = ToolRegistry(
    tasks: tasks,
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
    deviceCalendar: deviceCalendar,
    calendarSync: CalendarSyncService(
      deviceCalendar: deviceCalendar,
      schedule: schedule,
      tasks: tasks,
      settings: settings,
    ),
    pendingCalendar: PendingCalendarRepository(database),
    attachments: AttachmentRepository(database),
    idempotency: IdempotencyRepository(database),
    isPermissionEnabled: settings.isPermissionEnabled,
  );
  final orchestrator = AgentOrchestrator(
    client: ClaudeClient(),
    deepSeekClient: DeepSeekClient(),
    localClient: LocalEndpointClient(baseUrl: ''),
    registry: registry,
    chat: ChatRepository(database),
    behaviors: BehaviorRepository(database),
    settings: settings,
    // A voice note attached to an overlay turn gets the same treatment as in
    // the main app: transcribed by the local server the user set, never
    // forwarded as audio.
    audioTranscriber: OpenAiAudioTranscriber(settings: settings),
    intelligence:
        AgentIntelligence.standard(database: database, registry: registry),
  );
  runner.orchestratorFactory = () => orchestrator;
  return orchestrator;
}
