import 'package:exa_mobile/data/models/reminder.dart';
import 'package:exa_mobile/services/notifications/notification_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

Reminder reminderAt(DateTime remindAt, {String? recurrence}) => Reminder(
      id: 'r1',
      title: 'Test',
      remindAt: remindAt,
      recurrenceRule: recurrence,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );

void main() {
  setUpAll(tzdata.initializeTimeZones);

  group('nextOccurrence is epoch-preserving', () {
    // The 4-hours-early bug: the background isolate's zone lookup failed,
    // tz.local silently stayed UTC, and wall-clock field copying then
    // shifted every reminder by the UTC offset. Scheduling must land on
    // the stored instant no matter what tz.local claims.
    for (final zoneName in ['UTC', 'Etc/GMT+4', 'America/New_York']) {
      test('one-time reminder fires at the stored instant under $zoneName',
          () {
        tz.setLocalLocation(tz.getLocation(zoneName));
        final service = NotificationService();
        final remindAt = DateTime.now().add(const Duration(hours: 5));

        final scheduled = service.nextOccurrence(reminderAt(remindAt));

        expect(scheduled, isNotNull);
        expect(scheduled!.millisecondsSinceEpoch,
            remindAt.millisecondsSinceEpoch,
            reason: 'a mislabeled tz.local must not shift the fire time');
      });
    }

    test('past one-time reminder returns null', () {
      tz.setLocalLocation(tz.getLocation('UTC'));
      final service = NotificationService();
      final scheduled = service.nextOccurrence(
          reminderAt(DateTime.now().subtract(const Duration(hours: 1))));
      expect(scheduled, isNull);
    });

    test('daily recurrence rolls forward in whole days from the stored '
        'instant, even under a wrong tz.local', () {
      tz.setLocalLocation(tz.getLocation('UTC'));
      final service = NotificationService();
      final remindAt = DateTime.now().subtract(const Duration(hours: 30));

      final scheduled =
          service.nextOccurrence(reminderAt(remindAt, recurrence: 'daily'));

      expect(scheduled, isNotNull);
      final drift = (scheduled!.millisecondsSinceEpoch -
              remindAt.millisecondsSinceEpoch) %
          Duration.millisecondsPerDay;
      expect(drift, 0,
          reason: 'next occurrence must be remindAt + N whole days');
      expect(scheduled.isAfter(tz.TZDateTime.now(tz.local)), isTrue);
    });

    test('monthly recurrence lands on the right local wall time', () {
      tz.setLocalLocation(tz.getLocation('UTC'));
      final service = NotificationService();
      final now = DateTime.now();
      // Last month at 09:30 local - the next occurrence must be a future
      // month at 09:30 local (converted from a device-local DateTime).
      final remindAt =
          DateTime(now.year, now.month - 1, 15, 9, 30);

      final scheduled = service
          .nextOccurrence(reminderAt(remindAt, recurrence: 'monthly'));

      expect(scheduled, isNotNull);
      expect(scheduled!.isAfter(tz.TZDateTime.now(tz.local)), isTrue);
      final asLocal =
          DateTime.fromMillisecondsSinceEpoch(scheduled.millisecondsSinceEpoch);
      expect(asLocal.hour, 9);
      expect(asLocal.minute, 30);
      expect(asLocal.day, 15);
    });
  });

  group('etcZoneNameFor', () {
    test('maps whole-hour offsets with the inverted Etc sign', () {
      expect(NotificationService.etcZoneNameFor(const Duration(hours: -4)),
          'Etc/GMT+4');
      expect(NotificationService.etcZoneNameFor(const Duration(hours: 4)),
          'Etc/GMT-4');
      expect(NotificationService.etcZoneNameFor(const Duration(hours: -12)),
          'Etc/GMT+12');
      expect(NotificationService.etcZoneNameFor(const Duration(hours: 14)),
          'Etc/GMT-14');
    });

    test('every produced name exists in the tz database', () {
      for (var hours = -12; hours <= 14; hours++) {
        final name =
            NotificationService.etcZoneNameFor(Duration(hours: hours));
        if (name == null) continue;
        expect(() => tz.getLocation(name), returnsNormally, reason: name);
      }
    });

    test('returns null for zero, partial-hour, and out-of-range offsets',
        () {
      expect(NotificationService.etcZoneNameFor(Duration.zero), isNull);
      expect(
          NotificationService.etcZoneNameFor(
              const Duration(hours: 5, minutes: 30)),
          isNull);
      expect(NotificationService.etcZoneNameFor(const Duration(hours: -13)),
          isNull);
      expect(NotificationService.etcZoneNameFor(const Duration(hours: 15)),
          isNull);
    });
  });
}
