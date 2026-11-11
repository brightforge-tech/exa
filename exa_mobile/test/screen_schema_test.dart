import 'package:exa_mobile/data/models/user_collection.dart';
import 'package:exa_mobile/features/dynamic_ui/screen_schema.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ScreenSchema.validate', () {
    Map<String, Object?> validSchema() => {
          'layout': 'list',
          'data_source': {
            'table': 'tasks',
            'filters': [
              {'field': 'status', 'operator': 'equals', 'value': 'Pending'},
            ],
            'order_by': 'due_at',
          },
          'components': [
            {'type': 'header', 'text': 'Open tasks'},
            {
              'type': 'list',
              'item_template': {'title': '{{title}}'},
            },
          ],
        };

    test('accepts a valid schema', () {
      expect(ScreenSchema.validate(validSchema()), isNull);
    });

    test('rejects unknown tables', () {
      final schema = validSchema();
      (schema['data_source'] as Map)['table'] = 'sqlite_master';
      expect(ScreenSchema.validate(schema), contains('table'));
    });

    test('rejects unknown fields in filters', () {
      final schema = validSchema();
      ((schema['data_source'] as Map)['filters'] as List)[0] = {
        'field': 'password',
        'operator': 'equals',
        'value': 'x',
      };
      expect(ScreenSchema.validate(schema), contains('password'));
    });

    test('rejects unknown operators', () {
      final schema = validSchema();
      ((schema['data_source'] as Map)['filters'] as List)[0] = {
        'field': 'status',
        'operator': 'drop_table',
        'value': 'x',
      };
      expect(ScreenSchema.validate(schema), contains('drop_table'));
    });

    test('rejects unknown component types', () {
      final schema = validSchema();
      (schema['components'] as List).add({'type': 'web_view'});
      expect(ScreenSchema.validate(schema), contains('web_view'));
    });

    test('requires a data_source', () {
      final schema = validSchema()..remove('data_source');
      expect(ScreenSchema.validate(schema), isNotNull);
    });

    test('accepts the phase-4 components', () {
      final schema = validSchema();
      (schema['components'] as List).addAll(<Map<String, Object>>[
        {'type': 'card', 'title': 'Note', 'text': 'Hello'},
        {
          'type': 'table',
          'columns': [
            {'field': 'title', 'label': 'Task'},
            {'field': 'status'},
          ],
        },
        {'type': 'chart', 'chart_type': 'bar', 'group_by': 'status'},
        {
          'type': 'button',
          'label': 'All tasks',
          'action': {'type': 'open_screen', 'screen_key': 'tasks'},
        },
        {
          'type': 'search_box',
          'fields': ['title', 'description'],
        },
      ]);
      expect(ScreenSchema.validate(schema), isNull);
    });

    test('rejects table columns that are not real columns', () {
      final schema = validSchema();
      (schema['components'] as List).add({
        'type': 'table',
        'columns': [
          {'field': 'secret'},
        ],
      });
      expect(ScreenSchema.validate(schema), contains('secret'));
    });

    test('rejects charts grouped by unknown columns', () {
      final schema = validSchema();
      (schema['components'] as List)
          .add({'type': 'chart', 'group_by': 'password'});
      expect(ScreenSchema.validate(schema), contains('group_by'));
    });

    test('accepts the guide-completion components', () {
      final schema = validSchema();
      (schema['components'] as List).addAll(<Map<String, Object>>[
        {
          'type': 'form',
          'title': 'Quick task',
          'submit': {'tool': 'create_task'},
          'fields': [
            {'name': 'title', 'label': 'Title', 'required': true},
            {'name': 'due_at', 'label': 'Due', 'input': 'datetime'},
            {
              'name': 'priority',
              'label': 'Priority',
              'input': 'select',
              'options': ['Low', 'Normal', 'High'],
            },
          ],
        },
        {'type': 'task_board'},
        {'type': 'calendar', 'date_field': 'due_at'},
        {
          'type': 'web_preview',
          'url': 'https://example.com',
          'title': 'Example',
        },
      ]);
      expect(ScreenSchema.validate(schema), isNull);
    });

    test('rejects forms submitting to non-whitelisted tools', () {
      final schema = validSchema();
      (schema['components'] as List).add({
        'type': 'form',
        'submit': {'tool': 'delete_task'},
        'fields': [
          {'name': 'title', 'label': 'T'},
        ],
      });
      expect(ScreenSchema.validate(schema), contains('submit.tool'));
    });

    test('rejects form fields that are not tool parameters', () {
      final schema = validSchema();
      (schema['components'] as List).add({
        'type': 'form',
        'submit': {'tool': 'create_task'},
        'fields': [
          {'name': 'sql_injection', 'label': 'X'},
        ],
      });
      expect(ScreenSchema.validate(schema), contains('sql_injection'));
    });

    test('rejects calendars with invalid date fields', () {
      final schema = validSchema();
      (schema['components'] as List)
          .add({'type': 'calendar', 'date_field': 'password'});
      expect(ScreenSchema.validate(schema), contains('date_field'));
    });

    test('rejects non-http web previews', () {
      final schema = validSchema();
      (schema['components'] as List)
          .add({'type': 'web_preview', 'url': 'javascript:alert(1)'});
      expect(ScreenSchema.validate(schema), contains('http'));
    });

    test('rejects buttons with unknown action types', () {
      final schema = validSchema();
      (schema['components'] as List).add({
        'type': 'button',
        'label': 'Hack',
        'action': {'type': 'run_shell', 'cmd': 'rm -rf'},
      });
      expect(ScreenSchema.validate(schema), contains('action.type'));
    });
  });

  group('ScreenSchema.buildWhere', () {
    test('builds parameterized clauses', () {
      final (where, args) = ScreenSchema.buildWhere({
        'filters': [
          {'field': 'status', 'operator': 'equals', 'value': 'Pending'},
          {'field': 'due_at', 'operator': 'not_null'},
        ],
      });
      expect(where, 'status = ? AND due_at IS NOT NULL');
      expect(args, ['Pending']);
    });

    test("'today' with equals matches the whole day", () {
      final (where, args) = ScreenSchema.buildWhere({
        'filters': [
          {'field': 'start_at', 'operator': 'equals', 'value': 'today'},
        ],
      });
      expect(where, '(start_at >= ? AND start_at < ?)');
      final now = DateTime.now();
      final dayStart = DateTime(now.year, now.month, now.day);
      expect(args, [
        dayStart.toIso8601String(),
        dayStart.add(const Duration(days: 1)).toIso8601String(),
      ]);
    });

    test("'today' respects its operator instead of collapsing to one day",
        () {
      final now = DateTime.now();
      final dayStart = DateTime(now.year, now.month, now.day);

      // "From today onward" - the filter every forward-looking agenda
      // screen writes - used to silently mean "today only".
      final (gteWhere, gteArgs) = ScreenSchema.buildWhere({
        'filters': [
          {'field': 'start_at', 'operator': 'gte', 'value': 'today'},
        ],
      });
      expect(gteWhere, 'start_at >= ?');
      expect(gteArgs.single, dayStart.toIso8601String());

      // "Before today" - the overdue filter.
      final (ltWhere, ltArgs) = ScreenSchema.buildWhere({
        'filters': [
          {'field': 'due_at', 'operator': 'lt', 'value': 'today'},
        ],
      });
      expect(ltWhere, 'due_at < ?');
      expect(ltArgs.single, dayStart.toIso8601String());
    });

    test('not_equals keeps rows where the column is NULL', () {
      final (where, _) = ScreenSchema.buildWhere({
        'filters': [
          {'field': 'category', 'operator': 'not_equals', 'value': 'Work'},
        ],
      });
      expect(where, '(category != ? OR category IS NULL)');
    });
  });

  group('ScreenSchema.renderTemplate', () {
    test('substitutes placeholders and blanks missing columns', () {
      final rendered = ScreenSchema.renderTemplate(
        '{{title}} - {{missing}}',
        {'title': 'Hello'},
      );
      expect(rendered, 'Hello - ');
    });

    test('a timestamp renders as a readable date, not raw ISO', () {
      // Observed on device: the model wrote "Due {{due_at_label}}", which was
      // not a column, so every card showed a dangling "Due" with nothing after
      // it. `{{due_at}}` alone would have shown 2026-07-24T10:00:00.000.
      final rendered = ScreenSchema.renderTemplate(
        'Due {{due_at_label}}',
        {'due_at': '2026-07-24T10:00:00.000'},
      );
      expect(rendered, 'Due Friday, July 24, 2026 at 10:00');
    });

    test('midnight reads as a date with no time', () {
      final rendered = ScreenSchema.renderTemplate(
        '{{due_at_label}}',
        {'due_at': '2026-07-25T00:00:00.000'},
      );
      expect(rendered, 'Saturday, July 25, 2026');
    });

    test('the bare column also formats, so neither spelling shows raw ISO',
        () {
      expect(
        ScreenSchema.renderTemplate(
            '{{due_at}}', {'due_at': '2026-07-24T10:00:00.000'}),
        'Friday, July 24, 2026 at 10:00',
      );
    });

    test('non-date values are untouched', () {
      expect(
        ScreenSchema.renderTemplate('{{title}}/{{priority}}',
            {'title': 'v1 to v2', 'priority': 'High'}),
        'v1 to v2/High',
      );
    });
  });

  group('template placeholder validation', () {
    Map<String, Object?> screenWith(Map<String, Object?> itemTemplate) => {
          'layout': 'list',
          'data_source': {'table': 'tasks'},
          'components': [
            {'type': 'list', 'item_template': itemTemplate},
          ],
        };

    test('a placeholder naming no column is rejected with the valid names',
        () {
      final error = ScreenSchema.validate(screenWith({
        'title': '{{title}}',
        'subtitle': 'Owner {{assignee}}',
      }));
      expect(error, isNotNull);
      expect(error, contains('{{assignee}}'));
      expect(error, contains('due_at'),
          reason: 'the error has to name the valid columns - that is what '
              'makes the model fix it on the next attempt');
    });

    test('a _label placeholder on a real column is accepted', () {
      // The convention the agent already knows from every tool result.
      expect(
        ScreenSchema.validate(screenWith({
          'title': '{{title}}',
          'subtitle': 'Due {{due_at_label}} (Priority: {{priority}})',
        })),
        isNull,
      );
    });

    test('_label on a column that does not exist is still rejected', () {
      expect(
        ScreenSchema.validate(screenWith({'title': '{{nonsense_label}}'})),
        isNotNull,
      );
    });
  });

  group('named data sources', () {
    Map<String, Object?> dashboard() => {
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
              'type': 'stat',
              'source': 'overdue',
              'aggregate': 'count',
              'label': 'Overdue',
            },
            {
              'type': 'list',
              'source': 'today',
              'item_template': {'title': '{{title}}'},
            },
          ],
        };

    test('a screen can read two tables at once', () {
      expect(ScreenSchema.validate(dashboard()), isNull);
    });

    test('the old single data_source still works, as the default source', () {
      // Every screen built before named sources existed has to keep
      // rendering; the singular form is read as one source called 'default'.
      final sources = ScreenSchema.sourcesIn({
        'data_source': {'table': 'tasks'},
      });
      expect(sources.keys, [ScreenSchema.defaultSourceName]);
      expect(sources[ScreenSchema.defaultSourceName]!['table'], 'tasks');
    });

    test('a component with no source falls back to the only one there is', () {
      final sources = ScreenSchema.sourcesIn({
        'data_sources': {
          'anything': {'table': 'tasks'},
        },
      });
      expect(ScreenSchema.sourceNameFor(const {}, sources), 'anything');
    });

    test('two sources and no binding is rejected, not guessed', () {
      // Guessing here is how a screen quietly shows the wrong table.
      final schema = dashboard();
      (schema['components'] as List)[1] = {
        'type': 'list',
        'item_template': {'title': '{{title}}'},
      };
      final error = ScreenSchema.validate(schema);
      expect(error, contains('must name a source'));
      expect(error, contains('overdue'), reason: 'name the options');
    });

    test('a component naming a source that does not exist is rejected', () {
      final schema = dashboard();
      (schema['components'] as List)[1] = {
        'type': 'list',
        'source': 'yesterday',
        'item_template': {'title': '{{title}}'},
      };
      expect(ScreenSchema.validate(schema), contains('must name a source'));
    });

    test('a component is validated against ITS source, not another one', () {
      // 'priority' is a tasks column; this list reads schedule_items, so the
      // template is broken even though the column exists elsewhere on screen.
      final schema = dashboard();
      (schema['components'] as List)[1] = {
        'type': 'list',
        'source': 'today',
        'item_template': {'title': '{{title}}', 'subtitle': '{{priority}}'},
      };
      expect(ScreenSchema.validate(schema), contains('{{priority}}'));
    });

    test('a bad table in one source fails the whole screen', () {
      final schema = dashboard();
      (schema['data_sources'] as Map)['today'] = {'table': 'sqlite_master'};
      expect(ScreenSchema.validate(schema), contains('today'));
    });

    test('non-data components need no source', () {
      final schema = dashboard();
      (schema['components'] as List).add({'type': 'header', 'text': 'Hi'});
      (schema['components'] as List).add({
        'type': 'button',
        'label': 'Tasks',
        'action': {'type': 'open_screen', 'screen_key': 'tasks'},
      });
      expect(ScreenSchema.validate(schema), isNull);
    });
  });

  group('stat components', () {
    Map<String, Object?> screenWithStat(Map<String, Object?> stat) => {
          'data_source': {'table': 'attachments'},
          'components': [stat],
        };

    test('a count needs nothing but a label', () {
      expect(
        ScreenSchema.validate(screenWithStat(
            {'type': 'stat', 'aggregate': 'count', 'label': 'Files'})),
        isNull,
      );
    });

    test('aggregate defaults to count', () {
      expect(
        ScreenSchema.validate(
            screenWithStat({'type': 'stat', 'label': 'Files'})),
        isNull,
      );
    });

    test('sum and avg need a real column to total', () {
      expect(
        ScreenSchema.validate(screenWithStat({
          'type': 'stat',
          'aggregate': 'sum',
          'field': 'size_bytes',
          'label': 'Bytes',
        })),
        isNull,
      );
      expect(
        ScreenSchema.validate(screenWithStat(
            {'type': 'stat', 'aggregate': 'sum', 'label': 'Bytes'})),
        contains('field'),
      );
    });

    test('a made-up aggregate is rejected', () {
      expect(
        ScreenSchema.validate(screenWithStat(
            {'type': 'stat', 'aggregate': 'median', 'label': 'x'})),
        contains('median'),
      );
    });

    test('a sum over a column of another table is rejected', () {
      expect(
        ScreenSchema.validate(screenWithStat({
          'type': 'stat',
          'aggregate': 'avg',
          'field': 'priority',
          'label': 'x',
        })),
        isNotNull,
      );
    });
  });

  group('row actions', () {
    Map<String, Object?> screenWithActions(List<Object?> actions) => {
          'data_source': {'table': 'tasks'},
          'components': [
            {
              'type': 'list',
              'item_template': {'title': '{{title}}'},
              'actions': actions,
            },
          ],
        };

    test('accepts an allowlisted tool bound to the row', () {
      expect(
        ScreenSchema.validate(screenWithActions([
          {
            'label': 'Done',
            'icon': 'check',
            'tool': 'complete_task',
            'params': {'id': '{{id}}'},
          },
        ])),
        isNull,
      );
    });

    test('refuses a tool that is not on the row allowlist', () {
      // Nothing destructive or outbound may ever be one tap away inside a
      // screen the model wrote.
      final error = ScreenSchema.validate(screenWithActions([
        {
          'label': 'Delete',
          'tool': 'delete_task',
          'params': {'id': '{{id}}'},
        },
      ]));
      expect(error, contains('delete_task'));
      expect(error, contains('complete_task'), reason: 'name the options');
    });

    test('refuses a param the tool does not take', () {
      expect(
        ScreenSchema.validate(screenWithActions([
          {
            'label': 'Done',
            'tool': 'complete_task',
            'params': {'sql': 'drop'},
          },
        ])),
        contains('sql'),
      );
    });

    test('refuses a placeholder that names no column', () {
      // An action passing an empty id is worse than a rejected schema: it
      // would run against nothing and report success.
      expect(
        ScreenSchema.validate(screenWithActions([
          {
            'label': 'Done',
            'tool': 'complete_task',
            'params': {'id': '{{uuid}}'},
          },
        ])),
        contains('{{uuid}}'),
      );
    });

    test('a literal param value is fine', () {
      expect(
        ScreenSchema.validate(screenWithActions([
          {
            'label': 'Start',
            'tool': 'update_task',
            'params': {'id': '{{id}}', 'status': 'In Progress'},
          },
        ])),
        isNull,
      );
    });

    test('needs a label, and refuses an unknown icon', () {
      expect(
        ScreenSchema.validate(screenWithActions([
          {
            'tool': 'complete_task',
            'params': {'id': '{{id}}'},
          },
        ])),
        contains('label'),
      );
      expect(
        ScreenSchema.validate(screenWithActions([
          {'label': 'Done', 'icon': 'skull', 'tool': 'complete_task'},
        ])),
        contains('skull'),
      );
    });

    test('caps how many buttons a row can carry', () {
      final action = {
        'label': 'Done',
        'tool': 'complete_task',
        'params': {'id': '{{id}}'},
      };
      expect(
        ScreenSchema.validate(screenWithActions(
            List.filled(ScreenSchema.maxRowActions + 1, action))),
        contains('at most'),
      );
    });

    test('on_tap navigates and nothing else', () {
      Map<String, Object?> screenWithTap(Object? onTap) => {
            'data_source': {'table': 'tasks'},
            'components': [
              {
                'type': 'list',
                'item_template': {'title': '{{title}}'},
                'on_tap': onTap,
              },
            ],
          };
      expect(
        ScreenSchema.validate(
            screenWithTap({'type': 'open_screen', 'screen_key': 'tasks'})),
        isNull,
      );
      // A tap that mutates is deliberately not offered: changes are always a
      // labelled button the user aimed at.
      expect(
        ScreenSchema.validate(
            screenWithTap({'type': 'run_tool', 'tool': 'complete_task'})),
        isNotNull,
      );
      expect(
        ScreenSchema.validate(screenWithTap({'type': 'open_screen'})),
        contains('screen_key'),
      );
    });
  });

  group('collection-aware validation', () {
    final notes = UserCollection(
      name: 'notes',
      title: 'Notes',
      fields: const [
        CollectionField(name: 'title', required: true),
        CollectionField(name: 'body', type: 'multiline'),
        CollectionField(
            name: 'pinned', type: 'select', options: ['yes', 'no']),
        CollectionField(name: 'words', type: 'number'),
        CollectionField(name: 'due', type: 'datetime'),
      ],
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
    );
    final collections = {'notes': notes};

    Map<String, Object?> notesScreen(
            [List<Map<String, Object?>>? components]) =>
        {
          'data_source': <String, Object?>{'table': 'notes'},
          'components': components ??
              [
                {
                  'type': 'list',
                  'item_template': {'title': '{{title}}'},
                },
              ],
        };

    test('a collection queries exactly like a table', () {
      expect(
          ScreenSchema.validate(notesScreen(), collections: collections),
          isNull);
    });

    test('an undefined collection points at define_collection', () {
      expect(ScreenSchema.validate(notesScreen()),
          contains('define_collection'));
    });

    test("a collection template placeholder must name a real field", () {
      final schema = notesScreen([
        {
          'type': 'list',
          'item_template': {'title': '{{headline}}'},
        },
      ]);
      final error =
          ScreenSchema.validate(schema, collections: collections);
      expect(error, contains('headline'));
      expect(error, contains('title'));
    });

    test('a select filter value outside the options is rejected with them',
        () {
      final schema = notesScreen();
      (schema['data_source'] as Map)['filters'] = [
        {'field': 'pinned', 'operator': 'equals', 'value': 'maybe'},
      ];
      final error =
          ScreenSchema.validate(schema, collections: collections);
      expect(error, contains('maybe'));
      expect(error, contains('yes, no'));
    });

    test('a task status filter that can never match names the real values',
        () {
      // The observed on-device failure: "pending" validates, matches
      // nothing, and the screen ships permanently empty.
      final schema = {
        'data_source': {
          'table': 'tasks',
          'filters': [
            {'field': 'status', 'operator': 'equals', 'value': 'pending'},
          ],
        },
        'components': [
          {
            'type': 'list',
            'item_template': {'title': '{{title}}'},
          },
        ],
      };
      final error = ScreenSchema.validate(schema);
      expect(error, contains('pending'));
      expect(error, contains('Pending'));
    });

    test('sum needs a numeric column, and a collection number field is one',
        () {
      final overWords = notesScreen([
        {'type': 'stat', 'aggregate': 'sum', 'field': 'words', 'label': 'W'},
      ]);
      expect(
          ScreenSchema.validate(overWords, collections: collections),
          isNull);

      final overTitle = notesScreen([
        {'type': 'stat', 'aggregate': 'sum', 'field': 'title', 'label': 'T'},
      ]);
      expect(ScreenSchema.validate(overTitle, collections: collections),
          contains('numeric'));

      // Task titles are text; summing them would always show 0.
      final schema = {
        'data_source': {'table': 'tasks'},
        'components': [
          {'type': 'stat', 'aggregate': 'sum', 'field': 'title', 'label': 'X'},
        ],
      };
      expect(ScreenSchema.validate(schema), contains('numeric'));
    });

    test('view_record is a valid tap and needs nothing else', () {
      final schema = notesScreen([
        {
          'type': 'list',
          'item_template': {'title': '{{title}}'},
          'on_tap': {'type': 'view_record'},
        },
      ]);
      expect(
          ScreenSchema.validate(schema, collections: collections), isNull);
    });

    test('update_record row actions bind to the collection, and only there',
        () {
      final onNotes = notesScreen([
        {
          'type': 'list',
          'item_template': {'title': '{{title}}'},
          'actions': [
            {
              'label': 'Pin',
              'tool': 'update_record',
              'params': {'id': '{{id}}', 'pinned': 'yes'},
            },
          ],
        },
      ]);
      expect(
          ScreenSchema.validate(onNotes, collections: collections), isNull);

      final badParam = notesScreen([
        {
          'type': 'list',
          'item_template': {'title': '{{title}}'},
          'actions': [
            {
              'label': 'Pin',
              'tool': 'update_record',
              'params': {'id': '{{id}}', 'color': 'red'},
            },
          ],
        },
      ]);
      expect(ScreenSchema.validate(badParam, collections: collections),
          contains('color'));

      final onTasks = {
        'data_source': {'table': 'tasks'},
        'components': [
          {
            'type': 'list',
            'item_template': {'title': '{{title}}'},
            'actions': [
              {
                'label': 'X',
                'tool': 'update_record',
                'params': {'id': '{{id}}'},
              },
            ],
          },
        ],
      };
      expect(ScreenSchema.validate(onTasks), contains('collection'));
    });

    test('an add_record form takes the collection fields as its params', () {
      final good = notesScreen([
        {
          'type': 'form',
          'submit': {'tool': 'add_record', 'collection': 'notes'},
          'fields': [
            {'name': 'title', 'label': 'Title', 'required': true},
            {'name': 'body', 'label': 'Note', 'input': 'multiline'},
            {'name': 'words', 'label': 'Words', 'input': 'number'},
          ],
        },
      ]);
      expect(ScreenSchema.validate(good, collections: collections), isNull);

      final unknownField = notesScreen([
        {
          'type': 'form',
          'submit': {'tool': 'add_record', 'collection': 'notes'},
          'fields': [
            {'name': 'color', 'label': 'Color'},
          ],
        },
      ]);
      expect(
          ScreenSchema.validate(unknownField, collections: collections),
          contains('color'));

      final noCollection = notesScreen([
        {
          'type': 'form',
          'submit': {'tool': 'add_record'},
          'fields': [
            {'name': 'title', 'label': 'Title'},
          ],
        },
      ]);
      expect(
          ScreenSchema.validate(noCollection, collections: collections),
          contains('collection'));
    });

    test('a form-only screen needs no data source', () {
      final schema = {
        'components': [
          {'type': 'header', 'text': 'Quick note'},
          {
            'type': 'form',
            'submit': {'tool': 'add_record', 'collection': 'notes'},
            'fields': [
              {'name': 'title', 'label': 'Title', 'required': true},
            ],
          },
        ],
      };
      expect(
          ScreenSchema.validate(schema, collections: collections), isNull);
    });

    test('static text cannot smuggle placeholders', () {
      final schema = notesScreen([
        {'type': 'header', 'text': 'You have {{count}} notes'},
        {
          'type': 'list',
          'item_template': {'title': '{{title}}'},
        },
      ]);
      expect(ScreenSchema.validate(schema, collections: collections),
          contains('placeholders'));
    });

    test('limit must be a number', () {
      final schema = notesScreen();
      (schema['data_source'] as Map)['limit'] = '50';
      expect(ScreenSchema.validate(schema, collections: collections),
          contains('limit'));
    });
  });

  group('rowMatches mirrors buildWhere', () {
    // The Dart filter path (collections) and the SQL path (tables) must
    // answer alike, or the same schema behaves differently by source kind.
    test('not_equals keeps null rows on both paths', () {
      final source = {
        'filters': [
          {'field': 'category', 'operator': 'not_equals', 'value': 'Work'},
        ],
      };
      expect(ScreenSchema.rowMatches({'category': null}, source), isTrue);
      expect(ScreenSchema.rowMatches({'category': 'Home'}, source), isTrue);
      expect(ScreenSchema.rowMatches({'category': 'Work'}, source), isFalse);

      final (where, _) = ScreenSchema.buildWhere(source);
      expect(where, contains('IS NULL'));
    });

    test("'today' under gte means from the start of today onward", () {
      final source = {
        'filters': [
          {'field': 'due', 'operator': 'gte', 'value': 'today'},
        ],
      };
      final now = DateTime.now();
      final laterToday = DateTime(now.year, now.month, now.day, 23, 59);
      final tomorrow = now.add(const Duration(days: 1));
      final yesterday = now.subtract(const Duration(days: 1));
      expect(
          ScreenSchema.rowMatches(
              {'due': laterToday.toIso8601String()}, source),
          isTrue);
      expect(
          ScreenSchema.rowMatches(
              {'due': tomorrow.toIso8601String()}, source),
          isTrue);
      expect(
          ScreenSchema.rowMatches(
              {'due': yesterday.toIso8601String()}, source),
          isFalse);
    });

    test('numbers compare numerically, not as text', () {
      final source = {
        'filters': [
          {'field': 'amount', 'operator': 'gt', 'value': 9},
        ],
      };
      // As text, "10" < "9"; as a number it is greater.
      expect(ScreenSchema.rowMatches({'amount': 10}, source), isTrue);
      expect(ScreenSchema.rowMatches({'amount': 5}, source), isFalse);
    });

    test('like is a case-insensitive contains, as in SQL', () {
      final source = {
        'filters': [
          {'field': 'title', 'operator': 'like', 'value': 'pass'},
        ],
      };
      expect(
          ScreenSchema.rowMatches({'title': 'My Passport'}, source), isTrue);
      expect(ScreenSchema.rowMatches({'title': 'Tickets'}, source), isFalse);
    });

    test('orderAndLimit sorts, trims, and forgives a double limit', () {
      final rows = [
        {'title': 'b', 'n': 2},
        {'title': 'c', 'n': 3},
        {'title': 'a', 'n': 1},
      ];
      final ordered = ScreenSchema.orderAndLimit(rows, {
        'order_by': 'n',
        'order': 'desc',
        'limit': 2.0,
      });
      expect([for (final r in ordered) r['title']], ['c', 'b']);
    });
  });
}
