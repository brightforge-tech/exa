import 'package:exa_mobile/agent/security/capability_policy.dart';
import 'package:exa_mobile/agent/tools/tool_domains.dart';
import 'package:exa_mobile/agent/tools/tool_registry.dart';
import 'package:exa_mobile/data/database/app_database.dart';
import 'package:exa_mobile/data/repositories/behavior_repository.dart';
import 'package:exa_mobile/data/repositories/browser_context_repository.dart';
import 'package:exa_mobile/data/repositories/dynamic_screen_repository.dart';
import 'package:exa_mobile/data/repositories/email_repository.dart';
import 'package:exa_mobile/data/repositories/job_repository.dart';
import 'package:exa_mobile/data/repositories/mail_account_repository.dart';
import 'package:exa_mobile/data/repositories/pending_calendar_repository.dart';
import 'package:exa_mobile/data/repositories/reminder_repository.dart';
import 'package:exa_mobile/data/repositories/schedule_repository.dart';
import 'package:exa_mobile/data/repositories/task_repository.dart';
import 'package:exa_mobile/data/repositories/tool_call_repository.dart';
import 'package:exa_mobile/device/device_control.dart';
import 'package:exa_mobile/device/fake_device_backend.dart';
import 'package:exa_mobile/services/background_jobs/job_runner.dart';
import 'package:exa_mobile/services/browser/browser_bridge.dart';
import 'package:exa_mobile/services/calendar/device_calendar_service.dart';
import 'package:exa_mobile/services/mail/mail_service.dart';
import 'package:exa_mobile/services/notifications/notification_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

DeviceAdminStatus owner(Map<String, bool> grants) => DeviceAdminStatus(
      backend: DeviceBackendKind.deviceOwner,
      deviceOwner: true,
      adminActive: true,
      sdk: 36,
      grants: {DeviceGrants.deviceOwner: true, ...grants},
    );

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late AppDatabase database;
  late FakeDeviceBackend device;
  late ToolRegistry registry;

  setUp(() async {
    database = AppDatabase();
    await database.open(overridePath: inMemoryDatabasePath);
    device = FakeDeviceBackend(
        status: owner({DeviceGrants.accessibility: true}));
    final notifications = NotificationService();
    final mailAccounts = MailAccountRepository(database);
    final emails = EmailRepository(database);
    final schedule = ScheduleRepository(database);
    registry = ToolRegistry(
      tasks: TaskRepository(database),
      reminders: ReminderRepository(database),
      schedule: schedule,
      behaviors: BehaviorRepository(database),
      screens: DynamicScreenRepository(database),
      toolCalls: ToolCallRepository(database),
      notifications: notifications,
      database: database,
      jobs: JobRepository(database),
      jobRunner: JobRunner(database: database, notifications: notifications),
      browserContext: BrowserContextRepository(database),
      emails: emails,
      browserBridge: BrowserBridge(),
      mailAccounts: mailAccounts,
      mail: MailService(accounts: mailAccounts, emails: emails),
      deviceCalendar: DeviceCalendarService(schedule: schedule),
      pendingCalendar: PendingCalendarRepository(database),
      deviceControl: device,
    );
  });

  tearDown(() => database.close());

  group('the screen domain', () {
    test('registers under the screen domain and nothing else', () {
      const names = {
        'read_screen',
        'open_app',
        'tap_screen',
        'type_text',
        'swipe_screen',
        'press_button',
        'screen_screenshot',
      };
      final inDomain =
          registry.toolsForDomains({ToolDomains.screen}).map((t) => t.name);
      for (final n in names) {
        expect(inDomain, contains(n), reason: n);
      }
      // Not in the core (always-on) set - a small-model turn must route to
      // the screen domain deliberately.
      final coreTools =
          registry.toolsForDomains({ToolDomains.core}).map((t) => t.name);
      expect(coreTools, isNot(contains('tap_screen')));
    });

    test('every screen tool is classified (none defaults to outbound)', () {
      const reads = {'read_screen', 'screen_screenshot'};
      const writes = {
        'tap_screen',
        'type_text',
        'swipe_screen',
        'press_button',
        'open_app',
      };
      for (final n in reads) {
        expect(CapabilityGate.capabilityOf(n), ToolCapability.read, reason: n);
      }
      for (final n in writes) {
        expect(CapabilityGate.capabilityOf(n), ToolCapability.localWrite,
            reason: n);
      }
    });
  });

  group('read_screen', () {
    test('returns the foreground app and its elements', () async {
      device.screenControl.snapshot = const ScreenSnapshot(
        packageName: 'com.microsoft.office.outlook',
        appLabel: 'Outlook',
        elements: [
          ScreenElement(
              id: 0, text: 'Inbox', role: 'Text', bounds: [0, 0, 100, 40]),
          ScreenElement(
              id: 1,
              text: 'Compose',
              role: 'Button',
              clickable: true,
              bounds: [900, 2000, 1080, 2100]),
        ],
      );
      final r = await registry.execute('read_screen', const {});
      expect(r.success, isTrue);
      final data = r.data as Map;
      expect(data['app'], 'Outlook');
      final elements = data['elements'] as List;
      expect(elements, hasLength(2));
      expect((elements[1] as Map)['text'], 'Compose');
      expect((elements[1] as Map)['clickable'], true);
    });

    test('reports honestly when accessibility is off', () async {
      device.status = owner(const {}); // accessibility not granted
      final r = await registry.execute('read_screen', const {});
      expect(r.success, isFalse);
      expect(r.error, contains('accessibility'));
    });
  });

  group('driving apps', () {
    test('tap_screen taps the element id', () async {
      final r = await registry.execute('tap_screen', const {'id': 1});
      expect(r.success, isTrue);
      expect(device.screenControl.taps.single.id, 1);
    });

    test('type_text types into an element', () async {
      final r = await registry
          .execute('type_text', const {'id': 3, 'text': 'five minutes'});
      expect(r.success, isTrue);
      expect(device.screenControl.typed.single.text, 'five minutes');
    });

    test('open_app foregrounds a package', () async {
      final r = await registry
          .execute('open_app', const {'package': 'com.whatsapp'});
      expect(r.success, isTrue);
      expect(device.screenControl.openedApps.single, 'com.whatsapp');
    });

    test('press_button runs a global action', () async {
      final r = await registry.execute('press_button', const {'button': 'home'});
      expect(r.success, isTrue);
      expect(device.screenControl.globals.single, 'home');
    });

    test('an action is refused when the service is off', () async {
      device.status = owner(const {});
      final r = await registry.execute('tap_screen', const {'id': 0});
      expect(r.success, isFalse);
      expect(device.screenControl.taps, isEmpty);
    });
  });

  group('screen_screenshot', () {
    test('carries the image bytes back as base64 for the tool loop', () async {
      final r = await registry.execute('screen_screenshot', const {});
      expect(r.success, isTrue);
      final data = r.data as Map;
      expect(data['__image_base64'], isNotNull);
      expect(data['__image_media_type'], 'image/png');
      expect(device.screenControl.screenshots, 1);
    });

    test('needs the screenshot capability', () async {
      device.status = owner(const {}); // no accessibility => no screenshot
      final r = await registry.execute('screen_screenshot', const {});
      expect(r.success, isFalse);
    });
  });
}
