import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../agent/memory/memory_repository.dart';
import '../agent/orchestrator/agent_intelligence.dart';
import '../agent/orchestrator/agent_orchestrator.dart';
import '../agent/tools/tool_registry.dart';
import '../data/database/app_database.dart';
import '../data/repositories/idempotency_repository.dart';
import '../data/repositories/attachment_repository.dart';
import '../data/repositories/audit_repository.dart';
import '../data/repositories/behavior_repository.dart';
import '../data/repositories/diagnostics_repository.dart';
import '../data/repositories/browser_context_repository.dart';
import '../data/repositories/chat_repository.dart';
import '../data/repositories/day_plan_repository.dart';
import '../data/models/dynamic_screen.dart';
import '../data/repositories/connected_account_repository.dart';
import '../data/repositories/dynamic_screen_repository.dart';
import '../data/repositories/email_repository.dart';
import '../data/repositories/user_collection_repository.dart';
import '../data/repositories/inbound_media_repository.dart';
import '../data/repositories/inbound_message_repository.dart';
import '../data/repositories/job_repository.dart';
import '../data/repositories/provenance_repository.dart';
import '../data/repositories/mail_account_repository.dart';
import '../data/repositories/pending_calendar_repository.dart';
import '../data/repositories/reminder_repository.dart';
import '../data/repositories/schedule_repository.dart';
import '../data/repositories/settings_repository.dart';
import '../data/repositories/task_repository.dart';
import '../data/repositories/tool_call_repository.dart';
import '../data/repositories/transcript_repository.dart';
import '../data/models/transcript.dart';
import '../features/transcribe/dictation_controller.dart';
import '../services/ai_client/claude_client.dart';
import '../services/ai_client/deepseek_client.dart';
import '../services/ai_client/local_endpoint_client.dart';
import '../services/ai_client/on_device_client.dart';
import '../services/background_jobs/job_runner.dart';
import '../services/browser/browser_bridge.dart';
import '../services/calendar/calendar_sync_service.dart';
import '../services/calendar/device_calendar_service.dart';
import '../services/files/file_service.dart';
import '../services/mail/gmail_auth_service.dart';
import '../services/mail/mail_service.dart';
import '../services/messaging/message_ingest_service.dart';
import '../services/messaging/shared_intake_service.dart';
import '../services/notifications/notification_service.dart';
import '../services/transcription/audio_transcriber.dart';
import '../services/push_watchdog/push_watchdog.dart';
import '../device/device_owner_backend.dart';

/// Overridden in main() with the opened database / initialized service.
final appDatabaseProvider = Provider<AppDatabase>(
    (ref) => throw UnimplementedError('overridden in main'));
final notificationServiceProvider = Provider<NotificationService>(
    (ref) => throw UnimplementedError('overridden in main'));

/// Route to open at startup when the app was launched from a notification.
final launchRouteProvider = Provider<String?>((ref) => null);

/// Bumped when Exa is opened with a "start a voice message" request - the
/// bubble's Voice fan action and the lock-screen notification's Voice button,
/// both of which now open the real app and start listening (speech is
/// reliable in the main engine in a way it is not in the overlay engine). The
/// assistant screen listens and starts a single dictate-then-send session.
final assistantVoiceRequestProvider = StateProvider<int>((ref) => 0);

/// Bumped each time the user navigates to the Exa (assistant) tab, so the
/// chat can reload and scroll to the bottom even though its State is kept
/// alive in the nav IndexedStack and doesn't rebuild on revisit. The Exa tab
/// keeps its own tick because it also reloads from other entry points (e.g.
/// tapping a morning-brief notification).
final assistantVisitTickProvider = StateProvider<int>((ref) => 0);

/// Bumped each time the user selects a navigation tab, keyed by that tab's
/// branch index. The nav uses an IndexedStack, so a tab's screen is kept
/// alive and won't rebuild on revisit; data screens listen to their own
/// index and invalidate their data provider so anything that changed while
/// they were offstage (e.g. an event Exa added) shows up on return.
final tabVisitTickProvider =
    StateProvider.family<int, int>((ref, branchIndex) => 0);

