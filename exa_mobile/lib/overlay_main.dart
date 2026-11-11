import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'data/database/app_database.dart';
import 'features/overlay/overlay_app.dart';
import 'services/notifications/notification_service.dart';
import 'services/overlay/overlay_agent_stack.dart';

/// Entry point for the overlay FlutterEngine hosted by `ExaOverlayService`
/// (the floating bubble's chat / snippet / task panels). Started lazily when
/// a fan-menu action needs Flutter UI; destroyed after a few minutes idle.
@pragma('vm:entry-point')
Future<void> overlayMain() async {
  WidgetsFlutterBinding.ensureInitialized();
  final database = AppDatabase();
  await database.open();
  // Deliberately NO database.close() anywhere in this engine: sqflite shares
  // one native connection per database file across the whole process, so
  // closing it here would also close it for the running app (see the same
  // rule in background_worker.dart).
  final notifications = NotificationService();
  await notifications.init(requestPermissions: false);
  final orchestrator = buildOverlayOrchestrator(
    database: database,
    notifications: notifications,
  );
  runApp(
    ProviderScope(
      overrides: [
        overlayDatabaseProvider.overrideWithValue(database),
        overlayNotificationsProvider.overrideWithValue(notifications),
        overlayOrchestratorProvider.overrideWithValue(orchestrator),
      ],
      child: const OverlayApp(),
    ),
  );
}
