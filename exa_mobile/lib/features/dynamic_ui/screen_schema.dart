import '../../data/models/agent_datetime_label.dart';
import '../../data/models/reminder.dart';
import '../../data/models/task_item.dart';
import '../../data/models/user_collection.dart';

/// What one data source resolves to: a built-in table or an agent-defined
/// collection, with the columns a component bound to it may reference.
class SourceInfo {
  const SourceInfo({
    required this.table,
    required this.columns,
    this.numericColumns = const [],
    this.dateColumns,
    this.collection,
  });

  final String table;
  final List<String> columns;

  /// Columns a `sum`/`avg` stat may aggregate.
  final List<String> numericColumns;

  /// Columns holding datetimes, when known. Null means "not tracked"
  /// (built-in tables), in which case any column passes the calendar check
  /// as before.
  final List<String>? dateColumns;

  /// Set when the source is an agent-defined collection.
  final UserCollection? collection;

  bool get isCollection => collection != null;
}

/// Validation and query-building for agent-generated screen schemas.
///
/// The agent generates structured JSON only — never widget code. Anything
/// outside this whitelist is rejected before it reaches the renderer.
class ScreenSchema {
  static const allowedLayouts = ['list'];
  static const allowedComponentTypes = [
    'header',
    'text',
    'card',
    'stat',
    'list',
    'table',
    'chart',
    'button',
    'search_box',
    'form',
    'task_board',
    'calendar',
    'web_preview',
  ];

  /// Components that read rows, and so must resolve to exactly one source.
  /// Everything else (header, text, card, button, form, web_preview) is
  /// static or writes through a tool, and needs no data behind it.
  static const dataBoundComponentTypes = {
    'stat',
    'list',
    'table',
    'chart',
    'search_box',
    'task_board',
    'calendar',
  };

  static const allowedButtonActions = ['open_screen'];

  /// What a row tap may do: open another screen, or open THAT row
  /// full-screen (the record detail view - how a note becomes readable).
  static const allowedOnTapTypes = ['open_screen', 'view_record'];
  static const allowedChartTypes = ['bar'];
  static const allowedFormInputs = [
    'text',
    'multiline',
    'number',
    'datetime',
    'select',
  ];
  static const allowedAggregates = ['count', 'sum', 'avg'];

  /// The name a schema's single unnamed `data_source` is given, and the one
  /// components fall back to when they do not say which source they read.
  static const defaultSourceName = 'default';

  /// Icons a row action may show. Names, not codepoints: the schema never
  /// reaches into Flutter's API.
  static const allowedActionIcons = [
    'check',
    'close',
    'schedule',
    'event',
    'edit',
    'star',
    'play',
  ];

  /// How many buttons one row may carry before it stops being a list.
  static const maxRowActions = 3;

  /// Tools a row action may call, with their permitted params.
  ///
  /// Deliberately narrow, and deliberately non-destructive: a generated
  /// screen is something the model wrote, and a tap on one must never be
  /// able to delete, send, or spend. Everything here is reversible from the
  /// normal screens, and none of it requires confirmation - a tool that asks
  /// would have nowhere to ask from here (see the row-action test that pins
  /// both properties).
  ///
  /// `update_record` is the one addition for collection-bound lists; its
  /// permitted params are the collection's own fields and are checked in
  /// [_validateRowAction] against the source, not here.
  static const allowedRowTools = <String, List<String>>{
    'complete_task': ['id'],
    'update_task': ['id', 'status', 'priority', 'due_at'],
    'cancel_reminder': ['id'],
    'plan_day_item': [
      'task_id', 'reminder_id', 'title', 'date', 'start_time',
      'duration_minutes',
    ],
    'unplan_day_item': ['entry_id'],
    'update_record': ['collection', 'id'],
  };

