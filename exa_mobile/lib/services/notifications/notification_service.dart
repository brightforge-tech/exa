import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../../agent/behaviors/notification_policy.dart';
import '../../data/database/app_database.dart';
import '../../data/models/reminder.dart';
import '../../data/models/schedule_item.dart';
import '../../data/repositories/reminder_repository.dart';
import '../../data/repositories/schedule_repository.dart';

/// Routes to navigate to when the user taps a notification while the app
/// is alive. The app shell listens and pushes them onto the router.
final StreamController<String> notificationTapRoutes =
    StreamController<String>.broadcast();

const _snoozeActionId = 'snooze_reminder';
const _completeActionId = 'complete_reminder';

/// Entry point for notification action buttons (runs in its own isolate
/// when the app is backgrounded or dead).
@pragma('vm:entry-point')
Future<void> notificationActionBackgroundHandler(
    NotificationResponse response) async {
  try {
    await handleReminderAction(response);
  } catch (_) {
    // Best effort - never crash the notification isolate.
  }
}

/// Shared snooze/complete logic for both foreground and background.
Future<void> handleReminderAction(NotificationResponse response) async {
  final payload = response.payload ?? '';
  if (!payload.startsWith('reminder:')) return;
  final reminderId = payload.substring('reminder:'.length);

  final database = AppDatabase();
  await database.open();
  // NOTE: never close - the connection is shared process-wide.
  final reminders = ReminderRepository(database);
  final reminder = await reminders.getById(reminderId);
  if (reminder == null) return;
  final notificationId = reminder.notificationId ??
      ReminderRepository.stableNotificationId(reminder.id);

  final plugin = FlutterLocalNotificationsPlugin();
  await plugin.initialize(
    const InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    ),
  );

  switch (response.actionId) {
    case _snoozeActionId:
      tzdata.initializeTimeZones();
      await plugin.zonedSchedule(
        notificationId,
        reminder.title,
        reminder.description ?? 'Reminder from Exa',
        tz.TZDateTime.now(tz.local).add(const Duration(minutes: 10)),
        NotificationDetails(
            android: NotificationService.reminderChannel()),
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
        payload: payload,
      );
    case _completeActionId:
      await reminders.complete(reminderId);
      await plugin.cancel(notificationId);
  }
}

/// Local notifications for reminders and job results. Uses inexact
/// scheduling so no special exact-alarm permission is needed.
class NotificationService {
  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  bool _initialized = false;

  /// The user's notification behavior rules (quiet hours). Wired after
  /// construction - this service is built bare in main() and in the
  /// WorkManager isolate, before a database is available. Null means no
  /// rules are enforced, which is the pre-behaviors behaviour.
  Future<NotificationPolicy> Function()? policyLoader;

  Future<NotificationPolicy> _policy() async {
    final loader = policyLoader;
    if (loader == null) return NotificationPolicy.none;
    try {
      return await loader();
    } catch (_) {
      // A rule lookup failing must never cost the user a notification.
      return NotificationPolicy.none;
    }
  }

  /// Channel that job results and daily summaries are posted on.
  ///
  /// Not `exa_jobs`, which is what it was. A channel's importance can be
  /// lowered by whoever creates it again and never raised, and a native
  /// service that briefly used that id for its own quiet notification
  /// lowered it to minimum on every phone it ran on. The old id is removed
  /// in [init]; this one starts at the importance the old one was meant to
  /// have. Native code must never create a channel with this id.
  static const jobResultsChannelId = 'exa_job_results';

  static const _retiredChannelIds = ['exa_jobs'];

  static AndroidNotificationDetails reminderChannel() =>
      const AndroidNotificationDetails(
        'exa_reminders',
        'Reminders',
        channelDescription: 'Reminders created in Exa',
        importance: Importance.high,
        priority: Priority.high,
        actions: [
          AndroidNotificationAction(_snoozeActionId, 'Snooze 10 min',
              showsUserInterface: false),
          AndroidNotificationAction(_completeActionId, 'Done',
              showsUserInterface: false),
        ],
      );

  static AndroidNotificationDetails eventChannel() =>
      const AndroidNotificationDetails(
        'exa_events',
        'Calendar events',
        channelDescription: 'Alerts when an event on your Exa calendar starts',
        importance: Importance.high,
        priority: Priority.high,
      );

