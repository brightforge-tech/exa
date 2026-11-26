import 'package:flutter/material.dart';

import 'data/database/app_database.dart';
import 'data/repositories/behavior_repository.dart';
import 'agent/behaviors/notification_policy.dart';
import 'data/repositories/chat_repository.dart';
import 'features/voice/voice_session.dart';
import 'services/notifications/notification_service.dart';
import 'services/overlay/overlay_agent_stack.dart';
import 'shared/theme/exa_theme.dart';

/// Entry point for `VoiceActivity`: the side button, "Hey Exa", and spoken
/// follow-ups - shown over the lock screen when the phone is locked.
///
/// Builds the same headless agent stack as the overlay engine (no
/// on-device model, no main-app UI state), and nothing else: from here the
/// only thing a person holding a locked phone can reach is this
/// conversation.
@pragma('vm:entry-point')
Future<void> voiceMain() async {
  WidgetsFlutterBinding.ensureInitialized();
  final database = AppDatabase();
  await database.open();
  // Never closed here: sqflite shares one connection per file across the
  // process (see overlayMain).
  final notifications = NotificationService();
  await notifications.init(requestPermissions: false);
  notifications.policyLoader =
      () => NotificationPolicy.load(BehaviorRepository(database));
  final orchestrator = buildOverlayOrchestrator(
    database: database,
    notifications: notifications,
  );
  final theme = buildExaDarkTheme();
  runApp(MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: theme,
    darkTheme: theme,
    themeMode: ThemeMode.dark,
    home: VoiceSessionScreen(
      controller: VoiceSessionController(
        orchestrator: orchestrator,
        chat: ChatRepository(database),
      ),
    ),
  ));
}