  /// Tools a `form` component may submit to, with their permitted params.
  ///
  /// `add_record` is special-cased in [_validateComponent]: its permitted
  /// params are the fields of the collection the form writes to.
  static const allowedFormTools = <String, List<String>>{
    'create_task': [
      'title', 'description', 'due_at', 'priority', 'category',
      'recurrence_rule',
    ],
    'create_reminder': [
      'title', 'description', 'remind_at', 'recurrence_rule',
    ],
    'create_schedule_event': [
      'title', 'start_at', 'end_at', 'location', 'description',
    ],
    'add_record': ['collection'],
  };
  static const allowedOperators = [
    'equals',
    'not_equals',
    'lt',
    'lte',
    'gt',
    'gte',
    'like',
    'is_null',
    'not_null',
  ];

  /// Tables the dynamic UI may query, with their queryable columns.
  /// Agent-defined collections extend this set at validation time.
  static const allowedTables = <String, List<String>>{
    'tasks': [
      'id', 'title', 'description', 'status', 'priority', 'category',
      'due_at', 'completed_at', 'created_at', 'updated_at',
    ],
    'reminders': [
      'id', 'title', 'description', 'remind_at', 'recurrence_rule',
      'status', 'created_at', 'updated_at',
    ],
    'schedule_items': [
      'id', 'title', 'description', 'location', 'start_at', 'end_at',
      'status', 'created_at', 'updated_at',
    ],
    // Stored files - what the Files screen shows. Includes anything the
    // agent wrote with `write_file`, which is how generated content
    // (digests, summaries, notes) becomes reviewable in a screen.
    // `file_path` is deliberately absent: an absolute on-disk path is
    // nothing to filter on or render.
    'attachments': [
      'id', 'name', 'kind', 'mime_type', 'size_bytes', 'summary',
      'extracted_text', 'source', 'created_at',
    ],
  };

  /// Numeric columns of the built-in tables - what `sum`/`avg` may
  /// aggregate there. Everything else numeric lives in collections.
  static const numericTableColumns = <String, List<String>>{
    'attachments': ['size_bytes'],
  };

  /// Columns whose values come from a fixed set. A filter comparing one of
  /// these against a value outside the set validates the value too - a
  /// filter on status "pending" (real value "Pending") otherwise passes
  /// validation and ships a screen that is silently, permanently empty.
  static const enumColumns = <String, Map<String, List<String>>>{
    'tasks': {
      'status': TaskItem.statuses,
      'priority': TaskItem.priorities,
    },
    'reminders': {
      'status': Reminder.statuses,
    },
  };

  /// Filter values with special meaning, exempt from enum checking.
  static const _dynamicFilterValues = ['today', 'now'];

  /// Every query a schema declares, by name.
  ///
  /// A screen may carry one `data_source` (the original shape, still the
  /// right one for a single-list screen) or a `data_sources` map of named
  /// queries. The singular form is read as the one source named
  /// [defaultSourceName], so every screen written before this existed keeps
  /// working and the renderer only has one shape to handle.
  static Map<String, Map<String, Object?>> sourcesIn(
      Map<String, Object?> schema) {
    final named = schema['data_sources'];
    if (named is Map) {
      return {
        for (final entry in named.entries)
          if (entry.value is Map)
            '${entry.key}': (entry.value as Map).cast<String, Object?>(),
      };
    }
    final single = schema['data_source'];
    if (single is Map) {
      return {defaultSourceName: single.cast<String, Object?>()};
    }
    return const {};
  }

  /// Which source a component reads: the one it names, else the default,
  /// else the only one there is. Null when the answer is genuinely ambiguous
  /// - two sources and no `source` on the component - because guessing there
  /// is how a screen ends up quietly showing the wrong table.
  static String? sourceNameFor(
    Map<String, Object?> component,
    Map<String, Map<String, Object?>> sources,
  ) {
    final named = component['source'];
    if (named is String && named.isNotEmpty) {
      return sources.containsKey(named) ? named : null;
    }
    if (sources.containsKey(defaultSourceName)) return defaultSourceName;
    if (sources.length == 1) return sources.keys.first;
    return null;
  }