  Future<void> init({bool requestPermissions = true}) async {
    if (_initialized) return;

    tzdata.initializeTimeZones();
    try {
      final localTimezone = await FlutterTimezone.getLocalTimezone();
      tz.setLocalLocation(tz.getLocation(localTimezone.identifier));
    } catch (_) {
      // The zone name was unresolvable, or the flutter_timezone channel is
      // unavailable (background isolates). NEVER stay on the package
      // default (UTC): wall-clock recurrence rules would then repeat at
      // UTC wall times, hours off. Derive a fixed-offset zone from the
      // device clock instead - correct for everything except DST jumps.
      final etcName = etcZoneNameFor(DateTime.now().timeZoneOffset);
      if (etcName != null) {
        try {
          tz.setLocalLocation(tz.getLocation(etcName));
        } catch (_) {
          // Keep whatever tz.local already is; scheduling still lands on
          // the right instant because fire times are epoch-converted.
        }
      }
    }

    await _plugin.initialize(
      const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      ),
      onDidReceiveNotificationResponse: (response) {
        if (response.actionId == _snoozeActionId ||
            response.actionId == _completeActionId) {
          handleReminderAction(response);
          return;
        }
        // Plain tap: deep-link into the app.
        final payload = response.payload ?? '';
        if (payload.startsWith('reminder:')) {
          notificationTapRoutes.add('/reminders');
        } else if (payload.startsWith('route:')) {
          notificationTapRoutes.add(payload.substring('route:'.length));
        }
      },
      onDidReceiveBackgroundNotificationResponse:
          notificationActionBackgroundHandler,
    );

    try {
      final android = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      for (final retired in _retiredChannelIds) {
        await android?.deleteNotificationChannel(retired);
      }
    } catch (_) {
      // Tidying up a channel must never cost the app its notifications.
    }

    if (requestPermissions) {
      await _plugin
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.requestNotificationsPermission();
    }

