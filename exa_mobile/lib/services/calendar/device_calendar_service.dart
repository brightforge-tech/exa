import 'package:device_calendar/device_calendar.dart';
import 'package:timezone/timezone.dart' as tz;

import '../../data/repositories/schedule_repository.dart';
import '../../data/repositories/task_repository.dart';

class CalendarImportResult {
  final int imported;
  final int updated;
  final String? error;
  const CalendarImportResult(
      {this.imported = 0, this.updated = 0, this.error});

  String get summary => error != null
      ? 'Calendar import failed: $error'
      : 'Imported $imported new and updated $updated event(s) from the '
          'device calendar.';
}

/// Imports events from the Android device calendar into `schedule_items`
/// (source = "device", deduped by the platform event id), and writes
/// app-created events/tasks out to the phone calendar.
///
/// Phone-calendar events this app created are addressed by a stable ref
/// of the form "calendarId:eventId" (both are numeric on Android).
class DeviceCalendarService {
  DeviceCalendarService(
      {required this.schedule, this.tasks, DeviceCalendarPlugin? plugin})
      : _plugin = plugin ?? DeviceCalendarPlugin();

  final ScheduleRepository schedule;
  final TaskRepository? tasks;
  final DeviceCalendarPlugin _plugin;

  /// Whether calendar permission is already granted (never prompts).
  Future<bool> hasPermission() async {
    try {
      final perm = await _plugin.hasPermissions();
      return perm.data == true;
    } catch (_) {
      return false;
    }
  }

  /// Checks calendar permission, prompting the user if not yet granted.
  Future<void> _ensurePermission() async {
    var perm = await _plugin.hasPermissions();
    if (perm.data != true) {
      perm = await _plugin.requestPermissions();
    }
    if (perm.data != true) {
      throw StateError('Calendar permission was not granted${_errs(perm)}');
    }
  }

  /// Imports events from now until [days] ahead from all device calendars.
  /// Triggers the OS calendar-permission prompt on first use.
  Future<CalendarImportResult> import({int days = 30}) async {
    try {
      try {
        await _ensurePermission();
      } catch (e) {
        return CalendarImportResult(
            error: 'permission was not granted');
      }

      final calendarsResult = await _plugin.retrieveCalendars();
      final calendars = calendarsResult.data ?? <Calendar>[];
      if (calendars.isEmpty) {
        return CalendarImportResult(
            error: calendarsResult.hasErrors
                ? 'could not read calendars${_errs(calendarsResult)}'
                : 'no calendars found on this device');
      }

      // Phone events that are mirrors of our own events/tasks must not be
      // re-imported as separate "device" items.
      final ownEventIds = <String>{
        for (final ref in await schedule.deviceEventRefs()) _eventIdOf(ref),
        if (tasks != null)
          for (final ref in await tasks!.deviceEventRefs()) _eventIdOf(ref),
      };

      final now = DateTime.now();
      final params = RetrieveEventsParams(
        startDate: now.subtract(const Duration(hours: 12)),
        endDate: now.add(Duration(days: days)),
      );

      var imported = 0;
      var updated = 0;
      var failedCalendars = 0;
      String? firstError;

      for (final calendar in calendars) {
        final calendarId = calendar.id;
        if (calendarId == null) continue;

        final eventsResult =
            await _plugin.retrieveEvents(calendarId, params);
        if (eventsResult.hasErrors) {
          failedCalendars++;
          firstError ??= _errs(eventsResult);
          continue;
        }

        for (final event in eventsResult.data ?? <Event>[]) {
          final start = event.start;
          final externalId = event.eventId;
          final title = event.title?.trim();
          if (start == null || externalId == null) continue;
          if (title == null || title.isEmpty) continue;
          if (ownEventIds.contains(externalId)) continue;

          final wasNew = await schedule.upsertExternal(
            externalId: 'device:$externalId',
            title: title,
            startAt: start.toLocal(),
            endAt: event.end?.toLocal(),
            location: event.location,
            description: event.description,
            source: 'device',
          );
          if (wasNew) {
            imported++;
          } else {
            updated++;
          }
        }
      }

      // Nothing imported and every calendar errored -> surface the reason.
      if (imported == 0 &&
          updated == 0 &&
          failedCalendars > 0 &&
          failedCalendars == calendars.length) {
        return CalendarImportResult(
            error: 'could not read events$firstError');
      }
      return CalendarImportResult(imported: imported, updated: updated);
    } catch (e) {
      return CalendarImportResult(error: '$e');
    }
  }