  /// What [table] resolves to - a built-in table, an agent-defined
  /// collection, or null when it is neither.
  static SourceInfo? resolveTable(
      Object? table, Map<String, UserCollection> collections) {
    if (table is! String) return null;
    final builtIn = allowedTables[table];
    if (builtIn != null) {
      return SourceInfo(
        table: table,
        columns: builtIn,
        numericColumns: numericTableColumns[table] ?? const [],
      );
    }
    final collection = collections[table];
    if (collection == null) return null;
    return SourceInfo(
      table: table,
      columns: collection.columns,
      numericColumns: collection.numericColumns,
      dateColumns: collection.dateColumns,
      collection: collection,
    );
  }

  /// Returns an error string, or null if the schema is valid.
  ///
  /// [collections] is every agent-defined collection, keyed by name, so a
  /// screen may query a collection exactly like a table. Callers that only
  /// ever validate built-in-table screens may omit it.
  static String? validate(
    Map<String, Object?> schema, {
    Map<String, UserCollection> collections = const {},
  }) {
    final layout = schema['layout'];
    if (layout != null && !allowedLayouts.contains(layout)) {
      return "Unsupported layout '$layout'. Allowed: $allowedLayouts";
    }

    final sources = sourcesIn(schema);
    final components = schema['components'];
    if (components is! List || components.isEmpty) {
      return "Schema must include a non-empty 'components' array";
    }
    final typedComponents = [
      for (final component in components)
        if (component is Map) component.cast<String, Object?>(),
    ];
    if (typedComponents.length != components.length) {
      return 'Each component must be an object';
    }

    // A screen of nothing but static/form components needs no data behind
    // it - "a quick-add form" is a legitimate feature. Only a data-bound
    // component forces a source to exist.
    final needsData = typedComponents
        .any((c) => dataBoundComponentTypes.contains(c['type']));
    if (sources.isEmpty && needsData) {
      return "Schema must include a 'data_source' object, or a "
          "'data_sources' map of named sources";
    }
    for (final entry in sources.entries) {
      final error = _validateSource(entry.key, entry.value, collections);
      if (error != null) return error;
    }

    for (final typed in typedComponents) {
      final type = typed['type'];
      if (type is! String || !allowedComponentTypes.contains(type)) {
        return "Component type '$type' not allowed. "
            'Allowed: $allowedComponentTypes';
      }

      // A data-bound component is validated against the columns of the
      // source it actually reads, so a filter or template naming a column of
      // some *other* source on the same screen is caught here.
      var info = const SourceInfo(table: '', columns: []);
      if (dataBoundComponentTypes.contains(type)) {
        final sourceName = sourceNameFor(typed, sources);
        if (sourceName == null) {
          return "Component '$type' must name a source with \"source\": "
              'one of ${sources.keys.join(', ')}';
        }
        info = resolveTable(sources[sourceName]!['table'], collections)!;
      }

      final componentError = _validateComponent(typed, info, collections);
      if (componentError != null) return componentError;
    }
    return null;
  }

  static String? _validateSource(
    String name,
    Map<String, Object?> source,
    Map<String, UserCollection> collections,
  ) {
    final info = resolveTable(source['table'], collections);
    if (info == null) {
      final known = [...allowedTables.keys, ...collections.keys];
      return "Source '$name': table must be one of: ${known.join(', ')}. "
          'A new kind of data needs define_collection first.';
    }
    final columns = info.columns;

    final filters = source['filters'];
    if (filters != null) {
      if (filters is! List) return "Source '$name': filters must be an array";
      for (final filter in filters) {
        if (filter is! Map) return 'Each filter must be an object';
        final field = filter['field'];
        final operator = filter['operator'];
        if (field is! String || !columns.contains(field)) {
          return "Filter field '$field' is not a column of ${info.table}";
        }
        if (operator is! String || !allowedOperators.contains(operator)) {
          return "Filter operator '$operator' not allowed. "
              'Allowed: $allowedOperators';
        }
        final enumError = _validateEnumValue(info, field, operator,
            filter['value']);
        if (enumError != null) return enumError;
      }
    }

    final orderBy = source['order_by'];
    if (orderBy != null &&
        (orderBy is! String || !columns.contains(orderBy))) {
      return "order_by '$orderBy' is not a column of ${info.table}";
    }
    final order = source['order'];
    if (order != null &&
        (order is! String ||
            !const ['asc', 'desc'].contains(order.toLowerCase()))) {
      return "order '$order' must be 'asc' or 'desc'";
    }
    final limit = source['limit'];
    if (limit != null && limit is! num) {
      return "Source '$name': limit must be a number, not '$limit'";
    }
    return null;
  }