final taskRepositoryProvider =
    Provider((ref) => TaskRepository(ref.watch(appDatabaseProvider)));
final reminderRepositoryProvider =
    Provider((ref) => ReminderRepository(ref.watch(appDatabaseProvider)));
final scheduleRepositoryProvider =
    Provider((ref) => ScheduleRepository(ref.watch(appDatabaseProvider)));
final dayPlanRepositoryProvider =
    Provider((ref) => DayPlanRepository(ref.watch(appDatabaseProvider)));
final chatRepositoryProvider =
    Provider((ref) => ChatRepository(ref.watch(appDatabaseProvider)));
final toolCallRepositoryProvider =
    Provider((ref) => ToolCallRepository(ref.watch(appDatabaseProvider)));
final behaviorRepositoryProvider =
    Provider((ref) => BehaviorRepository(ref.watch(appDatabaseProvider)));

/// Operational log of problems that are deliberately swallowed in
/// background code, surfaced on the Background reliability screen.
final diagnosticsRepositoryProvider =
    Provider((ref) => DiagnosticsRepository(ref.watch(appDatabaseProvider)));

/// Keeps Google Play services' push connection alive (Settings > Device
/// control shows its last reading; the background tick runs it).
final pushWatchdogProvider = Provider((ref) => PushWatchdog(
      push: ref.watch(deviceControlProvider).push,
      settings: ref.watch(settingsRepositoryProvider),
      diagnostics: ref.watch(diagnosticsRepositoryProvider),
      notifications: ref.watch(notificationServiceProvider),
    ));
final dynamicScreenRepositoryProvider = Provider(
    (ref) => DynamicScreenRepository(ref.watch(appDatabaseProvider)));

/// Agent-defined data collections and their records - what a built feature
/// (notes, a tracker) stores and what its screens query.
final userCollectionRepositoryProvider = Provider(
    (ref) => UserCollectionRepository(ref.watch(appDatabaseProvider)));

/// Dynamic screens the user (or Exa) has saved, surfaced as extra entries in
/// the navigation menu. Invalidated when the Exa tab is revisited so newly
/// saved screens appear without an app restart.
final savedScreensProvider =
    FutureProvider.autoDispose<List<DynamicScreen>>((ref) async {
  final all = await ref.watch(dynamicScreenRepositoryProvider).listAll();
  return all.where((screen) => screen.isSaved).toList();
});
final settingsRepositoryProvider =
    Provider((ref) => SettingsRepository(ref.watch(appDatabaseProvider)));
final attachmentRepositoryProvider =
    Provider((ref) => AttachmentRepository(ref.watch(appDatabaseProvider)));
final transcriptRepositoryProvider =
    Provider((ref) => TranscriptRepository(ref.watch(appDatabaseProvider)));

/// Saved voice transcripts, newest-edited first. Invalidated after a save or
/// delete so the Transcribe list reflects changes without an app restart.
final transcriptsProvider = FutureProvider.autoDispose<List<Transcript>>(
    (ref) => ref.watch(transcriptRepositoryProvider).list());

/// Per-screen continuous-dictation controller. autoDispose releases the
/// microphone as soon as the Transcribe editor is popped.
final dictationControllerProvider =
    StateNotifierProvider.autoDispose<DictationController, DictationState>(
        (ref) => DictationController());

final jobRepositoryProvider =
    Provider((ref) => JobRepository(ref.watch(appDatabaseProvider)));

/// Reads (and reverses) the chain behind every record the agent created.
final provenanceRepositoryProvider =
    Provider((ref) => ProvenanceRepository(ref.watch(appDatabaseProvider)));
final browserContextRepositoryProvider = Provider(
    (ref) => BrowserContextRepository(ref.watch(appDatabaseProvider)));
final connectedAccountRepositoryProvider = Provider(
    (ref) => ConnectedAccountRepository(ref.watch(appDatabaseProvider)));
final auditRepositoryProvider =
    Provider((ref) => AuditRepository(ref.watch(appDatabaseProvider)));
