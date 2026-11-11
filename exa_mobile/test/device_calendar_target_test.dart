import 'dart:collection';

import 'package:device_calendar/device_calendar.dart';
import 'package:exa_mobile/data/database/app_database.dart';
import 'package:exa_mobile/data/repositories/schedule_repository.dart';
import 'package:exa_mobile/services/calendar/device_calendar_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:timezone/data/latest.dart' as tzdata;

/// Stands in for the platform plugin so calendar-target selection can be
/// driven from a fixed list of calendars.
class _FakeCalendarPlugin implements DeviceCalendarPlugin {
  _FakeCalendarPlugin(this.calendars, {this.retrieveErrors = false});

  final List<Calendar> calendars;
  final bool retrieveErrors;

  /// The calendar id `createOrUpdateEvent` was actually handed.
  String? wroteToCalendarId;

  @override
  Future<Result<bool>> hasPermissions() async => _ok(true);

  @override
  Future<Result<bool>> requestPermissions() async => _ok(true);

  @override
  Future<Result<UnmodifiableListView<Calendar>>> retrieveCalendars() async {
    final result = Result<UnmodifiableListView<Calendar>>()
      ..data = UnmodifiableListView(calendars);
    if (retrieveErrors) {
      result.errors.add(
          ResultError(0, 'calendar provider unavailable'));
    }
    return result;
  }

  @override
  Future<Result<String>?> createOrUpdateEvent(Event? event) async {
    wroteToCalendarId = event?.calendarId;
    return _ok('42');
  }

  static Result<T> _ok<T>(T value) => Result<T>()..data = value;

  @override
  noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} not faked');
}

Calendar _calendar(
  String? id, {
  bool readOnly = false,
  bool isDefault = false,
  String name = 'Calendar',
}) =>
    Calendar(
      id: id,
      name: name,
      isReadOnly: readOnly,
      isDefault: isDefault,
    );

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    tzdata.initializeTimeZones();
  });

  late AppDatabase database;
  late ScheduleRepository schedule;

  setUp(() async {
    database = AppDatabase();
    await database.open(overridePath: inMemoryDatabasePath);
    schedule = ScheduleRepository(database);
  });

  tearDown(() => database.close());

  Future<String> createVia(_FakeCalendarPlugin plugin) =>
      DeviceCalendarService(schedule: schedule, plugin: plugin).createEvent(
        title: 'Strategy Implementation KPI Scorecard',
        startAt: DateTime(2026, 7, 30, 13),
      );

  test('an idless default calendar falls through to a usable one', () async {
    // What the failing phone reported: the calendar picked first carried no
    // id, so the write died instead of using the account calendar next to
    // it.
    final plugin = _FakeCalendarPlugin([
      _calendar(null, isDefault: true, name: 'Placeholder'),
      _calendar('3', name: 'Work'),
    ]);

    await createVia(plugin);

    expect(plugin.wroteToCalendarId, '3');
  });

  test('an idless first writable calendar is skipped', () async {
    final plugin = _FakeCalendarPlugin([
      _calendar(null, name: 'Subscribed feed'),
      _calendar('7', name: 'Personal'),
    ]);

    await createVia(plugin);

    expect(plugin.wroteToCalendarId, '7');
  });

  test('a usable default still wins over other writable calendars', () async {
    final plugin = _FakeCalendarPlugin([
      _calendar('1', name: 'Work'),
      _calendar('2', isDefault: true, name: 'Personal'),
    ]);

    await createVia(plugin);

    expect(plugin.wroteToCalendarId, '2');
  });

  test('read-only calendars are never written to', () async {
    final plugin = _FakeCalendarPlugin([
      _calendar('1', readOnly: true, isDefault: true, name: 'Holidays'),
      _calendar('2', name: 'Personal'),
    ]);

    await createVia(plugin);

    expect(plugin.wroteToCalendarId, '2');
  });

  test('no usable calendar reports that, not a null-id crash', () async {
    final plugin = _FakeCalendarPlugin([
      _calendar(null),
      _calendar('1', readOnly: true),
    ]);

    await expectLater(
      createVia(plugin),
      throwsA(isA<StateError>().having((e) => e.message, 'message',
          contains('No writable calendar'))),
    );
  });

  test('a failed calendar read says so instead of "none found"', () async {
    final plugin = _FakeCalendarPlugin(const [], retrieveErrors: true);

    await expectLater(
      createVia(plugin),
      throwsA(isA<StateError>().having((e) => e.message, 'message',
          contains('Could not read the phone calendars'))),
    );
  });
}