  /// Rejects a filter comparing an enum-valued column against a value that
  /// can never match. The error lists the real values because that is what
  /// makes the model fix it on the next attempt.
  static String? _validateEnumValue(
    SourceInfo info,
    String field,
    String operator,
    Object? value,
  ) {
    if (operator != 'equals' && operator != 'not_equals') return null;
    if (value is! String || _dynamicFilterValues.contains(value)) return null;

    List<String>? allowed;
    final builtIn = enumColumns[info.table];
    if (builtIn != null) allowed = builtIn[field];
    final selectField = info.collection?.fieldNamed(field);
    if (selectField != null && selectField.type == 'select') {
      allowed = selectField.options;
    }
    if (allowed == null || allowed.contains(value)) return null;
    return "Filter value '$value' can never match ${info.table}.$field. "
        'Allowed values: ${allowed.join(', ')}';
  }

  static String? _validateComponent(
    Map<String, Object?> component,
    SourceInfo info,
    Map<String, UserCollection> collections,
  ) {
    final columns = info.columns;

    // Templates are checked before the per-type rules because every component
    // that has them had the same hole: `_validateComponent` verified `fields`,
    // `columns` and `group_by` but never the `{{placeholder}}` names, so a
    // placeholder that named no column passed validation and then rendered as
    // nothing. The screen looked built and shipped a blank field - the one
    // failure mode this whole allowlist exists to prevent.
    final templateError = _validateTemplates(component, columns);
    if (templateError != null) return templateError;

    switch (component['type']) {
      case 'header' || 'text' || 'card':
        // Static text has no row to render against, so a placeholder there
        // would silently print itself. Rejecting it teaches the model the
        // rule; the old behavior shipped a header reading "{{count}} tasks".
        for (final key in const ['text', 'title']) {
          final value = component[key];
          if (value is String && templatePlaceholders(value).isNotEmpty) {
            return "A '${component['type']}' component cannot use "
                '{{placeholders}} - they only work inside a list '
                "item_template. Put the text itself in '$key'.";
          }
        }
      case 'stat':
        final aggregate = component['aggregate'] ?? 'count';
        if (!allowedAggregates.contains(aggregate)) {
          return "stat aggregate '$aggregate' not allowed. "
              'Allowed: $allowedAggregates';
        }
        if (aggregate != 'count') {
          final field = component['field'];
          if (field is! String || !columns.contains(field)) {
            return "A '$aggregate' stat needs a numeric 'field' column "
                '(valid columns: ${columns.join(', ')})';
          }
          if (!info.numericColumns.contains(field)) {
            return "'$field' is not a numeric column of ${info.table}, so "
                "'$aggregate' would always be 0. Numeric columns: "
                '${info.numericColumns.isEmpty ? '(none - use count, or '
                    'define a number field)' : info.numericColumns.join(', ')}';
          }
        }
      case 'list':
        final onTap = component['on_tap'];
        if (onTap != null) {
          if (onTap is! Map || !allowedOnTapTypes.contains(onTap['type'])) {
            return "list 'on_tap.type' must be one of: $allowedOnTapTypes";
          }
          if (onTap['type'] == 'open_screen' &&
              onTap['screen_key'] is! String) {
            return "A list on_tap needs a 'screen_key'";
          }
        }
        final actions = component['actions'];
        if (actions != null) {
          if (actions is! List) return "list 'actions' must be an array";
          if (actions.length > maxRowActions) {
            return 'A list row may carry at most $maxRowActions actions';
          }
          for (final action in actions) {
            if (action is! Map) return 'Each row action must be an object';
            final error = _validateRowAction(
                action.cast<String, Object?>(), info);
            if (error != null) return error;
          }
        }
      case 'table':
        final tableColumns = component['columns'];
        if (tableColumns is! List || tableColumns.isEmpty) {
          return "A 'table' component needs a non-empty 'columns' array";
        }
        for (final column in tableColumns) {
          final field = column is Map ? column['field'] : column;
          if (field is! String || !columns.contains(field)) {
            return "Table column '$field' is not a valid column";
          }
        }
      case 'chart':
        final chartType = component['chart_type'] ?? 'bar';
        if (!allowedChartTypes.contains(chartType)) {
          return "chart_type '$chartType' not allowed. "
              'Allowed: $allowedChartTypes';
        }
        final groupBy = component['group_by'];
        if (groupBy is! String || !columns.contains(groupBy)) {
          return "Chart 'group_by' must be a valid column";
        }
      case 'button':
        final action = component['action'];
        if (action is! Map ||
            !allowedButtonActions.contains(action['type'])) {
          return "Button 'action.type' must be one of: "
              '$allowedButtonActions';
        }
        if (action['type'] == 'open_screen' &&
            action['screen_key'] is! String) {
          return "Button open_screen action needs a 'screen_key'";
        }
      case 'search_box':
        final fields = component['fields'];
        if (fields is! List || fields.isEmpty) {
          return "A 'search_box' component needs a non-empty 'fields' "
              'array of columns to search';
        }
        for (final field in fields) {
          if (field is! String || !columns.contains(field)) {
            return "search_box field '$field' is not a valid column";
          }
        }
      case 'form':
        return _validateForm(component, collections);
      case 'task_board':
        if (!columns.contains('status')) {
          return "A 'task_board' needs a table with a status column "
              '(use the tasks table)';
        }
      case 'calendar':
        final dateField = component['date_field'];
        if (dateField is! String || !columns.contains(dateField)) {
          return "A 'calendar' component needs a valid 'date_field' "
              'column (e.g. start_at, due_at, remind_at)';
        }
        final dates = info.dateColumns;
        if (dates != null && !dates.contains(dateField)) {
          return "'$dateField' is not a datetime field of ${info.table}. "
              'Datetime fields: ${dates.join(', ')}';
        }
      case 'web_preview':
        final url = component['url'];
        if (url is! String ||
            !(url.startsWith('https://') || url.startsWith('http://'))) {
          return "A 'web_preview' needs an http(s) 'url'";
        }
    }
    return null;
  }

