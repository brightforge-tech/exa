import 'dart:async';

import 'package:android_alarm_manager_plus/android_alarm_manager_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'agent/behaviors/notification_policy.dart';
import 'app.dart';
import 'data/database/app_database.dart';
import 'data/repositories/behavior_repository.dart';
import 'data/repositories/diagnostics_repository.dart';
import 'data/repositories/reminder_repository.dart';
import 'data/repositories/schedule_repository.dart';
import 'data/repositories/settings_repository.dart';
import 'data/repositories/task_repository.dart';
import 'device/device_bridge.dart';
import 'device/device_owner_backend.dart';
import 'job_service_main.dart';
import 'overlay_main.dart';
import 'services/background_jobs/background_worker.dart';
import 'services/background_jobs/brief_alarm.dart';
import 'services/calendar/calendar_sync_service.dart';
import 'services/calendar/device_calendar_service.dart';
import 'services/notifications/notification_service.dart';
import 'services/push_watchdog/push_watchdog.dart';
import 'shared/providers.dart';

/// Keeps the overlay entry point in the compiled app.
///
/// `ExaOverlayService` starts its second FlutterEngine by looking `overlayMain`
/// up by name at runtime, but the compiler only builds libraries reachable from
/// this one - and nothing else imports `overlay_main.dart`. Without this
/// reference the whole overlay UI is dropped from the snapshot and the bubble's
/// panels open as invisible windows that swallow every touch.
const overlayEntrypoint = overlayMain;

/// Keeps the job service's entry point in the compiled app, for the same
/// reason: `ExaJobService` looks `jobServiceMain` up by name.
const jobServiceEntrypoint = jobServiceMain;

/// Shown when startup failed before the app could exist. Deliberately plain -
/// no theme, no providers, nothing that could itself fail here.
class _StartupFailureApp extends StatelessWidget {
  const _StartupFailureApp({required this.error, required this.stack});

  final Object error;
  final StackTrace stack;

  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          body: SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Exa could not start',
                      style: TextStyle(
                          fontSize: 22, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  const Text('Its database would not open. The details below '
                      'are what to report.'),
                  const SizedBox(height: 16),
                  SelectableText('$error',
                      style: const TextStyle(
                          fontFamily: 'monospace', fontSize: 12)),
                  const SizedBox(height: 16),
                  SelectableText('$stack',
                      style: const TextStyle(
                          fontFamily: 'monospace', fontSize: 10)),
                ],
              ),
            ),
          ),
        ),
      );
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final database = AppDatabase();
  try {
    await database.open();
  } catch (error, stack) {
    // Opening the database was the one step in this function that could throw
    // past `runApp`, and a `main` that throws is a launch with no window and
    // no explanation - indistinguishable, to the user, from the app being
    // broken. Show what happened instead: on a device with no cable attached,
    // this text is the only diagnosis available.
    runApp(_StartupFailureApp(error: error, stack: stack));
    return;
  }

  // flutter_gemma is NOT initialized here. Its init probes MediaPipe's native
  // GPU delegates, which can abort the process on devices without a usable
  // driver - unlaunchable app, for a feature the user may never enable. It is
  // now initialized on first use of the on-device provider instead; see
  // [OnDeviceRuntime].

  final notificationService = NotificationService();
  // The user's notification_rule behaviors (quiet hours) are enforced here
  // rather than only read as prompt text. Wired after construction: the
  // service is built before the repositories exist.
  notificationService.policyLoader =
      () => NotificationPolicy.load(BehaviorRepository(database));
  String? launchRoute;
  try {
    await notificationService.init();
    launchRoute = await notificationService.consumeLaunchRoute();
    // Reminders must survive app restarts: re-register every active
    // notification with the OS on launch.
    final reminderRepository = ReminderRepository(database);
    final active = await reminderRepository.listByStatus('Active');
    await notificationService.rescheduleAll(active);
    // Event alerts likewise don't survive restarts - re-register upcoming
    // in-app events (device-calendar events are skipped inside the service).
    final scheduleRepository = ScheduleRepository(database);
    final now = DateTime.now();
    final upcoming = await scheduleRepository.listBetween(
        now, now.add(const Duration(days: 30)));
    await notificationService.rescheduleAllEvents(upcoming);

    // Phone-calendar mirroring self-heal: pick up items that appeared
    // without going through a synced path (e.g. recurring-task spawns).
    // Skips silently when sync is off or permission isn't granted - it
    // never prompts at startup.
    final taskRepository = TaskRepository(database);
    final calendarSync = CalendarSyncService(
      deviceCalendar: DeviceCalendarService(
          schedule: scheduleRepository, tasks: taskRepository),
      schedule: scheduleRepository,
      tasks: taskRepository,
      settings: SettingsRepository(database),
    );
    unawaited(calendarSync.syncPending());
  } catch (_) {
    // Notifications are best-effort; the rest of the app works without them.
  }

  try {
    // Periodic background tick that runs due scheduled jobs (Phase 3) -
    // the catch-up safety net.
    await registerBackgroundJobs();
  } catch (_) {
    // Background scheduling is unavailable on some platforms/emulators;
    // jobs can still be run manually from the Jobs screen.
  }

  try {
    // Exact-time alarm layer: fires the daily brief on the dot even in
    // Doze. Additive over WorkManager.
    await AndroidAlarmManager.initialize();
    await BriefAlarm.rearm(database);
  } catch (_) {
    // Falls back to the WorkManager tick if alarms are unavailable.
  }

  runApp(
    ProviderScope(
      overrides: [
        appDatabaseProvider.overrideWithValue(database),
        notificationServiceProvider.overrideWithValue(notificationService),
        launchRouteProvider.overrideWithValue(launchRoute),
      ],
      child: const ExaApp(),
    ),
  );

  // Opening Exa is often what a person does when notifications look dead,
  // so the push watchdog gets a turn here as well as on the background
  // tick. After runApp: it needs nothing the UI does, and must not delay
  // the first frame.
  unawaited(PushWatchdog(
    push: DeviceOwnerBackend(const DeviceBridge()).push,
    settings: SettingsRepository(database),
    diagnostics: DiagnosticsRepository(database),
    notifications: notificationService,
  ).check());
}
