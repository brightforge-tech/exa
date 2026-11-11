import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../data/models/agent_datetime_label.dart';
import '../../data/models/user_collection.dart';
import '../../shared/providers.dart';

/// One row of a dynamic screen, full-screen - what a `view_record` on_tap
/// opens.
///
/// This is the difference between "a list of truncated subtitles" and a
/// feature: a note is readable here in full, and when the row belongs to an
/// agent-defined collection it is also editable and deletable - the delete
/// confirmation that a row button could never show has a whole page to ask
/// from.
class RecordDetailPage extends ConsumerStatefulWidget {
  const RecordDetailPage({
    super.key,
    required this.table,
    required this.row,
    this.collection,
    this.onChanged,
  });

  /// Built-in table name or collection name the row came from.
  final String table;
  final Map<String, Object?> row;

  /// Set when [table] is an agent-defined collection - which is also what
  /// unlocks editing and deleting.
  final UserCollection? collection;

  /// Called after this page changes data, so the screen behind it can
  /// refresh.
  final VoidCallback? onChanged;

  @override
  ConsumerState<RecordDetailPage> createState() => _RecordDetailPageState();
}

class _RecordDetailPageState extends ConsumerState<RecordDetailPage> {
  late Map<String, Object?> _row;
  bool _editing = false;

  /// Draft values while editing, keyed by field name.
  final Map<String, Object?> _draft = {};

  @override
  void initState() {
    super.initState();
    _row = Map.of(widget.row);
  }

  /// Long-text columns rendered as the body, in full.
  List<String> get _bodyFields {
    final collection = widget.collection;
    if (collection != null) {
      return [
        for (final field in collection.fields)
          if (field.type == 'multiline') field.name,
      ];
    }
    return switch (widget.table) {
      'attachments' => const ['summary', 'extracted_text'],
      _ => const ['description'],
    };
  }

  String get _title {
    final collection = widget.collection;
    if (collection != null) {
      for (final field in collection.fields) {
        if (field.type == 'text' && _row[field.name] != null) {
          return '${_row[field.name]}';
        }
      }
    }
    return '${_row['title'] ?? _row['name'] ?? widget.collection?.title ?? ''}';
  }

  String _formatted(Object? value) {
    if (value == null) return '';
    final text = value.toString();
    final parsed = DateTime.tryParse(text);
    if (parsed == null || !text.contains('-')) return text;
    return parsed.hour == 0 && parsed.minute == 0
        ? agentDateLabel(parsed)
        : agentDateTimeLabel(parsed);
  }

  Future<void> _saveEdits() async {
    final collection = widget.collection!;
    final changed = <String, Object?>{};
    for (final entry in _draft.entries) {
      if (entry.value != _row[entry.key]) changed[entry.key] = entry.value;
    }
    if (changed.isEmpty) {
      setState(() => _editing = false);
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    final result = await ref.read(toolRegistryProvider).execute(
        'update_record',
        {'collection': collection.name, 'id': _row['id'], ...changed});
    if (!mounted) return;
    if (result.success) {
      setState(() {
        _row = ((result.data as Map?)?['record'] as Map?)
                ?.cast<String, Object?>() ??
            {..._row, ...changed};
        _editing = false;
      });
      widget.onChanged?.call();
    } else {
      messenger.showSnackBar(
          SnackBar(content: Text('Could not save: ${result.error}')));
    }
  }

  Future<void> _confirmDelete() async {
    final collection = widget.collection!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Delete this ${collection.title.toLowerCase()} entry?'),
        content: const Text('This entry goes for good.'),
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
    if (confirmed != true || !mounted) return;
    // The dialog above IS the confirmation the destructive tool would ask
    // for, so this goes straight to the repository - same pattern as
    // deleting a screen.
    await ref.read(userCollectionRepositoryProvider).deleteRecord(
        collection: collection.name, id: '${_row['id']}');
    widget.onChanged?.call();
    if (mounted) await Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final collection = widget.collection;
    final editable = collection != null;

    return Scaffold(
      appBar: AppBar(
        title: Text(_title, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          if (editable && !_editing)
            IconButton(
              tooltip: 'Edit',
              icon: const Icon(Icons.edit_outlined),
              onPressed: () => setState(() {
                _editing = true;
                _draft
                  ..clear()
                  ..addEntries([
                    for (final field in collection.fields)
                      MapEntry(field.name, _row[field.name]),
                  ]);
              }),
            ),
          if (editable && !_editing)
            IconButton(
              tooltip: 'Delete',
              icon: const Icon(Icons.delete_outline),
              onPressed: _confirmDelete,
            ),
          if (_editing)
            TextButton(onPressed: _saveEdits, child: const Text('Save')),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: _editing && collection != null
            ? [
                for (final field in collection.fields)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: _FieldEditor(
                      field: field,
                      value: _draft[field.name],
                      onChanged: (value) => _draft[field.name] = value,
                    ),
                  ),
              ]
            : _readOnlyChildren(context),
      ),
    );
  }

  List<Widget> _readOnlyChildren(BuildContext context) {
    final theme = Theme.of(context);
    final bodyFields = _bodyFields;
    final shown = <String>{};

    final children = <Widget>[];
    for (final field in bodyFields) {
      final value = _row[field];
      if (value == null || '$value'.trim().isEmpty) continue;
      shown.add(field);
      children.add(Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: SelectableText('$value', style: theme.textTheme.bodyLarge),
      ));
    }

    // Everything else, labelled - except identity/plumbing and whatever
    // already appears as the page title or body.
    final skip = {
      ...shown, 'id', 'title', 'name', 'file_path', 'created_at',
      'updated_at',
    };
    for (final entry in _row.entries) {
      if (skip.contains(entry.key) || entry.value == null) continue;
      final text = _formatted(entry.value);
      if (text.trim().isEmpty) continue;
      children.add(ListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        title: Text(entry.key.replaceAll('_', ' '),
            style: theme.textTheme.labelMedium),
        subtitle: SelectableText(text, style: theme.textTheme.bodyMedium),
      ));
    }