  /// A form writes through a tool. For the built-in tools the permitted
  /// params are fixed; for `add_record` they are the target collection's own
  /// fields, so the form and the data it creates can never disagree.
  static String? _validateForm(
    Map<String, Object?> component,
    Map<String, UserCollection> collections,
  ) {
    final submit = component['submit'];
    final tool = submit is Map ? submit['tool'] : null;
    if (tool is! String || !allowedFormTools.containsKey(tool)) {
      return "A 'form' needs submit.tool, one of: "
          '${allowedFormTools.keys.join(', ')}';
    }

    var allowedParams = allowedFormTools[tool]!;
    UserCollection? collection;
    if (tool == 'add_record') {
      final name = (submit as Map)['collection'];
      collection = name is String ? collections[name] : null;
      if (collection == null) {
        return "An add_record form needs submit.collection naming an "
            'existing collection (define_collection first). Known: '
            '${collections.keys.isEmpty ? '(none)' : collections.keys.join(', ')}';
      }
      allowedParams = [for (final field in collection.fields) field.name];
    }

    final fields = component['fields'];
    if (fields is! List || fields.isEmpty) {
      return "A 'form' needs a non-empty 'fields' array";
    }
    for (final field in fields) {
      if (field is! Map) return 'Each form field must be an object';
      final fieldName = field['name'];
      if (fieldName is! String || !allowedParams.contains(fieldName)) {
        return "Form field '$fieldName' is not a parameter of $tool "
            '(allowed: $allowedParams)';
      }
      final inputType = field['input'] ?? 'text';
      if (!allowedFormInputs.contains(inputType)) {
        return "Form input type '$inputType' not allowed. "
            'Allowed: $allowedFormInputs';
      }
      if (inputType == 'select' &&
          (field['options'] is! List ||
              (field['options'] as List).isEmpty)) {
        return "Form select field '$fieldName' needs an 'options' "
            'array';
      }
    }
    return null;
  }