  /// Creates or updates an event on the phone calendar and returns its
  /// stable ref ("calendarId:eventId"). With [eventRef] the existing
  /// platform event is updated in place; otherwise a new one is created in
  /// the default writable calendar. Throws with a readable message on
  /// failure (including permission being denied).
  Future<String> upsertEvent({
    String? eventRef,
    required String title,
    required DateTime startAt,
    DateTime? endAt,
    String? location,
    String? description,
    int? reminderMinutes,
  }) async {
    await _ensurePermission();

    String calendarId;
    String? eventId;
    if (eventRef != null) {
      (calendarId, eventId) = _splitRef(eventRef);
    } else {
      calendarId = await _defaultWritableCalendarId();
    }

    final location0 = tz.local;
    final event = Event(
      calendarId,
      eventId: eventId,
      title: title,
      start: tz.TZDateTime.from(startAt, location0),
      end: tz.TZDateTime.from(
          endAt ?? startAt.add(const Duration(hours: 1)), location0),
      location: location,
      description: description,
    );
    if (reminderMinutes != null) {
      event.reminders = [Reminder(minutes: reminderMinutes)];
    }

    final result = await _plugin.createOrUpdateEvent(event);
    if (result == null || result.hasErrors || result.data == null) {
      throw StateError(
          'Calendar rejected the event${result == null ? '' : _errs(result)}');
    }
    return '$calendarId:${result.data!}';
  }

  /// Deletes a phone-calendar event previously created via [upsertEvent],
  /// addressed by its "calendarId:eventId" ref. Missing events (e.g. the
  /// user already removed it in their calendar app) are not an error.
  Future<void> deleteEventByRef(String eventRef) async {
    await _ensurePermission();
    final (calendarId, eventId) = _splitRef(eventRef);
    final result = await _plugin.deleteEvent(calendarId, eventId);
    if (result.hasErrors) {
      throw StateError('Calendar delete failed${_errs(result)}');
    }
  }

  /// Writes an event to the phone's default writable calendar. Returns the
  /// created platform event id. Throws with a readable message on failure.
  ///
  /// High-risk: callers must have the user's explicit approval first.
  Future<String> createEvent({
    required String title,
    required DateTime startAt,
    DateTime? endAt,
    String? location,
    String? description,
  }) async {
    final ref = await upsertEvent(
      title: title,
      startAt: startAt,
      endAt: endAt,
      location: location,
      description: description,
    );
    return _eventIdOf(ref);
  }

  /// The device's default calendar, else the first writable one.
  ///
  /// A calendar with no id cannot be written to, and phones do report such
  /// entries - subscribed feeds and account placeholder rows come back
  /// writable but unaddressable. They are filtered out here rather than
  /// picked and then failing the write: an idless default must fall
  /// through to the next usable calendar, not sink the whole call. [import]
  /// already skips them the same way.
  Future<String> _defaultWritableCalendarId() async {
    final calendarsResult = await _plugin.retrieveCalendars();
    final calendars = calendarsResult.data ?? <Calendar>[];
    final writable = calendars
        .where((c) => c.isReadOnly != true && (c.id?.isNotEmpty ?? false))
        .toList();
    if (writable.isEmpty) {
      throw StateError(calendarsResult.hasErrors
          ? 'Could not read the phone calendars${_errs(calendarsResult)}'
          : 'No writable calendar found on this device');
    }
    final target = writable.firstWhere(
      (c) => c.isDefault == true,
      orElse: () => writable.first,
    );
    return target.id!;
  }

  static (String, String) _splitRef(String ref) {
    final split = ref.indexOf(':');
    if (split <= 0 || split == ref.length - 1) {
      throw StateError('Malformed calendar event ref: $ref');
    }
    return (ref.substring(0, split), ref.substring(split + 1));
  }

  static String _eventIdOf(String ref) =>
      ref.contains(':') ? ref.substring(ref.indexOf(':') + 1) : ref;

  /// Formats a plugin Result's errors into a readable suffix.
  static String _errs(Result result) {
    if (!result.hasErrors) return '';
    return ': ${result.errors.map((e) => e.errorMessage).join('; ')}';
  }
}