    _initialized = true;
  }

  /// The IANA 'Etc/GMT±N' zone matching a device UTC [offset], or null when
  /// no such zone exists (non-whole-hour offsets, zero, out of range).
  /// Note the inverted sign convention: UTC-4 is 'Etc/GMT+4'.
  @visibleForTesting
  static String? etcZoneNameFor(Duration offset) {
    final hours = offset.inHours;
    if (hours == 0 ||
        offset.inMinutes != hours * 60 ||
        hours < -12 ||
        hours > 14) {
      return null;
    }
    return 'Etc/GMT${hours < 0 ? '+' : '-'}${hours.abs()}';
  }

  AndroidFlutterLocalNotificationsPlugin? get _android =>
      _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();

  /// Whether the OS currently allows exact alarms (Android 13+ gate).
  Future<bool> canScheduleExact() async =>
      await _android?.canScheduleExactNotifications() ?? false;

  /// Opens the system screen to grant exact-alarm permission (Android 13+).
  Future<void> requestExactAlarms() async =>
      _android?.requestExactAlarmsPermission();

  /// Route to open when the app was cold-started from a notification tap.
  Future<String?> consumeLaunchRoute() async {
    final details = await _plugin.getNotificationAppLaunchDetails();
    if (details?.didNotificationLaunchApp != true) return null;
    final payload = details!.notificationResponse?.payload ?? '';
    if (payload.startsWith('reminder:')) return '/reminders';
    if (payload.startsWith('route:')) {
      return payload.substring('route:'.length);
    }
    return null;
  }

  /// Shows a notification immediately (used by background jobs).
  ///
  /// Job briefings are suppressed during the user's quiet hours: they are
  /// summaries of things that already happened, and the same text is also
  /// appended to the chat, so nothing is lost by not buzzing at 03:00.
  ///
  /// [channel] decides that: content is held back, but a system-health
  /// notice ("your morning review could not run") is not - a quiet night
  /// must not become an invisible outage. Set [respectQuietHours] false to
  /// bypass entirely.
  Future<void> showNow({
    required int id,
    required String title,
    required String body,
    String? route,
    bool respectQuietHours = true,
    String channel = NotificationPolicy.channelContent,
  }) async {
    if (!_initialized) return;
    if (respectQuietHours &&
        (await _policy()).shouldSuppress(channel, DateTime.now())) {
      return;
    }
    await _plugin.show(
      id,
      title,
      body,
      NotificationDetails(
        android: AndroidNotificationDetails(
          jobResultsChannelId,
          'Daily summaries',
          channelDescription: 'Job results and daily summaries from Exa',
          importance: Importance.defaultImportance,
          priority: Priority.defaultPriority,
          // Long summaries stay readable when the notification is expanded.
          styleInformation: BigTextStyleInformation(body),
        ),
      ),
      payload: route == null ? null : 'route:$route',
    );
  }

  Future<void> scheduleReminder(Reminder reminder) async {
    if (!_initialized) return;
    final id = reminder.notificationId ??
        ReminderRepository.stableNotificationId(reminder.id);

    var scheduled = nextOccurrence(reminder);
    if (scheduled == null) return; // one-time reminder already in the past

    // Quiet hours defer a one-off reminder only when the user's rule opts
    // timed alerts in. A recurring one is never moved: shifting it would
    // rewrite the daily/weekly pattern they set, not just this occurrence.
    final policy = await _policy();
    if (policy.includeTimedAlerts && reminder.recurrenceRule == null) {
      final shifted = policy.nextAudibleTime(
          DateTime.fromMillisecondsSinceEpoch(
              scheduled.millisecondsSinceEpoch));
      scheduled = tz.TZDateTime.from(shifted, tz.local);
    }

    // Fire exactly on time when allowed; otherwise fall back to the
    // battery-friendly inexact window.
    final exact = await canScheduleExact();
    await _plugin.zonedSchedule(
      id,
      reminder.title,
      reminder.description ?? 'Reminder from Exa',
      scheduled,
      NotificationDetails(android: reminderChannel()),
      androidScheduleMode: exact
          ? AndroidScheduleMode.exactAllowWhileIdle
          : AndroidScheduleMode.inexactAllowWhileIdle,
      uiLocalNotificationDateInterpretation:
          UILocalNotificationDateInterpretation.absoluteTime,
      matchDateTimeComponents: switch (reminder.recurrenceRule) {
        'daily' => DateTimeComponents.time,
        'weekly' => DateTimeComponents.dayOfWeekAndTime,
        _ => null,
      },
      payload: 'reminder:${reminder.id}',
    );
  }

  Future<void> cancelReminder(Reminder reminder) async {
    if (!_initialized) return;
    final id = reminder.notificationId ??
        ReminderRepository.stableNotificationId(reminder.id);
    await _plugin.cancel(id);
  }

  /// Re-registers all active reminders with the OS (called on app start —
  /// scheduled notifications do not survive reinstalls or force stops).
  Future<void> rescheduleAll(List<Reminder> reminders) async {
    for (final reminder in reminders) {
      if (reminder.status != 'Active') continue;
      await scheduleReminder(reminder);
    }
  }

  /// Schedules a heads-up notification at an in-app calendar event's start
  /// time. Device-calendar events are skipped: the user's own calendar app
  /// already notifies for those, so firing our own would double-notify.
  /// Canceled and past events are no-ops.
  Future<void> scheduleEventNotification(ScheduleItem event) async {
    if (!_initialized) return;
    if (event.source == 'device') return;
    if (event.status == 'Canceled') return;

    final now = tz.TZDateTime.now(tz.local);
    // Epoch-preserving conversion: the stored local DateTime already holds
    // the correct instant (Dart local times use the OS zone), so even a
    // mislabeled tz.local cannot shift when the alert fires.
    final start = tz.TZDateTime.from(event.startAt, tz.local);
    if (!start.isAfter(now)) return; // event already started / past

    // Fire [leadTimeMinutes] before the start, but never in the past: if the
    // lead window has already passed, fall back to alerting at the start.
    final lead = Duration(minutes: event.leadTimeMinutes);
    final leadFire = start.subtract(lead);
    var fireAt = leadFire.isAfter(now) ? leadFire : start;

    // An event alert is only useful before the event, so quiet hours can
    // move it earlier but never later: a "starts at 07:00" alert deferred to
    // 07:00 would arrive as the meeting begins. Deferring is therefore
    // limited to alerts whose event has not started when the window ends.
    final policy = await _policy();
    if (policy.includeTimedAlerts && policy.isQuiet(fireAt)) {
      final shifted = tz.TZDateTime.from(
          policy.nextAudibleTime(
              DateTime.fromMillisecondsSinceEpoch(
                  fireAt.millisecondsSinceEpoch)),
          tz.local);
      if (shifted.isBefore(start)) fireAt = shifted;
    }

    final time = '${event.startAt.hour.toString().padLeft(2, '0')}:'
        '${event.startAt.minute.toString().padLeft(2, '0')}';
    final body = [
      event.leadTimeMinutes > 0 && fireAt == leadFire
          ? 'In ${event.leadTimeMinutes} min · starts at $time'
          : 'Starts at $time',
      if (event.location != null && event.location!.isNotEmpty)
        event.location!,
    ].join(' · ');

    final exact = await canScheduleExact();
    await _plugin.zonedSchedule(
      ScheduleRepository.stableNotificationId(event.id),
      event.title,
      body,
      fireAt,
      NotificationDetails(android: eventChannel()),
      androidScheduleMode: exact
          ? AndroidScheduleMode.exactAllowWhileIdle
          : AndroidScheduleMode.inexactAllowWhileIdle,
      uiLocalNotificationDateInterpretation:
          UILocalNotificationDateInterpretation.absoluteTime,
      payload: 'route:/schedule',
    );
  }

  Future<void> cancelEventNotification(String eventId) async {
    if (!_initialized) return;
    await _plugin.cancel(ScheduleRepository.stableNotificationId(eventId));
  }

  /// Re-registers upcoming in-app event notifications on app start (scheduled
  /// notifications don't survive reinstalls or force stops).
  Future<void> rescheduleAllEvents(List<ScheduleItem> events) async {
    for (final event in events) {
      await scheduleEventNotification(event);
    }
  }

  /// Next fire time, or null when a non-recurring reminder is already past.
  ///
  /// Epoch-preserving: the stored local DateTime already holds the correct
  /// instant (Dart local times use the OS zone directly), so this converts
  /// by instant rather than copying wall-clock fields into tz.local - a
  /// mislabeled tz.local (e.g. the UTC default after a failed zone lookup
  /// in a background isolate) can no longer shift when reminders fire.
  @visibleForTesting
  tz.TZDateTime? nextOccurrence(Reminder reminder) {
    final now = tz.TZDateTime.now(tz.local);
    var scheduled = tz.TZDateTime.from(reminder.remindAt, tz.local);
    if (scheduled.isAfter(now)) return scheduled;

    switch (reminder.recurrenceRule) {
      case 'daily':
        while (!scheduled.isAfter(now)) {
          scheduled = scheduled.add(const Duration(days: 1));
        }
        return scheduled;
      case 'weekly':
        while (!scheduled.isAfter(now)) {
          scheduled = scheduled.add(const Duration(days: 7));
        }
        return scheduled;
      case 'monthly':
        // The OS can't auto-repeat monthly (no DateTimeComponents for it), so
        // this is scheduled as a one-shot at the next occurrence; rescheduleAll
        // (app start + the background tick) rolls it forward after it fires.
        final dom = reminder.remindAt.day;
        var month = reminder.remindAt.month;
        var next = scheduled;
        while (!next.isAfter(now)) {
          month++;
          next = _monthlyAt(reminder.remindAt.year, month, dom,
              reminder.remindAt.hour, reminder.remindAt.minute);
        }
        return next;
      default:
        return null;
    }
  }

  /// A local datetime for [desiredDom] of (year, month), normalizing month
  /// overflow and clamping the day to the month's length (so the 31st lands on
  /// the last day of shorter months). Built as a device-local DateTime first
  /// so the instant is correct even when tz.local is mislabeled.
  static tz.TZDateTime _monthlyAt(
      int year, int month, int desiredDom, int hour, int minute) {
    final y = year + (month - 1) ~/ 12;
    final m = (month - 1) % 12 + 1;
    final lastDom = DateTime(m == 12 ? y + 1 : y, m == 12 ? 1 : m + 1, 0).day;
    final dom = desiredDom <= lastDom ? desiredDom : lastDom;
    return tz.TZDateTime.from(DateTime(y, m, dom, hour, minute), tz.local);
  }
}