  /// One button on a row: which tool it calls and what it passes.
  ///
  /// Every param value is a template rendered against that row, so `{{id}}`
  /// is how an action knows which record it is acting on. The placeholders
  /// are checked against the source's columns for the same reason item
  /// templates are: one that names nothing renders empty, and an action that
  /// silently passes an empty id is worse than a rejected schema.
  static String? _validateRowAction(
      Map<String, Object?> action, SourceInfo info) {
    final columns = info.columns;
    final tool = action['tool'];
    if (tool is! String || !allowedRowTools.containsKey(tool)) {
      return "Row action tool '$tool' not allowed. Allowed: "
          '${allowedRowTools.keys.join(', ')}';
    }
    if (tool == 'update_record' && !info.isCollection) {
      return 'update_record row actions only work on a collection source, '
          "not on '${info.table}'";
    }
    if (action['label'] is! String ||
        (action['label'] as String).trim().isEmpty) {
      return "Row action for '$tool' needs a 'label'";
    }
    final icon = action['icon'];
    if (icon != null &&
        (icon is! String || !allowedActionIcons.contains(icon))) {
      return "Row action icon '$icon' not allowed. Allowed: "
          '$allowedActionIcons';
    }
    final params = action['params'];
    if (params != null && params is! Map) {
      return "Row action 'params' must be an object";
    }
    // For update_record the permitted params are the collection's fields
    // (plus the record's identity); a param no field owns would be stored
    // and never rendered.
    final allowedParams = tool == 'update_record'
        ? [
            ...allowedRowTools[tool]!,
            for (final field in info.collection!.fields) field.name,
          ]
        : allowedRowTools[tool]!;
    for (final entry in ((params as Map?) ?? const {}).entries) {
      final name = '${entry.key}';
      if (!allowedParams.contains(name)) {
        return "Row action param '$name' is not a parameter of $tool "
            '(allowed: $allowedParams)';
      }
      for (final placeholder
          in templatePlaceholders('${entry.value}')) {
        if (columnForPlaceholder(placeholder, columns) == null) {
          return "Row action param '$name' uses '{{$placeholder}}', which "
              'is not a column. Valid columns: ${columns.join(', ')}';
        }
      }
    }
    return null;
  }

  /// Checks every `{{placeholder}}` a component's templates reference.
  ///
  /// The error names the valid columns, because that is what makes the model
  /// fix it: on the device it corrected a rejected filter operator on its very
  /// next attempt when told the allowed values, and silently shipped a broken
  /// template when told nothing.
  static String? _validateTemplates(
      Map<String, Object?> component, List<String> columns) {
    final templates = <String>[
      for (final key in const ['title', 'subtitle', 'description'])
        if (((component['item_template'] as Map?) ?? const {})[key]
            case final value?)
          value.toString(),
    ];
    for (final template in templates) {
      for (final placeholder in templatePlaceholders(template)) {
        if (columnForPlaceholder(placeholder, columns) != null) continue;
        return "Template placeholder '{{$placeholder}}' is not a valid "
            'column. Valid columns: ${columns.join(', ')}. Add '
            "'$labelSuffix' to a date column (e.g. {{due_at$labelSuffix}}) "
            'to show it as a readable date.';
      }
    }
    return null;
  }

  /// The concrete bounds "today" describes under [operator], so a filter
  /// like `start_at gte today` means "from the start of today onward"
  /// instead of silently collapsing to "on today's date".
  static (String clause, List<Object?> args) _todayClause(
      String field, String operator) {
    final now = DateTime.now();
    final dayStart = DateTime(now.year, now.month, now.day);
    final nextDayStart = dayStart.add(const Duration(days: 1));
    final start = dayStart.toIso8601String();
    final end = nextDayStart.toIso8601String();
    return switch (operator) {
      'gte' => ('$field >= ?', [start]),
      'gt' => ('$field >= ?', [end]),
      'lt' => ('$field < ?', [start]),
      'lte' => ('$field < ?', [end]),
      'not_equals' => ('($field < ? OR $field >= ? OR $field IS NULL)',
          [start, end]),
      // equals, like, and anything else: "on today's date".
      _ => ('($field >= ? AND $field < ?)', [start, end]),
    };
  }