final emailRepositoryProvider =
    Provider((ref) => EmailRepository(ref.watch(appDatabaseProvider)));

// ------------------------------------------------------- chat messages --

final inboundMediaRepositoryProvider = Provider(
  (ref) => InboundMediaRepository(ref.watch(appDatabaseProvider)),
);

final inboundMessageRepositoryProvider = Provider(
  (ref) => InboundMessageRepository(
    ref.watch(appDatabaseProvider),
    // One lifecycle owner: message rows and their media rows are
    // created, pruned and cleared together, so the media repository
    // is part of the message repository's construction, not a
    // parallel thing callers have to remember to call.
    media: ref.watch(inboundMediaRepositoryProvider),
  ),
);

final messageIngestServiceProvider = Provider(
  (ref) => MessageIngestService(
    messages: ref.watch(inboundMessageRepositoryProvider),
    media: ref.watch(inboundMediaRepositoryProvider),
    settings: ref.watch(settingsRepositoryProvider),
    audioTranscriber: ref.watch(audioTranscriberProvider),
  ),
);

/// Routes a shared message / email / chat export to the right inbox.
/// OpenAI's hosted audio transcription endpoint, sharing the one saved key
/// with chat. Whether a key exists is checked when a pass runs, not here.
final audioTranscriberProvider = Provider((ref) => OpenAiAudioTranscriber(
      settings: ref.watch(settingsRepositoryProvider),
    ));

final sharedIntakeServiceProvider = Provider((ref) => SharedIntakeService(
      messages: ref.watch(inboundMessageRepositoryProvider),
      emails: ref.watch(emailRepositoryProvider),
      ingest: ref.watch(messageIngestServiceProvider),
    ));

/// Chats with captured messages, most recent first.
final conversationsProvider =
    FutureProvider.autoDispose<List<ConversationSummary>>(
        (ref) => ref.watch(inboundMessageRepositoryProvider).conversations());
final browserBridgeProvider = Provider((ref) => BrowserBridge());
final fileServiceProvider = Provider((ref) => FileService());
final mailAccountRepositoryProvider = Provider(
    (ref) => MailAccountRepository(ref.watch(appDatabaseProvider)));
final gmailAuthServiceProvider = Provider((ref) => GmailAuthService());
final mailServiceProvider = Provider((ref) => MailService(
      accounts: ref.watch(mailAccountRepositoryProvider),
      emails: ref.watch(emailRepositoryProvider),
      gmailAuth: ref.watch(gmailAuthServiceProvider),
    ));
final deviceCalendarServiceProvider = Provider((ref) =>
    DeviceCalendarService(
        schedule: ref.watch(scheduleRepositoryProvider),
        tasks: ref.watch(taskRepositoryProvider)));
final pendingCalendarRepositoryProvider = Provider(
    (ref) => PendingCalendarRepository(ref.watch(appDatabaseProvider)));
final calendarSyncServiceProvider = Provider((ref) => CalendarSyncService(
      deviceCalendar: ref.watch(deviceCalendarServiceProvider),
      schedule: ref.watch(scheduleRepositoryProvider),
      tasks: ref.watch(taskRepositoryProvider),
      settings: ref.watch(settingsRepositoryProvider),
    ));

final claudeClientProvider = Provider((ref) {
  final client = ClaudeClient();
  ref.onDispose(client.dispose);
  return client;
});

/// Single reused DeepSeek client; its baseUrl/apiKey are re-pointed from
/// settings by the orchestrator on each turn, like the local one.
final deepSeekClientProvider = Provider((ref) {
  final client = DeepSeekClient();
  ref.onDispose(client.dispose);
  return client;
});

/// Single reused local-endpoint client; its baseUrl/apiKey are re-pointed
/// from settings by the orchestrator on each turn.
final localEndpointClientProvider = Provider((ref) {
  final client = LocalEndpointClient(baseUrl: '');
  ref.onDispose(client.dispose);
  return client;
});

/// On-device (embedded model) client. Constructing it is cheap and does not
/// touch the native plugin until a message is actually sent.
final onDeviceClientProvider = Provider((ref) {
  final client = OnDeviceClient(ref.watch(settingsRepositoryProvider));
  ref.onDispose(client.dispose);
  return client;
});

