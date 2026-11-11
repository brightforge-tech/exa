import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../data/models/task_item.dart';
import '../../shared/theme/exa_theme.dart';
import 'transcript_analysis.dart';

/// Review step between "the model read the transcript" and "these are tasks".
///
/// Extraction is a guess: it invents work that was only discussed, misses the
/// obliquely-phrased ask, and mis-hears words the recognizer already mangled.
/// So nothing is created until the user has seen each candidate next to the
/// words it came from, unticked what is wrong, and fixed what is close. Pops
/// with the approved (and possibly edited) tasks, or null on cancel.
Future<List<ExtractedTask>?> showTaskReviewSheet(
  BuildContext context,
  List<ExtractedTask> candidates,
) {
  return showModalBottomSheet<List<ExtractedTask>>(
    context: context,
    isScrollControlled: true,
    backgroundColor: ExaColors.surface,
    shape: const RoundedRectangleBorder(
      borderRadius:
          BorderRadius.vertical(top: Radius.circular(ExaRadii.sheet)),
    ),
    builder: (_) => _TaskReviewSheet(candidates: candidates),
  );
}

class _TaskReviewSheet extends StatefulWidget {
  const _TaskReviewSheet({required this.candidates});

  final List<ExtractedTask> candidates;

  @override
  State<_TaskReviewSheet> createState() => _TaskReviewSheetState();
}

class _TaskReviewSheetState extends State<_TaskReviewSheet> {
  late final List<bool> _approved =
      List<bool>.filled(widget.candidates.length, true);
  late final List<TextEditingController> _titles = widget.candidates
      .map((candidate) => TextEditingController(text: candidate.title))
      .toList();

  @override
  void dispose() {
    for (final controller in _titles) {
      controller.dispose();
    }
    super.dispose();
  }

  int get _approvedCount => _approved.where((value) => value).length;

  void _cyclePriority(int index) {
    const priorities = TaskItem.priorities;
    final next =
        (priorities.indexOf(widget.candidates[index].priority) + 1) %
            priorities.length;
    setState(() => widget.candidates[index].priority = priorities[next]);
  }

  Future<void> _pickDue(int index) async {
    final candidate = widget.candidates[index];
    final now = DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: candidate.dueAt ?? now,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 5),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(
          candidate.dueAt ?? DateTime(now.year, now.month, now.day, 9)),
    );
    if (!mounted) return;
    setState(() {
      candidate.dueAt = DateTime(date.year, date.month, date.day,
          time?.hour ?? 9, time?.minute ?? 0);
    });
  }

  void _submit() {
    final approved = <ExtractedTask>[];
    for (var index = 0; index < widget.candidates.length; index++) {
      if (!_approved[index]) continue;
      final title = _titles[index].text.trim();
      if (title.isEmpty) continue;
      widget.candidates[index].title = title;
      approved.add(widget.candidates[index]);
    }
    Navigator.of(context).pop(approved);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      // Lift the sheet clear of the keyboard while a title is being edited.
      padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: ConstrainedBox(
        constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.85),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 12),
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: ExaColors.outline,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
              child: Row(
                children: [
                  const Icon(Icons.checklist, size: 18,
                      color: ExaColors.spark),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      widget.candidates.length == 1
                          ? '1 possible task'
                          : '${widget.candidates.length} possible tasks',
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Untick anything that was only talk. Tap a title to reword '
                  'it, or the chips to set priority and a due date.',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: ExaColors.textSecondary),
                ),
              ),
            ),
            const Divider(height: 1),
            Flexible(
              child: ListView.separated(
                padding: const EdgeInsets.symmetric(vertical: 4),
                shrinkWrap: true,
                itemCount: widget.candidates.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, index) => _buildRow(index),
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
              child: Row(
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                  const Spacer(),
                  FilledButton.icon(
                    onPressed: _approvedCount == 0 ? null : _submit,
                    icon: const Icon(Icons.add_task, size: 18),
                    label: Text(_approvedCount == 1
                        ? 'Create 1 task'
                        : 'Create $_approvedCount tasks'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRow(int index) {
    final theme = Theme.of(context);
    final candidate = widget.candidates[index];
    final approved = _approved[index];
    return Opacity(
      // Rejected rows stay readable but visibly out of the running.
      opacity: approved ? 1 : 0.45,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 8, 16, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Checkbox(
              value: approved,
              onChanged: (value) =>
                  setState(() => _approved[index] = value ?? false),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: _titles[index],
                    enabled: approved,
                    maxLines: null,
                    style: theme.textTheme.bodyLarge,
                    decoration: const InputDecoration(
                      isDense: true,
                      filled: false,
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      disabledBorder: InputBorder.none,
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                  if (candidate.details != null) ...[
                    const SizedBox(height: 2),
                    Text(candidate.details!,
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: ExaColors.textSecondary)),
                  ],
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      _chip(
                        label: candidate.priority,
                        icon: Icons.flag_outlined,
                        onTap: approved ? () => _cyclePriority(index) : null,
                        highlighted: candidate.priority == 'High' ||
                            candidate.priority == 'Urgent',
                      ),
                      _chip(
                        label: candidate.dueAt == null
                            ? 'No due date'
                            : DateFormat('MMM d, HH:mm')
                                .format(candidate.dueAt!),
                        icon: Icons.event_outlined,
                        onTap: approved ? () => _pickDue(index) : null,
                        onClear: candidate.dueAt == null || !approved
                            ? null
                            : () => setState(() => candidate.dueAt = null),
                        highlighted: candidate.dueAt != null,
                      ),
                    ],
                  ),
                  if (candidate.quote != null) ...[
                    const SizedBox(height: 8),
                    // The receipt: what was actually said. Without it the user
                    // has no way to tell an extracted task from an imagined
                    // one, which is the whole risk of this feature.
                    Container(
                      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
                      decoration: BoxDecoration(
                        color: ExaColors.surfaceHigh,
                        borderRadius: BorderRadius.circular(ExaRadii.chip),
                        border: const Border(
                          left: BorderSide(color: ExaColors.accent, width: 2),
                        ),
                      ),
                      child: Text(
                        '“${candidate.quote}”',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: ExaColors.textSecondary,
                          fontStyle: FontStyle.italic,
                          height: 1.35,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _chip({
    required String label,
    required IconData icon,
    required VoidCallback? onTap,
    VoidCallback? onClear,
    bool highlighted = false,
  }) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(ExaRadii.chip),
      child: Container(
        padding: const EdgeInsets.fromLTRB(10, 6, 8, 6),
        decoration: BoxDecoration(
          color: ExaColors.surfaceHighest,
          borderRadius: BorderRadius.circular(ExaRadii.chip),
          border: Border.all(
              color: highlighted ? ExaColors.accent : ExaColors.outline),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon,
                size: 14,
                color: highlighted
                    ? ExaColors.spark
                    : ExaColors.textSecondary),
            const SizedBox(width: 6),
            Text(label,
                style: theme.textTheme.labelMedium
                    ?.copyWith(color: ExaColors.textPrimary)),
            if (onClear != null) ...[
              const SizedBox(width: 2),
              InkWell(
                onTap: onClear,
                borderRadius: BorderRadius.circular(10),
                child: const Padding(
                  padding: EdgeInsets.all(2),
                  child: Icon(Icons.close,
                      size: 13, color: ExaColors.textTertiary),
                ),
              ),
            ] else
              const SizedBox(width: 2),
          ],
        ),
      ),
    );
  }
}