  /// Builds (whereClause, args) from validated filters. The special value
  /// "today" is interpreted under its operator (see [_todayClause]); "now"
  /// is the current datetime.
  static (String?, List<Object?>) buildWhere(Map<String, Object?> dataSource) {
    final filters = (dataSource['filters'] as List?) ?? const [];
    final clauses = <String>[];
    final args = <Object?>[];
    for (final raw in filters) {
      final filter = (raw as Map).cast<String, Object?>();
      final field = filter['field'] as String;
      final operator = filter['operator'] as String;
      var value = filter['value'];

      if (value == 'today') {
        final (clause, todayArgs) = _todayClause(field, operator);
        clauses.add(clause);
        args.addAll(todayArgs);
        continue;
      }
      if (value == 'now') {
        value = DateTime.now().toIso8601String();
      }

      switch (operator) {
        case 'equals':
          clauses.add('$field = ?');
          args.add(value);
        case 'not_equals':
          // SQL's `!=` drops NULL rows, which is never what "everything
          // except X" means to a person: an uncategorized task IS "not
          // Work".
          clauses.add('($field != ? OR $field IS NULL)');
          args.add(value);
        case 'lt':
          clauses.add('$field < ?');
          args.add(value);
        case 'lte':
          clauses.add('$field <= ?');
          args.add(value);
        case 'gt':
          clauses.add('$field > ?');
          args.add(value);
        case 'gte':
          clauses.add('$field >= ?');
          args.add(value);
        case 'like':
          clauses.add('$field LIKE ?');
          args.add('%$value%');
        case 'is_null':
          clauses.add('$field IS NULL');
        case 'not_null':
          clauses.add('$field IS NOT NULL');
      }
    }
    return (clauses.isEmpty ? null : clauses.join(' AND '), args);
  }

  /// Whether [row] passes [filters] - the Dart twin of [buildWhere], used
  /// for collection records (which are filtered after the fetch, never via
  /// SQL). The semantics are pinned to each other by test.
  static bool rowMatches(
      Map<String, Object?> row, Map<String, Object?> dataSource) {
    final filters = (dataSource['filters'] as List?) ?? const [];
    for (final raw in filters) {
      final filter = (raw as Map).cast<String, Object?>();
      final field = filter['field'] as String;
      final operator = filter['operator'] as String;
      var value = filter['value'];
      final actual = row[field];

      if (value == 'today') {
        final text = actual?.toString() ?? '';
        final now = DateTime.now();
        final dayStart = DateTime(now.year, now.month, now.day);
        final start = dayStart.toIso8601String();
        final end = dayStart.add(const Duration(days: 1)).toIso8601String();
        final ok = switch (operator) {
          'gte' => text.compareTo(start) >= 0,
          'gt' => text.compareTo(end) >= 0,
          'lt' => actual != null && text.compareTo(start) < 0,
          'lte' => actual != null && text.compareTo(end) < 0,
          'not_equals' =>
            actual == null || text.compareTo(start) < 0 ||
                text.compareTo(end) >= 0,
          _ => actual != null &&
              text.compareTo(start) >= 0 &&
              text.compareTo(end) < 0,
        };
        if (!ok) return false;
        continue;
      }
      if (value == 'now') value = DateTime.now().toIso8601String();

      final ok = switch (operator) {
        'equals' => _compare(actual, value) == 0,
        'not_equals' => actual == null || _compare(actual, value) != 0,
        'lt' => actual != null && (_compare(actual, value) ?? 1) < 0,
        'lte' => actual != null && (_compare(actual, value) ?? 1) <= 0,
        'gt' => actual != null && (_compare(actual, value) ?? -1) > 0,
        'gte' => actual != null && (_compare(actual, value) ?? -1) >= 0,
        'like' => (actual?.toString().toLowerCase() ?? '')
            .contains(value.toString().toLowerCase()),
        'is_null' => actual == null,
        'not_null' => actual != null,
        _ => true,
      };
      if (!ok) return false;
    }
    return true;
  }

