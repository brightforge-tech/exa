import 'package:exa_mobile/agent/security/capability_policy.dart';
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
import 'package:exa_mobile/services/background_jobs/job_runner.dart';
import 'package:exa_mobile/services/browser/browser_bridge.dart';
import 'package:exa_mobile/services/calendar/device_calendar_service.dart';
import 'package:exa_mobile/services/mail/mail_service.dart';
import 'package:exa_mobile/services/notifications/notification_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// The app-building story, at the tool level: an agent asked to "build me a
/// note-taking app" defines a collection, creates one screen over it, and
/// the result tells it whether the feature actually works. The schema tests
/// cover what is allowed; these cover what the agent experiences.
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late AppDatabase database;
  late ToolRegistry registry;

  setUp(() async {
    database = AppDatabase();
    await database.open(overridePath: inMemoryDatabasePath);
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
      jobRunner:
          JobRunner(database: database, notifications: notifications),
      browserContext: BrowserContextRepository(database),
      emails: emails,
      browserBridge: BrowserBridge(),
      mailAccounts: mailAccounts,
      mail: MailService(accounts: mailAccounts, emails: emails),
      deviceCalendar: DeviceCalendarService(schedule: schedule),
      pendingCalendar: PendingCalendarRepository(database),
    );
  });

  tearDown(() => database.close());

  Future<void> defineNotes() async {
    final result = await registry.execute('define_collection', {
      'name': 'notes',
      'title': 'Notes',
      'fields': [
        {'name': 'title', 'type': 'text', 'required': true},
        {'name': 'body', 'type': 'multiline'},
        {
          'name': 'pinned',
          'type': 'select',
          'options': ['yes', 'no'],
        },
      ],
    });
    expect(result.success, isTrue, reason: result.error);
  }

  /// The complete note-taking feature the system prompt teaches.
  Map<String, Object?> notesScreenSchema() => {
        'data_source': {
          'table': 'notes',
          'order_by': 'updated_at',
          'order': 'desc',
        },
        'components': [
          {
            'type': 'search_box',
            'fields': ['title', 'body'],
          },
          {
            'type': 'form',
            'title': 'New note',
            'submit': {'tool': 'add_record', 'collection': 'notes'},
            'fields': [
              {'name': 'title', 'label': 'Title', 'required': true},
              {'name': 'body', 'label': 'Note', 'input': 'multiline'},
            ],
          },
          {
            'type': 'list',
            'item_template': {
              'title': '{{title}}',
              'subtitle': '{{updated_at_label}}',
            },
            'on_tap': {'type': 'view_record'},
            'actions': [
              {
                'label': 'Pin',
                'icon': 'star',
                'tool': 'update_record',
                'params': {'id': '{{id}}', 'pinned': 'yes'},
              },
            ],
          },
        ],
      };

  group('define_collection', () {
    test('rejects names and fields that could not work', () async {
      final badName = await registry.execute('define_collection', {
        'name': 'My Notes',
        'title': 'Notes',
        'fields': [
          {'name': 'title'},
        ],
      });
      expect(badName.success, isFalse);
      expect(badName.error, contains('snake_case'));

      final shadowing = await registry.execute('define_collection', {
        'name': 'tasks',
        'title': 'Tasks',
        'fields': [
          {'name': 'title'},
        ],
      });
      expect(shadowing.success, isFalse);
      expect(shadowing.error, contains('built-in'));

      final reserved = await registry.execute('define_collection', {
        'name': 'notes',
        'title': 'Notes',
        'fields': [
          {'name': 'id'},
        ],
      });
      expect(reserved.success, isFalse);
      expect(reserved.error, contains('reserved'));

      final selectWithoutOptions = await registry.execute(
          'define_collection', {
        'name': 'notes',
        'title': 'Notes',
        'fields': [
          {'name': 'status', 'type': 'select'},
        ],
      });
      expect(selectWithoutOptions.success, isFalse);
      expect(selectWithoutOptions.error, contains('options'));
    });

    test('redefining keeps existing records', () async {
      await defineNotes();
      await registry.execute('add_record', {
        'collection': 'notes',
        'fields': {'title': 'Keep me'},
      });
      final redefined = await registry.execute('define_collection', {
        'name': 'notes',
        'title': 'Notes',
        'fields': [
          {'name': 'title', 'type': 'text', 'required': true},
          {'name': 'body', 'type': 'multiline'},
          {'name': 'topic', 'type': 'text'},
        ],
      });
      expect(redefined.success, isTrue);
      final rows = await registry.records.listRecords('notes');
      expect(rows.single['title'], 'Keep me');
    });
  });

  group('records', () {
    test('add_record validates and coerces against the definition',
        () async {
      await defineNotes();

      final missingRequired = await registry.execute('add_record', {
        'collection': 'notes',
        'fields': {'body': 'no title'},
      });
      expect(missingRequired.success, isFalse);
      expect(missingRequired.error, contains('title'));

      final badSelect = await registry.execute('add_record', {
        'collection': 'notes',
        'fields': {'title': 'Hi', 'pinned': 'maybe'},
      });
      expect(badSelect.success, isFalse);
      expect(badSelect.error, contains('yes, no'));

      final unknownField = await registry.execute('add_record', {
        'collection': 'notes',
        'fields': {'title': 'Hi', 'color': 'red'},
      });
      expect(unknownField.success, isFalse);
      expect(unknownField.error, contains('color'));

      // Values may also arrive flat beside the collection - the shape a
      // generated form submits.
      final flat = await registry.execute('add_record', {
        'collection': 'notes',
        'title': 'Groceries',
        'body': 'Milk, eggs',
      });
      expect(flat.success, isTrue);
    });

    test('a number field accepts numeric strings and stays a number',
        () async {
      await registry.execute('define_collection', {
        'name': 'expenses',
        'title': 'Expenses',
        'fields': [
          {'name': 'label', 'type': 'text', 'required': true},
          {'name': 'amount', 'type': 'number', 'required': true},
        ],
      });
      final added = await registry.execute('add_record', {
        'collection': 'expenses',
        'fields': {'label': 'Coffee', 'amount': '4.50'},
      });
      expect(added.success, isTrue);
      final rows = await registry.records.listRecords('expenses');
      expect(rows.single['amount'], 4.5);

      final notANumber = await registry.execute('add_record', {
        'collection': 'expenses',
        'fields': {'label': 'Lunch', 'amount': 'twelve'},
      });
      expect(notANumber.success, isFalse);
      expect(notANumber.error, contains('number'));
    });

    test('update_record merges changed fields only', () async {
      await defineNotes();
      await registry.execute('add_record', {
        'collection': 'notes',
        'fields': {'title': 'Draft', 'body': 'v1'},
      });
      final id =
          (await registry.records.listRecords('notes')).single['id'];

      final updated = await registry.execute('update_record', {
        'collection': 'notes',
        'id': id,
        'fields': {'pinned': 'yes'},
      });
      expect(updated.success, isTrue);
      final row = (await registry.records.listRecords('notes')).single;
      expect(row['title'], 'Draft');
      expect(row['body'], 'v1');
      expect(row['pinned'], 'yes');
    });

    test('delete_record destroys data, so a background run is refused',
        () async {
      await defineNotes();
      await registry.execute('add_record', {
        'collection': 'notes',
        'fields': {'title': 'Precious'},
      });
      final id =
          (await registry.records.listRecords('notes')).single['id'];

      final denied = await registry.execute(
        'delete_record',
        {'collection': 'notes', 'id': id},
        capabilities:
            const CapabilityContext(runMode: AgentRunMode.unattended),
      );
      expect(denied.wasDenied, isTrue);
      expect(await registry.records.listRecords('notes'), hasLength(1));

      final deleted = await registry
          .execute('delete_record', {'collection': 'notes', 'id': id});
      expect(deleted.success, isTrue);
      expect(await registry.records.listRecords('notes'), isEmpty);
    });
  });

  group('create_dynamic_screen over a collection', () {
    test('the complete notes feature validates, saves, opens and reports',
        () async {
      await defineNotes();
      final result = await registry.execute('create_dynamic_screen', {
        'screen_key': 'notes_app',
        'title': 'Notes',
        'schema': notesScreenSchema(),
      });
      expect(result.success, isTrue, reason: result.error);

      final data = (result.data as Map).cast<String, Object?>();
      // The screen survives the turn without a separate save_screen call,
      // and opens without a separate open_screen call.
      expect(data['saved_to_menu'], isTrue);
      expect(result.navigateTo, '/screen/notes_app');
      // And the agent is told what its query actually matches.
      expect((data['row_counts'] as Map)['default'], 0);

      final screens = DynamicScreenRepository(database);
      expect((await screens.getByKey('notes_app'))!.isSaved, isTrue);

      await registry.execute('add_record', {
        'collection': 'notes',
        'fields': {'title': 'First note', 'body': 'Hello'},
      });
      final again = await registry.execute('create_dynamic_screen', {
        'screen_key': 'notes_app',
        'title': 'Notes',
        'schema': notesScreenSchema(),
      });
      expect(
          ((again.data as Map)['row_counts'] as Map)['default'], 1);
    });

    test('a screen over an undefined collection names the fix', () async {
      final result = await registry.execute('create_dynamic_screen', {
        'screen_key': 'notes_app',
        'title': 'Notes',
        'schema': notesScreenSchema(),
      });
      expect(result.success, isFalse);
      expect(result.error, contains('define_collection'));
    });

    test('a filter value that can never match is rejected with the real '
        'values', () async {
      final result = await registry.execute('create_dynamic_screen', {
        'screen_key': 'open_tasks',
        'title': 'Open tasks',
        'schema': {
          'data_source': {
            'table': 'tasks',
            'filters': [
              // The observed silent-empty-screen bug: lowercase status.
              {'field': 'status', 'operator': 'equals', 'value': 'pending'},
            ],
          },
          'components': [
            {
              'type': 'list',
              'item_template': {'title': '{{title}}'},
            },
          ],
        },
      });
      expect(result.success, isFalse);
      expect(result.error, contains('Pending'));
    });

    test('a filtered source matching nothing carries a warning', () async {
      await defineNotes();
      final result = await registry.execute('create_dynamic_screen', {
        'screen_key': 'pinned_notes',
        'title': 'Pinned',
        'schema': {
          'data_source': {
            'table': 'notes',
            'filters': [
              {'field': 'pinned', 'operator': 'equals', 'value': 'yes'},
            ],
          },
          'components': [
            {
              'type': 'list',
              'item_template': {'title': '{{title}}'},
            },
          ],
        },
      });
      expect(result.success, isTrue);
      final warnings =
          ((result.data as Map)['warnings'] as List?) ?? const [];
      expect(warnings, isNotEmpty);
      expect('${warnings.first}', contains('0'));
    });

    test('search finds a record and points at the screen built over it',
        () async {
      await defineNotes();
      await registry.execute('add_record', {
        'collection': 'notes',
        'fields': {'title': 'Trip prep', 'body': 'Renew the passport'},
      });

      // Before any screen exists, the hit says how to build one.
      final unhoused = await registry
          .execute('search', {'query': 'passport', 'types': ['records']});
      final firstHit = (((unhoused.data as Map)['results'] as List).single
              as Map)
          .cast<String, Object?>();
      expect(firstHit['type'], 'record');
      expect(firstHit['title'], 'Trip prep');
      expect(firstHit['snippet'], contains('passport'));
      expect('${firstHit['note']}', contains('create_dynamic_screen'));

      await registry.execute('create_dynamic_screen', {
        'screen_key': 'notes_app',
        'title': 'Notes',
        'schema': notesScreenSchema(),
      });
      final housed = await registry
          .execute('search', {'query': 'passport', 'types': ['records']});
      final hit = (((housed.data as Map)['results'] as List).single as Map)
          .cast<String, Object?>();
      expect(hit['open'], '/screen/notes_app');
    });

    test('a form-only screen needs no data source', () async {
      await defineNotes();
      final result = await registry.execute('create_dynamic_screen', {
        'screen_key': 'quick_note',
        'title': 'Quick note',
        'schema': {
          'components': [
            {'type': 'header', 'text': 'Jot something down'},
            {
              'type': 'form',
              'submit': {'tool': 'add_record', 'collection': 'notes'},
              'fields': [
                {'name': 'title', 'label': 'Title', 'required': true},
                {'name': 'body', 'label': 'Note', 'input': 'multiline'},
              ],
            },
          ],
        },
      });
      expect(result.success, isTrue, reason: result.error);
    });
  });
}