    final created = _formatted(_row['created_at']);
    final updated = _formatted(_row['updated_at']);
    if (created.isNotEmpty || updated.isNotEmpty) {
      children.add(Padding(
        padding: const EdgeInsets.only(top: 16),
        child: Text(
          [
            if (created.isNotEmpty) 'Created $created',
            if (updated.isNotEmpty && updated != created)
              'Updated $updated',
          ].join(' · '),
          style: theme.textTheme.bodySmall,
        ),
      ));
    }
    return children;
  }
}

/// One editable field, typed by its collection definition.
class _FieldEditor extends StatelessWidget {
  const _FieldEditor({
    required this.field,
    required this.value,
    required this.onChanged,
  });

  final CollectionField field;
  final Object? value;
  final ValueChanged<Object?> onChanged;

  String get _label => field.name.replaceAll('_', ' ');

  @override
  Widget build(BuildContext context) {
    switch (field.type) {
      case 'select':
        return DropdownButtonFormField<String>(
          initialValue:
              field.options.contains('$value') ? '$value' : null,
          decoration: InputDecoration(
              labelText: _label, border: const OutlineInputBorder()),
          items: [
            for (final option in field.options)
              DropdownMenuItem(value: option, child: Text(option)),
          ],
          onChanged: onChanged,
        );
      case 'datetime':
        final current = DateTime.tryParse('${value ?? ''}');
        return OutlinedButton.icon(
          icon: const Icon(Icons.event),
          label: Text(current == null
              ? _label
              : '$_label: ${DateFormat('MMM d, HH:mm').format(current)}'),
          onPressed: () async {
            final date = await showDatePicker(
              context: context,
              initialDate: current ?? DateTime.now(),
              firstDate: DateTime(2020),
              lastDate: DateTime(2100),
            );
            if (date == null || !context.mounted) return;
            final time = await showTimePicker(
                context: context,
                initialTime: current == null
                    ? TimeOfDay.now()
                    : TimeOfDay.fromDateTime(current));
            onChanged(DateTime(date.year, date.month, date.day,
                    time?.hour ?? 9, time?.minute ?? 0)
                .toIso8601String());
          },
        );
      case 'number':
        return TextFormField(
          initialValue: '${value ?? ''}',
          keyboardType:
              const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(
              labelText: _label, border: const OutlineInputBorder()),
          onChanged: (text) => onChanged(num.tryParse(text) ?? text),
        );
      default:
        final multiline = field.type == 'multiline';
        return TextFormField(
          initialValue: '${value ?? ''}',
          minLines: multiline ? 5 : 1,
          maxLines: multiline ? 14 : 1,
          decoration: InputDecoration(
              labelText: _label, border: const OutlineInputBorder()),
          onChanged: onChanged,
        );
    }
  }
}
