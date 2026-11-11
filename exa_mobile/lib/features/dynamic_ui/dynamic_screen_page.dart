import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../agent/tools/tool_registry.dart' show builtInScreenRoutes;
import '../../data/models/dynamic_screen.dart';
import '../../data/models/user_collection.dart';
import '../../shared/providers.dart';
import '../../shared/theme/exa_theme.dart';
import '../../shared/widgets/exa_orb.dart';
import '../browser/browser_screen.dart'
    show browserSessionRepositoryProvider;
import 'record_detail_page.dart';
import 'screen_query.dart';
import 'screen_schema.dart';

class _ScreenData {
  const _ScreenData(
    this.screen, {
    this.rowsBySource = const {},
    this.stats = const {},
    this.collections = const {},
    this.schemaError,
  });

  final DynamicScreen screen;

  /// Rows per named source. A screen with the original singular
  /// `data_source` has the one entry `default`.
  final Map<String, List<Map<String, Object?>>> rowsBySource;

  /// Aggregate results, by the index of the `stat` component that asked for
  /// one. Computed over the whole source rather than [rowsBySource], so a
  /// count is the real count and not "however many rows fit under the row
  /// limit".
  final Map<int, num?> stats;

  /// Agent-defined collections, by name - so a component knows whether its
  /// source is a collection (whose records are editable full-screen).
  final Map<String, UserCollection> collections;

  /// Why the stored schema could not be used. Shown, not swallowed: a screen
  /// that renders blank looks built and is the failure this whole allowlist
  /// exists to prevent.
  final String? schemaError;

  List<Map<String, Object?>> rowsFor(String? sourceName) =>
      rowsBySource[sourceName] ?? const [];
}

final _screenDataProvider = FutureProvider.autoDispose
    .family<_ScreenData?, String>((ref, screenKey) async {
  final screen =
      await ref.watch(dynamicScreenRepositoryProvider).getByKey(screenKey);
  if (screen == null) return null;

  final records = ref.watch(userCollectionRepositoryProvider);
  final collections = await records.asMap();

  final error =
      ScreenSchema.validate(screen.schema, collections: collections);
  if (error != null) {
    return _ScreenData(screen, collections: collections, schemaError: error);
  }

  final db = ref.watch(appDatabaseProvider).db;
  final sources = ScreenSchema.sourcesIn(screen.schema);

  // Identifiers were checked against the allowlist (and the collection
  // definitions) by validate(); values are always bound args or filtered
  // in Dart - see [ScreenQuery].
  final rowsBySource = <String, List<Map<String, Object?>>>{};
  for (final entry in sources.entries) {
    rowsBySource[entry.key] = await ScreenQuery.rowsFor(
      db: db,
      records: records,
      source: entry.value,
      collections: collections,
    );
  }

  final components = (screen.schema['components'] as List? ?? [])
      .whereType<Map>()
      .map((component) => component.cast<String, Object?>())
      .toList();
  final stats = <int, num?>{};
  for (final (index, component) in components.indexed) {
    if (component['type'] != 'stat') continue;
    final sourceName = ScreenSchema.sourceNameFor(component, sources);
    final source = sources[sourceName];
    if (source == null) continue;
    stats[index] = await ScreenQuery.aggregate(
      db: db,
      records: records,
      source: source,
      component: component,
      collections: collections,
    );
  }

  return _ScreenData(screen,
      rowsBySource: rowsBySource, stats: stats, collections: collections);
});

/// Renders an agent-generated screen from its stored JSON schema using only
/// whitelisted components - the agent never produces widget code.
class DynamicScreenPage extends ConsumerStatefulWidget {
  const DynamicScreenPage({super.key, required this.screenKey});

  final String screenKey;

  @override
  ConsumerState<DynamicScreenPage> createState() =>
      _DynamicScreenPageState();
}

class _DynamicScreenPageState extends ConsumerState<DynamicScreenPage> {
  /// Search text per search_box component index. Kept per box rather than
  /// per screen so two boxes over two sources do not filter each other.
  final Map<int, String> _searchQueries = {};

  /// Form state, keyed by "componentIndex:fieldName".
  final Map<String, String> _formValues = {};