// Explicit types on this provider trio: the lazy orchestratorFactory makes
// them mutually referential (orchestrator -> registry -> jobRunner ->
// orchestrator), which is fine at runtime but defeats type inference.
final Provider<JobRunner> jobRunnerProvider = Provider((ref) => JobRunner(
      database: ref.watch(appDatabaseProvider),
      notifications: ref.watch(notificationServiceProvider),
      claudeClient: ref.watch(claudeClientProvider),
      // Lazy (read, not watch): the orchestrator depends on the tool
      // registry, which depends on this JobRunner - resolving it at job
      // time breaks the construction cycle.
      orchestratorFactory: () => ref.read(agentOrchestratorProvider),
    ));

final idempotencyRepositoryProvider = Provider(
    (ref) => IdempotencyRepository(ref.watch(appDatabaseProvider)));

/// Memory store, exposed separately so the Settings > Memory screen can
/// review and delete memories.
final memoryRepositoryProvider =
    Provider((ref) => MemoryRepository(ref.watch(appDatabaseProvider)));

final Provider<ToolRegistry> toolRegistryProvider =
    Provider((ref) => ToolRegistry(
      tasks: ref.watch(taskRepositoryProvider),
      reminders: ref.watch(reminderRepositoryProvider),
      schedule: ref.watch(scheduleRepositoryProvider),
      behaviors: ref.watch(behaviorRepositoryProvider),
      screens: ref.watch(dynamicScreenRepositoryProvider),
      toolCalls: ref.watch(toolCallRepositoryProvider),
      notifications: ref.watch(notificationServiceProvider),
      database: ref.watch(appDatabaseProvider),
      jobs: ref.watch(jobRepositoryProvider),
      jobRunner: ref.watch(jobRunnerProvider),
      browserContext: ref.watch(browserContextRepositoryProvider),
      emails: ref.watch(emailRepositoryProvider),
      browserBridge: ref.watch(browserBridgeProvider),
      mailAccounts: ref.watch(mailAccountRepositoryProvider),
      mail: ref.watch(mailServiceProvider),
      deviceCalendar: ref.watch(deviceCalendarServiceProvider),
      pendingCalendar: ref.watch(pendingCalendarRepositoryProvider),
      calendarSync: ref.watch(calendarSyncServiceProvider),
      attachments: ref.watch(attachmentRepositoryProvider),
      chatMessages: ref.watch(inboundMessageRepositoryProvider),
      messageIngest: ref.watch(messageIngestServiceProvider),
      idempotency: ref.watch(idempotencyRepositoryProvider),
      isPermissionEnabled:
          ref.watch(settingsRepositoryProvider).isPermissionEnabled,
    ));

/// The intelligence layer bundle (entity graph, memory, skills, contracts,
/// replay) wired over the app database and tool registry.
final agentIntelligenceProvider = Provider((ref) => AgentIntelligence.standard(
      database: ref.watch(appDatabaseProvider),
      registry: ref.watch(toolRegistryProvider),
    ));

final Provider<AgentOrchestrator> agentOrchestratorProvider =
    Provider((ref) => AgentOrchestrator(
      client: ref.watch(claudeClientProvider),
      deepSeekClient: ref.watch(deepSeekClientProvider),
      localClient: ref.watch(localEndpointClientProvider),
      onDeviceClient: ref.watch(onDeviceClientProvider),
      registry: ref.watch(toolRegistryProvider),
      chat: ref.watch(chatRepositoryProvider),
      behaviors: ref.watch(behaviorRepositoryProvider),
      settings: ref.watch(settingsRepositoryProvider),
      fileService: ref.watch(fileServiceProvider),
      // Same transcriber the chat-sync pass uses, so a voice note the user
      // attaches in chat and one captured from WhatsApp are heard by the one
      // endpoint they configured.
      audioTranscriber: ref.watch(audioTranscriberProvider),
      intelligence: ref.watch(agentIntelligenceProvider),
    ));