  /// Compares like SQLite would: numerically when both sides are (or parse
  /// as) numbers, as text otherwise. Null when incomparable.
  static int? _compare(Object? actual, Object? expected) {
    if (actual == null) return null;
    final a = actual is num ? actual : num.tryParse(actual.toString());
    final b = expected is num ? expected : num.tryParse('$expected');
    if (a != null && b != null) return a.compareTo(b);
    return actual.toString().compareTo('$expected');
  }

  /// Sorts and trims [rows] the way the SQL path would.
  static List<Map<String, Object?>> orderAndLimit(
    List<Map<String, Object?>> rows,
    Map<String, Object?> dataSource,
  ) {
    final orderBy = dataSource['order_by'] as String?;
    final desc =
        (dataSource['order'] as String?)?.toLowerCase() == 'desc';
    final sorted = [...rows];
    if (orderBy != null) {
      sorted.sort((x, y) {
        final cmp = _compare(x[orderBy], y[orderBy]) ??
            // Nulls last, like SQLite ASC puts them first - but a screen
            // sorting by due date wants the undated at the bottom.
            ((x[orderBy] == null ? 1 : 0) - (y[orderBy] == null ? 1 : 0));
        return desc ? -cmp : cmp;
      });
    }
    final limit = (dataSource['limit'] as num?)?.toInt() ?? 200;
    return sorted.length > limit ? sorted.sublist(0, limit) : sorted;
  }

  /// Placeholder suffix that renders a stored timestamp the way Exa quotes
  /// dates everywhere else.
  ///
  /// The agent already meets this convention on every tool result, where each
  /// scheduling field arrives beside a `..._label` (see [agentDateTimeLabel]).
  /// So it reaches for `{{due_at_label}}` in a screen template too - which was
  /// not a column, rendered as nothing, and left a dangling "Due" in the UI.
  /// Supporting the suffix is better than rejecting it: `{{due_at}}` alone
  /// would render `2026-07-24T10:00:00.000`, which is not what anyone wants on
  /// a card.
  static const labelSuffix = '_label';

  /// The `{{placeholder}}` names in [template].
  static Set<String> templatePlaceholders(String template) => {
        for (final match in RegExp(r'\{\{(\w+)\}\}').allMatches(template))
          match.group(1)!,
      };

  /// The column a placeholder reads, or null when it names nothing valid.
  static String? columnForPlaceholder(
      String placeholder, List<String> columns) {
    if (columns.contains(placeholder)) return placeholder;
    if (placeholder.endsWith(labelSuffix)) {
      final base =
          placeholder.substring(0, placeholder.length - labelSuffix.length);
      if (columns.contains(base)) return base;
    }
    return null;
  }

  /// Substitutes `{{column}}` placeholders in an item template string.
  ///
  /// A `..._label` placeholder, and any value that is a stored ISO timestamp,
  /// render as a readable date rather than raw ISO text.
  static String renderTemplate(String template, Map<String, Object?> row) {
    return template.replaceAllMapped(RegExp(r'\{\{(\w+)\}\}'), (match) {
      final name = match.group(1)!;
      if (row.containsKey(name)) {
        return _formatted(row[name]);
      }
      if (name.endsWith(labelSuffix)) {
        final base = name.substring(0, name.length - labelSuffix.length);
        if (row.containsKey(base)) return _formatted(row[base]);
      }
      return '';
    });
  }

  /// A stored value as the user should read it: timestamps become the same
  /// label the agent quotes, everything else is itself.
  static String _formatted(Object? value) {
    if (value == null) return '';
    final text = value.toString();
    final parsed = DateTime.tryParse(text);
    if (parsed == null || !text.contains('-')) return text;
    // Midnight almost always means "a date with no time", not 00:00.
    return parsed.hour == 0 && parsed.minute == 0
        ? agentDateLabel(parsed)
        : agentDateTimeLabel(parsed);
  }
}
