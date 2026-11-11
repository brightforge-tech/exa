import 'dart:io';
import 'dart:typed_data';

import 'package:exa_mobile/agent/security/capability_policy.dart';
import 'package:exa_mobile/agent/security/write_scope.dart';
import 'package:exa_mobile/agent/tools/tool_domains.dart';
import 'package:exa_mobile/agent/tools/tool_registry.dart';
import 'package:exa_mobile/data/database/app_database.dart';
import 'package:exa_mobile/data/repositories/attachment_repository.dart';
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
import 'package:exa_mobile/features/dynamic_ui/screen_schema.dart';
import 'package:exa_mobile/services/background_jobs/job_runner.dart';
import 'package:exa_mobile/services/browser/browser_bridge.dart';
import 'package:exa_mobile/services/calendar/device_calendar_service.dart';
import 'package:exa_mobile/services/files/file_service.dart';
import 'package:exa_mobile/services/mail/mail_service.dart';
import 'package:exa_mobile/services/notifications/notification_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Points path_provider at a real temp directory so `write_file` can store
/// bytes exactly as it does on device.
class _TempPathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _TempPathProvider(this.root);
  final String root;

  @override
  Future<String?> getApplicationDocumentsPath() async => root;
}

/// The user asks Exa to keep something it produced ("store these digested
/// summaries for review later") and then to show it. That needs two things
/// that used to be missing: a way to write generated text into storage, and
/// a dynamic screen that can query the files table.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Directory tempRoot;
  late AppDatabase database;
  late ToolRegistry registry;
  late AttachmentRepository attachments;

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp('exa_files_test');
    PathProviderPlatform.instance = _TempPathProvider(tempRoot.path);

    database = AppDatabase();
    await database.open(overridePath: inMemoryDatabasePath);
    attachments = AttachmentRepository(database);
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
      attachments: attachments,
    );
  });

  tearDown(() async {
    await database.close();
    if (await tempRoot.exists()) await tempRoot.delete(recursive: true);
  });

  group('store_file resolves the attachment the model meant', () {
    Attachment image(String name) => Attachment(
          name: name,
          mimeType: 'image/png',
          sizeBytes: 4,
          bytes: Uint8List.fromList([137, 80, 78, 71]),
          kind: 'image',
        );

    test('the only attached file is stored even when the name is a guess',
        () async {
      // A snippet is staged as `snippet_<epoch>.png`, a name the model has no
      // way to know. Failing the call over its guess told the user their
      // image had not attached - seconds after it had been analyzed correctly.
      registry.stageAttachments([image('snippet_1786712431123.png')]);

      final result =
          await registry.execute('store_file', {'name': 'screenshot.png'});

      expect(result.success, isTrue, reason: result.error);
      final stored = await attachments.list();
      expect(stored, hasLength(1));
      expect(stored.single.name, 'snippet_1786712431123.png');
      expect(await File(stored.single.filePath).exists(), isTrue);
    });

    test('a name still selects between several attached files', () async {
      registry.stageAttachments([image('a.png'), image('b.png')]);

      final result = await registry.execute('store_file', {'name': 'b.png'});

      expect(result.success, isTrue, reason: result.error);
      expect((await attachments.list()).single.name, 'b.png');
    });

    test('a wrong name among several lists what is actually attached',
        () async {
      // The model can only correct itself if the error names the options.
      registry.stageAttachments([image('a.png'), image('b.png')]);

      final result =
          await registry.execute('store_file', {'name': 'nope.png'});

      expect(result.success, isFalse);
      expect(result.error, contains('a.png'));
      expect(result.error, contains('b.png'));
      expect(await attachments.list(), isEmpty);
    });

    test('case and a leading path do not defeat the match', () async {
      registry.stageAttachments([image('a.png'), image('Snippet_12.PNG')]);

      final result =
          await registry.execute('store_file', {'name': '/tmp/snippet_12.png'});

      expect(result.success, isTrue, reason: result.error);
      expect((await attachments.list()).single.name, 'Snippet_12.PNG');
    });

    test('nothing attached is still a failure', () async {
      final result = await registry.execute('store_file', {});
      expect(result.success, isFalse);
      expect(result.error, contains('No file is attached'));
    });
  });

  test('write_file stores agent-generated text and reads back', () async {
    final result = await registry.execute('write_file', {
      'name': 'Email digest 2026-07-29',
      'content': '## Digest\n- Contractor quote due Friday',
      'summary': '1 deadline',
      'category': 'email_digest',
    });

    expect(result.success, isTrue, reason: result.error);

    final stored = await attachments.list();
    expect(stored, hasLength(1));
    expect(stored.single.name, 'Email digest 2026-07-29.md');
    expect(stored.single.source, 'email_digest');
    expect(stored.single.summary, '1 deadline');
    expect(stored.single.extractedText, contains('Contractor quote'));
    expect(await File(stored.single.filePath).exists(), isTrue);

    // The user can get the content back out.
    final read = await registry
        .execute('read_file', {'id': stored.single.id});
    expect(read.success, isTrue);
    expect((read.data! as Map)['text'], contains('Contractor quote'));
  });

  test('write_file refuses empty content instead of storing a blank file',
      () async {
    final result = await registry
        .execute('write_file', {'name': 'Nothing', 'content': '   '});

    expect(result.success, isFalse);
    expect(await attachments.list(), isEmpty);
  });

  test('write_file sanitizes a model-supplied name', () async {
    final result = await registry.execute('write_file', {
      'name': '../../etc/digest',
      'content': 'body',
    });

    expect(result.success, isTrue, reason: result.error);
    final stored = await attachments.list();
    expect(stored.single.name, isNot(contains('/')));
    expect(stored.single.name, isNot(startsWith('.')));
    // Bytes stay inside the app's attachments directory.
    expect(stored.single.filePath, startsWith(tempRoot.path));
  });

  test('write_file is registered in the files domain and gated as a '
      'local write', () async {
    expect(registry['write_file'], isNotNull);
    expect(registry.domainOf('write_file'), ToolDomains.files);
    expect(CapabilityGate.capabilities['write_file'],
        ToolCapability.localWrite);
    expect(WriteScope.effectOf('write_file', const {}),
        WriteEffect.fileStore);
  });

  test('a screen can be built over stored files', () async {
    await registry.execute('write_file', {
      'name': 'Digest',
      'content': 'body',
      'category': 'email_digest',
    });

    final created = await registry.execute('create_dynamic_screen', {
      'screen_key': 'email_digests',
      'title': 'Email digests',
      'schema': {
        'layout': 'list',
        'data_source': {
          'table': 'attachments',
          'filters': [
            {
              'field': 'source',
              'operator': 'equals',
              'value': 'email_digest',
            },
          ],
          'order_by': 'created_at',
          'order': 'desc',
        },
        'components': [
          {'type': 'header', 'text': 'Email digests'},
          {
            'type': 'search_box',
            'fields': ['name', 'extracted_text'],
          },
          {
            'type': 'list',
            'item_template': {
              'title': '{{name}}',
              'subtitle': '{{summary}}',
            },
          },
        ],
      },
    });

    expect(created.success, isTrue, reason: created.error);
  });

  test('the files table never exposes the on-disk path', () {
    expect(ScreenSchema.allowedTables['attachments'],
        isNot(contains('file_path')));
  });

  test('an invented table is still rejected', () {
    final error = ScreenSchema.validate({
      'data_source': {'table': 'digested_email_summary_v1'},
      'components': [
        {'type': 'header', 'text': 'Summaries'},
      ],
    });

    expect(error, isNotNull);
    expect(error, contains('attachments'));
  });
}
