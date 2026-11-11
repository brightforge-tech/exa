import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/overlay/overlay_agent_stack.dart';
import '../../services/overlay/overlay_panel_channel.dart';
import '../../shared/theme/exa_theme.dart';

/// Minimal quick-add form in the overlay: title + due date + optional
/// reminder, written straight through the same repositories the agent's
/// `create_task` tool uses (task row, best-effort phone-calendar mirror,
/// scheduled reminder notification, tool-activity audit row).
class QuickTaskPanel extends ConsumerStatefulWidget {
  const QuickTaskPanel({super.key, required this.onDone});

  final VoidCallback onDone;

  @override
  ConsumerState<QuickTaskPanel> createState() => _QuickTaskPanelState();
}

class _QuickTaskPanelState extends ConsumerState<QuickTaskPanel> {
  final _title = TextEditingController();
  final _focusNode = FocusNode();
  DateTime? _dueAt;
  bool _remind = false;
  bool _saving = false;
  bool _saved = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(() {
      ref.read(overlayPanelChannelProvider).setFocusable(_focusNode.hasFocus);
    });
  }

  @override
  void dispose() {
    _title.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  DateTime get _tonight {
    final now = DateTime.now();
    final tonight = DateTime(now.year, now.month, now.day, 19);
    return tonight.isAfter(now)
        ? tonight
        : now.add(const Duration(hours: 1));
  }

  DateTime get _tomorrowMorning {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day + 1, 9);
  }

  Future<void> _pickCustom() async {
    final now = DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: _dueAt ?? now,
      firstDate: now.subtract(const Duration(days: 1)),
      lastDate: now.add(const Duration(days: 365 * 2)),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_dueAt ?? now),
    );
    if (time == null) return;
    setState(() => _dueAt =
        DateTime(date.year, date.month, date.day, time.hour, time.minute));
  }

  Future<void> _save() async {
    final title = _title.text.trim();
    if (title.isEmpty) {
      setState(() => _error = 'Give the task a title');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final task = await ref.read(overlayTaskRepositoryProvider).create(
            title: title,
            dueAt: _dueAt,
            createdBy: 'user',
          );
      // Phone-calendar mirror, exactly like the create_task tool:
      // best-effort and only when the user enabled it in Settings.
      try {
        await ref.read(overlayCalendarSyncProvider).syncTaskIfEnabled(task);
      } catch (_) {}
      final due = _dueAt;
      if (_remind && due != null && due.isAfter(DateTime.now())) {
        final reminder =
            await ref.read(overlayReminderRepositoryProvider).create(
                  title: title,
                  remindAt: due,
                  taskId: task.id,
                  createdBy: 'user',
                );
        await ref
            .read(overlayNotificationsProvider)
            .scheduleReminder(reminder);
      }
      // Audit trail: no agent turn ran, but the activity log should still
      // show what the overlay did.
      try {
        await ref.read(overlayToolCallRepositoryProvider).log(
              toolName: 'quick_add_task',
              inputJson: jsonEncode({
                'title': title,
                if (due != null) 'due_at': due.toIso8601String(),
                'remind': _remind,
                'source': 'overlay',
              }),
              status: 'success',
            );
      } catch (_) {}
      if (!mounted) return;
      setState(() => _saved = true);
      await ref.read(overlayPanelChannelProvider).setFocusable(false);
      await Future.delayed(const Duration(milliseconds: 700));
      if (mounted) widget.onDone();
    } catch (e) {
      if (mounted) {
        setState(() => _error = 'Could not save the task: $e');
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_saved) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.check_circle, color: ExaColors.success, size: 42),
            SizedBox(height: 8),
            Text('Task created'),
          ],
        ),
      );
    }
    final formatter = MaterialLocalizations.of(context);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        GestureDetector(
          onTapDown: (_) =>
              ref.read(overlayPanelChannelProvider).setFocusable(true),
          child: TextField(
            controller: _title,
            focusNode: _focusNode,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _save(),
            decoration: const InputDecoration(
              labelText: 'Task',
              hintText: 'What needs doing?',
              border: OutlineInputBorder(),
            ),
          ),
        ),
        const SizedBox(height: 14),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            ChoiceChip(
              label: const Text('No due date'),
              selected: _dueAt == null,
              onSelected: (_) => setState(() {
                _dueAt = null;
                _remind = false;
              }),
            ),
            ChoiceChip(
              label: const Text('Tonight'),
              selected: false,
              onSelected: (_) => setState(() => _dueAt = _tonight),
            ),
            ChoiceChip(
              label: const Text('Tomorrow 9:00'),
              selected: false,
              onSelected: (_) => setState(() => _dueAt = _tomorrowMorning),
            ),
            ChoiceChip(
              label: const Text('Pick…'),
              selected: false,
              onSelected: (_) => _pickCustom(),
            ),
          ],
        ),
        if (_dueAt != null) ...[
          const SizedBox(height: 8),
          Text(
            'Due ${formatter.formatMediumDate(_dueAt!)} at '
            '${formatter.formatTimeOfDay(TimeOfDay.fromDateTime(_dueAt!))}',
            style: const TextStyle(color: ExaColors.textSecondary),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Remind me then'),
            value: _remind,
            onChanged: (value) => setState(() => _remind = value),
          ),
        ],
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(_error!,
                style: const TextStyle(color: ExaColors.error)),
          ),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: _saving ? null : _save,
          icon: _saving
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.add_task),
          label: const Text('Create task'),
        ),
      ],
    );
  }
}
