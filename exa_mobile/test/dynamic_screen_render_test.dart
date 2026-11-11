import 'package:exa_mobile/data/database/app_database.dart';
import 'package:exa_mobile/data/models/task_item.dart';
import 'package:exa_mobile/data/models/user_collection.dart';
import 'package:exa_mobile/data/repositories/dynamic_screen_repository.dart';
import 'package:exa_mobile/data/repositories/schedule_repository.dart';
import 'package:exa_mobile/data/repositories/task_repository.dart';
import 'package:exa_mobile/data/repositories/user_collection_repository.dart';
import 'package:exa_mobile/features/dynamic_ui/dynamic_screen_page.dart';
import 'package:exa_mobile/services/notifications/notification_service.dart';
import 'package:exa_mobile/shared/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// End-to-end for a generated screen: the schema goes in, real rows come out
/// of SQLite, and what is on screen is what the schema asked for. The schema
/// tests cover what is *allowed*; these cover what is *rendered*.
///
/// Every database call is wrapped in [WidgetTester.runAsync]. `testWidgets`
/// runs its body inside a fake-async zone where sqflite's real I/O never
/// completes - without it, each test hangs on the loading spinner instead of
/// failing, which is a slow way to learn nothing.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late AppDatabase database;
  late TaskRepository tasks;
  late ScheduleRepository schedule;
  late DynamicScreenRepository screens;
  late UserCollectionRepository records;

  setUp(() async {
    database = AppDatabase();
    await database.open(overridePath: inMemoryDatabasePath);
    tasks = TaskRepository(database);
    schedule = ScheduleRepository(database);
    screens = DynamicScreenRepository(database);
    records = UserCollectionRepository(database);
  });

  tearDown(() => database.close());

  /// Lets the screen's real database I/O finish, then rebuilds. When the
  /// caller names what it is waiting for with [ready], the real-async
  /// windows stay open - up to a fixed budget - until it is on screen:
  /// with the full suite's other databases running in parallel, a fixed
  /// delay can lose the race with SQLite, and a spinner is not a failure.
  Future<void> settle(WidgetTester tester, {Finder? ready}) async {
    for (var attempt = 0;; attempt++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 150)));
      await tester.pump();
      await tester.pump();
      if (ready == null || tester.any(ready) || attempt >= 19) return;
    }
  }

  Future<void> pumpScreen(WidgetTester tester, String key,
      {Finder? ready}) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(database),
          // Row actions run through the real tool registry, which needs
          // this. Left uninitialized so scheduling is a safe no-op.
          notificationServiceProvider.overrideWithValue(NotificationService()),
        ],
        // A plain dark theme, not the app's: buildExaDarkTheme pulls
        // webfonts, and under runAsync that fetch really is attempted and
        // fails. Nothing asserted here depends on the typeface.
        child: MaterialApp(
          theme: ThemeData.dark(),
          home: DynamicScreenPage(screenKey: key),
        ),
      ),
    );
    await settle(tester, ready: ready);
  }

  testWidgets('a two-source dashboard shows each list its own rows',
      (tester) async {
    await tester.runAsync(() async {
      await tasks.create(title: 'Overdue thing', dueAt: DateTime(2020, 1, 1));
      await tasks.create(title: 'Someday thing');
      await schedule.create(
          title: 'Standup',
          startAt: DateTime.now().add(const Duration(minutes: 30)));
      await screens.upsert(
        screenKey: 'dashboard',
        title: 'My day',
        schema: {
          'data_sources': {
            'overdue': {
              'table': 'tasks',
              'filters': [
                {'field': 'due_at', 'operator': 'lt', 'value': 'now'},
              ],
            },
            'today': {
              'table': 'schedule_items',
              'filters': [
                {'field': 'start_at', 'operator': 'equals', 'value': 'today'},
              ],
            },
          },
          'components': [
            {
              'type': 'list',
              'source': 'overdue',
              'item_template': {'title': '{{title}}'},
            },
            {
              'type': 'list',
              'source': 'today',
              'item_template': {'title': '{{title}}'},
            },
          ],
        },
      );
    });

    await pumpScreen(tester, 'dashboard', ready: find.text('Overdue thing'));

    // Each list rendered from the source it names - the point of having
    // more than one on a screen.
    expect(find.text('Overdue thing'), findsOneWidget);
    expect(find.text('Standup'), findsOneWidget);
    // ...and the task matching neither filter is on neither list.
    expect(find.text('Someday thing'), findsNothing);
  });

  testWidgets('a stat counts the whole source, not the rows on screen',
      (tester) async {
    await tester.runAsync(() async {
      for (var i = 0; i < 7; i++) {
        await tasks.create(title: 'Task $i');
      }
      await screens.upsert(
        screenKey: 'counts',
        title: 'Counts',
        schema: {
          // The list is capped at two rows; the count must still say 7.
          // Counting the fetched rows instead is the bug this pins.
          'data_source': {'table': 'tasks', 'limit': 2},
          'components': [
            {'type': 'stat', 'aggregate': 'count', 'label': 'Open'},
            {
              'type': 'list',
              'item_template': {'title': '{{title}}'},
            },
          ],
        },
      );
    });

    await pumpScreen(tester, 'counts', ready: find.text('7'));

    expect(find.text('7'), findsOneWidget);
    expect(find.text('Open'), findsOneWidget);
    expect(find.byType(ListTile), findsNWidgets(2));
  });

  testWidgets('a row action runs its tool and the screen catches up',
      (tester) async {
    late TaskItem task;
    await tester.runAsync(() async {
      task = await tasks.create(title: 'Finish me');
      await screens.upsert(
        screenKey: 'actions',
        title: 'Actions',
        schema: {
          'data_source': {
            'table': 'tasks',
            'filters': [
              {'field': 'status', 'operator': 'equals', 'value': 'Pending'},
            ],
          },
          'components': [
            {'type': 'stat', 'aggregate': 'count', 'label': 'Pending'},
            {
              'type': 'list',
              'item_template': {'title': '{{title}}'},
              'actions': [
                {
                  'label': 'Done',
                  'icon': 'check',
                  'tool': 'complete_task',
                  'params': {'id': '{{id}}'},
                },
              ],
            },
          ],
        },
      );
    });

    await pumpScreen(tester, 'actions', ready: find.text('Finish me'));
    expect(find.text('Finish me'), findsOneWidget);
    expect(find.text('1'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.check));
    // One real-async window each for the tool call, the re-query the
    // invalidation kicks off, and the frame that paints it. Not
    // pumpAndSettle: while the provider refreshes there is a spinner on
    // screen, and a spinner never settles.
    await settle(tester);
    await settle(tester);
    await settle(tester, ready: find.text('0'));

    // The task really completed, through the tool registry...
    await tester.runAsync(() async {
      expect((await tasks.getById(task.id))!.isOpen, isFalse);
    });
    // ...and the screen re-read itself, so neither the row nor the count is
    // left claiming otherwise.
    expect(find.text('Finish me'), findsNothing);
    expect(find.text('0'), findsOneWidget);
  });

  testWidgets('the user can delete a screen they are done with',
      (tester) async {
    await tester.runAsync(() async {
      await screens.upsert(
        screenKey: 'scratch',
        title: 'Scratch view',
        schema: {
          'data_source': {'table': 'tasks'},
          'components': [
            {
              'type': 'list',
              'item_template': {'title': '{{title}}'},
            },
          ],
        },
      );
    });

    await pumpScreen(tester, 'scratch', ready: find.byType(PopupMenuButton<String>));
    expect(find.text('Scratch view'), findsOneWidget);

    // Explicit pumps, never pumpAndSettle: the "Generated by Exa" banner
    // holds a breathing orb, so this page has an animation that never ends.
    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('Delete this screen'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // It asks first - the whole screen goes, and it says what does not.
    expect(find.textContaining('Delete "Scratch view"?'), findsOneWidget);
    expect(find.textContaining('tasks, events and files are untouched'),
        findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await settle(tester);

    await tester.runAsync(() async {
      expect(await screens.getByKey('scratch'), isNull);
    });
  });

  testWidgets('a note-taking feature works end to end: add, read, edit',
      (tester) async {
    // The complete feature the system prompt teaches the agent to build:
    // a collection, then one screen with a form, a list, and full-screen
    // records behind each row.
    await tester.runAsync(() async {
      await records.define(
        name: 'notes',
        title: 'Notes',
        fields: const [
          CollectionField(name: 'title', required: true),
          CollectionField(name: 'body', type: 'multiline'),
        ],
      );
      await screens.upsert(
        screenKey: 'notes_app',
        title: 'Notes',
        schema: {
          'data_source': {'table': 'notes'},
          'components': [
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
              'item_template': {'title': '{{title}}'},
              'on_tap': {'type': 'view_record'},
            },
          ],
        },
      );
    });

    await pumpScreen(tester, 'notes_app', ready: find.text('New note'));
    expect(find.text('New note'), findsOneWidget);
    expect(find.text('Nothing to show.'), findsOneWidget);

    // Add a note through the generated form - the write goes through the
    // real tool registry, add_record, and the collection store.
    await tester.enterText(
        find.widgetWithText(TextFormField, 'Title'), 'Packing list');
    await tester.enterText(find.widgetWithText(TextFormField, 'Note'),
        'Passport, tickets, charger');
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await settle(tester);
    await settle(tester);
    await settle(tester, ready: find.widgetWithText(ListTile, 'Packing list'));

    // One list row for the new note (the form field also still shows the
    // text it was typed into, so scope the finder to the list).
    expect(find.widgetWithText(ListTile, 'Packing list'), findsOneWidget);
    expect(find.text('Nothing to show.'), findsNothing);

    // Tap the note: it opens full-screen, whole body readable. The extra
    // timed pump carries the route transition to its end, so the list page
    // behind is truly offstage before anything is asserted.
    await tester.tap(find.widgetWithText(ListTile, 'Packing list'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    // The body, in full, as selectable text - only the detail view renders
    // it that way (the form field behind still holds what was typed).
    expect(find.widgetWithText(SelectableText, 'Passport, tickets, charger'),
        findsOneWidget);

    // Edit it there and save.
    await tester.tap(find.byIcon(Icons.edit_outlined));
    await tester.pump();
    await tester.enterText(
        find.widgetWithText(TextFormField, 'body'), 'Just the passport');
    await tester.tap(find.widgetWithText(TextButton, 'Save'));
    await settle(tester);
    await settle(tester, ready: find.text('Just the passport'));
    expect(find.text('Just the passport'), findsOneWidget);

    await tester.runAsync(() async {
      final row = (await records.listRecords('notes')).single;
      expect(row['body'], 'Just the passport');
      expect(row['title'], 'Packing list');
    });
  });

  testWidgets('a record can be deleted from its detail view, with a dialog',
      (tester) async {
    await tester.runAsync(() async {
      await records.define(
        name: 'notes',
        title: 'Notes',
        fields: const [CollectionField(name: 'title', required: true)],
      );
      await records.addRecord(
          collection: 'notes', values: {'title': 'Old idea'});
      await screens.upsert(
        screenKey: 'notes_app',
        title: 'Notes',
        schema: {
          'data_source': {'table': 'notes'},
          'components': [
            {
              'type': 'list',
              'item_template': {'title': '{{title}}'},
              'on_tap': {'type': 'view_record'},
            },
          ],
        },
      );
    });

    await pumpScreen(tester, 'notes_app');
    await tester.tap(find.text('Old idea'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // The delete a row button could never confirm has a whole page to ask
    // from.
    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.textContaining('Delete this notes entry?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await settle(tester);
    await settle(tester);

    await tester.runAsync(() async {
      expect(await records.listRecords('notes'), isEmpty);
    });
  });

  testWidgets('a number field feeds a sum stat - the expense tracker case',
      (tester) async {
    await tester.runAsync(() async {
      await records.define(
        name: 'expenses',
        title: 'Expenses',
        fields: const [
          CollectionField(name: 'label', required: true),
          CollectionField(name: 'amount', type: 'number', required: true),
        ],
      );
      await records.addRecord(
          collection: 'expenses',
          values: {'label': 'Coffee', 'amount': 4.5});
      await records.addRecord(
          collection: 'expenses',
          values: {'label': 'Lunch', 'amount': 12});
      await screens.upsert(
        screenKey: 'spending',
        title: 'Spending',
        schema: {
          'data_source': {'table': 'expenses'},
          'components': [
            {
              'type': 'stat',
              'aggregate': 'sum',
              'field': 'amount',
              'label': 'Total',
            },
            {
              'type': 'list',
              'item_template': {'title': '{{label}}'},
            },
          ],
        },
      );
    });

    await pumpScreen(tester, 'spending', ready: find.text('16.5'));
    expect(find.text('16.5'), findsOneWidget);
    expect(find.text('Coffee'), findsOneWidget);
    expect(find.text('Lunch'), findsOneWidget);
  });

  testWidgets('a schema that no longer validates says so instead of blanking',
      (tester) async {
    await tester.runAsync(() async {
      // Written straight to the repository: the shape of a screen stored
      // before a rule tightened, which is when a user actually meets this.
      await screens.upsert(
        screenKey: 'broken',
        title: 'Broken',
        schema: {
          'data_source': {'table': 'tasks'},
          'components': [
            {
              'type': 'list',
              'item_template': {'title': '{{not_a_column}}'},
            },
          ],
        },
      );
    });

    await pumpScreen(tester, 'broken', ready: find.text('This screen could not be built'));

    expect(find.text('This screen could not be built'), findsOneWidget);
    expect(find.textContaining('{{not_a_column}}'), findsOneWidget);
  });
}