  @override
  Widget build(BuildContext context) {
    final dataAsync = ref.watch(_screenDataProvider(widget.screenKey));

    return dataAsync.when(
      loading: () => const Scaffold(
          body: Center(child: CircularProgressIndicator())),
      error: (error, _) => Scaffold(
        appBar: AppBar(),
        body: Center(child: Text('Could not load screen: $error')),
      ),
      data: (data) {
        if (data == null) {
          return Scaffold(
            appBar: AppBar(title: const Text('Screen not found')),
            body: Center(
                child:
                    Text("No screen named '${widget.screenKey}' exists.")),
          );
        }
        final screen = data.screen;
        return Scaffold(
          appBar: AppBar(
            title: Text(screen.title),
            actions: [
              IconButton(
                tooltip:
                    screen.isSaved ? 'Saved view' : 'Save this view',
                icon: Icon(screen.isSaved
                    ? Icons.bookmark
                    : Icons.bookmark_outline),
                onPressed: () async {
                  await ref
                      .read(dynamicScreenRepositoryProvider)
                      .markSaved(widget.screenKey, saved: !screen.isSaved);
                  ref.invalidate(_screenDataProvider(widget.screenKey));
                },
              ),
              PopupMenuButton<String>(
                onSelected: (value) {
                  if (value == 'delete') _confirmDelete(context, screen);
                },
                itemBuilder: (context) => const [
                  PopupMenuItem(
                      value: 'delete', child: Text('Delete this screen')),
                ],
              ),
            ],
          ),
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 14, vertical: 7),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      ExaColors.accentGlowStart.withValues(alpha: 0.30),
                      ExaColors.accentGlowEnd.withValues(alpha: 0.10),
                      Colors.transparent,
                    ],
                  ),
                  border: const Border(
                    bottom: BorderSide(color: ExaColors.outline),
                  ),
                ),
                child: Row(
                  children: [
                    const ExaOrb(size: 16),
                    const SizedBox(width: 8),
                    Text('Generated by Exa',
                        style: Theme.of(context)
                            .textTheme
                            .labelMedium
                            ?.copyWith(color: ExaColors.spark)),
                  ],
                ),
              ),
              Expanded(child: _renderComponents(context, data)),
            ],
          ),
        );
      },
    );
  }

  Widget _renderComponents(BuildContext context, _ScreenData data) {
    final components = (data.screen.schema['components'] as List? ?? [])
        .whereType<Map>()
        .map((c) => c.cast<String, Object?>())
        .toList();
    final sources = ScreenSchema.sourcesIn(data.screen.schema);

    String? sourceOf(Map<String, Object?> component) =>
        ScreenSchema.sourceNameFor(component, sources);

    // A search box filters the source it reads, and only that one - on a
    // dashboard, typing in the tasks box must not empty the events list.
    List<Map<String, Object?>> rowsFor(Map<String, Object?> component) {
      final sourceName = sourceOf(component);
      var rows = data.rowsFor(sourceName);
      for (final (index, box) in components.indexed) {
        if (box['type'] != 'search_box') continue;
        if (sourceOf(box) != sourceName) continue;
        final query = (_searchQueries[index] ?? '').trim().toLowerCase();
        if (query.isEmpty) continue;
        final fields = (box['fields'] as List? ?? []).whereType<String>();
        rows = rows
            .where((row) => fields.any((field) =>
                (row[field]?.toString().toLowerCase() ?? '').contains(query)))
            .toList();
      }
      return rows;
    }

    // Consecutive stats render as one strip of tiles, so "12 open · 3
    // overdue · 4 today" reads as a summary rather than three paragraphs.
    final rendered = <Widget>[];
    for (var index = 0; index < components.length; index++) {
      final component = components[index];
      if (component['type'] == 'stat') {
        final run = <(int, Map<String, Object?>)>[];
        while (index < components.length &&
            components[index]['type'] == 'stat') {
          run.add((index, components[index]));
          index++;
        }
        index--;
        rendered.add(_renderStatRow(context, run, data));
        continue;
      }
      rendered.add(_renderComponent(
          context, index, component, rowsFor, data, sourceOf));
    }

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        if (data.schemaError != null) _SchemaErrorBanner(error: data.schemaError!),
        ...rendered,
      ],
    );
  }

  Widget _renderComponent(
    BuildContext context,
    int componentIndex,
    Map<String, Object?> component,
    List<Map<String, Object?>> Function(Map<String, Object?>) rowsFor,
    _ScreenData data,
    String? Function(Map<String, Object?>) sourceOf,
  ) {
    final rows = ScreenSchema.dataBoundComponentTypes
            .contains(component['type'])
        ? rowsFor(component)
        : const <Map<String, Object?>>[];
    // The table (or collection) behind this component, for components that
    // open or write back to their rows.
    final sources = ScreenSchema.sourcesIn(data.screen.schema);
    final sourceTable =
        sources[sourceOf(component)]?['table'] as String?;
    return switch (component['type']) {
            'form' => _renderForm(context, componentIndex, component),
            'task_board' => _renderTaskBoard(context, rows),
            'calendar' => _renderCalendar(context, component, rows),
            'web_preview' => _renderWebPreview(context, component),
            'header' => Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  component['text']?.toString() ?? '',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
              ),
            'text' => Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Text(component['text']?.toString() ?? ''),
              ),
            'card' => Card(
                margin: const EdgeInsets.symmetric(vertical: 6),
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (component['title'] != null)
                        Text(component['title'].toString(),
                            style:
                                Theme.of(context).textTheme.titleMedium),
                      if (component['text'] != null) ...[
                        const SizedBox(height: 4),
                        Text(component['text'].toString()),
                      ],
                    ],
                  ),
                ),
              ),
            'search_box' => Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: TextField(
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search),
                    hintText: 'Search...',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  onChanged: (value) => setState(
                      () => _searchQueries[componentIndex] = value),
                ),
              ),
            'button' => Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: FilledButton(
                  onPressed: () => _runButtonAction(component),
                  child:
                      Text(component['label']?.toString() ?? 'Open'),
                ),
              ),
            'list' => _renderList(context, component, rows,
                table: sourceTable,
                collection: data.collections[sourceTable]),
            'table' => _renderTable(context, component, rows),
            'chart' => _renderBarChart(context, component, rows),
            _ => const SizedBox.shrink(),
          };
  }

  /// Deletes the screen for good and leaves.
  ///
  /// Distinct from the bookmark, which only decides whether it sits in the
  /// menu: a screen the user is finished with should be able to actually go,
  /// rather than accumulating invisibly forever. Nothing it *showed* is
  /// touched - a screen is a saved question about the data, not the data.
  Future<void> _confirmDelete(BuildContext context, DynamicScreen screen) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Delete "${screen.title}"?'),
        content: const Text(
            'The screen goes for good. Your tasks, events and files are '
            'untouched - only this view of them. Exa can build it again if '
            'you ask.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (confirmed != true) return;
    await ref
        .read(dynamicScreenRepositoryProvider)
        .delete(widget.screenKey);
    // The nav menu lists saved screens; one that no longer exists must not
    // still be a tile there.
    ref.invalidate(savedScreensProvider);
    // Navigator rather than context.pop(): this page is pushed onto
    // go_router's own Navigator, so both work in the app, and this one does
    // not demand a router ancestor just to leave a screen.
    if (context.mounted) await Navigator.of(context).maybePop();
  }

  /// A strip of number tiles - the answer to "how many", without making the
  /// user count a list.
  Widget _renderStatRow(
    BuildContext context,
    List<(int, Map<String, Object?>)> stats,
    _ScreenData data,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      // IntrinsicHeight, not crossAxisAlignment.stretch: the strip sits in a
      // scrolling column, where "stretch" asks for infinite height and
      // throws. This keeps the tiles equal even when one label wraps.
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final (index, component) in stats)
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: _StatTile(
                    label: component['label']?.toString() ?? '',
                    value: _formatStat(component, data.stats[index]),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// Counts stay integers; an average is worth one decimal and no more.
  static String _formatStat(Map<String, Object?> component, num? value) {
    if (value == null) return '—';
    final aggregate = component['aggregate']?.toString() ?? 'count';
    final text = aggregate == 'avg'
        ? value.toStringAsFixed(1)
        : (value % 1 == 0 ? value.toInt().toString() : value.toString());
    final unit = component['unit']?.toString();
    return unit == null || unit.isEmpty ? text : '$text$unit';
  }

  /// Runs one row action through the tool registry - the same validated,
  /// logged path a form submit takes. The schema never executes anything
  /// itself; it names a tool from a short allowlist and the registry decides.
  Future<void> _runRowAction(
    Map<String, Object?> action,
    Map<String, Object?> row, {
    UserCollection? collection,
  }) async {
    final tool = action['tool'] as String;
    final params = ((action['params'] as Map?) ?? const {})
        .map((key, value) => MapEntry(
            '$key', ScreenSchema.renderTemplate('$value', row) as Object?));
    // A row on a collection list already knows its collection; the schema
    // does not have to repeat it on every action.
    if (tool == 'update_record' && collection != null) {
      params.putIfAbsent('collection', () => collection.name);
      params.putIfAbsent('id', () => '${row['id']}');
    }
    final messenger = ScaffoldMessenger.of(context);
    final result =
        await ref.read(toolRegistryProvider).execute(tool, params);
    messenger.showSnackBar(SnackBar(
      content: Text(result.success
          ? '${action['label']} — done.'
          : 'Could not: ${result.error}'),
    ));
    if (result.success) {
      // Both the list and any counts above it are now stale.
      ref.invalidate(_screenDataProvider(widget.screenKey));
    }
  }

  void _openRow(
    Map<String, Object?> onTap,
    Map<String, Object?> row, {
    String? table,
    UserCollection? collection,
  }) {
    switch (onTap['type']) {
      case 'open_screen':
        final key = onTap['screen_key'] as String?;
        if (key == null) return;
        context.push(builtInScreenRoutes[key] ?? '/screen/$key');
      case 'view_record':
        // The tapped row, full-screen. The row map is already loaded, so
        // the detail page renders from memory; edits and deletes report
        // back through onChanged so this screen refreshes.
        if (table == null) return;
        Navigator.of(context).push(MaterialPageRoute<void>(
          builder: (_) => RecordDetailPage(
            table: table,
            row: row,
            collection: collection,
            onChanged: () =>
                ref.invalidate(_screenDataProvider(widget.screenKey)),
          ),
        ));
    }
  }

  static IconData _actionIcon(String? name) => switch (name) {
        'check' => Icons.check,
        'close' => Icons.close,
        'schedule' => Icons.schedule,
        'event' => Icons.event,
        'edit' => Icons.edit_outlined,
        'star' => Icons.star_outline,
        'play' => Icons.play_arrow,
        _ => Icons.bolt,
      };

  /// Agent-defined input form that submits through the (logged, validated)
  /// tool registry - the schema never executes anything directly.
  Widget _renderForm(
      BuildContext context, int componentIndex, Map<String, Object?> component) {
    final fields = (component['fields'] as List? ?? [])
        .whereType<Map>()
        .map((f) => f.cast<String, Object?>())
        .toList();
    final submit =
        ((component['submit'] as Map?) ?? const {}).cast<String, Object?>();
    final submitTool = submit['tool'] as String?;
    if (submitTool == null) return const SizedBox.shrink();

    String keyFor(String field) => '$componentIndex:$field';

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (component['title'] != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Text(component['title'].toString(),
                    style: Theme.of(context).textTheme.titleMedium),
              ),
            for (final field in fields)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _renderFormField(context, keyFor, field),
              ),
            FilledButton(
              onPressed: () => _submitForm(componentIndex, submit, fields),
              child: Text(component['submit_label']?.toString() ?? 'Save'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _renderFormField(
    BuildContext context,
    String Function(String) keyFor,
    Map<String, Object?> field,
  ) {
    final name = field['name'] as String;
    final label = field['label']?.toString() ?? name;
    final input = field['input']?.toString() ?? 'text';
    final stateKey = keyFor(name);

    switch (input) {
      case 'select':
        final options = (field['options'] as List? ?? [])
            .map((o) => o.toString())
            .toList();
        return DropdownButtonFormField<String>(
          initialValue: _formValues[stateKey],
          decoration: InputDecoration(
              labelText: label, border: const OutlineInputBorder()),
          items: [
            for (final option in options)
              DropdownMenuItem(value: option, child: Text(option)),
          ],
          onChanged: (value) =>
              setState(() => _formValues[stateKey] = value ?? ''),
        );
      case 'datetime':
        final current = _formValues[stateKey];
        return OutlinedButton.icon(
          icon: const Icon(Icons.event),
          label: Text(current == null
              ? label
              : '$label: ${DateFormat('MMM d, HH:mm').format(DateTime.parse(current))}'),
          onPressed: () async {
            final date = await showDatePicker(
              context: context,
              initialDate: DateTime.now(),
              firstDate: DateTime(2020),
              lastDate: DateTime(2100),
            );
            if (date == null || !context.mounted) return;
            final time = await showTimePicker(
                context: context, initialTime: TimeOfDay.now());
            final value = DateTime(date.year, date.month, date.day,
                time?.hour ?? 9, time?.minute ?? 0);
            setState(() =>
                _formValues[stateKey] = value.toIso8601String());
          },
        );
      case 'number':
        return TextFormField(
          initialValue: _formValues[stateKey],
          keyboardType:
              const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(
              labelText: label, border: const OutlineInputBorder()),
          onChanged: (value) => _formValues[stateKey] = value,
        );
      default:
        return TextFormField(
          initialValue: _formValues[stateKey],
          decoration: InputDecoration(
              labelText: label, border: const OutlineInputBorder()),
          minLines: input == 'multiline' ? 3 : 1,
          maxLines: input == 'multiline' ? 5 : 1,
          onChanged: (value) => _formValues[stateKey] = value,
        );
    }
  }

  Future<void> _submitForm(
    int componentIndex,
    Map<String, Object?> submit,
    List<Map<String, Object?>> fields,
  ) async {
    final tool = submit['tool'] as String;
    final input = <String, Object?>{
      // add_record forms name the collection they write to.
      if (submit['collection'] is String)
        'collection': submit['collection'],
    };
    for (final field in fields) {
      final name = field['name'] as String;
      final value = _formValues['$componentIndex:$name'];
      if (value != null && value.trim().isNotEmpty) {
        // Number inputs travel as numbers; everything else as trimmed text.
        input[name] = field['input'] == 'number'
            ? (num.tryParse(value.trim()) ?? value.trim())
            : value.trim();
      } else if (field['required'] == true) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text("'${field['label'] ?? name}' is required")));
        return;
      }
    }
    final messenger = ScaffoldMessenger.of(context);
    final result =
        await ref.read(toolRegistryProvider).execute(tool, input);
    messenger.showSnackBar(SnackBar(
        content: Text(result.success
            ? 'Saved.'
            : 'Could not save: ${result.error}')));
    if (result.success) {
      setState(() => _formValues
          .removeWhere((key, _) => key.startsWith('$componentIndex:')));
      ref.invalidate(_screenDataProvider(widget.screenKey));
    }
  }

  /// Kanban-style columns grouped by the status column.
  Widget _renderTaskBoard(
      BuildContext context, List<Map<String, Object?>> rows) {
    const statusOrder = [
      'Pending', 'In Progress', 'Waiting', 'Overdue', 'Completed',
      'Canceled',
    ];
    final groups = <String, List<Map<String, Object?>>>{};
    for (final row in rows) {
      final status = row['status']?.toString() ?? '(none)';
      groups.putIfAbsent(status, () => []).add(row);
    }
    final orderedKeys = [
      ...statusOrder.where(groups.containsKey),
      ...groups.keys.where((k) => !statusOrder.contains(k)),
    ];
    if (orderedKeys.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(child: Text('Nothing to show.')),
      );
    }
    return SizedBox(
      height: 320,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          for (final status in orderedKeys)
            Container(
              width: 220,
              margin: const EdgeInsets.only(right: 10),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color:
                    Theme.of(context).colorScheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.all(4),
                    child: Text(
                        '$status (${groups[status]!.length})',
                        style:
                            Theme.of(context).textTheme.titleSmall),
                  ),
                  Expanded(
                    child: ListView(
                      children: [
                        for (final row in groups[status]!)
                          Card(
                            child: Padding(
                              padding: const EdgeInsets.all(8),
                              child: Text(
                                  row['title']?.toString() ?? '',
                                  maxLines: 3,
                                  overflow: TextOverflow.ellipsis),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// Agenda-style calendar: rows grouped by day of their date column.
  Widget _renderCalendar(
    BuildContext context,
    Map<String, Object?> component,
    List<Map<String, Object?>> rows,
  ) {
    final dateField = component['date_field'] as String?;
    if (dateField == null) return const SizedBox.shrink();

    final byDay = <String, List<Map<String, Object?>>>{};
    for (final row in rows) {
      final raw = row[dateField]?.toString();
      final parsed = raw == null ? null : DateTime.tryParse(raw);
      if (parsed == null) continue;
      final dayKey =
          DateTime(parsed.year, parsed.month, parsed.day).toIso8601String();
      byDay.putIfAbsent(dayKey, () => []).add(row);
    }
    if (byDay.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(child: Text('Nothing scheduled.')),
      );
    }
    final days = byDay.keys.toList()..sort();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final day in days) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 12, 4, 4),
            child: Text(
              DateFormat('EEEE, MMM d').format(DateTime.parse(day)),
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ),
          for (final row in byDay[day]!)
            Card(
              margin: const EdgeInsets.symmetric(vertical: 3),
              child: ListTile(
                dense: true,
                leading: Text(
                  DateFormat('HH:mm').format(
                      DateTime.parse(row[dateField].toString())),
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                title: Text(row['title']?.toString() ?? ''),
              ),
            ),
        ],
      ],
    );
  }

  /// Link tile that opens the URL in the in-app browser.
  Widget _renderWebPreview(
      BuildContext context, Map<String, Object?> component) {
    final url = component['url']?.toString() ?? '';
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: ListTile(
        leading: const Icon(Icons.public),
        title: Text(component['title']?.toString() ?? url),
        subtitle: Text(url, maxLines: 1, overflow: TextOverflow.ellipsis),
        trailing: const Icon(Icons.open_in_new),
        onTap: () async {
          final opened =
              ref.read(browserBridgeProvider).requestOpenUrl(url);
          if (!opened) {
            // Browser not alive yet: persist the tab so it appears when
            // the browser first opens.
            await ref
                .read(browserSessionRepositoryProvider)
                .addTab(url);
          }
          if (context.mounted) context.go('/browser');
        },
      ),
    );
  }

  void _runButtonAction(Map<String, Object?> component) {
    final action =
        ((component['action'] as Map?) ?? const {}).cast<String, Object?>();
    if (action['type'] == 'open_screen') {
      final key = action['screen_key'] as String?;
      if (key == null) return;
      final builtIn = builtInScreenRoutes[key];
      context.push(builtIn ?? '/screen/$key');
    }
  }

  Widget _renderList(
    BuildContext context,
    Map<String, Object?> component,
    List<Map<String, Object?>> rows, {
    String? table,
    UserCollection? collection,
  }) {
    if (rows.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(child: Text('Nothing to show.')),
      );
    }
    final template = ((component['item_template'] as Map?) ?? const {})
        .cast<String, Object?>();
    // Most tables title on `title`; the files table uses `name`. Fall back
    // rather than rendering a screen of blank cards.
    final titleTemplate = template['title']?.toString() ??
        (rows.first.containsKey('title') ? '{{title}}' : '{{name}}');
    final subtitleTemplate = template['subtitle']?.toString();
    final descriptionTemplate = template['description']?.toString();
    final onTap = (component['on_tap'] as Map?)?.cast<String, Object?>();
    final actions = (component['actions'] as List? ?? [])
        .whereType<Map>()
        .map((action) => action.cast<String, Object?>())
        .toList();

    return Column(
      children: [
        for (final row in rows)
          Card(
            margin: const EdgeInsets.symmetric(vertical: 4),
            child: ListTile(
              title:
                  Text(ScreenSchema.renderTemplate(titleTemplate, row)),
              subtitle: _subtitle(
                  subtitleTemplate, descriptionTemplate, row),
              // A tap navigates and never writes: mutating on a stray tap,
              // in a screen the model laid out, is not a thing the user
              // asked for. Changes are always a labelled button.
              onTap: onTap == null
                  ? null
                  : () => _openRow(onTap, row,
                      table: table, collection: collection),
              trailing: actions.isEmpty
                  ? null
                  : Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (final action in actions)
                          IconButton(
                            icon: Icon(
                                _actionIcon(action['icon'] as String?),
                                size: 20),
                            tooltip: action['label']?.toString(),
                            onPressed: () => _runRowAction(action, row,
                                collection: collection),
                          ),
                      ],
                    ),
            ),
          ),
      ],
    );
  }

  Widget _renderTable(
    BuildContext context,
    Map<String, Object?> component,
    List<Map<String, Object?>> rows,
  ) {
    final columns = (component['columns'] as List? ?? [])
        .map((c) => c is Map
            ? (
                field: c['field'].toString(),
                label: (c['label'] ?? c['field']).toString()
              )
            : (field: c.toString(), label: c.toString()))
        .toList();
    if (columns.isEmpty || rows.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(child: Text('Nothing to show.')),
      );
    }
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(
        columns: [
          for (final column in columns)
            DataColumn(label: Text(column.label)),
        ],
        rows: [
          for (final row in rows)
            DataRow(cells: [
              for (final column in columns)
                DataCell(Text(
                  row[column.field]?.toString() ?? '',
                  overflow: TextOverflow.ellipsis,
                )),
            ]),
        ],
      ),
    );
  }

  /// Minimal dependency-free bar chart: counts of rows per group_by value.
  Widget _renderBarChart(
    BuildContext context,
    Map<String, Object?> component,
    List<Map<String, Object?>> rows,
  ) {
    final groupBy = component['group_by'] as String?;
    if (groupBy == null || rows.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(child: Text('Nothing to chart.')),
      );
    }
    final counts = <String, int>{};
    for (final row in rows) {
      final key = row[groupBy]?.toString() ?? '(none)';
      counts[key] = (counts[key] ?? 0) + 1;
    }
    final maxCount =
        counts.values.fold<int>(1, (a, b) => a > b ? a : b);
    final color = Theme.of(context).colorScheme.primary;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (component['title'] != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(component['title'].toString(),
                  style: Theme.of(context).textTheme.titleMedium),
            ),
          for (final entry in counts.entries)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                children: [
                  SizedBox(
                    width: 110,
                    child: Text(entry.key,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall),
                  ),
                  Expanded(
                    child: LayoutBuilder(
                      builder: (context, constraints) => Stack(
                        children: [
                          Container(
                            height: 18,
                            decoration: BoxDecoration(
                              color: color.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(4),
                            ),
                          ),
                          Container(
                            height: 18,
                            width: constraints.maxWidth *
                                (entry.value / maxCount),
                            decoration: BoxDecoration(
                              color: color,
                              borderRadius: BorderRadius.circular(4),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 32,
                    child: Text('${entry.value}',
                        textAlign: TextAlign.end,
                        style: Theme.of(context).textTheme.bodySmall),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget? _subtitle(String? subtitleTemplate, String? descriptionTemplate,
      Map<String, Object?> row) {
    final parts = <String>[
      if (subtitleTemplate != null)
        ScreenSchema.renderTemplate(subtitleTemplate, row),
      if (descriptionTemplate != null)
        ScreenSchema.renderTemplate(descriptionTemplate, row),
    ].where((part) => part.trim().isNotEmpty).toList();
    if (parts.isEmpty) return null;
    return Text(parts.join('\n'),
        maxLines: 3, overflow: TextOverflow.ellipsis);
  }
}

/// One number with its label. Sized to sit three-across on a phone.
class _StatTile extends StatelessWidget {
  const _StatTile({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
      decoration: BoxDecoration(
        color: ExaColors.surfaceHigh,
        borderRadius: BorderRadius.circular(ExaRadii.chip),
        border: Border.all(color: ExaColors.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(value,
              maxLines: 1,
              style: Theme.of(context)
                  .textTheme
                  .headlineSmall
                  ?.copyWith(color: ExaColors.spark)),
          const SizedBox(height: 2),
          Text(label,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  fontSize: 11, color: ExaColors.textSecondary)),
        ],
      ),
    );
  }
}

/// Shown when a stored schema no longer validates - after an app update
/// tightened a rule, or because the model wrote something wrong.
///
/// The alternative was what this screen used to do: render nothing and look
/// finished. Naming the fault is what lets the user ask Exa to fix it.
class _SchemaErrorBanner extends StatelessWidget {
  const _SchemaErrorBanner({required this.error});

  final String error;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: ExaColors.surfaceHigh,
        borderRadius: BorderRadius.circular(ExaRadii.chip),
        border: Border.all(color: ExaColors.warning),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.report_gmailerrorred_outlined,
              size: 18, color: ExaColors.warning),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('This screen could not be built',
                    style: TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                Text(error,
                    style: const TextStyle(
                        fontSize: 12, color: ExaColors.textSecondary)),
                const SizedBox(height: 6),
                const Text('Ask Exa to rebuild it.',
                    style: TextStyle(
                        fontSize: 12, color: ExaColors.textTertiary)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
